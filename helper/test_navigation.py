#!/usr/bin/env python3
"""Offline navigation regression tests; all executable calls use local stubs."""
import json
import os
from pathlib import Path
import subprocess
import tomllib
import unittest

REPO = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ["OWNED_TEMP_DIR"])


class Navigation(unittest.TestCase):
    def exercise(self, direction, monitor, focus_exit=0):
        root = ROOT / self._testMethodName
        root.mkdir()
        wm = root / "aerospace"
        wm.write_text("""#!/usr/bin/env python3
import json, os, pathlib, sys
a=sys.argv[1:]
r=pathlib.Path(os.environ['NAV_TEST_ROOT'])
with (r/'calls').open('a') as f: f.write(json.dumps(a)+'\\n')
if a[0]=='list-windows':
 if '%{monitor-name}' in a: print(os.environ['NAV_MONITOR'])
 elif '--focused' in a: print('101')
 else: print('101\\n102')
elif a[0]=='focus': sys.exit(int(os.environ['NAV_FOCUS_EXIT']))
elif a[0]!='move-mouse': sys.exit(99)
""")
        wm.chmod(0o755)
        omni = root / "omni"
        omni.write_text("#!/bin/sh\nexit 1\n")
        omni.chmod(0o755)
        script = root / "cycle"
        script.write_text((REPO / "bin/omacosy-cycle").read_text().replace(
            '$HOME/.local/bin/omacosy-omni', str(omni)))
        env = dict(os.environ, PATH=str(root) + ":" + os.environ["PATH"], NAV_TEST_ROOT=str(root),
                   NAV_MONITOR=monitor, NAV_FOCUS_EXIT=str(focus_exit))
        result = subprocess.run(["bash", str(script), direction], env=env, capture_output=True, text=True)
        return result, [json.loads(line) for line in (root / "calls").read_text().splitlines()]

    def test_external_horizontal_focus_moves_cursor(self):
        result, calls = self.exercise("right", "C49RG9x")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-2:], [["focus", "--boundaries", "all-monitors-outer-frame", "right"],
                                     ["move-mouse", "window-lazy-center"]])

    def test_failed_direction_does_not_warp_cursor(self):
        result, calls = self.exercise("left", "C49RG9x", 2)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == "move-mouse" for call in calls))

    def test_laptop_stack_still_cycles(self):
        result, calls = self.exercise("left", "Built-in Retina Display")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[-2:], [["focus", "--window-id", "102"], ["move-mouse", "window-lazy-center"]])

    def test_vertical_bindings_include_cursor(self):
        data = tomllib.loads((REPO / "config/aerospace/aerospace.template.toml").read_text())
        bindings = data["mode"]["main"]["binding"]
        for key, direction in [("j", "down"), ("k", "up"), ("down", "down"), ("up", "up")]:
            self.assertEqual(bindings["cmd-ctrl-alt-" + key], ["focus-monitor " + direction, "move-mouse window-lazy-center"])
        self.assertEqual(bindings["cmd-ctrl-alt-left"], bindings["cmd-ctrl-alt-h"])
        self.assertEqual(bindings["cmd-ctrl-alt-right"], bindings["cmd-ctrl-alt-l"])


if __name__ == "__main__":
    unittest.main()
