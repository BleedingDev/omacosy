#!/usr/bin/env python3
"""Run the actual shell policies against isolated CLI fixtures, never windows.

Usage: owned-temp-dir --run omacosy-policy-tests -- python3 -S helper/test_desktop_policy.py
"""
import json
import os
from pathlib import Path
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ["OWNED_TEMP_DIR"])
STUB = '''#!/usr/bin/env -S python3 -S
import json,os,pathlib,sys
r=pathlib.Path(os.environ['OMACOSY_TEST_ROOT'])
c=json.loads((r/'scenario.json').read_text());a=sys.argv[1:]
with (r/'calls.jsonl').open('a') as f:f.write(json.dumps([pathlib.Path(sys.argv[0]).name,*a])+'\\n')
name=pathlib.Path(sys.argv[0]).name
if name=='omacosy-omni':sys.exit(1)
if name=='omacosy-helper':print(c.get('input_age',90));sys.exit(0)
if a[0]=='list-monitors':print('1')
elif a[0]=='list-workspaces':
 print(c['focused'] if '--focused' in a else '\\n'.join(c.get('workspaces',['1','2','3','4','11'])))
elif a[0]=='list-windows':
 print(c['focused'] if '--focused' in a else '\\n'.join(c.get('occupied',[])))
elif a[0]=='workspace':pass
else:sys.exit(99)
'''


class DesktopPolicy(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / self._testMethodName
        self.bin = self.root / '.local/bin'
        self.bin.mkdir(parents=True)
        for name in ['aerospace', 'omacosy-helper', 'omacosy-omni']:
            path = self.bin / name
            path.write_text(STUB)
            path.chmod(0o755)
        self.env = dict(os.environ, OMACOSY_TEST_ROOT=str(self.root), PATH=str(self.bin) + ':' + os.environ['PATH'])

    def run_policy(self, name, args=(), **scenario):
        (self.root / 'scenario.json').write_text(json.dumps(scenario))
        script = self.root / name
        script.write_text((REPO / 'bin' / name).read_text().replace('$HOME', '$OMACOSY_TEST_ROOT')
                          .replace('/opt/homebrew/bin', str(self.bin))
                          .replace('/tmp/omacosy', str(self.root / 'omacosy')))
        result = subprocess.run(['/bin/bash', str(script), *args], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [json.loads(line) for line in (self.root / 'calls.jsonl').read_text().splitlines()]

    def switch_calls(self, calls):
        return [call[-1] for call in calls if call[:2] == ['aerospace', 'workspace']]

    def test_cycle_skips_empty_workspaces(self):
        calls = self.run_policy('omacosy-ws', ('next', 'next'), focused='1', occupied=['1', '4', '4'])
        self.assertEqual(self.switch_calls(calls), ['4'])

    def test_next_from_empty_workspace_uses_next_occupied(self):
        calls = self.run_policy('omacosy-ws', ('next', 'next'), focused='3', occupied=['1', '4'])
        self.assertEqual(self.switch_calls(calls), ['4'])

    def test_prev_from_empty_workspace_uses_previous_occupied(self):
        calls = self.run_policy('omacosy-ws', ('prev', 'prev'), focused='3', occupied=['1', '4'])
        self.assertEqual(self.switch_calls(calls), ['1'])

    def test_occupied_guest_remains_reachable_when_undocked(self):
        calls = self.run_policy('omacosy-ws', ('next', 'next'), focused='9', occupied=['1','2','3','4','5','6','7','8','9','11'])
        self.assertEqual(self.switch_calls(calls), ['11'])

    def test_direct_slot_prefers_primary_over_guest(self):
        calls = self.run_policy('omacosy-ws', ('1',), focused='3', workspaces=['11', '1', '3'])
        self.assertEqual(self.switch_calls(calls), ['1'])

    def test_cycle_empty_monitor_is_noop(self):
        calls = self.run_policy('omacosy-ws', ('next', 'next'), focused='1', occupied=[])
        self.assertEqual(self.switch_calls(calls), [])

    def test_workspace_hooks_cannot_bounce_focus(self):
        template = (REPO / 'config/aerospace/aerospace.template.toml').read_text()
        self.assertNotIn('omacosy-focus-guard', template)
        self.assertFalse((REPO / 'bin/omacosy-focus-guard').exists())


class ExternalConfiguration(unittest.TestCase):
    def setUp(self):
        self.root = ROOT / self._testMethodName
        self.root.mkdir()
        self.configs = [self.root / '.config/ghostty', self.root / 'Library/Application Support/com.mitchellh.ghostty']
        for path in self.configs:
            path.mkdir(parents=True)
            (path / 'config').write_text('theme = user-theme\nkeybind = global:option+space=toggle_quick_terminal\n')
        self.before = [(path / 'config').read_bytes() for path in self.configs]

    def execute(self, text):
        result = subprocess.run(['/bin/bash', '-s'], input=text.replace('$HOME', '$OMACOSY_TEST_ROOT'),
                                env=dict(os.environ, OMACOSY_TEST_ROOT=str(self.root)),
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([(p / 'config').read_bytes() for p in self.configs], self.before)
        self.assertTrue(all(not p.is_symlink() for p in self.configs))

    def test_install_linking_preserves_both_ghostty_configs(self):
        source = (REPO / 'install.sh').read_text()
        block = source.split('log "Linking configs"', 1)[1].split('# Karabiner is COPIED', 1)[0]
        # Execute the real linking phase. The fixture link deliberately replaces
        # destinations, so any reintroduced Ghostty link fails this test.
        self.execute('''
log() { :; }
zshrc_setup() { :; }
link() { rm -rf "$2"; ln -s "$1" "$2"; }
REPO_DIR="$OMACOSY_TEST_ROOT/repo"
''' + block)

    def test_uninstall_preserves_legacy_ghostty_manifest_entries(self):
        manifest = self.root / 'manifest'
        manifest.write_text(''.join('copied-config ' + str(p) + '\n' for p in self.configs))
        source = (REPO / 'uninstall.sh').read_text()
        block = source.split('restore() {', 1)[1].split('# --- ~/.zshrc.local', 1)[0]
        self.execute('''
log() { :; }
have() { return 1; }
MANIFEST="$OMACOSY_TEST_ROOT/manifest"
restore() {
''' + block)


unittest.main()
