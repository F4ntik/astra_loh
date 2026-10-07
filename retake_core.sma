#include <amxmodx>
#include <reapi>
#include <engine>

#include <retake>

// Требуется AMX Mod X 1.10+

#define PLUGIN_NAME "Retake Core"
#define PLUGIN_VERSION "0.1"
#define PLUGIN_AUTHOR "Asura"

#define TASK_RESPAWN 90000
#define TASK_PREPARE 70000
#define TASK_CHECK 70001

// PLUGIN_STATE
enum 
{
  GS_WARMUP,
  GS_RETAKE,
  GS_NONE
}

new g_game_state = GS_NONE;

// PLAYER STATE
enum
{
  P_INGAME,
  P_QUEUE,
  P_SPECTATE,
  P_NONE
}

new g_players_state[MAX_PLAYERS + 1];

// ---
new g_menu_choose = -1;

new queue_ingame[MAX_PLAYERS + 2];
new queue_ingame_size = 0;

new bool:g_is_game_prepare;
new bool:g_round_scored;
new bool:g_restarting;

// RETAKE GAME MEMBERS AND STATE
enum
{
  PLANTSITE_A,
  PLANTSITE_B
}

new m_round_ct = 0;
new m_round_t = 0;

new m_plantsite = PLANTSITE_A;

// RETAKE CVARS
new cvar_min_players;
new cvar_max_players;
new cvar_roundtime;
new cvar_freezetime;
new cvar_prepare_time;
new cvar_win_round;
new cvar_plantsite_chooser;

// FORWARDS
new forw_round_start;
new forw_round_end;

// SAVED SERVER CVARS
// new sv_cvar_freezetime; // Не нужно сохртанять. Т.к. он все равно при старте свой запустит из настроек retake
// new sv_cvar_roundtime; // Тоже самое что и фризтайм
// new sv_cvar_buytime; // Тоже самое что и фризтайм
// new sv_cvar_startmoney; // В ретейке мообще деньги не нужны

public plugin_init()
{
  register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

  cvar_min_players = register_cvar("retake_min_players", "2");
  // retake_max_players для определения макс колва игроков в тиме делит на 2. А при нечетном отдавать +1 к CT
  cvar_max_players = register_cvar("retake_max_players", "10");
  cvar_roundtime = register_cvar("retake_roundtime",   "45");
  cvar_freezetime = register_cvar("retake_freezetime",  "5");
  cvar_prepare_time = register_cvar("retake_prepare_time",  "10");
  cvar_win_round = register_cvar("retake_win_round",  "13");

  // 0 - Через один
  // 1 - Случайным образом
  // 2 - Постоянно A
  // 3 - Постоянно B
  cvar_plantsite_chooser = register_cvar("retake_plantsite_chooser",  "0");

  register_clcmd("chooseteam", "force_retake_menu");
  register_clcmd("jointeam",   "force_retake_menu");

  RegisterHookChain(RG_CBasePlayer_Spawn, "on_player_spawn", true);

  RegisterHookChain(RG_CSGameRules_RestartRound, "on_round_restart_pre", false);
  RegisterHookChain(RG_CSGameRules_RestartRound, "on_round_restart_post", true);
  RegisterHookChain(RG_RoundEnd, "on_round_end_post", true);

  register_srvcmd("retake_status", "cmd_retake_status");

  hook_cvar_change(cvar_min_players, "on_limits_changed");
  hook_cvar_change(cvar_max_players, "on_limits_changed");
  hook_cvar_change(cvar_plantsite_chooser, "on_limits_changed");

  forw_round_start = CreateMultiForward("retake_round_start", ET_IGNORE);
  forw_round_end = CreateMultiForward("retake_round_end", ET_IGNORE);

  for(new i = 0; i <= MAX_PLAYERS; i++)
  {
    g_players_state[i] = P_NONE;
  }
}

public plugin_cfg()
{
  create_menu();
  start_warmup();
}

public client_putinserver(id)
{
  g_players_state[id] = P_NONE;
  remove_task(TASK_RESPAWN + id);
  if (is_user_bot(id) || is_user_hltv(id)) return;

  set_task(0.25, "task_show_choose_menu", id);
}

public client_disconnected(id, bool:drop, message[], maxlen)
{
  g_players_state[id] = P_NONE;
  remove_task(id);
  remove_task(TASK_RESPAWN + id);
  queue_remove(id);

  check_retake_conditions();
}

