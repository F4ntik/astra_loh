#include <amxmodx>
#include <reapi>
#include <xs>

#include <retake>

// Требуется AMX Mod X 1.10+

#define PLUGIN_NAME "Retake Core"
#define PLUGIN_VERSION "0.1"
#define PLUGIN_AUTHOR "Asura"

#define TASK_RESPAWN 90000
#define TASK_PREPARE 70000

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
new g_menu_choose;

new queue_ingame[MAX_PLAYERS + 2];
new queue_ingame_size = 0;

new g_is_game_prepare = false;
new g_task_prepare;

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
  RegisterHookChain(RG_RoundEnd, "on_round_end_post", true);

  RegisterHookChain(RG_CSGameRules_GetPlayerSpawnSpot, "on_player_spawn_pre", false);

  forw_round_start = CreateMultiForward("retake_round_start", ET_IGNORE);
  forw_round_end = CreateMultiForward("retake_round_end", ET_IGNORE);

  for(new i = 0; i <= MAX_PLAYERS; i++)
  {
    g_players_state[i] = P_NONE;
  }
}

public plugin_cfg()
{
  start_warmup();
  create_menu();
}

public client_putinserver(id)
{
  if (is_user_bot(id) || is_user_hltv(id)) return;

  g_players_state[id] = P_NONE;

  set_task(0.25, "task_show_choose_menu", id);
}

public client_disconnected(id, bool:drop, message[], maxlen)
{
  g_players_state[id] = P_NONE;
  remove_task(id);
  queue_remove(id);

  check_retake_conditions();
}

start_warmup()
{
  g_is_game_prepare = false;
  g_game_state = GS_WARMUP

  m_round_ct = 0;
  m_round_t = 0;

  set_cvar_num("mp_roundtime", 0);
  set_cvar_num("mp_freezetime", 0);
  set_cvar_num("mp_buytime", -1);
  set_cvar_num("mp_startmoney", 16000);
  set_cvar_string("mp_round_infinite", "1");
  set_cvar_float("mp_respawn_immunitytime", 3.0);
  set_cvar_num("mp_forcerespawn", 1);

  server_cmd("sv_restartround 1"); // Применяем

  client_print_color(0, print_team_blue , "^4[RETAKE] ^1Warmup started!");
}

prepare_retake()
{
  if (g_is_game_prepare) return;

  g_is_game_prepare = true;
  
  new time = get_pcvar_num(cvar_prepare_time);

  client_print_color(0, print_team_blue , "^4[RETAKE] ^1Retake will start in ^4%d s", time);

  // g_task_prepare = TASK_PREPARE + time;
  set_task(float(time), "task_prepare", TASK_PREPARE);
}

cancel_prepare()
{
  if (!g_is_game_prepare) return;
  g_is_game_prepare = false;

  remove_task(g_task_prepare);
}

public task_prepare(big_time)
{
  if (!g_is_game_prepare) return;
  if (g_game_state != GS_WARMUP) return;

  start_retake();

  // new time = big_time - TASK_PREPARE - 5;

  // if (time <= 0 && g_is_game_prepare && g_game_state == GS_WARMUP)
  // {
  //   start_retake();
  // }
  // else if (g_is_game_prepare)
  // {
  //   client_print_color(0, print_team_blue , "^4[RETAKE] ^1Retake will start in ^4%d s", time);
  //   g_task_prepare = TASK_PREPARE + time;
  //   set_task(5.0, "task_prepare", g_task_prepare);
  // }
}

start_retake()
{
  cancel_prepare();
  g_game_state = GS_RETAKE;

  for (new i = 1; i <= MAX_PLAYERS; i++)
  {
    remove_task(TASK_RESPAWN + i);
  }

  new Float:seconds = float(get_pcvar_num(cvar_roundtime));

  set_cvar_float("mp_roundtime", seconds / 60.0);
  set_cvar_num("mp_freezetime", get_pcvar_num(cvar_freezetime));
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

  log_amx("MENU ID: %d", g_menu_choose);

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
  if (g_players_state[player_id] == P_INGAME || g_players_state[player_id] == P_QUEUE) return;

  if (get_ingame_players() >= get_pcvar_num(cvar_max_players))
  {
    g_players_state[player_id] = P_QUEUE;
    queue_push(player_id);

    return;
  }

  init_player(player_id);

  check_retake_conditions();
}

