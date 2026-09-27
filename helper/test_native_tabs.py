#!/usr/bin/env python3
"""Native tab projection regression tests; compile only the bar's model functions."""
import json
import os
from pathlib import Path
import subprocess
import unittest

REPO = Path(__file__).resolve().parents[1]
ROOT = Path(os.environ['OWNED_TEMP_DIR'])


class NativeTabs(unittest.TestCase):
    def test_shortcut_is_native_and_app_scoped(self):
        data = json.loads((REPO / 'config/karabiner/karabiner.json').read_text())
        rules = [r for p in data['profiles'] for r in p.get('complex_modifications', {}).get('rules', [])
                 if r['description'].startswith('Ghostty: Command Tab')]
        self.assertEqual(len(rules), 1)
        for m in rules[0]['manipulators']:
            modifiers = ['left_control'] + (['left_shift'] if 'shift' in m['from']['modifiers']['mandatory'] else [])
            self.assertEqual(m['to'], [{'key_code': 'tab', 'modifiers': modifiers}])
            self.assertEqual(m['conditions'], [{'type': 'frontmost_application_if',
                                                'bundle_identifiers': [r'^com\.mitchellh\.ghostty$']}])

    def test_native_projection_preserves_order_duplicates_and_other_windows(self):
        source = (REPO / 'helper/bar.swift').read_text()
        model = source[source.index('struct WindowTitle:'):source.index('@_silgen_name("_AXUIElementGetWindow")')]
        test = r'''
let rows: [[String: Any]] = [
 ["window-id": 10, "workspace": "3", "app-name": "Ghostty", "app-bundle-id": "com.mitchellh.ghostty", "window-title": "same"],
 ["window-id": 11, "workspace": "3", "app-name": "Ghostty", "app-bundle-id": "com.mitchellh.ghostty", "window-title": "same"],
 ["window-id": 12, "workspace": "3", "app-name": "Ghostty", "app-bundle-id": "com.mitchellh.ghostty", "window-title": "third"],
 ["window-id": 20, "workspace": "2", "app-name": "Edge", "window-title": "web"],
 ["window-id": 30, "workspace": "11", "app-name": "Ghostty", "app-bundle-id": "com.mitchellh.ghostty", "window-title": "external"]]
let tabs = [
 WindowTitle(id: 12, workspace: "3", title: "third", appName: "Ghostty", nativeSelected: true),
 WindowTitle(id: 12, workspace: "3", title: "same", appName: "Ghostty", nativeSelected: false),
 WindowTitle(id: 12, workspace: "3", title: "same", appName: "Ghostty", nativeSelected: false),
 WindowTitle(id: 30, workspace: "11", title: "external", appName: "Ghostty")]
let result = workspaceWindowTitles(from: rows, ghosttyTabs: tabs)
precondition(result.filter { $0.workspace == "3" }.map { $0.title } == ["third", "same", "same"])
precondition(result.filter { $0.workspace == "3" && $0.nativeSelected }.count == 1)
precondition(result.filter { $0.workspace == "11" }.map { $0.id } == [30])
precondition(result.filter { $0.appName == "Edge" }.map { $0.id } == [20])
precondition(workspaceWindowTitles(from: rows).map { $0.id } == [10, 11, 12, 20, 30])
precondition(workspaceWindowTitles(from: rows, ghosttyTabs: []).map { $0.id } == [10, 11, 12, 20, 30])
print("PASS native order, duplicate titles, active tab, multiple workspaces and AX fallback")
'''
        swift = ROOT / 'native-tab-tests.swift'
        swift.write_text('import AppKit\nimport ApplicationServices\n' + model + test)
        build = ROOT / 'build'
        build.mkdir(exist_ok=True)
        owner = 'omacosy-native-tab-tests'
        subprocess.run(['/Users/satan/bin/disk-guardian-artifacts', 'register', str(build), '--owner', owner,
                        '--owner-pid', str(os.getpid()), '--grace-hours', '24', '--kind', 'build'], check=True)
        try:
            subprocess.run(['swiftc', '-module-cache-path', str(build / 'cache'), str(swift), '-o', str(build / 'tests')], check=True)
            subprocess.run([str(build / 'tests')], check=True)
        finally:
            subprocess.run(['/Users/satan/bin/disk-guardian-artifacts', 'release', str(build), '--owner', owner], check=True)
            subprocess.run(['/Users/satan/bin/disk-guardian-artifacts', 'cleanup', '--only', str(build), '--no-caches', '--apply'], check=True)


if __name__ == '__main__':
    unittest.main()