start_warmup()
{
  cancel_prepare();
  g_game_state = GS_WARMUP;
  g_round_scored = false;
  m_plantsite = PLANTSITE_B;

  m_round_ct = 0;
  m_round_t = 0;

  set_cvar_num("mp_roundtime", 0);
  set_cvar_num("mp_freezetime", 0);
  set_cvar_num("mp_buytime", -1);
  set_cvar_num("mp_startmoney", 16000);
  set_cvar_string("mp_round_infinite", "1");
  set_cvar_float("mp_respawn_immunitytime", 3.0);
  set_cvar_num("mp_forcerespawn", 1);
  set_cvar_num("mp_autoteambalance", 0);

  server_cmd("sv_restartround 1"); // Применяем

  client_print_color(0, print_team_blue , "^4[RETAKE] ^1Warmup started!");
  remove_task(TASK_CHECK);
  set_task(1.5, "task_check_conditions", TASK_CHECK);
}

prepare_retake()
{
  if (g_is_game_prepare) return;

  g_is_game_prepare = true;
  
  new time = clamp(get_pcvar_num(cvar_prepare_time), 1, 300);

  client_print_color(0, print_team_blue , "^4[RETAKE] ^1Retake will start in ^4%d s", time);

  remove_task(TASK_PREPARE);
  set_task(float(time), "task_prepare", TASK_PREPARE);
}

cancel_prepare()
{
  g_is_game_prepare = false;
  remove_task(TASK_PREPARE);
}

public task_prepare()
{
  if (!g_is_game_prepare) return;
  if (g_game_state != GS_WARMUP) return;

  if (!can_start_retake())
  {
    cancel_prepare();
    return;
  }
  start_retake();
}

start_retake()
{
  cancel_prepare();
  g_game_state = GS_RETAKE;

  for (new i = 1; i <= MAX_PLAYERS; i++)
  {
    remove_task(TASK_RESPAWN + i);
  }

  new Float:seconds = float(clamp(get_pcvar_num(cvar_roundtime), 1, 3600));

  set_cvar_float("mp_roundtime", seconds / 60.0);
  set_cvar_num("mp_freezetime", clamp(get_pcvar_num(cvar_freezetime), 0, 60));
  set_cvar_num("mp_buytime", 0);
  set_cvar_num("mp_startmoney", 0);
  set_cvar_string("mp_round_infinite", "0");
  set_cvar_float("mp_respawn_immunitytime", 0.0);
  set_cvar_num("mp_forcerespawn", 0);

  server_cmd("sv_restartround 1"); // Применяем

  client_print_color(0, print_team_blue , "^4[RETAKE] ^1Retake started!");
}

create_menu()
{
  g_menu_choose = menu_create("^4Retake: ", "choose_menu_handler");

  menu_additem(g_menu_choose, "Join game", "1");
  menu_additem(g_menu_choose, "Spectator mode", "2");

  menu_setprop(g_menu_choose, MPROP_EXIT, MEXIT_NEVER);
}

public choose_menu_handler(player_id, menu_id, item_id)
{
  if (item_id < 0)
  {
    return PLUGIN_HANDLED;
  }

  new data[6];

  menu_item_getinfo(menu_id, item_id, _, data, charsmax(data), _, 0, _);

  new choosed_key = str_to_num(data);

  if (choosed_key == 1) 
  {
    join_choosed(player_id);
  }
  else if (choosed_key == 2)
  {
    spectate_choosed(player_id);
  }

  return PLUGIN_HANDLED;
}

join_choosed(player_id)
{
  if (!is_user_connected(player_id)) return;
  if (g_players_state[player_id] == P_INGAME || g_players_state[player_id] == P_QUEUE) return;

  if (g_game_state == GS_RETAKE || get_ingame_players() >= get_player_limit())
  {
    move_to_spectator(player_id);
    g_players_state[player_id] = P_QUEUE;
    queue_push(player_id);
    client_print_color(player_id, print_team_default,
      "^4[RETAKE] ^1Queued: %d. Waiting for a free place at round start.", queue_ingame_size);
    return;
  }

  init_player(player_id);

  check_retake_conditions();
}

