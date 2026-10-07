#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <string>
#include <engine>
#include <retake>
#include <retake_config>

#define PLUGIN_NAME "Retake Editor"
#define PLUGIN_VERSION "0.1.0"
#define PLUGIN_AUTHOR "Retake Project"

#define MAX_SPAWNS RT_MAX_SPAWNS
#define MAX_WALLS RT_MAX_WALLS
#define WALL_NAME_LEN RT_WALL_NAME_LEN

// CVAR
new cvar_max_spawns_per_slot;
new cvar_wall_size;

// Данные спавнов
new Float:g_spawns[SPAWN_SLOTS][MAX_SPAWNS][6];
new g_spawn_count[SPAWN_SLOTS];

// Данные стен
new Float:g_wall_origin[MAX_WALLS][3];
new Float:g_wall_size[MAX_WALLS];
new g_wall_name[MAX_WALLS][WALL_NAME_LEN];
new g_wall_ent[MAX_WALLS];
new g_wall_id[MAX_WALLS];
new g_next_wall_id = 1;
new g_wall_count = 0;

// Состояние редактора
new bool:g_is_editing[MAX_PLAYERS + 1];
new g_edit_plant[MAX_PLAYERS + 1];
new g_edit_team[MAX_PLAYERS + 1];
new g_wall_list_action[MAX_PLAYERS + 1];
new g_rename_wall_id[MAX_PLAYERS + 1];
new g_saved_movetype[MAX_PLAYERS + 1];
new g_editor_menu[MAX_PLAYERS + 1];
new bool:g_config_ready;
new g_config_saved_forward;

new const WALL_MODEL[] = "models/box.mdl";


public plugin_precache()
{
  precache_model(WALL_MODEL);
}


public plugin_init()
{
  register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

  cvar_max_spawns_per_slot = register_cvar("amx_retake_max_spawns_per_slot", "32");
  cvar_wall_size = register_cvar("amx_retake_wall_size", "64");

  register_clcmd("say /retake_editor", "cmd_open_editor");
  register_clcmd("retake_editor_open", "cmd_open_editor");
  register_clcmd("retake_editor_exit", "cmd_exit_editor");
  register_clcmd("retake_editor_save", "cmd_save_config");
  register_clcmd("retake_editor_reload", "cmd_reload_config");
  register_clcmd("retake_editor_rename_input", "cmd_rename_input");

  RegisterHookChain(RG_CBasePlayer_Killed, "player_killed_post", true);
  RegisterHookChain(RG_CBasePlayer_Spawn, "player_spawn_post", true);
  g_config_saved_forward = CreateMultiForward("retake_config_saved", ET_IGNORE);
  for (new id = 1; id <= MAX_PLAYERS; id++)
  {
    g_editor_menu[id] = -1;
  }

  check_configs_dir();
}

public plugin_cfg()
{
  new path[PLATFORM_MAX_PATH], backup[PLATFORM_MAX_PATH];
  get_config_path(path, charsmax(path));
  formatex(backup, charsmax(backup), "%s.bak", path);
  if (!file_exists(path) && file_exists(backup))
  {
    log_amx("[Retake Editor] Main config missing but backup exists. Restore %s to %s before editing.", backup, path);
    return;
  }
  g_config_ready = !file_exists(path) || load_config_from_file();
}

public plugin_end()
{
  for (new id = 1; id <= MAX_PLAYERS; id++)
  {
    stop_editor(id);
  }
  DestroyForward(g_config_saved_forward);
}

public player_killed_post(id)
{
  stop_editor(id);
}

public player_spawn_post(id)
{
  stop_editor(id);
}


public client_disconnected(id, bool:drop, message[], maxlen)
{
  stop_editor(id);
  g_wall_list_action[id] = 0;
  g_edit_plant[id] = 0;
  g_edit_team[id] = 0;
  return PLUGIN_CONTINUE;
}

bool:has_active_editor()
{
  for (new id = 1; id <= MAX_PLAYERS; id++)
  {
    if (g_is_editing[id]) return true;
  }
  return false;
}

stop_editor(id)
{
  if (!g_is_editing[id]) return;
  g_is_editing[id] = false;
  g_rename_wall_id[id] = 0;
  if (is_user_connected(id))
  {
    if (is_user_alive(id) && get_entvar(id, var_movetype) == MOVETYPE_NOCLIP)
    {
      set_entvar(id, var_movetype, g_saved_movetype[id]);
    }
    new old_menu, current_menu;
    player_menu_info(id, old_menu, current_menu);
    if (g_editor_menu[id] != -1 && current_menu == g_editor_menu[id])
    {
      menu_cancel(id);
      show_menu(id, 0, "");
    }
  }
  g_editor_menu[id] = -1;
  if (!has_active_editor())
  {
    for (new i = 0; i < g_wall_count; i++) remove_wall_entity(i);
  }
}

