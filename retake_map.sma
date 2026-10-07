#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <engine>

#include <retake>
#include <retake_config>

#define PLUGIN_NAME "Retake Map"
#define PLUGIN_VERSION "0.1"
#define PLUGIN_AUTHOR "Asura"

new bool:g_has_map_cfg;
new Float:arr_spawn[SPAWN_SLOTS][RT_MAX_SPAWNS][6];
new arr_spawn_count[SPAWN_SLOTS];
new bool:g_spawn_used[SPAWN_SLOTS][RT_MAX_SPAWNS];
new arr_wallent[RT_MAX_WALLS];
new arr_wall_count;
new forw_map_cfg_loaded;

new const WALL_MODEL[] = "models/box.mdl";
new const WALL_CLASSNAME[] = "retake_map_wall";
new const SPAWN_SECTIONS[SPAWN_SLOTS][] = {
  "spawns_t_a", "spawns_t_b", "spawns_ct_a", "spawns_ct_b"
};

public plugin_precache()
{
  precache_model(WALL_MODEL);
}

public plugin_init()
{
  register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);
  register_srvcmd("retake_map_status", "cmd_map_status");
  forw_map_cfg_loaded = CreateMultiForward("retake_map_loaded", ET_IGNORE);
}

public plugin_natives()
{
  register_native("retake_map_has_config", "RTM_has_config");
  register_native("retake_map_get_spawn", "RTM_get_spawn");
  register_native("retake_map_spawn_count", "RTM_spawn_count");
  register_native("retake_map_reset_spawns", "RTM_reset_spawns");
}

public plugin_cfg()
{
  load_config();
}

public plugin_end()
{
  for (new i; i < arr_wall_count; i++) remove_owned_wall(arr_wallent[i]);
  DestroyForward(forw_map_cfg_loaded);
}

public retake_config_saved()
{
  load_config();
}

public RTM_has_config()
{
  return g_has_map_cfg;
}

public RTM_spawn_count(plugin_id, num_params)
{
  if (num_params != 1) return 0;
  new slot = get_param(1);
  if (slot < 0 || slot >= SPAWN_SLOTS) return 0;
  return arr_spawn_count[slot];
}

public RTM_reset_spawns()
{
  for (new slot; slot < SPAWN_SLOTS; slot++)
    for (new i; i < RT_MAX_SPAWNS; i++) g_spawn_used[slot][i] = false;
  return 1;
}

public RTM_get_spawn(plugin_id, num_params)
{
  if (num_params != 3) return 0;
  new slot = get_param(1);
  if (slot < 0 || slot >= SPAWN_SLOTS || !g_has_map_cfg) return 0;

  new available[RT_MAX_SPAWNS], count;
  for (new i; i < arr_spawn_count[slot]; i++)
    if (!g_spawn_used[slot][i]) available[count++] = i;
  if (!count) return 0;

  new index = available[random(count)];
  new Float:origin[3], Float:angles[3];
  for (new axis; axis < 3; axis++)
  {
    origin[axis] = arr_spawn[slot][index][axis];
    angles[axis] = arr_spawn[slot][index][axis + 3];
  }
  set_array_f(2, origin, sizeof(origin));
  set_array_f(3, angles, sizeof(angles));
  g_spawn_used[slot][index] = true;
  return 1;
}

public cmd_map_status()
{
  server_print("[Retake Map] Ready=%d, walls=%d", g_has_map_cfg, arr_wall_count);
  for (new slot; slot < SPAWN_SLOTS; slot++)
  {
    new used;
    for (new i; i < arr_spawn_count[slot]; i++)
      if (g_spawn_used[slot][i]) used++;
    server_print("[Retake Map] %s: total=%d, remaining=%d", SPAWN_SECTIONS[slot],
      arr_spawn_count[slot], arr_spawn_count[slot] - used);
  }
  return PLUGIN_HANDLED;
}