public init_player(player_id)
{
  if (player_id < 1 || player_id > MAX_PLAYERS) return;
  if (!is_user_connected(player_id)) return;

  g_players_state[player_id] = P_INGAME;

  if (is_user_alive(player_id))
    user_kill(player_id, 1);

  rg_set_user_team(player_id, choose_player_team());

  set_member(player_id, m_iMenu, Menu_OFF);
  // PlayerSpawn skips the initial equipment while m_bJustConnected is true.
  // A queued first join is spawned by RestartRound, without GetIntoGame.
  set_member(player_id, m_bJustConnected, false);
  set_member(player_id, m_bNotKilled, false);
  set_member(player_id, m_iJoiningState, g_game_state == GS_WARMUP ? GETINTOGAME : JOINED);
  
  remove_task(TASK_RESPAWN + player_id);
  if (g_game_state == GS_WARMUP)
    set_task(0.5, "respawn_player", TASK_RESPAWN + player_id);
}

TeamName:choose_player_team()
{
  new num_t = count_team(TEAM_TERRORIST);
  new num_ct = count_team(TEAM_CT);

  if (num_ct <= num_t) 
  {
    return TEAM_CT;
  }
  else
  {
    return TEAM_TERRORIST;
  }
}

public respawn_player(task_id)
{
  new player_id = task_id - TASK_RESPAWN;
  if (player_id < 1 || player_id > MAX_PLAYERS) return;
  if (!is_user_connected(player_id)) return;
  if (g_game_state != GS_WARMUP || g_players_state[player_id] != P_INGAME) return;
  if (is_user_alive(player_id)) return;

  rg_round_respawn(player_id);
}

// QUEUE

queue_push(player_id)
{
  if (queue_ingame_size >= MAX_PLAYERS) return;
  for (new i; i < queue_ingame_size; i++)
    if (queue_ingame[i] == player_id) return;
  queue_ingame[queue_ingame_size] = player_id;
  queue_ingame_size++;
}

queue_pop()
{
  if (queue_ingame_size == 0) return -1;

  new ret_id = queue_ingame[0];

  for (new i = 0; i < queue_ingame_size - 1; i++)
  {
    queue_ingame[i] = queue_ingame[i+1];
  }

  queue_ingame[--queue_ingame_size] = 0;

  return ret_id;
}

queue_remove(player_id)
{
  new index = -1;
  for (new i = 0; i < queue_ingame_size; i++)
  {
    if (queue_ingame[i] == player_id)
    {
      index = i;
      break;
    }
  }

  if (index == -1) return;

  for (new i = index; i < queue_ingame_size - 1; i++)
  {
    queue_ingame[i] = queue_ingame[i+1];
  }

  queue_ingame[--queue_ingame_size] = 0;
}

// queue_contain(player_id)
// {
//   for (new i = 0; i < queue_ingame_size; i++)
//   {
//     if (queue_ingame[i] == player_id)  return true;
//   }

//   return false;
// }

// ---

get_ingame_players()
{
  new counter = 0;
  for (new i = 1; i <= MAX_PLAYERS; i++)
  {
    if (is_user_connected(i) && g_players_state[i] == P_INGAME) counter++;
  }

  return counter;
}

check_retake_conditions()
{
  if (g_game_state == GS_NONE) return;
  if (g_game_state == GS_WARMUP) fill_free_places();

  if (can_start_retake())
  {
    if(g_game_state == GS_WARMUP)
    {
      prepare_retake();
    }
  }
  else 
  {
    cancel_prepare();
    if(g_game_state == GS_RETAKE)
    {
      start_warmup();
    }
  }

}

spectate_choosed(player_id)
{
  if (g_players_state[player_id] == P_SPECTATE) return;

  if (g_players_state[player_id] == P_QUEUE)
  {
    queue_remove(player_id);
  }

  g_players_state[player_id] = P_SPECTATE;
  move_to_spectator(player_id);

  check_retake_conditions();
}

public task_show_choose_menu(id)
{
  if (!is_user_connected(id)) return;
  if (g_menu_choose < 0) return;

  menu_display(id, g_menu_choose, 0);
}

public force_retake_menu(id)
{
  if (g_menu_choose < 0) return PLUGIN_HANDLED; 

  menu_display(id, g_menu_choose, 0);

  return PLUGIN_HANDLED;
}