bool:check_editor_access(id)
{
  if (!is_user_connected(id) || !(get_user_flags(id) & ADMIN_CFG) || !is_user_alive(id))
  {
    stop_editor(id);
    return false;
  }
  return g_is_editing[id];
}

display_editor_menu(id, menu)
{
  if (!check_editor_access(id))
  {
    menu_destroy(menu);
    return;
  }
  menu_display(id, menu, 0);
  g_editor_menu[id] = menu;
}

bool:begin_menu_callback(id, menu, item)
{
  if (g_editor_menu[id] == menu) g_editor_menu[id] = -1;
  if (item < 0 || !check_editor_access(id))
  {
    menu_destroy(menu);
    return false;
  }
  return true;
}

// === Команды ===

public cmd_open_editor(id)
{
  if (!(get_user_flags(id) & ADMIN_CFG))
  {
    stop_editor(id);
    client_print(id, print_chat, "[Retake Editor] Access denied. Required flag: 'h' (ADMIN_CFG).");
    return PLUGIN_HANDLED;
  }

  if (!is_user_alive(id))
  {
    client_print(id, print_chat, "[Retake Editor] Join a team and spawn before editing.");
    return PLUGIN_HANDLED;
  }

  if (!g_is_editing[id])
  {
    g_saved_movetype[id] = get_entvar(id, var_movetype);
    g_is_editing[id] = true;
    set_entvar(id, var_movetype, MOVETYPE_NOCLIP);
    for (new i = 0; i < g_wall_count; i++)
    {
      if (!g_wall_ent[i]) g_wall_ent[i] = create_wall_entity(i);
    }
    client_print(id, print_chat, "[Retake Editor] Noclip enabled.");
  }

  show_main_menu(id);
  return PLUGIN_HANDLED;
}


public cmd_exit_editor(id)
{
  if (g_is_editing[id])
  {
    stop_editor(id);
    client_print(id, print_chat, "[Retake Editor] Editor closed.");
  }
  return PLUGIN_HANDLED;
}


public cmd_save_config(id)
{
  if (!check_editor_access(id))
  {
    return PLUGIN_HANDLED;
  }

  if (!g_config_ready)
  {
    client_print(id, print_chat, "[Retake Editor] Existing config could not be loaded. Fix it and reload before saving.");
  }
  else if (!config_has_all_spawns())
  {
    client_print(id, print_chat, "[Retake Editor] Add at least one T and CT spawn on both A and B before saving.");
  }
  else if (spawns_overlap(g_spawns, g_spawn_count))
  {
    client_print(id, print_chat, "[Retake Editor] Spawns overlap on the same site. Separate them before saving.");
  }
  else if (save_config_to_file())
  {
    new result;
    ExecuteForward(g_config_saved_forward, result);
    client_print(id, print_chat, "[Retake Editor] Config saved; map reload requested.");
  }
  else
  {
    client_print(id, print_chat, "[Retake Editor] Save failed. Draft retained; check the server log.");
  }
  show_main_menu(id);
  return PLUGIN_HANDLED;
}


public cmd_reload_config(id)
{
  if (!check_editor_access(id))
  {
    return PLUGIN_HANDLED;
  }

  if (load_config_from_file())
  {
    g_config_ready = true;
    client_print(id, print_chat, "[Retake Editor] Config reloaded.");
  }
  else
  {
    client_print(id, print_chat, "[Retake Editor] Reload failed. Current draft retained; check the server log.");
  }
  show_main_menu(id);
  return PLUGIN_HANDLED;
}


public cmd_rename_input(id)
{
  if (!check_editor_access(id))
  {
    return PLUGIN_HANDLED;
  }

  new wall_index = find_wall_by_id(g_rename_wall_id[id]);
  g_rename_wall_id[id] = 0;
  if (wall_index == -1)
  {
    client_print(id, print_chat, "[Retake Editor] Selected wall is no longer available.");
    show_walls_menu(id);
    return PLUGIN_HANDLED;
  }

  new new_name[192];
  read_args(new_name, charsmax(new_name));
  remove_quotes(new_name);
  trim(new_name);

  if (!rt_valid_wall_name(new_name) || wall_name_exists(new_name, wall_index))
  {
    client_print(id, print_chat, "[Retake Editor] Name must be unique; do not use INI separators or control characters.");
    show_walls_menu(id);
    return PLUGIN_HANDLED;
  }

  copy(g_wall_name[wall_index], charsmax(g_wall_name[]), new_name);
  client_print(id, print_chat, "[Retake Editor] Wall renamed to '%s'.", new_name);
  show_walls_menu(id);
  return PLUGIN_HANDLED;
}


