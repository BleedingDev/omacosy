#!/usr/bin/env python3
"""Exercise the installed hook logic with isolated CLI doubles, never the desktop.

Run inside owned-temp-dir; only dependency paths in a copied hook are redirected.
HOME is never changed, and all fixture state/logs stay in OWNED_TEMP_DIR.
"""
import json
import os
from pathlib import Path
import subprocess
import unittest

ROOT = Path(os.environ["OWNED_TEMP_DIR"])
SOURCE = Path(__file__).resolve().parents[1] / "bin/omacosy-ws-collapse"
STUB = '''#!/usr/bin/env -S python3 -S
import json, os, pathlib, sys
r=pathlib.Path(os.environ['OMACOSY_TEST_ROOT']);cfg=json.loads((r/'scenario.json').read_text())
name=pathlib.Path(sys.argv[0]).name;args=sys.argv[1:]
with (r/'calls.jsonl').open('a') as f:f.write(json.dumps([name,*args])+'\\n')
if name=='omacosy-omni':sys.exit(1)
if name=='omacosy-helper' or name=='sleep':sys.exit(0)
if name=='omacosy-native-spaces':
 if args==['snapshot']:sys.exit(0)
 previous=sum(1 for line in (r/'calls.jsonl').read_text().splitlines() if json.loads(line)==[name,'collapse'])
 exits=cfg.get('native_exits',[0]);sys.exit(exits[min(previous-1,len(exits)-1)])
if args[0]=='list-monitors':
 print('1 | Built-in')
 if cfg['monitors']==2:print('2 | External')
elif args[0]=='list-workspaces':print('1\\n2\\n11')
elif args[0]=='list-windows':
 ws=args[args.index('--workspace')+1]
 if ws==cfg.get('failed_probe'):sys.exit(1)
 if ws=='1' or (len(ws)==1 and cfg.get('primary_full')):print('99')
 elif ws=='11':print('101')
elif args[0]=='move-node-to-workspace':
 wid=args[args.index('--window-id')+1]
 sys.exit(1 if wid in cfg.get('failed_windows',[]) else 0)
else:sys.exit(90)
'''


class CollapseHook(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / self._testMethodName
        self.bin = self.root / ".local/bin"
        self.state = self.root / ".local/state/omacosy"
        self.bin.mkdir(parents=True)
        self.state.mkdir(parents=True)
        for name in ["aerospace", "omacosy-native-spaces", "omacosy-omni", "omacosy-helper", "sleep"]:
            p = self.bin / name
            p.write_text(STUB)
            p.chmod(0o755)
        self.script = self.root / "hook"
        self.script.write_text(SOURCE.read_text().replace("$HOME", "$OMACOSY_TEST_ROOT")
                               .replace("/opt/homebrew/bin", str(self.bin))
                               .replace("/tmp/omacosy", str(self.root / "omacosy")))
        self.map = self.state / "collapse-map"

    def run_hook(self, op, *args, **scenario):
        (self.root / "scenario.json").write_text(json.dumps(scenario))
        env = dict(os.environ, OMACOSY_TEST_ROOT=str(self.root), OMACOSY_COLLAPSE_LOCK_HELD="1")
        result = subprocess.run(["/bin/bash", str(self.script), op, *args], env=env, capture_output=True, text=True)
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        return result, calls

    def test_fold_and_native_consolidation_remain_enabled(self):
        result, calls = self.run_hook("collapse", monitors=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["aerospace", "move-node-to-workspace", "--window-id", "101", "2"], calls)
        self.assertIn(["omacosy-native-spaces", "collapse"], calls)

    def test_upstream_sync_verb_runs_local_native_consolidation(self):
        result, calls = self.run_hook("sync", "1", monitors=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["omacosy-native-spaces", "collapse"], calls)
        self.assertIn(["aerospace", "move-node-to-workspace", "--window-id", "101", "2"], calls)
        self.assertEqual(self.map.read_text(), "101\t11\n")

    def test_unverified_native_move_is_not_retried(self):
        result, calls = self.run_hook("collapse", monitors=1, native_exits=[1])
        self.assertEqual(result.returncode, 1)
        self.assertEqual(calls.count(["omacosy-native-spaces", "collapse"]), 1)
        self.assertEqual(self.map.read_text(), "101\t11\n")

    def test_full_primary_set_keeps_guest_without_merging(self):
        result, calls = self.run_hook("collapse", monitors=1, primary_full=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[:2] == ["aerospace", "move-node-to-workspace"] for call in calls))
        self.assertIn(["omacosy-native-spaces", "collapse"], calls)

    def test_failed_occupancy_probe_never_counts_as_empty(self):
        result, calls = self.run_hook("collapse", monitors=1, failed_probe="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[:2] == ["aerospace", "move-node-to-workspace"] for call in calls))
        self.assertNotIn(["omacosy-native-spaces", "collapse"], calls)

    def test_transient_deferral_is_retried_with_fresh_probe(self):
        result, calls = self.run_hook("collapse", monitors=1, native_exits=[75, 0])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls.count(["omacosy-native-spaces", "collapse"]), 2)

    def test_failed_restore_preserves_only_failed_records(self):
        self.map.write_text("101\t11\n102\t12\n")
        result, calls = self.run_hook("restore", monitors=2, failed_windows=["102"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.map.read_text(), "102\t12\n")
        self.assertIn(["omacosy-native-spaces", "snapshot"], calls)

    def test_interrupted_restore_map_is_recovered(self):
        (self.state / "collapse-map.run").write_text("101\t11\n")
        result, calls = self.run_hook("restore", monitors=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["aerospace", "move-node-to-workspace", "--window-id", "101", "11"], calls)
        self.assertFalse((self.state / "collapse-map.run").exists())

    def test_restore_while_undocked_does_not_consume_map(self):
        self.map.write_text("101\t11\n")
        result, calls = self.run_hook("restore", monitors=1)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(self.map.read_text(), "101\t11\n")
        self.assertFalse(any(call[0] == "omacosy-native-spaces" for call in calls))


unittest.main()
