"""Tests for src/core/config.py: config file loading, validation and the
variable store with its subscriptions.

config.py needs only the standard library and PyYAML (no GTK), so it is loaded
straight from its file, once per test: the module keeps its defaults in a
module-level dict that Config.init() mutates in place, and a fresh load gives
every test a pristine copy.

Run from the repository root:

    python3 -m unittest discover -s tests -v
"""

import contextlib
import importlib.util
import io
import tempfile
import unittest
from pathlib import Path

CONFIG_PY = Path(__file__).resolve().parent.parent / "src" / "core" / "config.py"

GIGABYTE = 1000 * 1000 * 1000

VALID_CONFIG = """\
distribution_name: Testix
scripts:
  install: scripts/install.sh
"""


def load_module():
    spec = importlib.util.spec_from_file_location("os_installer_config", CONFIG_PY)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ConfigTestCase(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def quiet(self, func, *args, **kwargs):
        """Run func, returning (result, captured stdout); the module reports by print."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            result = func(*args, **kwargs)
        return result, out.getvalue()

    def write_config(self, text, name="config.yaml"):
        path = Path(self.tmp.name) / name
        path.write_text(text)
        return path

    def init_from(self, text, demo=False, test=False):
        cfg = self.mod.Config()
        path = self.write_config(text)
        self.quiet(cfg.init, str(path), demo, test)
        return cfg


class MatchTest(ConfigTestCase):
    def test_present_with_expected_type(self):
        ok, out = self.quiet(self.mod._match, {"a": 1}, "a", int)
        self.assertTrue(ok)
        self.assertEqual(out, "")

    def test_missing_variable_is_reported(self):
        ok, out = self.quiet(self.mod._match, {}, "a", int)
        self.assertFalse(ok)
        self.assertIn("a does not exist", out)

    def test_wrong_type_is_reported(self):
        ok, out = self.quiet(self.mod._match, {"a": "x"}, "a", int)
        self.assertFalse(ok)
        self.assertIn("not of expected type", out)

    def test_any_of_several_types(self):
        for value in (1, 1.5):
            ok, _ = self.quiet(self.mod._match, {"a": value}, "a", int, float)
            self.assertTrue(ok, value)

    def test_bool_is_not_accepted_as_int(self):
        # The check is `type(x) in ok_types`, not isinstance, so True is not an int.
        ok, _ = self.quiet(self.mod._match, {"a": True}, "a", int)
        self.assertFalse(ok)


class ValidateScriptsTest(ConfigTestCase):
    def test_install_script_is_enough(self):
        ok, _ = self.quiet(self.mod._validate_scripts,
                           {"scripts": {"install": "i.sh", "configure": None}})
        self.assertTrue(ok)

    def test_configure_script_is_enough(self):
        ok, _ = self.quiet(self.mod._validate_scripts,
                           {"scripts": {"install": None, "configure": "c.sh"}})
        self.assertTrue(ok)

    def test_neither_script_is_rejected(self):
        ok, out = self.quiet(self.mod._validate_scripts,
                             {"scripts": {"install": None, "configure": None}})
        self.assertFalse(ok)
        self.assertIn("Either install or configure script must exist", out)

    def test_default_scripts_are_rejected(self):
        # prepare alone cannot install anything; the shipped defaults have no scripts.
        ok, _ = self.quiet(self.mod._validate_scripts, self.mod.default_config)
        self.assertFalse(ok)

    def test_scripts_of_wrong_type_are_rejected_without_indexing(self):
        ok, out = self.quiet(self.mod._validate_scripts, {"scripts": "install.sh"})
        self.assertFalse(ok)
        self.assertIn("scripts not of expected type", out)

    def test_scripts_missing_is_rejected(self):
        ok, _ = self.quiet(self.mod._validate_scripts, {})
        self.assertFalse(ok)


class ValidateTest(ConfigTestCase):
    def test_default_config_is_valid(self):
        ok, out = self.quiet(self.mod._validate, self.mod.default_config)
        self.assertTrue(ok, out)

    def test_wrong_type_fails(self):
        self.mod.default_config["disk"]["partition_ok"] = "yes"
        ok, out = self.quiet(self.mod._validate, self.mod.default_config)
        self.assertFalse(ok)
        self.assertIn("partition_ok not of expected type", out)

    def test_missing_key_fails(self):
        del self.mod.default_config["user"]["request_username"]
        ok, out = self.quiet(self.mod._validate, self.mod.default_config)
        self.assertFalse(ok)
        self.assertIn("request_username does not exist", out)

    def test_disk_min_size_accepts_float(self):
        self.mod.default_config["disk"]["min_size"] = 7.5
        ok, _ = self.quiet(self.mod._validate, self.mod.default_config)
        self.assertTrue(ok)

    def test_fixed_language_string_is_valid(self):
        self.mod.default_config["fixed_language"] = "de_DE"
        ok, _ = self.quiet(self.mod._validate, self.mod.default_config)
        self.assertTrue(ok)

    def test_fixed_language_true_is_an_assertion_error(self):
        self.mod.default_config["fixed_language"] = True
        with self.assertRaisesRegex(AssertionError, "fixed language"):
            self.quiet(self.mod._validate, self.mod.default_config)


class InitTest(ConfigTestCase):
    def test_valid_file_is_loaded_and_not_demo(self):
        cfg = self.init_from(VALID_CONFIG)
        self.assertTrue(cfg.initialized)
        self.assertFalse(cfg.is_demo())
        self.assertFalse(cfg.is_test())
        self.assertEqual(cfg.get("distribution_name"), "Testix")
        self.assertEqual(cfg.get("scripts")["install"], "scripts/install.sh")

    def test_base_path_is_the_config_directory(self):
        cfg = self.init_from(VALID_CONFIG)
        self.assertEqual(cfg.base_path, Path(self.tmp.name).absolute())

    def test_min_size_is_converted_from_gigabytes_to_bytes(self):
        cfg = self.init_from(VALID_CONFIG + "disk:\n  min_size: 20\n")
        self.assertEqual(cfg.get("disk")["min_size"], 20 * GIGABYTE)

    def test_default_min_size_is_converted_too(self):
        cfg = self.init_from(VALID_CONFIG)
        self.assertEqual(cfg.get("disk")["min_size"], 5 * GIGABYTE)

    def test_nested_section_keeps_unspecified_defaults(self):
        cfg = self.init_from(VALID_CONFIG + "disk_encryption:\n  forced: true\n")
        section = cfg.get("disk_encryption")
        self.assertTrue(section["forced"])
        self.assertTrue(section["offered"])
        self.assertEqual(section["min_length"], 1)

    def test_unknown_property_is_ignored_with_a_message(self):
        cfg = self.mod.Config()
        path = self.write_config(VALID_CONFIG + "no_such_option: 1\n")
        _, out = self.quiet(cfg.init, str(path), False, False)
        self.assertIn('Ignoring unknown config for "no_such_option"', out)
        self.assertFalse(cfg.has("no_such_option"))
        self.assertFalse(cfg.is_demo())

    def test_internal_values_are_added(self):
        cfg = self.init_from(VALID_CONFIG)
        self.assertEqual(cfg.get("timezone"), "UTC")
        self.assertFalse(cfg.get("installation_running"))

    def test_missing_file_falls_back_to_demo(self):
        cfg = self.mod.Config()
        missing = Path(self.tmp.name) / "absent.yaml"
        _, out = self.quiet(cfg.init, str(missing), False, False)
        self.assertIn("Could not find config file", out)
        self.assertTrue(cfg.is_demo())
        self.assertTrue(cfg.initialized)

    def test_yaml_syntax_error_falls_back_to_demo(self):
        cfg = self.mod.Config()
        path = self.write_config("scripts: [unclosed\n")
        _, out = self.quiet(cfg.init, str(path), False, False)
        self.assertIn("syntax errors", out)
        self.assertTrue(cfg.is_demo())

    def test_config_without_scripts_falls_back_to_demo(self):
        cfg = self.mod.Config()
        path = self.write_config("distribution_name: Testix\n")
        _, out = self.quiet(cfg.init, str(path), False, False)
        self.assertIn("Config errors", out)
        self.assertTrue(cfg.is_demo())

    def test_wrongly_typed_value_falls_back_to_demo(self):
        cfg = self.mod.Config()
        path = self.write_config(VALID_CONFIG + "internet:\n  connection_required: maybe\n")
        _, out = self.quiet(cfg.init, str(path), False, False)
        self.assertIn("connection_required not of expected type", out)
        self.assertTrue(cfg.is_demo())

    def test_demo_flag(self):
        cfg = self.init_from(VALID_CONFIG, demo=True)
        self.assertTrue(cfg.is_demo())
        self.assertFalse(cfg.is_test())

    def test_test_flag(self):
        cfg = self.init_from(VALID_CONFIG, test=True)
        self.assertTrue(cfg.is_test())
        self.assertFalse(cfg.is_demo())

    def test_demo_wins_over_test(self):
        cfg = self.mod.Config()
        path = self.write_config(VALID_CONFIG)
        _, out = self.quiet(cfg.init, str(path), True, True)
        self.assertIn("Using demo mode", out)
        self.assertTrue(cfg.is_demo())
        self.assertFalse(cfg.is_test())

    def test_fallback_to_demo_overrides_test_mode(self):
        cfg = self.init_from("distribution_name: Testix\n", test=True)
        self.assertTrue(cfg.is_demo())
        self.assertFalse(cfg.is_test())


class LegacyValuesTest(ConfigTestCase):
    def test_top_level_rename(self):
        cfg = self.init_from(VALID_CONFIG + "skip_locale: true\n")
        self.assertIs(cfg.get("skip_region"), True)

    def test_moved_into_a_section(self):
        cfg = self.init_from(VALID_CONFIG + "minimum_disk_size: 12\n")
        self.assertEqual(cfg.get("disk")["min_size"], 12 * GIGABYTE)

    def test_moved_command_keeps_sibling_commands(self):
        cfg = self.init_from(VALID_CONFIG + "browser_cmd: firefox\n")
        commands = cfg.get("commands")
        self.assertEqual(commands["browser"], "firefox")
        self.assertEqual(commands["reboot"], "reboot")

    def test_deprecation_hint_names_the_replacement(self):
        cfg = self.mod.Config()
        path = self.write_config(VALID_CONFIG + "internet_checker_url: http://x/\n")
        _, out = self.quiet(cfg.init, str(path), False, False)
        self.assertIn('"internet_checker_url" is deprecated, use "internet -> checker_url"', out)
        self.assertEqual(cfg.get("internet")["checker_url"], "http://x/")

    def test_removed_option_is_reported_and_not_stored(self):
        cfg = self.mod.Config()
        path = self.write_config(VALID_CONFIG + "suggested_languages: [de]\n")
        _, out = self.quiet(cfg.init, str(path), False, False)
        self.assertIn('"suggested_languages" has been removed', out)
        self.assertIn("all languages with translations are listed", out)
        self.assertFalse(cfg.has("suggested_languages"))

    def test_conditional_replacement(self):
        # No shipped option uses the four-element form. It is only reached for a
        # tuple: a list is taken by the "moved" branch above it, whatever its length.
        self.mod.legacy_values["old_flag"] = ("new_flag", "yes", "on", "off")
        cfg = self.mod.Config()
        self.quiet(cfg._handle_legacy, "old_flag", "yes")
        self.assertEqual(cfg.variables["new_flag"], "on")
        self.quiet(cfg._handle_legacy, "old_flag", "no")
        self.assertEqual(cfg.variables["new_flag"], "off")

    def test_overlong_move_path_is_an_internal_error(self):
        self.mod.legacy_values["old_flag"] = ["a", "b", "c"]
        cfg = self.mod.Config()
        _, out = self.quiet(cfg._handle_legacy, "old_flag", 1)
        self.assertIn("Unhandled legacy replacement", out)


class VariableStoreTest(ConfigTestCase):
    def setUp(self):
        super().setUp()
        self.cfg = self.init_from(VALID_CONFIG)

    def test_get_known_variable(self):
        self.assertEqual(self.cfg.get("distribution_name"), "Testix")

    def test_get_uses_fallback_with_a_message(self):
        value, out = self.quiet(self.cfg.get, "welcome_page_image")
        self.assertEqual(value, "weather-clear-symbolic")
        self.assertIn("Using fallback value for welcome_page_image", out)

    def test_config_value_beats_fallback(self):
        self.cfg.set("chosen_device", "/dev/sda")
        self.assertEqual(self.cfg.get("chosen_device"), "/dev/sda")

    def test_get_unknown_is_none(self):
        value, out = self.quiet(self.cfg.get, "nonsense")
        self.assertIsNone(value)
        self.assertIn('Requested "nonsense" not in config', out)

    def test_has_ignores_fallbacks(self):
        self.assertTrue(self.cfg.has("distribution_name"))
        self.assertFalse(self.cfg.has("welcome_page_image"))

    def test_set_reports_whether_it_changed(self):
        self.assertTrue(self.cfg.set("timezone", "Europe/Berlin"))
        self.assertFalse(self.cfg.set("timezone", "Europe/Berlin"))
        self.assertEqual(self.cfg.get("timezone"), "Europe/Berlin")

    def test_set_notifies_subscribers_only_on_change(self):
        seen = []
        self.cfg.subscribe("timezone", seen.append)
        self.assertEqual(seen, ["UTC"])  # subscribing delivers the current value
        self.cfg.set("timezone", "Asia/Tokyo")
        self.cfg.set("timezone", "Asia/Tokyo")
        self.assertEqual(seen, ["UTC", "Asia/Tokyo"])

    def test_set_before_init_complains_unless_fallback(self):
        cfg = self.mod.Config()
        _, out = self.quiet(cfg.set, "timezone", "UTC+1")
        self.assertIn('Setting "timezone" before config was read', out)
        _, out = self.quiet(cfg.set, "chosen_device", "/dev/sda")
        self.assertNotIn("before config was read", out)

    def test_set_next_page_sets_displayed_page_and_returns_false(self):
        result = self.cfg.set_next_page("disk")
        self.assertIs(result, False)
        self.assertEqual(self.cfg.get("displayed-page"), ("next", "disk"))

    def test_steal_removes_and_returns(self):
        self.assertEqual(self.cfg.steal("timezone"), "UTC")
        self.assertFalse(self.cfg.has("timezone"))
        self.assertIsNone(self.cfg.steal("timezone"))

    def test_bump_republishes_without_changing(self):
        seen = []
        self.cfg.subscribe("timezone", seen.append, delayed=True)
        self.assertEqual(seen, [])  # delayed: nothing delivered yet
        self.cfg.bump("timezone")
        self.assertEqual(seen, ["UTC"])

    def test_subscribe_to_fallback_variable_is_silent(self):
        _, out = self.quiet(self.cfg.subscribe, "chosen_device", lambda v: None)
        self.assertNotIn("Internal error", out)

    def test_subscribe_to_unknown_variable_is_an_internal_error(self):
        called = []
        _, out = self.quiet(self.cfg.subscribe, "nonsense", called.append)
        self.assertIn('Subscribing to unknown variable "nonsense"', out)
        self.assertEqual(called, [])

    def test_subscribers_all_receive_updates(self):
        first, second = [], []
        self.cfg.subscribe("timezone", first.append, delayed=True)
        self.cfg.subscribe("timezone", second.append, delayed=True)
        self.cfg.set("timezone", "Asia/Tokyo")
        self.assertEqual(first, ["Asia/Tokyo"])
        self.assertEqual(second, ["Asia/Tokyo"])

    def test_unsubscribe_removes_methods_of_that_object_only(self):
        class Listener:
            def __init__(self):
                self.seen = []

            def on_change(self, value):
                self.seen.append(value)

        gone, kept = Listener(), Listener()
        self.cfg.subscribe("timezone", gone.on_change, delayed=True)
        self.cfg.subscribe("timezone", kept.on_change, delayed=True)
        self.cfg.unsubscribe(gone)
        self.cfg.set("timezone", "Asia/Tokyo")
        self.assertEqual(gone.seen, [])
        self.assertEqual(kept.seen, ["Asia/Tokyo"])

    # Config.unsubscribe removes from the list it is iterating, so the second of
    # two methods bound to one object is skipped (issue #6). Drop the decorator
    # when the production loop is fixed; it then fails loudly as an unexpected
    # success, which is the reminder to do so.
    @unittest.expectedFailure
    def test_unsubscribe_removes_every_method_of_the_object(self):
        class Listener:
            def __init__(self):
                self.seen = []

            def first(self, value):
                self.seen.append(("first", value))

            def second(self, value):
                self.seen.append(("second", value))

        gone = Listener()
        self.cfg.subscribe("timezone", gone.first, delayed=True)
        self.cfg.subscribe("timezone", gone.second, delayed=True)
        self.cfg.unsubscribe(gone)
        self.cfg.set("timezone", "Asia/Tokyo")
        self.assertEqual(gone.seen, [])

    def test_unsubscribe_ignores_plain_functions(self):
        seen = []
        self.cfg.subscribe("timezone", seen.append, delayed=True)
        self.cfg.unsubscribe(object())
        self.cfg.set("timezone", "Asia/Tokyo")
        self.assertEqual(seen, ["Asia/Tokyo"])


if __name__ == "__main__":
    unittest.main()