// === Главное меню ===

public show_main_menu(id)
{
  new menu = menu_create("Retake Editor", "handle_main_menu");
  menu_additem(menu, "Spawns", "spawns");
  menu_additem(menu, "Walls", "walls");
  menu_additem(menu, "Save config", "save");
  menu_additem(menu, "Reload config", "reload");
  menu_additem(menu, "Exit editor", "exit");
  menu_setprop(menu, MPROP_EXIT, MEXIT_NEVER);
  display_editor_menu(id, menu);
}


public handle_main_menu(id, menu, item)
{
  if (!begin_menu_callback(id, menu, item))
  {
    return PLUGIN_HANDLED;
  }

  new data[16], name[64], access, callback;
  menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback);
  menu_destroy(menu);

  if (equali(data, "spawns"))
  {
    show_spawns_plant_menu(id);
  }
  else if (equali(data, "walls"))
  {
    show_walls_menu(id);
  }
  else if (equali(data, "save"))
  {
    cmd_save_config(id);
  }
  else if (equali(data, "reload"))
  {
    cmd_reload_config(id);
  }
  else if (equali(data, "exit"))
  {
    cmd_exit_editor(id);
  }
  return PLUGIN_HANDLED;
}


// === Меню спавнов ===

public show_spawns_plant_menu(id)
{
  new menu = menu_create("Spawns - Select Plant", "handle_spawns_plant_menu");
  menu_additem(menu, "Plant A", "0");
  menu_additem(menu, "Plant B", "1");
  menu_additem(menu, "Return", "-1");
  menu_setprop(menu, MPROP_EXIT, MEXIT_NEVER);
  display_editor_menu(id, menu);
}


public handle_spawns_plant_menu(id, menu, item)
{
  if (!begin_menu_callback(id, menu, item))
  {
    return PLUGIN_HANDLED;
  }

  new data[8], name[64], access, callback;
  menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback);
  menu_destroy(menu);

  new plant = str_to_num(data);

  if (plant == -1)
  {
    show_main_menu(id);
    return PLUGIN_HANDLED;
  }

  g_edit_plant[id] = plant;
  show_spawns_team_menu(id);
  return PLUGIN_HANDLED;
}


public show_spawns_team_menu(id)
{
  new menu = menu_create("Spawns - Select Team", "handle_spawns_team_menu");
  menu_additem(menu, "Terrorist", "0");
  menu_additem(menu, "Counter-Terrorist", "1");
  menu_additem(menu, "Return", "-1");
  menu_setprop(menu, MPROP_EXIT, MEXIT_NEVER);
  display_editor_menu(id, menu);
}


public handle_spawns_team_menu(id, menu, item)
{
  if (!begin_menu_callback(id, menu, item))
  {
    return PLUGIN_HANDLED;
  }

  new data[8], name[64], access, callback;
  menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback);
  menu_destroy(menu);

  new team = str_to_num(data);

  if (team == -1)
  {
    show_spawns_plant_menu(id);
    return PLUGIN_HANDLED;
  }

  g_edit_team[id] = team;
  show_spawns_action_menu(id);
  return PLUGIN_HANDLED;
}


public show_spawns_action_menu(id)
{
  new plant = g_edit_plant[id];
  new team = g_edit_team[id];

  new title[64];
  formatex(title, charsmax(title), "Spawns - %s %s",
    plant == 0 ? "A" : "B",
    team == 0 ? "T" : "CT");

  new menu = menu_create(title, "handle_spawns_action_menu");
  menu_additem(menu, "Add here", "add");
  menu_additem(menu, "Delete last", "del_last");
  menu_additem(menu, "Delete all", "del_all");
  menu_additem(menu, "Return", "return");
  menu_setprop(menu, MPROP_EXIT, MEXIT_NEVER);
  display_editor_menu(id, menu);
}


