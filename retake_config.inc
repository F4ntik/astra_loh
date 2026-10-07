#if defined _retake_config_included
  #endinput
#endif
#define _retake_config_included

#include <string>

#define RT_MAX_SPAWNS 32
#define RT_MAX_WALLS 64
#define RT_WALL_NAME_LEN 64

// Require complete numeric tokens: str_to_float alone also accepts garbage.
stock bool:rt_parse_floats(const value[], Float:output[], count)
{
  new buffer[256];
  if (strlen(value) >= sizeof(buffer)) return false;
  copy(buffer, charsmax(buffer), value);

  new pos, parsed, length = strlen(buffer);
  while (pos < length)
  {
    while (pos < length && (buffer[pos] == ' ' || buffer[pos] == 9)) pos++;
    if (pos == length) break;
    if (parsed >= count) return false;

    new start = pos;
    while (pos < length && buffer[pos] != ' ' && buffer[pos] != 9) pos++;
    for (new i = start; i < pos; i++)
    {
      if ((buffer[i] < '0' || buffer[i] > '9') && buffer[i] != '+' &&
          buffer[i] != '-' && buffer[i] != '.' && buffer[i] != 'e' && buffer[i] != 'E')
        return false;
    }
    new saved = buffer[pos];
    buffer[pos] = 0;
    new consumed;
    new Float:number = strtof(buffer[start], consumed);
    buffer[pos] = saved;
    if (consumed != pos - start || consumed == 0) return false;
    // This ordered comparison also rejects NaN and infinity.
    if (!(number >= -32768.0 && number <= 32768.0)) return false;
    output[parsed++] = number;
  }
  return parsed == count;
}

stock bool:rt_valid_wall_name(const name[])
{
  new length = strlen(name);
  if (length == 0 || length >= RT_WALL_NAME_LEN) return false;
  if (name[0] == ' ' || name[length - 1] == ' ') return false;
  for (new i; i < length; i++)
  {
    if (name[i] < 32 || name[i] == 127 || name[i] == '=' ||
        name[i] == '[' || name[i] == ']' || name[i] == ';' || name[i] == '#')
      return false;
  }
  return true;
}
