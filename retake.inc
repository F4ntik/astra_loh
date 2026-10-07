#if defined _retake_included
  #endinput
#endif
#define _retake_included

// --- Slots ---
enum
{
  SPAWN_T_A = 0,
  SPAWN_T_B,
  SPAWN_CT_A,
  SPAWN_CT_B,
  SPAWN_SLOTS
}

// --- Natives (provided by retake_map) ---
native retake_map_has_config();
native retake_map_get_spawn(slot, Float:origin[3], Float:angles[3]);
native retake_map_spawn_count(slot);
// Reset reservations once before the players spawn for a new round.
native retake_map_reset_spawns();

// --- Forwards ---
forward retake_map_loaded();
forward retake_config_saved();
forward retake_round_start();
forward retake_round_end();
