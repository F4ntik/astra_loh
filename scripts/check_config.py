"""Validate retake map INI files without running a Counter-Strike server.

The validator requires canonical INI: each section and key occurs once.
The plugin can append repeated spawn sections or keys, but the editor writes
unique sections and keys; consolidate hand-written duplicates before validation.
"""

import argparse
import configparser
from dataclasses import dataclass, field
import itertools
import math
from pathlib import Path
import re


SPAWN_SECTIONS = ("spawns_t_a", "spawns_t_b", "spawns_ct_a", "spawns_ct_b")
NUMBER = re.compile(r"[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\Z")
MAX_SPAWNS = 32
MAX_WALLS = 64


@dataclass
class ValidationResult:
    counts: dict[str, int] = field(default_factory=lambda: dict.fromkeys(SPAWN_SECTIONS, 0))
    walls: int = 0
    capacity: int = 0
    errors: list[str] = field(default_factory=list)


def parse_numbers(value: str, count: int) -> list[float]:
    if "\n" in value or "\r" in value:
        raise ValueError("a row must fit on one line")
    tokens = re.split(r"[ \t]+", value.strip(" \t"))
    if len(tokens) != count:
        raise ValueError(f"expected exactly {count} numbers, got {len(tokens)}")
    if any(not NUMBER.fullmatch(token) for token in tokens):
        raise ValueError("use decimal numbers, for example -12.5 or 1e2")
    numbers = [float(token) for token in tokens]
    if any(not math.isfinite(number) or abs(number) > 32768 for number in numbers):
        raise ValueError("numbers must be finite and within -32768..32768")
    return numbers


def validate_text(text: str, players: int | None = None) -> ValidationResult:
    result = ValidationResult()
    for line_number, raw_line in enumerate(text.splitlines(keepends=True), 1):
        line = raw_line.strip()
        if len(raw_line.encode("utf-8")) >= 383:
            result.errors.append(f"line {line_number}: too long for the plugin's 384-byte buffer")
        if not line or line.startswith((";", "#")):
            continue
        if line.startswith("[") and not line.endswith("]"):
            result.errors.append(f"line {line_number}: expected a complete [section] header")
        elif "=" in line and len(line.split("=", 1)[1].encode("utf-8")) >= 256:
            result.errors.append(f"line {line_number}: value must be shorter than 256 UTF-8 bytes")
    config = configparser.ConfigParser(
        interpolation=None, delimiters=("=",), inline_comment_prefixes=None,
        empty_lines_in_values=False,
    )
    config.optionxform = str
    try:
        config.read_string(text)
    except configparser.Error as error:
        result.errors.append(f"invalid INI syntax: {error}")
        return result

    if config.defaults():
        result.errors.append("[DEFAULT] values are unsupported; put rows in their own section")
        return result

    sections = {}
    for section in config.sections():
        name = section.lower()
        if name in sections:
            result.errors.append(f"duplicate section [{name}]")
        sections[name] = section
        if name not in (*SPAWN_SECTIONS, "walls"):
            result.errors.append(f"unknown section [{section}]")

    spawns = {name: [] for name in SPAWN_SECTIONS}
    for name in SPAWN_SECTIONS:
        if name not in sections:
            result.errors.append(f"missing section [{name}]")
            continue
        rows = config[sections[name]]
        if not rows:
            result.errors.append(f"[{name}] needs at least one spawn")
        if len(rows) > MAX_SPAWNS:
            result.errors.append(f"[{name}] has {len(rows)} rows; maximum is {MAX_SPAWNS}")
        for key, value in rows.items():
            if not re.fullmatch(r"[0-9]{1,63}", key):
                result.errors.append(f"[{name}] {key!r}: spawn key must contain 1..63 decimal digits")
            try:
                point = parse_numbers(value, 6)
                spawns[name].append((key, point))
                result.counts[name] += 1
            except ValueError as error:
                result.errors.append(f"[{name}] {key}: {error}")

    # Standing player hulls must not overlap, including opposing teams at one site.
    for site in ("a", "b"):
        points = [(f"[{name}] {key}", point) for name in SPAWN_SECTIONS if name.endswith(site)
                  for key, point in spawns[name]]
        for (first_key, first), (second_key, second) in itertools.combinations(points, 2):
            if all(abs(first[axis] - second[axis]) < size
                   for axis, size in enumerate((32, 32, 72))):
                result.errors.append(f"{first_key} and {second_key}: overlapping standing player spawns")

    if "walls" in sections:
        rows = config[sections["walls"]]
        result.walls = len(rows)
        if result.walls > MAX_WALLS:
            result.errors.append(f"[walls] has {result.walls} rows; maximum is {MAX_WALLS}")
        names = set()
        for key, value in rows.items():
            if key.lower() in names:
                result.errors.append(f"[walls] {key!r}: duplicate wall name (case-insensitive)")
            names.add(key.lower())
            if (not key or len(key.encode("utf-8")) > 63
                    or any(char in "=[];#" or ord(char) < 32 or ord(char) == 127 for char in key)):
                result.errors.append(f"[walls] {key!r}: name must be 1..63 UTF-8 bytes without =[];# or control characters")
            try:
                numbers = parse_numbers(value, 4)
                if not 1 <= numbers[3] <= 4096:
                    raise ValueError("wall size must be within 1..4096")
            except ValueError as error:
                result.errors.append(f"[walls] {key}: {error}")

    for count in range(2, 33):
        if all(result.counts[f"spawns_t_{site}"] >= count // 2
               and result.counts[f"spawns_ct_{site}"] >= (count + 1) // 2 for site in ("a", "b")):
            result.capacity = count
    if players is not None:
        if not 2 <= players <= 32:
            result.errors.append("requested player count must be within 2..32")
        elif result.capacity < players:
            result.errors.append(
                f"capacity is {result.capacity} players; {players} players need at least "
                f"{players // 2} T and {(players + 1) // 2} CT spawns on each site"
            )
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", type=Path, nargs="+", help="map INI file(s) to validate")
    parser.add_argument("--players", type=int, choices=range(2, 33), metavar="2..32",
                        help="also require enough spawns for this player count (odd player goes to CT)")
    args = parser.parse_args(argv)
    failed = False
    for path in args.files:
        try:
            result = validate_text(path.read_text(encoding="utf-8"), args.players)
        except (OSError, UnicodeError) as error:
            print(f"ERROR {path}: {error}")
            failed = True
            continue
        for error in result.errors:
            print(f"ERROR {path}: {error}")
        failed |= bool(result.errors)
        if not result.errors:
            print(f"OK {path}: A {result.counts['spawns_t_a']}T/{result.counts['spawns_ct_a']}CT, "
                  f"B {result.counts['spawns_t_b']}T/{result.counts['spawns_ct_b']}CT; "
                  f"capacity {result.capacity} players; {result.walls} walls")
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