public handle_spawns_action_menu(id, menu, item)
{
  if (!begin_menu_callback(id, menu, item))
  {
    return PLUGIN_HANDLED;
  }

  new data[16], name[64], access, callback;
  menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback);
  menu_destroy(menu);

  if (equali(data, "add"))
  {
    add_spawn_here(id);
    show_spawns_action_menu(id);
  }
  else if (equali(data, "del_last"))
  {
    delete_last_spawn(id);
    show_spawns_action_menu(id);
  }
  else if (equali(data, "del_all"))
  {
    delete_all_spawns(id);
    show_spawns_action_menu(id);
  }
  else if (equali(data, "return"))
  {
    show_spawns_team_menu(id);
  }
  return PLUGIN_HANDLED;
}


get_spawn_slot(plant, team)
{
  if (plant == 0 && team == 0) return SPAWN_T_A;
  if (plant == 1 && team == 0) return SPAWN_T_B;
  if (plant == 0 && team == 1) return SPAWN_CT_A;
  return SPAWN_CT_B;
}


add_spawn_here(id)
{
  new slot = get_spawn_slot(g_edit_plant[id], g_edit_team[id]);

  new max_spawns = clamp(get_pcvar_num(cvar_max_spawns_per_slot), 1, MAX_SPAWNS);

  if (g_spawn_count[slot] >= max_spawns)
  {
    client_print(id, print_chat, "[Retake Editor] Spawn limit reached (%d).", max_spawns);
    return;
  }

  new Float:origin[3], Float:angles[3];
  get_entvar(id, var_origin, origin);
  get_entvar(id, var_v_angle, angles);
  for (new axis = 0; axis < 3; axis++)
  {
    if (!(origin[axis] >= -32768.0 && origin[axis] <= 32768.0))
    {
      client_print(id, print_chat, "[Retake Editor] Spawn position is outside supported map bounds.");
      return;
    }
  }

  new i = g_spawn_count[slot];
  g_spawns[slot][i][0] = origin[0];
  g_spawns[slot][i][1] = origin[1];
  g_spawns[slot][i][2] = origin[2];
  g_spawns[slot][i][3] = angles[0];
  g_spawns[slot][i][4] = angles[1];
  g_spawns[slot][i][5] = angles[2];
  g_spawn_count[slot]++;

  client_print(id, print_chat, "[Retake Editor] Spawn added (slot %d, index %d).", slot, i);
}


delete_last_spawn(id)
{
  new slot = get_spawn_slot(g_edit_plant[id], g_edit_team[id]);

  if (g_spawn_count[slot] == 0)
  {
    client_print(id, print_chat, "[Retake Editor] No spawns to delete.");
    return;
  }

  g_spawn_count[slot]--;
  client_print(id, print_chat, "[Retake Editor] Last spawn deleted (slot %d).", slot);
}


delete_all_spawns(id)
{
  new slot = get_spawn_slot(g_edit_plant[id], g_edit_team[id]);
  g_spawn_count[slot] = 0;
  client_print(id, print_chat, "[Retake Editor] All spawns cleared (slot %d).", slot);
}


// === Меню стен ===

public show_walls_menu(id)
{
  new menu = menu_create("Walls", "handle_walls_menu");
  menu_additem(menu, "Create wall here", "create");
  menu_additem(menu, "Rename last wall", "rename");
  menu_additem(menu, "Delete last wall", "del_last");
  menu_additem(menu, "Delete wall by name", "del_name");
  menu_additem(menu, "Delete all walls", "del_all");
  menu_additem(menu, "Return", "return");
  menu_setprop(menu, MPROP_EXIT, MEXIT_NEVER);
  display_editor_menu(id, menu);
}


public handle_walls_menu(id, menu, item)
{
  if (!begin_menu_callback(id, menu, item))
  {
    return PLUGIN_HANDLED;
  }

  new data[16], name[64], access, callback;
  menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback);
  menu_destroy(menu);

  if (equali(data, "create"))
  {
    create_wall_here(id);
    show_walls_menu(id);
  }
  else if (equali(data, "rename"))
  {
    if (g_wall_count == 0)
    {
      client_print(id, print_chat, "[Retake Editor] No walls to rename.");
      show_walls_menu(id);
      return PLUGIN_HANDLED;
    }
    g_rename_wall_id[id] = g_wall_id[g_wall_count - 1];
    client_print(id, print_chat, "[Retake Editor] Type new name for last wall in chat.");
    client_cmd(id, "messagemode retake_editor_rename_input");
  }
  else if (equali(data, "del_last"))
  {
    delete_last_wall(id);
    show_walls_menu(id);
  }
  else if (equali(data, "del_name"))
  {
    g_wall_list_action[id] = 1;
    show_wall_list_menu(id);
  }
  else if (equali(data, "del_all"))
  {
    delete_all_walls(id);
    show_walls_menu(id);
  }
  else if (equali(data, "return"))
  {
    show_main_menu(id);
  }
  return PLUGIN_HANDLED;
}


