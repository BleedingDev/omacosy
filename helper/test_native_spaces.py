#!/usr/bin/env python3
"""Pure fixture tests. Pass a compiled native-spaces binary; never calls collapse."""
import copy
import json
import subprocess
import sys
import unittest

BINARY = sys.argv.pop(1)


def space(sid, uuid, kind=0):
    return {"ManagedSpaceID": sid, "uuid": uuid, "type": kind}


def display(name, spaces, current):
    return {"Display Identifier": name, "Spaces": spaces, "Current Space": current}


class NativeSpaceOwnership(unittest.TestCase):
    def setUp(self):
        self.local = space(3, "mac-desktop")
        self.guest = space(7, "external-desktop")
        self.fixture = {
            "displays": [display("mac", [self.local, self.guest], self.guest)],
            "ownership": {"mac": "mac-desktop", "external": "external-desktop"},
            "windows": [{"id": 99, "spaces": [3]}, {"id": 101, "spaces": [7]}],
        }

    def plan(self, data=None):
        result = subprocess.run([BINARY, "plan"], input=json.dumps(data or self.fixture),
                                text=True, capture_output=True, check=True)
        return json.loads(result.stdout)

    def test_active_guest_is_not_the_target(self):
        result = self.plan()
        self.assertTrue(result["ok"])
        self.assertEqual(result["target"], 3)
        self.assertTrue(result["activate"])
        self.assertEqual(result["windows"], [101])

    def test_current_owner_needs_no_switch(self):
        self.fixture["displays"][0]["Current Space"] = self.local
        self.assertFalse(self.plan()["activate"])

    def test_space_id_reuse_resolved_by_uuid(self):
        self.local["ManagedSpaceID"] = 42
        self.fixture["windows"][0]["spaces"] = [42]
        self.assertEqual(self.plan()["target"], 42)

    def test_missing_owner_never_falls_back_to_current(self):
        self.fixture["ownership"] = {}
        self.assertFalse(self.plan()["ok"])

    def test_deleted_owner_never_falls_back_to_guest(self):
        self.fixture["displays"][0]["Spaces"] = [self.guest]
        self.assertFalse(self.plan()["ok"])

    def test_reconnected_display_cancels_collapse(self):
        self.fixture["displays"].append(display("external", [space(9, "other")], space(9, "other")))
        self.assertFalse(self.plan()["ok"])

    def test_fullscreen_on_survivor_is_not_interrupted(self):
        fs = space(8, "fullscreen", 4)
        self.fixture["displays"][0]["Spaces"].append(fs)
        self.fixture["displays"][0]["Current Space"] = fs
        self.assertFalse(self.plan()["ok"])

    def test_sticky_fullscreen_and_vanished_windows_are_excluded(self):
        self.fixture["displays"][0]["Spaces"].append(space(8, "fullscreen", 4))
        self.fixture["windows"] += [{"id": 102, "spaces": [3, 7]},
                                    {"id": 103, "spaces": [8]}, {"id": 104, "spaces": []}]
        self.assertEqual(self.plan()["windows"], [101])

    def test_dock_invalid_current_state_is_rejected(self):
        self.fixture["displays"][0]["Current Space"] = space(999, "missing")
        self.assertFalse(self.plan()["ok"])

    def test_duplicate_space_identity_is_rejected(self):
        self.fixture["displays"][0]["Spaces"].append(copy.deepcopy(self.local))
        self.assertFalse(self.plan()["ok"])

    def test_already_consolidated_is_idempotent(self):
        self.fixture["windows"][1]["spaces"] = [3]
        self.assertEqual(self.plan()["windows"], [])

    def test_external_display_can_be_the_survivor(self):
        self.fixture["displays"][0]["Display Identifier"] = "external"
        result = self.plan()
        self.assertEqual(result["target"], 7)
        self.assertEqual(result["windows"], [99])

    def snapshot_fixture(self):
        self.fixture["operation"] = "snapshot"
        self.fixture["displays"] = [display("mac", [self.local], self.local),
                                    display("external", [self.guest], self.guest)]

    def test_snapshot_keeps_known_owner_during_fullscreen(self):
        self.snapshot_fixture()
        fs = space(8, "fullscreen", 4)
        self.fixture["displays"][1]["Spaces"] += [fs]
        self.fixture["displays"][1]["Current Space"] = fs
        result = self.plan()
        self.assertTrue(result["ok"])
        self.assertEqual(result["ownership"]["external"], "external-desktop")

    def test_snapshot_refuses_single_display_overwrite(self):
        self.fixture["operation"] = "snapshot"
        self.assertFalse(self.plan()["ok"])

    def test_snapshot_refuses_shared_desktop_between_displays(self):
        self.snapshot_fixture()
        self.fixture["displays"][1] = display("external", [self.local], self.local)
        self.assertFalse(self.plan()["ok"])

    def test_snapshot_refuses_missing_current_desktop(self):
        self.snapshot_fixture()
        self.fixture["displays"][1]["Current Space"] = space(123, "missing")
        self.assertFalse(self.plan()["ok"])


unittest.main()
