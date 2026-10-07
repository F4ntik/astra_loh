import contextlib
import io
from pathlib import Path
import tempfile
import unittest

from scripts.check_config import main, parse_numbers, validate_text


FIXTURE = Path(__file__).resolve().parents[1] / "de_dust2.ini"


class ConfigTests(unittest.TestCase):
    def setUp(self):
        self.config = FIXTURE.read_text(encoding="utf-8")

    def test_repository_fixture_is_ready_for_one_vs_one(self):
        result = validate_text(self.config)
        self.assertEqual(result.errors, [])
        self.assertEqual(result.capacity, 2)
        self.assertEqual(result.walls, 2)

    def test_capacity_only_enforced_when_requested(self):
        self.assertEqual(validate_text(self.config, 2).errors, [])
        self.assertTrue(any("capacity is 2" in error for error in validate_text(self.config, 10).errors))

    def test_odd_player_needs_an_extra_ct_spawn_on_both_sites(self):
        expanded = self.config.replace("[spawns_ct_a]", "[spawns_ct_a]\n1 = 4096 0 0 0 0 0")
        expanded = expanded.replace("[spawns_ct_b]", "[spawns_ct_b]\n1 = 4096 0 0 0 0 0")
        self.assertEqual(validate_text(expanded, 3).errors, [])
        self.assertEqual(validate_text(expanded).capacity, 3)
        self.assertTrue(validate_text(expanded, 4).errors)

    def test_malformed_numeric_rows(self):
        for row in ("0 0 0 0 0", "0 0 0 0 0 0 1", "bad 0 0 0 0 0", "1junk 0 0 0 0 0",
                    "nan 0 0 0 0 0", "inf 0 0 0 0 0", "1e99 0 0 0 0 0", "32769 0 0 0 0 0",
                    "1_000 0 0 0 0 0", "0 0 0\n0 0 0", "0\u00a00 0 0 0 0"):
            with self.subTest(row=row), self.assertRaises(ValueError):
                parse_numbers(row, 6)

    def test_valid_numeric_forms_and_boundaries(self):
        self.assertEqual(parse_numbers("+1 -2.5 .5 1. -3e2 32768", 6), [1, -2.5, .5, 1, -300, 32768])

    def test_wall_size_bounds(self):
        for size in ("0", "-1", "0.5", "4097"):
            with self.subTest(size=size):
                result = validate_text(self.config.replace("64.000000", size))
                self.assertTrue(any("wall size" in error for error in result.errors))
        for size in ("1", "4096"):
            with self.subTest(size=size):
                self.assertEqual(validate_text(self.config.replace("64.000000", size)).errors, [])

    def test_invalid_wall_names(self):
        for name in ("x" * 64, "name[bad]", "name;bad", "name#bad", "name=bad", "name\x7fbad",
                     "name\nbad", "name\rbad", "", "\u044f" * 32):
            with self.subTest(name=name):
                self.assertTrue(validate_text(self.config.replace("wall_1", name)).errors)
        self.assertEqual(validate_text(self.config.replace("wall_1", "x" * 63)).errors, [])

    def test_wall_names_are_case_insensitively_unique(self):
        result = validate_text(self.config.replace("wall_2", "WALL_1"))
        self.assertTrue(any("duplicate wall name" in error for error in result.errors))

    def test_spawn_keys_are_decimal_digits(self):
        for key in ("name", "-1", "1.5", "1" * 64):
            with self.subTest(key=key):
                result = validate_text(self.config.replace("0 =", f"{key} ="))
                self.assertTrue(any("spawn key" in error for error in result.errors))

    def test_missing_and_empty_spawn_sections(self):
        self.assertTrue(any("missing section" in error for error in validate_text("[walls]\nx = 0 0 0 64").errors))
        empty = "\n".join(f"[{name}]" for name in ("spawns_t_a", "spawns_t_b", "spawns_ct_a", "spawns_ct_b"))
        self.assertEqual(len(validate_text(empty).errors), 4)

    def test_spawn_and_wall_limits(self):
        for section, count, numbers in (("spawns_t_a", 32, "0 0 0 0 0 0"), ("walls", 64, "0 0 0 64")):
            with self.subTest(section=section):
                extra = "\n".join(f"extra_{index} = {numbers}" for index in range(count))
                result = validate_text(self.config.replace(f"[{section}]", f"[{section}]\n{extra}"))
                self.assertTrue(any("maximum is" in error for error in result.errors))

    def test_cross_team_overlapping_spawns(self):
        lines = self.config.splitlines()
        first_spawn = next(line for line in lines if line.startswith("0 ="))
        ct_index = lines.index("[spawns_ct_a]") + 1
        lines[ct_index] = first_spawn
        self.assertTrue(any("overlapping" in error for error in validate_text("\n".join(lines)).errors))

    def test_exact_player_hull_boundary_does_not_overlap(self):
        lines = self.config.splitlines()
        lines[lines.index("[spawns_t_a]") + 1] = "0 = 0 0 0 0 0 0"
        lines[lines.index("[spawns_ct_a]") + 1] = "0 = 32 0 0 0 0 0"
        self.assertEqual(validate_text("\n".join(lines)).errors, [])

    def test_duplicate_sections_and_default_values(self):
        self.assertTrue(validate_text(self.config + "\n[SPAWNS_T_A]\nx = 0 0 0 0 0 0").errors)
        self.assertTrue(validate_text("[DEFAULT]\nx = 0 0 0 0 0 0\n" + self.config).errors)

    def test_unknown_sections_header_suffixes_and_long_values(self):
        self.assertTrue(validate_text(self.config + "\n[unknown]\nx = 1").errors)
        self.assertTrue(validate_text(self.config.replace("[walls]", "[walls] trailing")).errors)
        self.assertTrue(validate_text(self.config.replace("[walls]", "[ walls ]")).errors)
        self.assertTrue(validate_text(self.config.replace("64.000000", "0" * 256 + "64")).errors)

    def test_cli_exit_codes_and_summary(self):
        output = io.StringIO()
        with contextlib.redirect_stdout(output):
            self.assertEqual(main([str(FIXTURE)]), 0)
            self.assertEqual(main([str(FIXTURE), "--players", "10"]), 1)
            with tempfile.TemporaryDirectory() as directory:
                self.assertEqual(main([str(Path(directory) / "missing.ini")]), 1)
        self.assertIn("capacity 2 players", output.getvalue())
        self.assertIn("ERROR", output.getvalue())


if __name__ == "__main__":
    unittest.main()