create_wall_here(id)
{
  if (g_wall_count >= MAX_WALLS)
  {
    client_print(id, print_chat, "[Retake Editor] Wall limit reached (%d).", MAX_WALLS);
    return;
  }

  new i = g_wall_count;
  get_entvar(id, var_origin, g_wall_origin[i]);
  for (new axis = 0; axis < 3; axis++)
  {
    if (!(g_wall_origin[i][axis] >= -32768.0 && g_wall_origin[i][axis] <= 32768.0))
    {
      client_print(id, print_chat, "[Retake Editor] Wall position is outside supported map bounds.");
      return;
    }
  }
  g_wall_size[i] = get_pcvar_float(cvar_wall_size);
  if (!(g_wall_size[i] >= 1.0 && g_wall_size[i] <= 4096.0))
  {
    client_print(id, print_chat, "[Retake Editor] Wall size must be between 1 and 4096.");
    return;
  }
  do
  {
    g_wall_id[i] = g_next_wall_id++;
    formatex(g_wall_name[i], charsmax(g_wall_name[]), "wall_%d", g_wall_id[i]);
  }
  while (wall_name_exists(g_wall_name[i]));
  g_wall_ent[i] = create_wall_entity(i);
  g_wall_count++;

  if (g_wall_ent[i])
    client_print(id, print_chat, "[Retake Editor] Wall '%s' added to draft.", g_wall_name[i]);
  else
    client_print(id, print_chat, "[Retake Editor] Wall added to draft; preview unavailable (entity limit).");
}


// === Создание и удаление сущностей стен ===

create_wall_entity(wall_index)
{
  if (!has_active_editor()) return 0;
  new ent = rg_create_entity("info_target", false);
  if (!ent)
  {
    log_amx("[Retake Editor] Failed to create preview for wall %d", wall_index);
    return 0;
  }

  new Float:half = g_wall_size[wall_index] / 2.0;
  new Float:mins[3], Float:maxs[3];

  mins[0] = -half;
  mins[1] = -half;
  mins[2] = -half;
  maxs[0] = half;
  maxs[1] = half;
  maxs[2] = half;

  entity_set_model(ent, WALL_MODEL);
  DispatchSpawn(ent);

  set_entvar(ent, var_classname, "retake_editor_preview");
  entity_set_origin(ent, g_wall_origin[wall_index]);
  entity_set_size(ent, mins, maxs);
  set_entvar(ent, var_solid, SOLID_NOT);
  set_entvar(ent, var_movetype, MOVETYPE_NONE);

  set_entvar(ent, var_rendermode, kRenderTransTexture);
  set_entvar(ent, var_renderamt, 100.0);

  return ent;
}


remove_wall_entity(wall_index)
{
  if (wall_index < 0 || wall_index >= g_wall_count)
  {
    return;
  }

  new ent = g_wall_ent[wall_index];
  if (ent > 0 && is_entity(ent))
  {
    new classname[32];
    get_entvar(ent, var_classname, classname, charsmax(classname));
    if (equal(classname, "retake_editor_preview"))
    {
      remove_entity(ent);
    }
  }
  g_wall_ent[wall_index] = 0;
}


delete_last_wall(id)
{
  if (g_wall_count == 0)
  {
    client_print(id, print_chat, "[Retake Editor] No walls to delete.");
    return;
  }

  remove_wall_entity(g_wall_count - 1);
  g_wall_count--;
  client_print(id, print_chat, "[Retake Editor] Last wall deleted. Remaining: %d.", g_wall_count);
}


delete_all_walls(id)
{
  for (new i = 0; i < g_wall_count; i++)
  {
    remove_wall_entity(i);
  }
  g_wall_count = 0;
  client_print(id, print_chat, "[Retake Editor] All walls deleted.");
}


// === Список стен ===