public on_player_spawn(player_id)
{
  if (!is_user_alive(player_id)) return;
  // A warmup restart can spawn the player before the next JoiningThink.
  if (g_players_state[player_id] == P_INGAME)
    set_member(player_id, m_iJoiningState, JOINED);
  if (g_game_state == GS_WARMUP) {
    set_member(player_id, m_iAccount, 16000);
    return;
  }
  if (g_game_state == GS_RETAKE && g_players_state[player_id] == P_INGAME)
    place_retake_player(player_id);
}

public on_round_restart_pre()
{
  if (g_game_state != GS_RETAKE) return;

  g_restarting = true;
  fill_free_places();
  if (!can_start_retake())
  {
    start_warmup();
    return;
  }
  balance_players();
  choose_plantsite();
  retake_map_reset_spawns();
  g_round_scored = false;
}

public on_round_restart_post()
{
  g_restarting = false;
  if (g_game_state != GS_RETAKE) return;
  ExecuteForward(forw_round_start);

  new rounds_num = m_round_t + m_round_ct + 1;
  client_print_color(0, print_team_blue , "^4[RETAKE] ^1Round %d | CT %d : %d T", rounds_num, m_round_ct, m_round_t);
}

choose_plantsite()
{
  new chooser = clamp(get_pcvar_num(cvar_plantsite_chooser), 0, 3);

  if (chooser == 0) // через один
  {
    if (m_plantsite == PLANTSITE_A) m_plantsite = PLANTSITE_B;
    else if (m_plantsite == PLANTSITE_B) m_plantsite = PLANTSITE_A;
  }
  else if (chooser == 1) // случайно
  {
    new rand = random(2);
    if (rand == 0) m_plantsite = PLANTSITE_A;
    else m_plantsite = PLANTSITE_B;
  }
  else if (chooser == 2) // только А
  {
    m_plantsite = PLANTSITE_A;
  }
  else if (chooser == 3) // только B
  {
    m_plantsite = PLANTSITE_B;
  }
}

place_retake_player(player_id)
{
  new TeamName:player_team = get_member(player_id, m_iTeam);

  if (player_team != TEAM_TERRORIST && player_team != TEAM_CT) return;

  new slot;

  if (m_plantsite == PLANTSITE_A)
  {
    if (player_team == TEAM_TERRORIST) slot = SPAWN_T_A;
    if (player_team == TEAM_CT) slot = SPAWN_CT_A;
  }
  else if (m_plantsite == PLANTSITE_B)
  {
    if (player_team == TEAM_TERRORIST) slot = SPAWN_T_B;
    if (player_team == TEAM_CT) slot = SPAWN_CT_B;
  }

  new Float:new_origin[3];
  new Float:new_angles[3];

  if (!retake_map_get_spawn(slot, new_origin, new_angles))
  {
    log_amx("[Retake] No unused spawn for slot %d; returning to warmup.", slot);
    start_warmup();
    return;
  }

  entity_set_origin(player_id, new_origin);

  set_entvar(player_id, var_angles, new_angles);
  set_entvar(player_id, var_v_angle, new_angles);
  set_entvar(player_id, var_fixangle, 1);

  new Float:zero[3] = {0.0, 0.0, 0.0}; 
  set_entvar(player_id, var_velocity, zero);
  set_entvar(player_id, var_basevelocity, zero);

}

public on_round_end_post(WinStatus:status, ScenarioEventEndRound:event, Float:delay)
{
  if (g_game_state != GS_RETAKE || g_restarting || g_round_scored) return;
  // Other plugins may reject RG_RoundEnd; count only an accepted round result.
  if (!GetHookChainReturn(ATYPE_BOOL)) return;
  if (status != WINSTATUS_TERRORISTS && status != WINSTATUS_CTS) return;
  g_round_scored = true;

  if (status == WINSTATUS_TERRORISTS) m_round_t++;
  if (status == WINSTATUS_CTS) m_round_ct++;

  ExecuteForward(forw_round_end);

  if (m_round_t >= clamp(get_pcvar_num(cvar_win_round), 1, 1000))
  {
    client_print_color(0, print_team_red , "^4[RETAKE] ^3Terrorists ^1win! | CT %d : %d T", m_round_ct, m_round_t);

    start_warmup();
  }
  else if (m_round_ct >= clamp(get_pcvar_num(cvar_win_round), 1, 1000))
  {
    client_print_color(0, print_team_blue , "^4[RETAKE] ^3Counter-Terrorists ^1win! | CT %d : %d T", m_round_ct, m_round_t );

    start_warmup();
  }
}