load_config()
{
  // Parse and build a complete replacement before touching the active map.
  static Float:spawns[SPAWN_SLOTS][RT_MAX_SPAWNS][6];
  static spawn_count[SPAWN_SLOTS];
  static Float:walls[RT_MAX_WALLS][4];
  static wall_names[RT_MAX_WALLS][RT_WALL_NAME_LEN];
  static wall_entities[RT_MAX_WALLS];
  arrayset(spawn_count, 0, sizeof(spawn_count));
  arrayset(wall_entities, 0, sizeof(wall_entities));
  new wall_count;

  new path[PLATFORM_MAX_PATH];
  get_config_path(path, charsmax(path));
  new file = fopen(path, "r");
  if (!file)
  {
    config_rejected(path, 0, "cannot read file; save a complete map configuration first");
    return;
  }

  new line[384], line_number, section = -1, reason[192];
  while (fgets(file, line, charsmax(line)))
  {
    line_number++;
    if (strlen(line) == charsmax(line))
    {
      copy(reason, charsmax(reason), "line is too long; shorten this entry");
      break;
    }
    trim(line);
    if (!line[0] || line[0] == ';' || line[0] == '#') continue;

    if (line[0] == '[')
    {
      new length = strlen(line);
      if (line[length - 1] != ']')
      {
        copy(reason, charsmax(reason), "expected a complete [section] header");
        break;
      }
      line[length - 1] = 0;
      section = -1;
      for (new slot; slot < SPAWN_SLOTS; slot++)
        if (equali(line[1], SPAWN_SECTIONS[slot])) section = slot;
      if (equali(line[1], "walls")) section = SPAWN_SLOTS;
      if (section == -1)
      {
        copy(reason, charsmax(reason), "unknown section; use spawns_t_a, spawns_t_b, spawns_ct_a, spawns_ct_b or walls");
        break;
      }
      continue;
    }

    new eq = strfind(line, "=");
    if (section == -1 || eq <= 0)
    {
      copy(reason, charsmax(reason), "expected key = values inside a known section");
      break;
    }
    if (strlen(line[eq + 1]) >= 256)
    {
      copy(reason, charsmax(reason), "value is too long; shorten this entry");
      break;
    }
    new value[256];
    copy(value, charsmax(value), line[eq + 1]);
    line[eq] = 0;
    trim(line);
    if (!line[0] || strlen(line) >= RT_WALL_NAME_LEN)
    {
      copy(reason, charsmax(reason), "key must contain 1..63 characters");
      break;
    }

    new Float:values[6];
    if (!rt_parse_floats(value, values, section == SPAWN_SLOTS ? 4 : 6))
    {
      copy(reason, charsmax(reason), "expected exactly 6 spawn numbers or 4 wall numbers, each within -32768..32768");
      break;
    }

    if (section < SPAWN_SLOTS)
    {
      for (new c; line[c]; c++)
      {
        if (line[c] < '0' || line[c] > '9')
        {
          copy(reason, charsmax(reason), "spawn key must be a non-negative integer");
          break;
        }
      }
      if (reason[0]) break;
      if (spawn_count[section] == RT_MAX_SPAWNS)
      {
        formatex(reason, charsmax(reason), "%s exceeds the limit of %d spawns", SPAWN_SECTIONS[section], RT_MAX_SPAWNS);
        break;
      }

      // Enum slots alternate A/B; reject intersecting standing-player boxes at the same site.
      for (new other = section % 2; other < SPAWN_SLOTS; other += 2)
      {
        for (new i; i < spawn_count[other]; i++)
        {
          if (floatabs(values[0] - spawns[other][i][0]) < 32.0 &&
              floatabs(values[1] - spawns[other][i][1]) < 32.0 &&
              floatabs(values[2] - spawns[other][i][2]) < 72.0)
          {
            formatex(reason, charsmax(reason), "spawn overlaps %s entry %d; separate player boxes by 32 horizontally or 72 vertically", SPAWN_SECTIONS[other], i);
            break;
          }
        }
        if (reason[0]) break;
      }
      if (reason[0]) break;
      new index = spawn_count[section]++;
      for (new i; i < 6; i++) spawns[section][index][i] = values[i];
    }
    else
    {
      if (!rt_valid_wall_name(line))
      {
        copy(reason, charsmax(reason), "invalid wall name; remove control characters and INI delimiters");
        break;
      }
      if (wall_count == RT_MAX_WALLS || values[3] < 1.0 || values[3] > 4096.0)
      {
        copy(reason, charsmax(reason), "wall limit is 64 and wall size must be within 1..4096");
        break;
      }
      for (new i; i < wall_count; i++)
      {
        if (equali(line, wall_names[i]))
        {
          copy(reason, charsmax(reason), "duplicate wall name; give every wall a unique name");
          break;
        }
      }
      if (reason[0]) break;
      copy(wall_names[wall_count], RT_WALL_NAME_LEN - 1, line);
      for (new i; i < 4; i++) walls[wall_count][i] = values[i];
      wall_count++;
    }
  }
  if (!feof(file) && !reason[0])
    copy(reason, charsmax(reason), "file read failed before end of file");
  fclose(file);

  if (reason[0])
  {
    config_rejected(path, line_number, reason);
    return;
  }
  for (new slot; slot < SPAWN_SLOTS; slot++)
  {
    if (!spawn_count[slot])
    {
      formatex(reason, charsmax(reason), "section [%s] requires at least one spawn", SPAWN_SECTIONS[slot]);
      config_rejected(path, 0, reason);
      return;
    }
  }

  for (new i; i < wall_count; i++)
  {
    wall_entities[i] = create_wall_entity(walls[i]);
    if (!wall_entities[i])
    {
      for (new j; j < i; j++) remove_owned_wall(wall_entities[j]);
      formatex(reason, charsmax(reason), "cannot create wall '%s'; check free entity capacity", wall_names[i]);
      config_rejected(path, 0, reason);
      return;
    }
  }

  for (new i; i < arr_wall_count; i++) remove_owned_wall(arr_wallent[i]);
  arr_wall_count = wall_count;
  for (new i; i < wall_count; i++)
  {
    arr_wallent[i] = wall_entities[i];
    set_entvar(arr_wallent[i], var_solid, SOLID_BBOX);
    new Float:origin[3];
    for (new axis; axis < 3; axis++) origin[axis] = walls[i][axis];
    entity_set_origin(arr_wallent[i], origin);
  }
  for (new slot; slot < SPAWN_SLOTS; slot++)
  {
    arr_spawn_count[slot] = spawn_count[slot];
    for (new i; i < spawn_count[slot]; i++)
      for (new axis; axis < 6; axis++) arr_spawn[slot][i][axis] = spawns[slot][i][axis];
  }
  RTM_reset_spawns();
  g_has_map_cfg = true;
  log_amx("[Retake Map] Applied %s: T/A=%d T/B=%d CT/A=%d CT/B=%d, walls=%d", path,
    arr_spawn_count[SPAWN_T_A], arr_spawn_count[SPAWN_T_B],
    arr_spawn_count[SPAWN_CT_A], arr_spawn_count[SPAWN_CT_B], arr_wall_count);
  ExecuteForward(forw_map_cfg_loaded);
}

