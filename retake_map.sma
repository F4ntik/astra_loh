#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <engine>
#include <string>

#include <retake>

// Требуется AMX Mod X 1.10+

#define PLUGIN_NAME "Retake Map"
#define PLUGIN_VERSION "0.1"
#define PLUGIN_AUTHOR "Asura"

new g_has_map_cfg = false;

// ARRAYS FOR WALLS AND SPAWNS
#define MAX_SPAWNS 32

new Float:arr_spawn[SPAWN_SLOTS][MAX_SPAWNS][6];
new arr_spawn_count[SPAWN_SLOTS];

#define MAX_WALLS 64

new Float:arr_wall[MAX_WALLS][3];
new arr_wallname[MAX_WALLS][64];
new Float:arr_wallsize[MAX_WALLS];
new arr_wallent[MAX_WALLS];
new arr_wall_count = 0;

// FORWARDS
new forw_map_cfg_loaded;

new const WALL_MODEL[] = "models/box.mdl";
public plugin_precache()
{
  precache_model(WALL_MODEL);
}

public plugin_init()
{
  register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

  forw_map_cfg_loaded = CreateMultiForward("retake_map_loaded", ET_IGNORE);
}

public plugin_natives()
{
  register_native("retake_map_has_config", "RTM_has_config");
  register_native("retake_map_get_spawn", "RTM_get_spawn");
}

public plugin_cfg()
{
  load_config();
}

public retake_config_saved()
{
  load_config();
}

map_cfg_loaded()
{
  ExecuteForward(forw_map_cfg_loaded);
}

// -------
// Natives
// -------
public RTM_has_config()
{
  return g_has_map_cfg;
}

// public RTM_get_spawn(slot, Float:origin[], Float:angles[])
// {
//   log_amx("retake map: slot %d, count %d", slot, arr_spawn_count);
//   if (slot < 0 || slot >= SPAWN_SLOTS) return 0;
//   if (arr_spawn_count[slot] == 0) return 0;

//   new index = random(arr_spawn_count[slot]); // from 0

//   set_float_byref(origin[0], arr_spawn[slot][index][0]);
//   set_float_byref(origin[1], arr_spawn[slot][index][1]);
//   set_float_byref(origin[2], arr_spawn[slot][index][2] + 2.0); 

//   set_float_byref(angles[0], arr_spawn[slot][index][3]);
//   set_float_byref(angles[1], arr_spawn[slot][index][4]);
//   set_float_byref(angles[2], arr_spawn[slot][index][5]);

//   return 1;
// }

public RTM_get_spawn(plugin_id, num_params)
{
  new slot = get_param(1); 

  log_amx("retake map: slot %d, count %d", slot, arr_spawn_count[slot]);

  if (slot < 0 || slot >= SPAWN_SLOTS) return 0;
  if (arr_spawn_count[slot] == 0) return 0;

  new index = random(arr_spawn_count[slot]); // Выбираем случайный спавн

  new Float:output_origin[3];
  new Float:output_angles[3];

  output_origin[0] = arr_spawn[slot][index][0];
  output_origin[1] = arr_spawn[slot][index][1];
  output_origin[2] = arr_spawn[slot][index][2];

  output_angles[0] = arr_spawn[slot][index][3];
  output_angles[1] = arr_spawn[slot][index][4];
  output_angles[2] = arr_spawn[slot][index][5];

  set_array_f(2, output_origin, 3);
  set_array_f(3, output_angles, 3);

  return 1;
}

load_config()
{
  clear_spawns();

  remove_all_walls();

  g_has_map_cfg = false;

  new default_cfg_path[PLATFORM_MAX_PATH];
  get_config_path(default_cfg_path, charsmax(default_cfg_path));

  if (!file_exists(default_cfg_path))
  {
    log_amx("[Retake Map] No config for this map (%s).", default_cfg_path);
    map_cfg_loaded();
    return;
  }

  new file = fopen(default_cfg_path, "r");
  if (!file)
  {
    log_amx("[Retake Map] Cannot open file for reading: %s", default_cfg_path);
    map_cfg_loaded();
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
      trim(section);
    }
    else
    {
        new eq = strfind(line, "=");
        if (eq == -1)
        {
            continue;
        }

        new key[64], value[128];

        // Берём '=' внутри уже усечённого key, а не в исходной line
        copy(key, charsmax(key), line);
        new key_eq = strfind(key, "=");
        if (key_eq == -1)
        {
            continue; // '=' оказался за границей key — пропускаем строку
        }
        key[key_eq] = 0;
        trim(key);

        copy(value, charsmax(value), line[eq + 1]);
        trim(value);

        if (equali(section, "spawns_t_a"))
            parse_spawn_line(SPAWN_T_A, value);

        else if (equali(section, "spawns_t_b"))
            parse_spawn_line(SPAWN_T_B, value);

        else if (equali(section, "spawns_ct_a"))
            parse_spawn_line(SPAWN_CT_A, value);

        else if (equali(section, "spawns_ct_b"))
            parse_spawn_line(SPAWN_CT_B, value);

        else if (equali(section, "walls"))
            parse_wall_line(key, value);
    }
  }

  fclose(file);

  for (new i = 0; i < arr_wall_count; i++)
  {
    arr_wallent[i] = create_wall_entity(i);

    log_amx("[Retake Map] Wall %d '%s': origin=(%.1f %.1f %.1f) size=%.1f ent=%d",
      i, arr_wallname[i],
      arr_wall[i][0], arr_wall[i][1], arr_wall[i][2],
      arr_wallsize[i], arr_wallent[i]);
  }

  g_has_map_cfg = true;

  log_amx("[Retake Map] Loaded config: spawns T/A=%d T/B=%d CT/A=%d CT/B=%d, walls=%d",
    arr_spawn_count[SPAWN_T_A], arr_spawn_count[SPAWN_T_B],
    arr_spawn_count[SPAWN_CT_A], arr_spawn_count[SPAWN_CT_B],
    arr_wall_count);

  map_cfg_loaded();
}