count_team(TeamName:team)
{
  new count;
  for (new id = 1; id <= MAX_PLAYERS; id++)
    if (is_user_connected(id) && g_players_state[id] == P_INGAME &&
        get_member(id, m_iTeam) == team) count++;
  return count;
}

get_player_limit()
{
  new limit = clamp(get_pcvar_num(cvar_max_players), 2, MAX_PLAYERS);
  if (!retake_map_has_config()) return limit;
  new chooser = clamp(get_pcvar_num(cvar_plantsite_chooser), 0, 3);
  new t = retake_map_spawn_count(SPAWN_T_A);
  new ct = retake_map_spawn_count(SPAWN_CT_A);
  if (chooser == 3)
  {
    t = retake_map_spawn_count(SPAWN_T_B);
    ct = retake_map_spawn_count(SPAWN_CT_B);
  }
  else if (chooser != 2)
  {
    t = min(t, retake_map_spawn_count(SPAWN_T_B));
    ct = min(ct, retake_map_spawn_count(SPAWN_CT_B));
  }
  return min(limit, min(t * 2 + 1, ct * 2));
}

bool:can_start_retake()
{
  new count = get_ingame_players();
  return retake_map_has_config() &&
    count >= clamp(get_pcvar_num(cvar_min_players), 2, MAX_PLAYERS) &&
    count <= get_player_limit();
}

fill_free_places()
{
  new limit = get_player_limit();
  // A smaller map/config may have fewer places than the previous warmup.
  for (new id = MAX_PLAYERS; id >= 1 && get_ingame_players() > limit; id--)
  {
    if (!is_user_connected(id) || g_players_state[id] != P_INGAME) continue;
    g_players_state[id] = P_QUEUE;
    move_to_spectator(id);
    queue_push(id);
  }
  while (queue_ingame_size > 0 && get_ingame_players() < limit)
  {
    new id = queue_pop();
    if (id < 1 || id > MAX_PLAYERS || !is_user_connected(id)) continue;
    if (g_players_state[id] != P_QUEUE) continue;
    init_player(id);
  }
}

balance_players()
{
  new desired_ct = (get_ingame_players() + 1) / 2;
  new num_ct = count_team(TEAM_CT);
  for (new id = 1; id <= MAX_PLAYERS && num_ct != desired_ct; id++)
  {
    if (!is_user_connected(id) || g_players_state[id] != P_INGAME) continue;
    new TeamName:team = get_member(id, m_iTeam);
    if (num_ct < desired_ct && team == TEAM_TERRORIST)
    {
      rg_set_user_team(id, TEAM_CT);
      num_ct++;
    }
    else if (num_ct > desired_ct && team == TEAM_CT)
    {
      rg_set_user_team(id, TEAM_TERRORIST);
      num_ct--;
    }
  }
}

move_to_spectator(id)
{
  remove_task(TASK_RESPAWN + id);
  if (is_user_alive(id)) user_kill(id, 1);
  rg_set_user_team(id, TEAM_SPECTATOR);
  set_member(id, m_iMenu, Menu_OFF);
  set_member(id, m_iJoiningState, JOINED);
}

public task_check_conditions()
{
  check_retake_conditions();
}

public retake_map_loaded()
{
  if (g_game_state == GS_NONE) return;
  if (g_game_state == GS_RETAKE) start_warmup();
  else check_retake_conditions();
}

public on_limits_changed(pcvar, const old_value[], const new_value[])
{
  if (g_game_state == GS_NONE) return;
  cancel_prepare();
  remove_task(TASK_CHECK);
  set_task(0.1, "task_check_conditions", TASK_CHECK);
}

public cmd_retake_status()
{
  server_print("[Retake] state=%d players=%d queued=%d minimum=%d capacity=%d config=%d preparing=%d",
    g_game_state, get_ingame_players(), queue_ingame_size,
    clamp(get_pcvar_num(cvar_min_players), 2, MAX_PLAYERS), get_player_limit(),
    retake_map_has_config(), g_is_game_prepare);
  return PLUGIN_HANDLED;
}