public show_wall_list_menu(id)
{
  if (g_wall_count == 0)
  {
    client_print(id, print_chat, "[Retake Editor] No walls.");
    show_walls_menu(id);
    return;
  }

  new title[64];
  formatex(title, charsmax(title), "Select wall to %s",
    g_wall_list_action[id] == 0 ? "rename" : "delete");

  new menu = menu_create(title, "handle_wall_list_menu");

  for (new i = 0; i < g_wall_count; i++)
  {
    new data[16];
    num_to_str(g_wall_id[i], data, charsmax(data));
    menu_additem(menu, g_wall_name[i], data);
  }

  menu_additem(menu, "Return", "return");
  menu_setprop(menu, MPROP_EXIT, MEXIT_NEVER);
  menu_setprop(menu, MPROP_PERPAGE, 7);
  display_editor_menu(id, menu);
}


public handle_wall_list_menu(id, menu, item)
{
  if (!begin_menu_callback(id, menu, item))
  {
    return PLUGIN_HANDLED;
  }

  new data[16], name[64], access, callback;
  menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback);
  menu_destroy(menu);

  if (equal(data, "return"))
  {
    show_walls_menu(id);
    return PLUGIN_HANDLED;
  }
  new wall_index = find_wall_by_id(str_to_num(data));

  if (wall_index < 0 || wall_index >= g_wall_count)
  {
    show_walls_menu(id);
    return PLUGIN_HANDLED;
  }

  if (g_wall_list_action[id] == 0)
  {
    client_print(id, print_chat, "[Retake Editor] Rename by list not implemented yet.");
  }
  else if (g_wall_list_action[id] == 1)
  {
    delete_wall_by_index(id, wall_index);
  }

  show_walls_menu(id);
  return PLUGIN_HANDLED;
}


delete_wall_by_index(id, index)
{
  if (index < 0 || index >= g_wall_count)
  {
    return;
  }

  remove_wall_entity(index);

  for (new i = index; i < g_wall_count - 1; i++)
  {
    g_wall_origin[i][0] = g_wall_origin[i + 1][0];
    g_wall_origin[i][1] = g_wall_origin[i + 1][1];
    g_wall_origin[i][2] = g_wall_origin[i + 1][2];

    g_wall_size[i] = g_wall_size[i + 1];
    g_wall_ent[i] = g_wall_ent[i + 1];
    g_wall_id[i] = g_wall_id[i + 1];
    copy(g_wall_name[i], charsmax(g_wall_name[]), g_wall_name[i + 1]);
  }

  g_wall_count--;
  client_print(id, print_chat, "[Retake Editor] Wall deleted. Remaining: %d.", g_wall_count);
}

find_wall_by_id(wall_id)
{
  if (wall_id <= 0) return -1;
  for (new i = 0; i < g_wall_count; i++)
  {
    if (g_wall_id[i] == wall_id) return i;
  }
  return -1;
}

bool:wall_name_exists(const name[], except = -1)
{
  for (new i = 0; i < g_wall_count; i++)
  {
    if (i != except && equali(name, g_wall_name[i])) return true;
  }
  return false;
}

bool:config_has_all_spawns()
{
  for (new slot = 0; slot < SPAWN_SLOTS; slot++)
  {
    if (!g_spawn_count[slot]) return false;
  }
  return true;
}

bool:spawns_overlap(const Float:spawns[SPAWN_SLOTS][MAX_SPAWNS][6], const spawn_counts[SPAWN_SLOTS])
{
  for (new site = 0; site < 2; site++)
  {
    for (new team = 0; team < 2; team++)
    {
      new slot = site + team * 2;
      for (new i = 0; i < spawn_counts[slot]; i++)
      {
        for (new other_team = team; other_team < 2; other_team++)
        {
          new other_slot = site + other_team * 2;
          new start = other_slot == slot ? i + 1 : 0;
          for (new j = start; j < spawn_counts[other_slot]; j++)
          {
            if (floatabs(spawns[slot][i][0] - spawns[other_slot][j][0]) < 32.0 &&
                floatabs(spawns[slot][i][1] - spawns[other_slot][j][1]) < 32.0 &&
                floatabs(spawns[slot][i][2] - spawns[other_slot][j][2]) < 72.0)
              return true;
          }
        }
      }
    }
  }
  return false;
}

bool:valid_spawn_key(const key[])
{
  new length = strlen(key);
  if (length < 1 || length > 63) return false;
  for (new i = 0; i < length; i++)
  {
    if (key[i] < '0' || key[i] > '9') return false;
  }
  return true;
}


// === Файл конфига ===

