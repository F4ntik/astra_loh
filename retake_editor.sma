#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <string>
#include <engine>

#define PLUGIN_NAME "Retake Editor"
#define PLUGIN_VERSION "0.1.0"
#define PLUGIN_AUTHOR "Retake Project"

#define MAX_SPAWNS 32
#define SPAWN_SLOTS 4
#define MAX_WALLS 64
#define WALL_NAME_LEN 32

enum
{
  SPAWN_T_A = 0,
  SPAWN_T_B,
  SPAWN_CT_A,
  SPAWN_CT_B
}

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
new g_wall_count = 0;

// Состояние редактора
new bool:g_is_editing[MAX_PLAYERS + 1];
new g_edit_plant[MAX_PLAYERS + 1];
new g_edit_team[MAX_PLAYERS + 1];
new g_wall_list_action[MAX_PLAYERS + 1];

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

  check_configs_dir();
}


public client_disconnected(id, bool:drop, message[], maxlen)
{
  g_is_editing[id] = false;
  g_wall_list_action[id] = 0;
  return PLUGIN_CONTINUE;
}


// === Команды ===

public cmd_open_editor(id)
{
  if (!(get_user_flags(id) & ADMIN_CFG))
  {
    client_print(id, print_chat, "[Retake Editor] Access denied. Required flag: 'h' (ADMIN_CFG).");
    return PLUGIN_HANDLED;
  }

  if (!g_is_editing[id])
  {
    g_is_editing[id] = true;
    set_entvar(id, var_movetype, MOVETYPE_NOCLIP);
    client_print(id, print_chat, "[Retake Editor] Noclip enabled.");
  }

  show_main_menu(id);
  return PLUGIN_HANDLED;
}


public cmd_exit_editor(id)
{
  if (!(get_user_flags(id) & ADMIN_CFG))
  {
    return PLUGIN_HANDLED;
  }

  if (g_is_editing[id])
  {
    g_is_editing[id] = false;
    set_entvar(id, var_movetype, MOVETYPE_WALK);
    client_print(id, print_chat, "[Retake Editor] Noclip disabled.");
  }
  return PLUGIN_HANDLED;
}


public cmd_save_config(id)
{
  if (!(get_user_flags(id) & ADMIN_CFG))
  {
    return PLUGIN_HANDLED;
  }

  save_config_to_file();
  client_print(id, print_chat, "[Retake Editor] Config saved.");
  return PLUGIN_HANDLED;
}


public cmd_reload_config(id)
{
  if (!(get_user_flags(id) & ADMIN_CFG))
  {
    return PLUGIN_HANDLED;
  }

  delete_all_walls(id);
  load_config_from_file();
  client_print(id, print_chat, "[Retake Editor] Config reloaded.");
  return PLUGIN_HANDLED;
}


public cmd_rename_input(id)
{
  if (!(get_user_flags(id) & ADMIN_CFG) || !g_is_editing[id])
  {
    return PLUGIN_HANDLED;
  }

  if (g_wall_count == 0)
  {
    client_print(id, print_chat, "[Retake Editor] No walls to rename.");
    show_walls_menu(id);
    return PLUGIN_HANDLED;
  }

  new new_name[WALL_NAME_LEN];
  read_args(new_name, charsmax(new_name));
  remove_quotes(new_name);
  trim(new_name);

  if (new_name[0] == 0)
  {
    client_print(id, print_chat, "[Retake Editor] Empty name, ignoring.");
    show_walls_menu(id);
    return PLUGIN_HANDLED;
  }

  new last = g_wall_count - 1;
  copy(g_wall_name[last], charsmax(g_wall_name[]), new_name);
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
  menu_display(id, menu, 0);
}


