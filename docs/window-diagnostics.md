# Window diagnostics and restored monitor policy

The helper and FFM agent write `~/.local/state/omacosy/window-events.jsonl`. The active file and three rotated archives are each limited to 2 MiB. Files use mode 0600. Records contain window/process IDs, app bundle IDs, geometry, workspace/monitor assignments, native focus events and AX result codes. They omit window titles, page URLs, video paths and keyboard contents.

Each record has Unix time, monotonic uptime, writer PID, a process session ID and sequence number. `cause` connects a native lifecycle event to the helper it launches. `pass` connects a zone snapshot, membership correction and geometry writes. `command` connects the beginning and completion of an AeroSpace command. `focus_request` connects each FFM request and its API result. Native focus notifications and front-to-back window snapshots record the observed outcome separately from API acceptance.

Read all four files in uptime order when diagnosing a window. Follow `workspace.reconcile.*`, `geometry.validate`, `geometry.write.*`, `geometry.skip`, `ffm.focus.*` and `native.window`. A begin record without its end indicates interruption or a pending operation. CLI refreshes are logged too because reads can influence AeroSpace's refresh scheduling. Native logging itself never calls AeroSpace. Movement/resize notifications only record evidence and do not trigger layout.

The restore policy applies once to normal, previously unplaced windows during automatic sync. At least 70% of the window must lie on one unambiguous display. Both source and destination workspace must be visible, with one visible workspace per display. Existing placements, pins, hidden workspaces, fullscreen, undocking and explicit layout shortcuts do not invoke this policy. The helper revalidates window identity, membership, physical frame and display topology before changing membership. It then rereads the allocation snapshot. Workspace moves use an explicit window ID and do not request focus-following, as documented in the [AeroSpace command reference](https://nikitabobko.github.io/AeroSpace/commands#move-node-to-workspace).

Before geometry changes the helper checks the target window's current PID, workspace, monitor, fullscreen and minimized state. Fullscreen/minimized state is checked again before each AX write. Unreadable state causes a skip. A skipped new window is not persisted as already placed. These checks reduce stale writes; macOS and AeroSpace do not provide an atomic transaction spanning all these reads and writes.

The new policy is a candidate for the IINA restore incident. It does not patch AeroSpace internals or establish the exact actor behind every application activation. Unknown windows restored only after their first completed placement remain outside this policy. Live two-display video/fullscreen validation is still required.

## Offline verification

Run `owned-temp-dir --run omacosy-diagnostics -- bash helper/test-window-diagnostics.sh` from this checkout. It builds both production executables, runs the pure monitor/target-state tests, runs concurrent JSONL rotation tests, and runs existing zone/pin self-tests. FFM is built but never launched. The production helper only runs its offline self-test subcommands.

Run `owned-temp-dir --run omacosy-navigation -- python3 -S helper/test_navigation.py` to test directional navigation with stubbed commands. No window manager or real cursor is used by these tests.

## Cross-monitor Edge focus regression

On 2026-09-27 the existing live FFM was reproduced pulling the laptop from workspace 3 or 1 to Edge workspace 2 when hovering Edge window 2257 on CR9 workspace 11. The reproducible precondition was Edge remembering its laptop window 2260 before switching to Ghostty or T3 Code. When Edge remembered its CR9 window, those tests preserved the laptop workspace.

This resembles AeroSpace's [same-app cross-monitor focus issue](https://github.com/nikitabobko/AeroSpace/issues/101), but that issue alone does not prove this incident's internal cause. Native probes confirmed the visible-window change before the final AeroSpace query. Focus guard had no new bounce entry. Two experimental event-order changes were discarded: one still changed the laptop workspace, and the other failed to focus Edge. Neither experiment is included in this release. Some additional trials were invalidated by concurrent user mouse movement and are not counted as passes.

The release adds evidence for this regression but does not claim to fix it. Avoid adding a callback that switches the laptop back after the fact: that would recreate the visible workspace flicker. A durable fix needs the intended window focus and workspace visibility to be coordinated by the window manager.

Super is Caps Lock, remapped to Cmd+Ctrl+Opt. The configuration adds cursor-following to Super+J/K and vertical arrow aliases. H/L retain laptop window cycling and external directional focus, with cursor-following in both paths. These changes do not alter the mouse-hover focus protocol.