config_rejected(const path[], line, const reason[])
{
  log_amx("[Retake Map] Rejected %s (line %d): %s", path, line, reason);
  if (g_has_map_cfg) log_amx("[Retake Map] Previous valid configuration remains active.");
  else log_amx("[Retake Map] Retake unavailable until the configuration is corrected.");
}

create_wall_entity(const Float:wall[4])
{
  new ent = rg_create_entity("func_wall", false);
  if (ent <= MaxClients || !is_valid_ent(ent)) return 0;
  entity_set_model(ent, WALL_MODEL);
  DispatchSpawn(ent);
  if (!is_valid_ent(ent)) return 0;
  set_entvar(ent, var_classname, WALL_CLASSNAME);
  set_entvar(ent, var_solid, SOLID_NOT);
  set_entvar(ent, var_movetype, MOVETYPE_NONE);

  new Float:half = wall[3] / 2.0;
  new Float:mins[3], Float:maxs[3], Float:origin[3];
  for (new axis; axis < 3; axis++)
  {
    mins[axis] = -half;
    maxs[axis] = half;
    origin[axis] = wall[axis];
  }
  entity_set_size(ent, mins, maxs);
  entity_set_origin(ent, origin);
  set_entvar(ent, var_rendermode, kRenderNormal);
  set_entvar(ent, var_renderamt, 255.0);
  return ent;
}

remove_owned_wall(ent)
{
  if (ent <= MaxClients || !is_valid_ent(ent)) return;
  new classname[32];
  entity_get_string(ent, EV_SZ_classname, classname, charsmax(classname));
  if (equal(classname, WALL_CLASSNAME)) remove_entity(ent);
}

get_config_path(output[], len)
{
  new mapname[32], configsdir[PLATFORM_MAX_PATH];
  get_mapname(mapname, charsmax(mapname));
  strtolower(mapname);
  get_configsdir(configsdir, charsmax(configsdir));
  formatex(output, len, "%s/retakes/%s.ini", configsdir, mapname);
}