get_config_path(output[], len)
{
  new mapname[32];
  get_mapname(mapname, charsmax(mapname));
  strtolower(mapname);

  new configsdir[PLATFORM_MAX_PATH];
  get_configsdir(configsdir, charsmax(configsdir));

  formatex(output, len, "%s/retakes/%s.ini", configsdir, mapname);
}


check_configs_dir()
{
  new test_path[PLATFORM_MAX_PATH];
  new configsdir[PLATFORM_MAX_PATH];
  get_configsdir(configsdir, charsmax(configsdir));
  formatex(test_path, charsmax(test_path), "%s/retakes/_check.tmp", configsdir);

  new file = fopen(test_path, "w");
  if (!file)
  {
    log_amx("[Retake Editor] Cannot write to 'addons/amxmodx/configs/retakes/'. Create the folder manually.");
    return;
  }
  fclose(file);
  delete_file(test_path);
}


bool:save_config_to_file()
{
  new path[PLATFORM_MAX_PATH], temporary[PLATFORM_MAX_PATH], backup[PLATFORM_MAX_PATH];
  get_config_path(path, charsmax(path));
  if (strlen(path) + 4 >= sizeof(temporary))
  {
    log_amx("[Retake Editor] Config path is too long for temporary and backup names.");
    return false;
  }
  formatex(temporary, charsmax(temporary), "%s.tmp", path);
  formatex(backup, charsmax(backup), "%s.bak", path);

  new file = fopen(temporary, "wb");
  if (!file)
  {
    log_amx("[Retake Editor] Cannot open temporary file for writing: %s", temporary);
    return false;
  }

  new expected_bytes;
  new bool:ok = write_spawn_section(file, "spawns_t_a", SPAWN_T_A, expected_bytes);
  if (ok) ok = write_spawn_section(file, "spawns_t_b", SPAWN_T_B, expected_bytes);
  if (ok) ok = write_spawn_section(file, "spawns_ct_a", SPAWN_CT_A, expected_bytes);
  if (ok) ok = write_spawn_section(file, "spawns_ct_b", SPAWN_CT_B, expected_bytes);

  if (ok) ok = write_config_text(file, "[walls]^n", expected_bytes);
  for (new i = 0; ok && i < g_wall_count; i++)
  {
    new buf[256];
    formatex(buf, charsmax(buf), "%s = %f %f %f %f^n",
      g_wall_name[i],
      _:g_wall_origin[i][0], _:g_wall_origin[i][1], _:g_wall_origin[i][2],
      _:g_wall_size[i]);
    ok = write_config_text(file, buf, expected_bytes);
  }

  if (fflush(file) != 0) ok = false;
  fclose(file);
  if (!ok || file_size(temporary) != expected_bytes)
  {
    log_amx("[Retake Editor] Temporary config write failed; original preserved: %s", path);
    delete_file(temporary);
    return false;
  }

  new bool:had_original = bool:file_exists(path);
  if (had_original)
  {
    if ((file_exists(backup) && !delete_file(backup)) || !rename_file(path, backup, 1))
    {
      log_amx("[Retake Editor] Cannot create backup; original preserved: %s", path);
      delete_file(temporary);
      return false;
    }
  }

  if (!rename_file(temporary, path, 1))
  {
    if (had_original && !rename_file(backup, path, 1))
    {
      g_config_ready = false;
      log_amx("[Retake Editor] Replacement and rollback failed. Restore %s to %s before saving again.", backup, path);
    }
    else
      log_amx("[Retake Editor] Replacement failed; previous config restored: %s", path);
    delete_file(temporary);
    return false;
  }
  log_amx("[Retake Editor] Config saved: %s", path);
  return true;
}

bool:write_config_text(file, const text[], &expected_bytes)
{
  new length = strlen(text);
  expected_bytes += length;
  return fprintf(file, "%s", text) == length;
}

bool:write_spawn_section(file, const section[], slot, &expected_bytes)
{
  new header[64];
  formatex(header, charsmax(header), "[%s]^n", section);
  if (!write_config_text(file, header, expected_bytes)) return false;
  for (new i = 0; i < g_spawn_count[slot]; i++)
  {
    new buf[256];
    formatex(buf, charsmax(buf), "%d = %f %f %f %f %f %f^n", i,
      _:g_spawns[slot][i][0], _:g_spawns[slot][i][1], _:g_spawns[slot][i][2],
      _:g_spawns[slot][i][3], _:g_spawns[slot][i][4], _:g_spawns[slot][i][5]);
    if (!write_config_text(file, buf, expected_bytes)) return false;
  }
  return write_config_text(file, "^n", expected_bytes);
}