parse_spawn_line(slot, value[])
{
  if (arr_spawn_count[slot] >= MAX_SPAWNS)
  {
    return;
  }

  new Float:vals[6];
  if (parse_floats(value, vals, 6) != 6)
  {
    log_amx("[Retake Map] Bad spawn line: '%s'", value);
    return;
  }

  new i = arr_spawn_count[slot];
  for (new j = 0; j < 6; j++)
  {
    arr_spawn[slot][i][j] = vals[j];
  }
  arr_spawn_count[slot]++;
}

parse_wall_line(key[], value[])
{
  if (arr_wall_count >= MAX_WALLS)
  {
    return;
  }

  new Float:vals[4];
  if (parse_floats(value, vals, 4) != 4)
  {
    log_amx("[Retake Map] Bad wall line: '%s = %s'", key, value);
    return;
  }

  new i = arr_wall_count;

  copy(arr_wallname[i], charsmax(arr_wallname[]), key);

  arr_wall[i][0] = vals[0];
  arr_wall[i][1] = vals[1];
  arr_wall[i][2] = vals[2];

  arr_wallsize[i] = vals[3];
  arr_wallent[i] = 0;

  arr_wall_count++;
}

create_wall_entity(wall_index)
{
  new ent = rg_create_entity("func_wall", false);

  if (!ent)
  {
    log_amx("[Retake Map] Failed to create func_wall for wall %d", wall_index);
    return 0;
  }

  new Float:half = arr_wallsize[wall_index] / 2.0;
  new Float:mins[3], Float:maxs[3];

  mins[0] = -half;
  mins[1] = -half;
  mins[2] = -half;
  maxs[0] = half;
  maxs[1] = half;
  maxs[2] = half;

  entity_set_model(ent, WALL_MODEL);

  DispatchSpawn(ent);

  set_entvar(ent, var_origin, arr_wall[wall_index]);
  entity_set_size(ent, mins, maxs);
  set_entvar(ent, var_solid, SOLID_BBOX);
  set_entvar(ent, var_movetype, MOVETYPE_PUSH);

  set_entvar(ent, var_rendermode, kRenderNormal);
  set_entvar(ent, var_renderamt, 255.0);
  

  return ent;
}

parse_floats(const value[], Float:out[], count)
{
  new buffer[256];
  copy(buffer, charsmax(buffer), value);

  new pos = 0;
  new parsed = 0;
  new len = strlen(buffer);

  while (pos < len && parsed < count)
  {
    while (pos < len && (buffer[pos] == ' ' || buffer[pos] == 9))
    {
      pos++;
    }
    if (pos >= len)
    {
      break;
    }

    new start = pos;
    while (pos < len && buffer[pos] != ' ' && buffer[pos] != 9)
    {
      pos++;
    }

    new saved = buffer[pos];
    buffer[pos] = 0;
    out[parsed] = str_to_float(buffer[start]);
    buffer[pos] = saved;
    parsed++;
  }

  return parsed;
}

get_config_path(output[], len)
{
  new mapname[32];
  get_mapname(mapname, charsmax(mapname));
  strtolower(mapname);

  new configsdir[PLATFORM_MAX_PATH];
  get_configsdir(configsdir, charsmax(configsdir));

  formatex(output, len, "%s/retakes/%s.ini", configsdir, mapname);
}

remove_all_walls()
{
  for (new i = 0; i < arr_wall_count; i++)
  {
    if (arr_wallent[i] > 0)
    {
      rg_remove_entity(arr_wallent[i]);
    }
    arr_wallent[i] = 0;
  }

  arr_wall_count = 0;
}

clear_spawns()
{
  for (new i = 0; i < SPAWN_SLOTS; i++)
  {
    arr_spawn_count[i] = 0;
  }
}