public init_player(player_id)
{
  if (player_id < 0 || player_id > MAX_PLAYERS) return;
  if (!is_user_connected(player_id)) return;

  g_players_state[player_id] = P_INGAME;

  if (is_user_alive(player_id))
    user_kill(player_id, 1);

  rg_set_user_team(player_id, choose_player_team());

  set_member(player_id, m_iMenu, Menu_OFF); 
  set_member(player_id, m_iJoiningState, GETINTOGAME);
  
  set_task(0.5, "respawn_player", TASK_RESPAWN + player_id);
}

choose_player_team()
{
  new num_t = get_member_game(m_iNumTerrorist);
  new num_ct = get_member_game(m_iNumCT);

  if (num_ct <= num_t) 
  {
    return TEAM_CT;
  }
  else
  {
    return TEAM_TERRORIST;
  }
}

public respawn_player(player_id)
{
  if (!is_user_connected(player_id)) return;

  rg_round_respawn(player_id);
}

// QUEUE

queue_push(player_id)
{
  queue_ingame[queue_ingame_size] = player_id;
  queue_ingame_size++;
}

queue_pop()
{
  if (queue_ingame_size == 0) return -1;

  new ret_id = queue_ingame[0];

  for (new i = 0; i < queue_ingame_size; i++)
  {
    queue_ingame[i] = queue_ingame[i+1];
  }

  queue_ingame_size--;

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

  for (new i = index; i < queue_ingame_size; i++)
  {
    queue_ingame[i] = queue_ingame[i+1];
  }

  queue_ingame_size--;
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
  for (new i = 0; i <= MAX_PLAYERS; i++)
  {
    if (g_players_state[i] == P_INGAME) counter++;
  }

  return counter;
}

check_retake_conditions()
{
  new counter = get_ingame_players();

  // Проверяем на минимум сначала
  if(counter >= get_pcvar_num(cvar_min_players))
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

  // Проверяем на максимум. Запускаем по одному
  if(counter < get_pcvar_num(cvar_max_players))
  {
    new new_player_id = queue_pop();

    if (new_player_id == -1) return;

    init_player(new_player_id);

    check_retake_conditions();
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

  if (is_user_alive(player_id))
    user_kill(player_id, 1);

  rg_set_user_team(player_id, TEAM_SPECTATOR);

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
  if (g_game_state == GS_WARMUP) {
    set_member(player_id, m_iAccount, 16000);
    return;
  }
}

public on_round_restart_pre()
{
  if (g_game_state != GS_RETAKE) return;

  choose_plantsite();

  ExecuteForward(forw_round_start);

  new rounds_num = m_round_t + m_round_ct + 1;
  client_print_color(0, print_team_blue , "^4[RETAKE] ^1Round %d | CT %d : %d T", rounds_num, m_round_ct, m_round_t);
}

choose_plantsite()
{
  new chooser = get_pcvar_num(cvar_plantsite_chooser);

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

public on_player_spawn_pre(player_id)
{
  if (g_game_state != GS_RETAKE) return HC_CONTINUE;
  if (g_players_state[player_id] != P_INGAME) return HC_CONTINUE; // А по хорошему узнать почему он спавнится

  new player_team = get_user_team(player_id);

  if (player_team == -1) return HC_CONTINUE;

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
    log_amx("retake spawns not found");
    return HC_CONTINUE; 
  }

  set_entvar(player_id, var_origin, new_origin);

  set_entvar(player_id, var_angles, new_angles);
  set_entvar(player_id, var_v_angle, new_angles);
  set_entvar(player_id, var_fixangle, 1.0);

  new Float:zero[3] = {0.0, 0.0, 0.0}; 
  set_entvar(player_id, var_velocity, zero);
  set_entvar(player_id, var_basevelocity, zero);

  log_amx("spawn: %f, %f, %f", new_origin[0], new_origin[1], new_origin[2]);

  SetHookChainReturn(ATYPE_INTEGER, 1); 
  return HC_BREAK;
}

public on_round_end_post(status, event, delay)
{
  if (g_game_state != GS_RETAKE) return;

  if (status == WINSTATUS_TERRORISTS) m_round_t++;
  if (status == WINSTATUS_CTS) m_round_ct++;

  ExecuteForward(forw_round_end);

  if (m_round_t >= get_pcvar_num(cvar_win_round))
  {
    client_print_color(0, print_team_red , "^4[RETAKE] ^3Terrorists ^1win! | CT %d : %d T", m_round_ct, m_round_t);

    start_warmup();
  }
  else if (m_round_ct >= get_pcvar_num(cvar_win_round))
  {
    client_print_color(0, print_team_blue , "^4[RETAKE] ^3Counter-Terrorists ^1win! | CT %d : %d T", m_round_ct, m_round_t );

    start_warmup();
  }
}