bool:load_config_from_file()
{
  new path[PLATFORM_MAX_PATH];
  get_config_path(path, charsmax(path));

  if (!file_exists(path))
  {
    log_amx("[Retake Editor] Config not found: %s", path);
    return false;
  }

  new file = fopen(path, "r");
  if (!file)
  {
    log_amx("[Retake Editor] Cannot open file for reading: %s", path);
    return false;
  }

  // Keep the current draft and previews intact until the entire file is valid.
  static Float:spawns[SPAWN_SLOTS][MAX_SPAWNS][6];
  static Float:wall_origins[MAX_WALLS][3], Float:wall_sizes[MAX_WALLS];
  static wall_names[MAX_WALLS][WALL_NAME_LEN];
  new spawn_counts[SPAWN_SLOTS], wall_count;
  new line[512], section = -1, line_number;
  new bool:valid = true;

  while (fgets(file, line, charsmax(line)))
  {
    line_number++;
    if (strlen(line) == charsmax(line))
    {
      valid = false;
      break;
    }
    trim(line);
    if (line[0] == 0 || line[0] == ';' || line[0] == '#')
    {
      continue;
    }

    if (line[0] == '[')
    {
      new end = strfind(line, "]");
      if (end <= 1 || end != strlen(line) - 1)
      {
        valid = false;
        break;
      }
      line[end] = 0;
      if (equali(line[1], "spawns_t_a")) section = SPAWN_T_A;
      else if (equali(line[1], "spawns_t_b")) section = SPAWN_T_B;
      else if (equali(line[1], "spawns_ct_a")) section = SPAWN_CT_A;
      else if (equali(line[1], "spawns_ct_b")) section = SPAWN_CT_B;
      else if (equali(line[1], "walls")) section = SPAWN_SLOTS;
      else
      {
        valid = false;
        break;
      }
    }
    else
    {
      new eq = strfind(line, "=");
      if (eq <= 0 || section < 0)
      {
        valid = false;
        break;
      }

      // Split in the full line buffer before copying the bounded key.
      line[eq] = 0;
      trim(line);
      new Float:values[6];
      if (section < SPAWN_SLOTS)
      {
        if (!valid_spawn_key(line) || spawn_counts[section] >= MAX_SPAWNS ||
            !rt_parse_floats(line[eq + 1], values, 6))
        {
          valid = false;
          break;
        }
        new index = spawn_counts[section]++;
        for (new j = 0; j < 6; j++) spawns[section][index][j] = values[j];
      }
      else
      {
        if (!rt_valid_wall_name(line) || wall_count >= MAX_WALLS ||
            !rt_parse_floats(line[eq + 1], values, 4) ||
            !(values[3] >= 1.0 && values[3] <= 4096.0))
        {
          valid = false;
          break;
        }
        for (new j = 0; j < wall_count; j++)
        {
          if (equali(wall_names[j], line)) valid = false;
        }
        if (!valid) break;
        copy(wall_names[wall_count], charsmax(wall_names[]), line);
        for (new j = 0; j < 3; j++) wall_origins[wall_count][j] = values[j];
        wall_sizes[wall_count++] = values[3];
      }
    }
  }

  if (!feof(file)) valid = false;
  fclose(file);
  for (new slot = 0; slot < SPAWN_SLOTS; slot++)
  {
    if (!spawn_counts[slot]) valid = false;
  }
  if (valid && spawns_overlap(spawns, spawn_counts)) valid = false;
  if (!valid)
  {
    log_amx("[Retake Editor] Invalid or incomplete config near line %d; draft retained: %s", line_number, path);
    return false;
  }

  for (new i = 0; i < g_wall_count; i++) remove_wall_entity(i);
  for (new slot = 0; slot < SPAWN_SLOTS; slot++)
  {
    g_spawn_count[slot] = spawn_counts[slot];
    for (new i = 0; i < spawn_counts[slot]; i++)
      for (new j = 0; j < 6; j++) g_spawns[slot][i][j] = spawns[slot][i][j];
  }
  g_wall_count = wall_count;
  for (new i = 0; i < wall_count; i++)
  {
    for (new j = 0; j < 3; j++) g_wall_origin[i][j] = wall_origins[i][j];
    g_wall_size[i] = wall_sizes[i];
    copy(g_wall_name[i], charsmax(g_wall_name[]), wall_names[i]);
    g_wall_id[i] = g_next_wall_id++;
    g_wall_ent[i] = create_wall_entity(i);
  }
  return true;
}
