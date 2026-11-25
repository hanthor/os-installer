# SPDX-License-Identifier: GPL-3.0-or-later

import importlib.util
import pathlib
import unittest

# config.py needs only PyYAML; load it from its file so the test runs without GTK.
_CONFIG_PATH = pathlib.Path(__file__).resolve().parent.parent / 'src' / 'core' / 'config.py'
_spec = importlib.util.spec_from_file_location('config_under_test', _CONFIG_PATH)
config_module = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(config_module)


class Listener:
    def first(self, value):
        pass

    def second(self, value):
        pass


class UnsubscribeTest(unittest.TestCase):
    def setUp(self):
        self.config = config_module.Config()

    def test_unsubscribe_removes_every_method_of_the_object(self):
        obj = Listener()
        self.config.subscribe('x', obj.first, delayed=True)
        self.config.subscribe('x', obj.second, delayed=True)

        self.config.unsubscribe(obj)

        self.assertEqual(self.config.subscriptions['x'], [])

    def test_unsubscribe_keeps_other_objects_subscribers(self):
        obj = Listener()
        other = Listener()
        self.config.subscribe('x', obj.first, delayed=True)
        self.config.subscribe('x', other.first, delayed=True)
        self.config.subscribe('x', obj.second, delayed=True)
        self.config.subscribe('x', other.second, delayed=True)

        self.config.unsubscribe(obj)

        self.assertEqual(self.config.subscriptions['x'], [other.first, other.second])


if __name__ == '__main__':
    unittest.main()