public handle_main_menu(id, menu, item)
{
  if (item == MENU_EXIT)
  {
    menu_destroy(menu);
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
  menu_display(id, menu, 0);
}


public handle_spawns_plant_menu(id, menu, item)
{
  if (item == MENU_EXIT)
  {
    menu_destroy(menu);
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
  menu_display(id, menu, 0);
}


public handle_spawns_team_menu(id, menu, item)
{
  if (item == MENU_EXIT)
  {
    menu_destroy(menu);
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
  menu_display(id, menu, 0);
}


public handle_spawns_action_menu(id, menu, item)
{
  if (item == MENU_EXIT)
  {
    menu_destroy(menu);
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

  new max_spawns = get_pcvar_num(cvar_max_spawns_per_slot);
  if (max_spawns > MAX_SPAWNS)
  {
    max_spawns = MAX_SPAWNS;
  }

  if (g_spawn_count[slot] >= max_spawns)
  {
    client_print(id, print_chat, "[Retake Editor] Spawn limit reached (%d).", max_spawns);
    return;
  }

  new Float:origin[3], Float:angles[3];
  get_entvar(id, var_origin, origin);
  get_entvar(id, var_angles, angles);

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
  menu_display(id, menu, 0);
}


public handle_walls_menu(id, menu, item)
{
  if (item == MENU_EXIT)
  {
    menu_destroy(menu);
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
  g_wall_size[i] = get_pcvar_float(cvar_wall_size);
  formatex(g_wall_name[i], charsmax(g_wall_name[]), "wall_%d", i + 1);
  g_wall_ent[i] = create_wall_entity(i);
  g_wall_count++;

  client_print(id, print_chat, "[Retake Editor] Wall '%s' created (ent %d).", g_wall_name[i], g_wall_ent[i]);
}


// === Создание и удаление сущностей стен ===

create_wall_entity(wall_index)
{
  new ent = rg_create_entity("func_wall", false);
  if (!ent)
  {
    log_amx("[Retake Editor] Failed to create func_wall for wall %d", wall_index);
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

  set_entvar(ent, var_origin, g_wall_origin[wall_index]);
  entity_set_size(ent, mins, maxs);
  set_entvar(ent, var_solid, SOLID_BBOX);
  set_entvar(ent, var_movetype, MOVETYPE_PUSH);

  set_entvar(ent, var_rendermode, kRenderNormal);
  set_entvar(ent, var_renderamt, 255.0);

  return ent;
}


remove_wall_entity(wall_index)
{
  if (wall_index < 0 || wall_index >= g_wall_count)
  {
    return;
  }

  new ent = g_wall_ent[wall_index];
  if (ent > 0)
  {
    rg_remove_entity(ent);
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
    new data[8];
    num_to_str(i, data, charsmax(data));
    menu_additem(menu, g_wall_name[i], data);
  }

  menu_setprop(menu, MPROP_EXIT, MEXIT_NEVER);
  menu_setprop(menu, MPROP_PERPAGE, 7);
  menu_display(id, menu, 0);
}


public handle_wall_list_menu(id, menu, item)
{
  if (item == MENU_EXIT)
  {
    menu_destroy(menu);
    return PLUGIN_HANDLED;
  }

  new data[8], name[64], access, callback;
  menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback);
  menu_destroy(menu);

  new wall_index = str_to_num(data);

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
    copy(g_wall_name[i], charsmax(g_wall_name[]), g_wall_name[i + 1]);
  }

  g_wall_count--;
  client_print(id, print_chat, "[Retake Editor] Wall deleted. Remaining: %d.", g_wall_count);
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


save_config_to_file()
{
  new path[PLATFORM_MAX_PATH];
  get_config_path(path, charsmax(path));

  new file = fopen(path, "w");
  if (!file)
  {
    log_amx("[Retake Editor] Cannot open file for writing: %s", path);
    return;
  }

  write_spawn_section(file, "spawns_t_a", SPAWN_T_A);
  write_spawn_section(file, "spawns_t_b", SPAWN_T_B);
  write_spawn_section(file, "spawns_ct_a", SPAWN_CT_A);
  write_spawn_section(file, "spawns_ct_b", SPAWN_CT_B);

  fprintf(file, "[walls]^n");
  for (new i = 0; i < g_wall_count; i++)
  {
    new buf[256];
    formatex(buf, charsmax(buf), "%s = %f %f %f %f^n",
      g_wall_name[i],
      _:g_wall_origin[i][0], _:g_wall_origin[i][1], _:g_wall_origin[i][2],
      _:g_wall_size[i]);
    fprintf(file, "%s", buf);
  }

  fclose(file);
  log_amx("[Retake Editor] Config saved: %s", path);
}


write_spawn_section(file, const section[], slot)
{
  fprintf(file, "[%s]^n", section);
  for (new i = 0; i < g_spawn_count[slot]; i++)
  {
    new buf[256];
    formatex(buf, charsmax(buf), "%d = %f %f %f %f %f %f^n", i,
      _:g_spawns[slot][i][0], _:g_spawns[slot][i][1], _:g_spawns[slot][i][2],
      _:g_spawns[slot][i][3], _:g_spawns[slot][i][4], _:g_spawns[slot][i][5]);
    fprintf(file, "%s", buf);
  }
  fprintf(file, "^n");
}


load_config_from_file()
{
  for (new s = 0; s < SPAWN_SLOTS; s++)
  {
    g_spawn_count[s] = 0;
  }
  g_wall_count = 0;

  new path[PLATFORM_MAX_PATH];
  get_config_path(path, charsmax(path));

  if (!file_exists(path))
  {
    log_amx("[Retake Editor] Config not found: %s", path);
    return;
  }

  new file = fopen(path, "r");
  if (!file)
  {
    log_amx("[Retake Editor] Cannot open file for reading: %s", path);
    return;
  }

  new line[256];
  new section[32] = "";

  while (fgets(file, line, charsmax(line)))
  {
    trim(line);
    if (line[0] == 0 || line[0] == ';' || line[0] == '#')
    {
      continue;
    }

    if (line[0] == '[')
    {
      new end = strfind(line, "]");
      if (end == -1)
      {
        continue;
      }
      line[end] = 0;
      copy(section, charsmax(section), line[1]);
    }
    else
    {
      new eq = strfind(line, "=");
      if (eq == -1)
      {
        continue;
      }

      new key[64], value[128];
      copy(key, charsmax(key), line);
      key[eq] = 0;
      trim(key);

      copy(value, charsmax(value), line[eq + 1]);
      trim(value);

      if (equali(section, "spawns_t_a"))
      {
        parse_spawn_line(SPAWN_T_A, value);
      }
      else if (equali(section, "spawns_t_b"))
      {
        parse_spawn_line(SPAWN_T_B, value);
      }
      else if (equali(section, "spawns_ct_a"))
      {
        parse_spawn_line(SPAWN_CT_A, value);
      }
      else if (equali(section, "spawns_ct_b"))
      {
        parse_spawn_line(SPAWN_CT_B, value);
      }
      else if (equali(section, "walls"))
      {
        parse_wall_line(key, value);
      }
    }
  }

  fclose(file);

  for (new i = 0; i < g_wall_count; i++)
  {
    g_wall_ent[i] = create_wall_entity(i);
  }
}


parse_spawn_line(slot, value[])
{
  if (g_spawn_count[slot] >= MAX_SPAWNS)
  {
    return;
  }

  new Float:vals[6];
  if (parse(value, "%f %f %f %f %f %f",
    vals[0], vals[1], vals[2], vals[3], vals[4], vals[5]) < 6)
  {
    return;
  }

  new i = g_spawn_count[slot];
  for (new j = 0; j < 6; j++)
  {
    g_spawns[slot][i][j] = vals[j];
  }
  g_spawn_count[slot]++;
}


parse_wall_line(key[], value[])
{
  if (g_wall_count >= MAX_WALLS)
  {
    return;
  }

  new Float:vals[4];
  if (parse(value, "%f %f %f %f",
    vals[0], vals[1], vals[2], vals[3]) < 4)
  {
    return;
  }

  new i = g_wall_count;
  copy(g_wall_name[i], charsmax(g_wall_name[]), key);
  g_wall_origin[i][0] = vals[0];
  g_wall_origin[i][1] = vals[1];
  g_wall_origin[i][2] = vals[2];
  g_wall_size[i] = vals[3];
  g_wall_ent[i] = 0;
  g_wall_count++;
}