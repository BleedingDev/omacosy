// Stable, gapless desktop zones. AeroSpace owns workspaces and focus; this
// helper places normal floating windows without changing the tiling tree.
import AppKit
import ApplicationServices
import Darwin

@_silgen_name("_AXUIElementGetWindow")
private func zoneWindowID(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

private struct ZonePlacement: Codable, Equatable {
    var slot: Int
    var free = false
    var maximized = false
}

private func zoneRequestedPlacement(_ saved: ZonePlacement?, preferred: Int,
                                    action: String, focused: Bool) -> ZonePlacement {
    var placement = saved ?? ZonePlacement(slot: preferred)
    guard focused else { return placement }
    switch action {
    case "free": placement.free.toggle()
    case "maximize": placement.maximized.toggle(); placement.free = false
    case "left", "center", "right", "step-left", "step-right":
        placement.free = false; placement.maximized = false
    default: break
    }
    return placement
}

private enum ZoneLayout: String, Codable, CaseIterable {
    case half = "quarter-half-quarter", thirds, quarters
    var edges: [CGFloat] {
        switch self {
        case .half: return [0, 0.25, 0.75, 1]
        case .thirds: return [0, 1.0/3, 2.0/3, 1]
        case .quarters: return [0, 0.25, 0.5, 0.75, 1]
        }
    }
    var slots: Int { edges.count - 1 }
    var next: ZoneLayout { self == .half ? .thirds : self == .thirds ? .quarters : .half }
}

private struct ZoneState: Codable {
    var boot: String
    var thirds = false // Legacy default retained when migrating existing state.
    var layouts: [String: ZoneLayout]?
    func layout(_ workspace: String) -> ZoneLayout {
        layouts?[workspace] ?? (thirds ? .thirds : .half)
    }
    var windows: [String: ZonePlacement] = [:]
}

private func zoneCommand(_ args: [String]) throws -> String {
    let p = Process(), out = Pipe(), err = Pipe()
    let commandID = UUID().uuidString
    let started = ProcessInfo.processInfo.systemUptime
    WindowDiagnostics.shared.record("wm.command.begin", ["command": commandID, "args": args])
    defer { WindowDiagnostics.shared.record("wm.command.end", ["command": commandID,
        "duration": ProcessInfo.processInfo.systemUptime - started,
        "exit": p.isRunning ? -1 : (p.processIdentifier == 0 ? -2 : Int(p.terminationStatus))]) }
    p.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/aerospace")
    p.arguments = args
    // Explicit IDs below; never inherit a stale callback's target.
    p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AEROSPACE_") }
    p.standardOutput = out; p.standardError = err
    try p.run()
    let limit = Date().addingTimeInterval(3)
    while p.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
    if p.isRunning { p.terminate(); throw NSError(domain: "zones: AeroSpace timeout", code: 1) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard p.terminationStatus == 0 else {
        let reason = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(domain: "zones: \(reason)", code: Int(p.terminationStatus))
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private func zoneRows(_ args: [String]) throws -> [[String: Any]] {
    let text = try zoneCommand(args + ["--json"])
    guard let data = text.data(using: .utf8),
          let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { throw NSError(domain: "zones: invalid AeroSpace response", code: 1) }
    return rows
}

private func zoneAttribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
    return value
}

private func zoneRect(_ window: AXUIElement) -> CGRect? {
    guard let p = zoneAttribute(window, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID(),
          let s = zoneAttribute(window, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
    var point = CGPoint.zero, size = CGSize.zero
    guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
          AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
    return CGRect(origin: point, size: size)
}

// Shared rounded boundaries, rather than rounded widths, ensure adjacent
// thirds share the exact same edge even when the width is not divisible by 3.
private func zoneTarget(_ area: CGRect, slot: Int, layout: ZoneLayout, centered: Bool = false) -> CGRect {
    let edges = layout.edges
    let slot = centered ? 1 : min(max(0, slot), layout.slots - 1)
    let left = (area.width * edges[slot]).rounded()
    let right = (area.width * edges[slot + 1]).rounded()
    let x = centered ? area.minX + ((area.width - (right - left)) / 2).rounded() : area.minX + left
    return CGRect(x: x, y: area.minY, width: right - left, height: area.height)
}

// The laptop intentionally uses a full-size stack. Window cycling and
// explicit activation select its front window; layout never changes focus.
private func zoneCompactTarget(_ area: CGRect, slot: Int, count: Int) -> CGRect {
    area
}

private func zoneSame(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX-b.minX) < 1 && abs(a.minY-b.minY) < 1 &&
    abs(a.width-b.width) < 1 && abs(a.height-b.height) < 1
}

private func zoneConstrainedFrame(_ target: CGRect, size: CGSize) -> CGRect? {
    guard size.width > 0, size.height > 0,
          size.width <= target.width + 1, size.height <= target.height + 1 else { return nil }
    return CGRect(x: target.minX + ((target.width - size.width) / 2).rounded(),
                  y: target.minY, width: size.width, height: size.height)
}

private func zoneSetFrame(_ window: AXUIElement, _ rect: CGRect, context: [String: Any]) -> Bool {
    var p = rect.origin, s = rect.size
    guard let position = AXValueCreate(.cgPoint, &p), let size = AXValueCreate(.cgSize, &s) else { return false }
    func write(_ attribute: String, _ value: AXValue) -> Bool {
        var fields = context
        fields["attribute"] = attribute
        fields["requested"] = diagnosticRect(rect)
        if attribute == kAXPositionAttribute {
            var point = CGPoint.zero
            if AXValueGetValue(value, .cgPoint, &point) { fields["value"] = [point.x, point.y] }
        } else {
            var size = CGSize.zero
            if AXValueGetValue(value, .cgSize, &size) { fields["value"] = [size.width, size.height] }
        }
        // Fullscreen can change even after the final WM snapshot. Recheck
        // natively before every individual AX write, without another WM refresh.
        guard zoneAttribute(window, "AXFullScreen") as? Bool == false,
              zoneAttribute(window, kAXMinimizedAttribute) as? Bool == false else {
            fields["reason"] = "fullscreen-minimized-or-unreadable"
            WindowDiagnostics.shared.record("geometry.skip", fields)
            return false
        }
        fields["before"] = zoneRect(window).map(diagnosticRect) ?? []
        WindowDiagnostics.shared.record("geometry.write.begin", fields)
        let result = AXUIElementSetAttributeValue(window, attribute as CFString, value)
        fields["ax_error"] = result.rawValue
        fields["after"] = zoneRect(window).map(diagnosticRect) ?? []
        WindowDiagnostics.shared.record("geometry.write.end", fields)
        return result == .success
    }
    // Shrink first so macOS does not clamp the position against the old size.
    guard write(kAXSizeAttribute, size), write(kAXPositionAttribute, position),
          write(kAXSizeAttribute, size) else { return false }
    guard let actual = zoneRect(window) else { return false }
    if zoneSame(actual, rect) { return true }
    // Video windows can enforce their aspect ratio even though AXSize is
    // writable. Keep the accepted size inside its zone and center its width;
    // never rewrite the player's preferences or treat letterboxing as failure.
    guard let fitted = zoneConstrainedFrame(rect, size: actual.size) else { return false }
    var fittedPoint = fitted.origin
    guard let fittedPosition = AXValueCreate(.cgPoint, &fittedPoint) else { return false }
    guard write(kAXPositionAttribute, fittedPosition) else { return false }
    return zoneRect(window).map { zoneSame($0, fitted) } ?? false
}

// Fixed-size utility/authentication windows must never take a desktop column.
private func zoneParticipates(subrole: String?, resizable: Bool, app: String, free: Bool = false) -> Bool {
    subrole == kAXStandardWindowSubrole && resizable && !free &&
    !["org.pqrs.Karabiner-Elements.Settings", "com.apple.systempreferences",
      "com.apple.SecurityAgent", "com.apple.authorizationhost",
      "com.apple.LocalAuthentication.UIAgent", "io.tailscale.ipn.macsys"].contains(app)
}

private func zonePreferredSlot(app: String, layout: ZoneLayout) -> Int {
    if app == "com.mitchellh.ghostty" { return layout.slots - 1 }
    // Keep the main browser in the middle when it and a newly opened player
    // arrive in the same pass. A lone window is centered independently below.
    if ["com.microsoft.edgemac", "com.google.Chrome", "com.apple.Safari"].contains(app) {
        return min(1, layout.slots - 1)
    }
    // New utility/player windows should consume a side before displacing a
    // browser that already owns the center slot.
    return 0
}

// A window can retain a slot from an earlier single-window layout. When a
// second window appears, reusing that stale slot makes both windows occupy the
// same rectangle; whichever app was focused last then hides the other one.
// Preserve valid saved slots, but repair duplicates deterministically before
// placing any window. Overflow is allowed only when there are more windows
// than available zones.
private func normalizedSlots(_ members: [(key: String, slot: Int, id: Int, persisted: Bool, preferred: Int)], slots: Int,
                             moving: (key: String, slot: Int)? = nil) -> [String: Int] {
    guard slots > 0 else { return [:] }
    var result: [String: Int] = [:]
    var used = Set<Int>()
    for member in members.sorted(by: {
        // Saved placements describe an intentional user choice. New windows
        // must wait for those placements instead of stealing their slot.
        if $0.persisted != $1.persisted { return $0.persisted }
        let lhs = min(max($0.persisted ? $0.slot : $0.preferred, 0), slots - 1)
        let rhs = min(max($1.persisted ? $1.slot : $1.preferred, 0), slots - 1)
        return lhs == rhs ? $0.id < $1.id : lhs < rhs
    }) {
        let requested = min(max(member.persisted ? member.slot : member.preferred, 0), slots - 1)
        let slot = used.contains(requested)
            ? ((0..<slots).first { !used.contains($0) } ?? requested)
            : requested
        result[member.key] = slot
        used.insert(slot)
    }
    // Apply the move to the whole plan. Moving only the focused window
    // after allocation left it on top of the previous occupant.
    if let moving, let oldSlot = result[moving.key] {
        let newSlot = min(max(moving.slot, 0), slots - 1)
        for (key, slot) in result where key != moving.key && slot == newSlot {
            result[key] = oldSlot
        }
        result[moving.key] = newSlot
    }
    return result
}

func runZones(_ args: [String]) {
    let action = args.first ?? "sync"
    if action == "self-test" {
        for width in [1512.0, 5120.0, 3440.0, 1920.0] {
            for layout in ZoneLayout.allCases {
                let area = CGRect(x: -1796, y: -1406, width: width, height: 1406)
                let frames = (0..<layout.slots).map { zoneTarget(area, slot: $0, layout: layout) }
                precondition(frames[0].minX == area.minX && frames.last!.maxX == area.maxX)
                precondition(zip(frames, frames.dropFirst()).allSatisfy { $0.maxX == $1.minX })
                precondition(frames.allSatisfy { $0.minY == area.minY && $0.height == area.height })
                if layout == .half { precondition(frames[1].width == width / 2) }
                // A stale left/right slot must not pull a lone window off center.
                for slot in 0..<layout.slots {
                    let single = zoneTarget(area, slot: slot, layout: layout, centered: true)
                    precondition(abs(single.midX - area.midX) <= 0.5)
                    precondition(single.width == frames[1].width)
                    precondition(single.minY == area.minY && single.height == area.height)
                }
            }
        }
        // A floating dialog must not turn a centered lone browser into a
        // two-column layout, including dialogs advertising AXStandardWindow.
        let area = CGRect(x: -1796, y: -1406, width: 5120, height: 1406)
        let browser = zoneParticipates(subrole: kAXStandardWindowSubrole, resizable: true, app: "com.microsoft.edgemac")
        precondition(browser)
        for (role, resizable, app, free) in [
            (kAXDialogSubrole, true, "test.dialog", false),
            (kAXStandardWindowSubrole, false, "test.fixed", false),
            (kAXStandardWindowSubrole, true, "com.apple.SecurityAgent", false),
            (kAXStandardWindowSubrole, true, "io.tailscale.ipn.macsys", false),
            (kAXStandardWindowSubrole, true, "test.free", true)
        ] {
            let extra = zoneParticipates(subrole: role, resizable: resizable, app: app, free: free)
            precondition(!extra)
            let count = [browser, extra].filter { $0 }.count
            precondition(zoneTarget(area, slot: 0, layout: .half, centered: count == 1) ==
                         zoneTarget(area, slot: 0, layout: .half, centered: true))
        }
        let repaired = normalizedSlots([
            (key: "edge", slot: 1, id: 5331, persisted: true, preferred: 1),
            (key: "marta", slot: 1, id: 11746, persisted: true, preferred: 0)
        ], slots: 3)
        precondition(repaired["edge"] != repaired["marta"])
        precondition(Set(repaired.values).count == 2)
        let swapped = normalizedSlots([
            (key: "edge", slot: 1, id: 1, persisted: true, preferred: 1),
            (key: "marta", slot: 0, id: 2, persisted: true, preferred: 0)
        ], slots: 3, moving: (key: "edge", slot: 0))
        precondition(swapped["edge"] == 0 && swapped["marta"] == 1)
        let freed = zoneRequestedPlacement(ZonePlacement(slot: 1), preferred: 0, action: "free", focused: true)
        precondition(freed.free)
        precondition(!zoneRequestedPlacement(freed, preferred: 0, action: "free", focused: true).free)
        let maximized = ZonePlacement(slot: 1, maximized: true)
        let restored = zoneRequestedPlacement(maximized, preferred: 0, action: "maximize", focused: true)
        precondition(!restored.maximized && !restored.free)
        // A window leaving maximize participates in allocation immediately.
        let restoredSlots = normalizedSlots([
            (key: "edge", slot: 1, id: 1, persisted: true, preferred: 1),
            (key: "restored", slot: restored.slot, id: 2, persisted: true, preferred: 0)
        ], slots: 3)
        precondition(restoredSlots["edge"] != restoredSlots["restored"])
        precondition(zoneRequestedPlacement(maximized, preferred: 0, action: "left", focused: false) == maximized)
        let emptyMove = normalizedSlots([
            (key: "edge", slot: 1, id: 1, persisted: true, preferred: 1)
        ], slots: 3, moving: (key: "edge", slot: 2))
        precondition(emptyMove["edge"] == 2)
        let browserWithNewPlayer = normalizedSlots([
            (key: "edge", slot: 1, id: 5331, persisted: true, preferred: 1),
            (key: "player", slot: 1, id: 100, persisted: false, preferred: 0)
        ], slots: 3)
        precondition(browserWithNewPlayer["edge"] == 1 && browserWithNewPlayer["player"] == 0)
        let freshBrowserAndPlayer = normalizedSlots([
            (key: "edge", slot: 1, id: 5331, persisted: false, preferred: zonePreferredSlot(app: "com.microsoft.edgemac", layout: .half)),
            (key: "iina", slot: 1, id: 100, persisted: false, preferred: zonePreferredSlot(app: "com.colliderli.iina", layout: .half))
        ], slots: 3)
        precondition(freshBrowserAndPlayer["edge"] == 1 && freshBrowserAndPlayer["iina"] == 0)
        precondition(zonePreferredSlot(app: "com.microsoft.edgemac", layout: .half) == 1)
        precondition(zonePreferredSlot(app: "com.colliderli.iina", layout: .half) == 0)
        let compact = CGRect(x: 0, y: 34, width: 1512, height: 948)
        let video = zoneConstrainedFrame(compact, size: CGSize(width: 1511, height: 850))!
        precondition(compact.contains(video) && abs(video.midX - compact.midX) <= 0.5)
        precondition(zoneConstrainedFrame(compact, size: CGSize(width: 1700, height: 850)) == nil)
        for count in 1...4 {
            let cells = (0..<count).map { zoneCompactTarget(compact, slot: $0, count: count) }
            precondition(cells.allSatisfy { $0 == compact })
        }
        precondition(zoneParticipates(subrole: kAXStandardWindowSubrole, resizable: true, app: "com.mitchellh.ghostty"))
        let legacy = Data("{\"boot\":\"test\",\"thirds\":true,\"windows\":{}}".utf8)
        var migrated = try! JSONDecoder().decode(ZoneState.self, from: legacy)
        precondition(migrated.layout("11") == .thirds)
        migrated.layouts = ["11": .quarters, "12": .half]
        let decoded = try! JSONDecoder().decode(ZoneState.self, from: JSONEncoder().encode(migrated))
        precondition(decoded.layout("11") == .quarters && decoded.layout("12") == .half && decoded.layout("13") == .thirds)
        precondition(ZoneLayout.half.next.next.next == .half)
        print("PASS: gapless external zones, occupied-slot swaps, laptop stack, lone-window centering and state round-trip")
        return
    }
    let valid = ["sync", "status", "half", "thirds", "quarters", "toggle", "left", "center", "right", "step-left", "step-right", "free", "maximize"]
    guard valid.contains(action) else { fail("zones: unknown action \(action)") }
    guard AXIsProcessTrusted() else { fail("zones: Accessibility permission is unavailable to this process") }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/omacosy")
    let url = root.appendingPathComponent("zones.json")
    do {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let requestURL = root.appendingPathComponent("zones.request")
        let completedURL = root.appendingPathComponent("zones.completed")
        if action == "sync" {
            try Data(UUID().uuidString.utf8).write(to: requestURL, options: .atomic)
        }
        let fd = open(root.appendingPathComponent("zones.lock").path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { fail("zones: cannot open lock") }
        defer { flock(fd, LOCK_UN); close(fd) }
        if action == "sync" {
            guard flock(fd, LOCK_EX) == 0 else { fail("zones: cannot acquire layout lock") }
        } else {
            let deadline = Date().addingTimeInterval(5)
            while flock(fd, LOCK_EX | LOCK_NB) != 0 {
                if Date() >= deadline { fail("zones: busy, retry shortcut") }
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        let request = action == "sync" ? try? Data(contentsOf: requestURL) : nil
        if let request, request == (try? Data(contentsOf: completedURL)) { return }
        // Pinned windows settle their workspace before this pass reads the
        // window list, or a window the pin moves away would still count as
        // occupying a slot here.
        let pinned = action == "sync" ? reconcilePins() : []
        let pinnedIDs = Set(pinned.compactMap { $0["id"] as? Int })
        var bootTime = timeval(), bootSize = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &bootTime, &bootSize, nil, 0) == 0 else { fail("zones: cannot identify boot session") }
        let boot = "\(bootTime.tv_sec)"
        let original = try? Data(contentsOf: url)
        var state = original.flatMap { try? JSONDecoder().decode(ZoneState.self, from: $0) } ?? ZoneState(boot: boot)
        if state.boot != boot { state.boot = boot; state.windows = [:] }
        let knownWindowKeys = Set(state.windows.keys)
        let format = "%{window-id} %{app-bundle-id} %{app-pid} %{workspace} %{window-layout} %{monitor-name}"
        var rows = try zoneRows(["list-windows", "--all", "--format", format])
        let workspaceArgs = ["list-workspaces", "--monitor", "all", "--visible", "--format", "%{workspace} %{monitor-name}"]
        var visibleRows = try zoneRows(workspaceArgs)
        func monitorSnapshot() -> [ZoneMonitor] {
            NSScreen.screens.compactMap { screen in
                guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
                return ZoneMonitor(name: screen.localizedName, frame: CGDisplayBounds(id.uint32Value))
            }
        }
        func visibleByMonitor(_ values: [[String: Any]]) -> [String: [String]] {
            var result: [String: [String]] = [:]
            for row in values {
                if let monitor = row["monitor-name"] as? String, let workspace = row["workspace"] as? String {
                    result[monitor, default: []].append(workspace)
                }
            }
            return result.mapValues { $0.sorted() }
        }
        let pass = UUID().uuidString
        let cause = ProcessInfo.processInfo.environment["OMACOSY_EVENT_ID"] ?? "direct-or-workspace-hook"
        WindowDiagnostics.shared.record("zones.begin", ["pass": pass, "action": action, "cause": cause,
            "callback_workspace": ProcessInfo.processInfo.environment["AEROSPACE_FOCUSED_WORKSPACE"] ?? "",
            "callback_previous_workspace": ProcessInfo.processInfo.environment["AEROSPACE_PREV_WORKSPACE"] ?? ""])
        // Resolve AX once. Nothing is moved while enumerating application windows.
        var axWindows: [Int: AXUIElement] = [:]
        for pid in Set(rows.compactMap { $0["app-pid"] as? Int }) {
            let app = AXUIElementCreateApplication(pid_t(pid))
            AXUIElementSetMessagingTimeout(app, 0.3)
            for w in zoneAttribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? [] {
                var id: CGWindowID = 0
                if zoneWindowID(w, &id) == .success { axWindows[Int(id)] = w }
            }
        }
        let restoreScreens = monitorSnapshot()
        let restoreVisible = visibleByMonitor(visibleRows)
        var reconciled = false
        for row in rows {
            guard let id = row["window-id"] as? Int, let pid = row["app-pid"] as? Int,
                  let workspace = row["workspace"] as? String, let monitor = row["monitor-name"] as? String,
                  let app = row["app-bundle-id"] as? String, let window = axWindows[id],
                  let frame = zoneRect(window) else { continue }
            let context: [String: Any] = ["pass": pass, "id": id, "pid": pid, "app": app,
                "workspace": workspace, "monitor": monitor, "frame": diagnosticRect(frame),
                "physical_monitor": zonePhysicalMonitor(frame, screens: restoreScreens) ?? "ambiguous-or-hidden",
                "ax": diagnosticAXWindow(window)]
            WindowDiagnostics.shared.record("window.snapshot", context)
            var resizable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success,
                  zoneParticipates(subrole: zoneAttribute(window, kAXSubroleAttribute) as? String, resizable: resizable.boolValue, app: app),
                  let destination = zoneRestoreDestination(action: action, known: state.windows["\(pid):\(id)"] != nil,
                    pinned: pinnedIDs.contains(id), fullscreen: row["window-layout"] as? String == "macos_native_fullscreen" ||
                        zoneAttribute(window, "AXFullScreen") as? Bool != false,
                    workspace: workspace, monitor: monitor, frame: frame, screens: restoreScreens, visible: restoreVisible)
            else { continue }
            var decision = context
            decision["destination"] = destination
            decision["reason"] = "new-window-restored-on-other-display"
            let now = try zoneRows(["list-windows", "--all", "--format", format]).first { $0["window-id"] as? Int == id }
            let nowVisible = try zoneRows(workspaceArgs)
            guard zoneWindowStillEligible(id: id, pid: pid, workspace: workspace, monitor: monitor, current: now,
                    fullscreen: zoneAttribute(window, "AXFullScreen") as? Bool, minimized: zoneAttribute(window, kAXMinimizedAttribute) as? Bool),
                  monitorSnapshot() == restoreScreens, visibleByMonitor(nowVisible) == restoreVisible,
                  zoneRect(window).map({ zoneSame($0, frame) }) == true else {
                decision["reason"] = "restore-snapshot-changed"
                decision["current"] = now ?? [:]
                decision["current_frame"] = zoneRect(window).map(diagnosticRect) ?? []
                decision["current_visible"] = visibleByMonitor(nowVisible)
                WindowDiagnostics.shared.record("workspace.reconcile.skip", decision)
                continue
            }
            WindowDiagnostics.shared.record("workspace.reconcile.begin", decision)
            do {
                _ = try zoneCommand(["move-node-to-workspace", "--window-id", String(id), destination])
            } catch {
                decision["error_code"] = (error as NSError).code
                WindowDiagnostics.shared.record("workspace.reconcile.error", decision)
                throw error
            }
            let after = try zoneRows(["list-windows", "--all", "--format", format])
                .first { $0["window-id"] as? Int == id }
            decision["actual_workspace"] = after?["workspace"] as? String ?? "missing"
            decision["verified"] = after?["workspace"] as? String == destination
            WindowDiagnostics.shared.record("workspace.reconcile.end", decision)
            guard after?["workspace"] as? String == destination else { return }
            reconciled = true
        }
        // A membership change invalidates the whole allocation/focus snapshot.
        if reconciled {
            rows = try zoneRows(["list-windows", "--all", "--format", format])
            visibleRows = try zoneRows(workspaceArgs)
        }
        let visibleSnapshot = Set(visibleRows.compactMap { $0["workspace"] as? String })
        let focus = (try? zoneRows(["list-windows", "--focused", "--format", "%{window-id}"]))?.first?["window-id"] as? Int
        let focused = try zoneCommand(["list-workspaces", "--focused"])
            .split(whereSeparator: \.isNewline).map(String.init)
        let focusedWorkspace = rows.first(where: { $0["window-id"] as? Int == focus })?["workspace"] as? String
            ?? focused.first ?? ""
        // During undocking AeroSpace can temporarily report both the former
        // guest and the actual laptop workspace as visible on one display.
        let visible = NSScreen.screens.count == 1 ? Set([focusedWorkspace]) : visibleSnapshot
        let previousLayout = state.layout(focusedWorkspace)
        let requested: ZoneLayout? = action == "toggle" ? previousLayout.next : ["half": .half, "thirds": .thirds, "quarters": .quarters][action]
        if let requested {
            if state.layouts == nil { state.layouts = [:] }
            state.layouts![focusedWorkspace] = requested
            // Keep empty slots and left/center/right identity. The allocator
            // repairs out-of-range slots only when the slot count shrinks.
        }
        let screens = NSScreen.screens
        let screenSnapshot = monitorSnapshot()
        let workspaceSnapshot = visibleByMonitor(visibleRows)
        WindowDiagnostics.shared.record("zones.snapshot", ["pass": pass, "visible": workspaceSnapshot,
            "focused_workspace": focusedWorkspace, "focused_window": focus ?? -1,
            "screens": screenSnapshot.map { ["name": $0.name, "frame": diagnosticRect($0.frame)] }])
        let primaryHeight = screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() })?.frame.maxY ?? 0
        // Only resizable desktop windows participate. Free windows and
        // fixed-size/system dialogs neither occupy slots nor uncenter a peer.
        var normalWindowIDs = Set<Int>()
        var windowCounts: [String: Int] = [:]
        var placements: [String: ZonePlacement] = [:]
        for row in rows {
            guard let id = row["window-id"] as? Int, let pid = row["app-pid"] as? Int,
                  let window = axWindows[id],
                  let ws = row["workspace"] as? String, let monitor = row["monitor-name"] as? String,
                  let app = row["app-bundle-id"] as? String,
                  row["window-layout"] as? String != "macos_native_fullscreen",
                  zoneAttribute(window, kAXMinimizedAttribute) as? Bool != true,
                  zoneAttribute(window, "AXFullScreen") as? Bool != true
            else { continue }
            var resizable: DarwinBoolean = false
            guard AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &resizable) == .success,
                  zoneParticipates(subrole: zoneAttribute(window, kAXSubroleAttribute) as? String,
                                   resizable: resizable.boolValue, app: app) else { continue }
            normalWindowIDs.insert(id)
            let key = "\(pid):\(id)"
            let placement = zoneRequestedPlacement(state.windows[key],
                preferred: zonePreferredSlot(app: app, layout: state.layout(ws)),
                action: action, focused: id == focus)
            placements[key] = placement
            if !placement.free { windowCounts[monitor + ":" + ws, default: 0] += 1 }
        }
        // Repair stale/duplicate saved slots before processing windows. This
        // is the case that made Marta disappear below Edge after a restart:
        // both windows had inherited the center slot from their last
        // single-window layout.
        var membersByArea: [String: [(key: String, slot: Int, id: Int, persisted: Bool, preferred: Int)]] = [:]
        var areaSlots: [String: Int] = [:]
        for row in rows {
            guard let id = row["window-id"] as? Int, normalWindowIDs.contains(id),
                  let pid = row["app-pid"] as? Int,
                  let ws = row["workspace"] as? String, let monitor = row["monitor-name"] as? String,
                  let app = row["app-bundle-id"] as? String else { continue }
            let key = "\(pid):\(id)"
            guard let placement = placements[key], !placement.free, !placement.maximized else { continue }
            let layout = state.layout(ws)
            let preferred = zonePreferredSlot(app: app, layout: layout)
            let area = monitor + ":" + ws
            areaSlots[area] = monitor.contains("C49RG9") ? layout.slots : min(4, max(1, windowCounts[area] ?? 1))
            membersByArea[area, default: []].append(
                (key: key, slot: placement.slot, id: id,
                 persisted: state.windows[key] != nil, preferred: preferred))
        }
        var slotAssignments: [String: Int] = [:]
        for (area, members) in membersByArea {
            let slots = areaSlots[area] ?? 1
            var moving: (key: String, slot: Int)?
            if let member = members.first(where: { $0.id == focus }) {
                let old = normalizedSlots(members, slots: slots)[member.key] ?? member.slot
                if let slot = ["left": 0, "center": 1, "right": slots - 1,
                               "step-left": old - 1, "step-right": old + 1][action] {
                    moving = (member.key, slot)
                }
            }
            slotAssignments.merge(normalizedSlots(members, slots: slots, moving: moving)) { _, new in new }
        }
        var liveKeys = Set<String>(), report: [[String: Any]] = [], changed = 0, failed = 0
        for row in rows {
            guard let id = row["window-id"] as? Int, let pid = row["app-pid"] as? Int,
                  let workspace = row["workspace"] as? String,
                  let monitor = row["monitor-name"] as? String else { continue }
            let key = "\(pid):\(id)"
            liveKeys.insert(key)
            guard visible.contains(workspace),
                  let screen = screens.first(where: { $0.localizedName == monitor }),
                  monitor.contains("C49RG9") || monitor.lowercased().contains("built-in") else { continue }
            guard let window = axWindows[id] else {
                report.append(["id": id, "status": "AX window unavailable"]); continue
            }
            guard normalWindowIDs.contains(id) else { continue }
            let layout = state.layout(workspace)
            let occupancyKey = monitor + ":" + workspace
            guard var placement = placements[key] else { continue }
            let external = monitor.contains("C49RG9")
            let displaySlot = slotAssignments[key] ?? placement.slot
            // The compact display has a different slot count. Do not persist
            // its temporary slot over the CR9 placement when undocked.
            if external { placement.slot = min(displaySlot, layout.slots - 1) }
            if placement.free {
                state.windows[key] = placement
                report.append(["id": id, "status": "free"])
                continue
            }
            let frame = screen.frame, visibleFrame = screen.visibleFrame
            // Reserve the actual 34-point bar, including the notch/menu strip.
            let top = max(primaryHeight - visibleFrame.maxY, primaryHeight - frame.maxY + 34)
            let area = CGRect(x: visibleFrame.minX, y: top, width: visibleFrame.width,
                              height: primaryHeight - visibleFrame.minY - top)
            let compactSlot = id == focus && ["left", "center", "right", "step-left", "step-right"].contains(action)
                ? placement.slot : displaySlot
            let target = placement.maximized ? area : (external
                ? zoneTarget(area, slot: placement.slot, layout: layout, centered: windowCounts[occupancyKey] == 1)
                : zoneCompactTarget(area, slot: compactSlot, count: windowCounts[occupancyKey] ?? 1))
            let needsWrite = row["window-layout"] as? String != "floating" || (zoneRect(window).map { !zoneSame($0, target) } ?? true)
            if action != "status", needsWrite {
                // AX enumeration can be slow. Never use its old workspace
                // snapshot to pull an already-hidden window back on screen.
                let nowWorkspaces = try zoneRows(workspaceArgs)
                let nowVisible = Set(nowWorkspaces.compactMap { $0["workspace"] as? String })
                let nowFocused = try zoneCommand(["list-workspaces", "--focused"])
                    .split(whereSeparator: \.isNewline).map(String.init)
                let nowWindowWorkspace = try zoneCommand(["list-windows", "--focused", "--format", "%{workspace}"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard nowVisible == visibleSnapshot, nowFocused == focused,
                      nowWindowWorkspace.isEmpty || nowWindowWorkspace == focusedWorkspace,
                      monitorSnapshot() == screenSnapshot, visibleByMonitor(nowWorkspaces) == workspaceSnapshot else {
                    WindowDiagnostics.shared.record("zones.abort", ["pass": pass, "reason": "workspace-focus-or-displays-changed", "id": id])
                    return
                }
                let context: [String: Any] = ["pass": pass, "action": action, "id": id, "pid": pid,
                    "workspace": workspace, "monitor": monitor, "target": diagnosticRect(target)]
                func stillEligible() throws -> Bool {
                    let current = try zoneRows(["list-windows", "--all", "--format", format])
                        .first { $0["window-id"] as? Int == id }
                    let fullscreen = zoneAttribute(window, "AXFullScreen") as? Bool
                    let minimized = zoneAttribute(window, kAXMinimizedAttribute) as? Bool
                    let eligible = zoneWindowStillEligible(id: id, pid: pid, workspace: workspace, monitor: monitor,
                        current: current, fullscreen: fullscreen, minimized: minimized)
                    WindowDiagnostics.shared.record("geometry.validate", context.merging([
                        "current": current ?? [:], "eligible": eligible,
                        "fullscreen": fullscreen.map { $0 as Any } ?? NSNull(),
                        "minimized": minimized.map { $0 as Any } ?? NSNull(),
                        "current_frame": zoneRect(window).map(diagnosticRect) ?? []
                    ]) { _, new in new })
                    return eligible
                }
                guard try stillEligible() else {
                    WindowDiagnostics.shared.record("geometry.skip", context.merging(["reason": "target-window-changed-or-unreadable"]) { _, new in new })
                    continue
                }
                if row["window-layout"] as? String != "floating",
                   (try? zoneCommand(["layout", "--window-id", String(id), "floating"])) == nil {
                    report.append(["id": id, "status": "cannot float window"])
                    failed += 1
                    continue
                }
                // layout itself can refresh the WM model, so revalidate after it.
                if row["window-layout"] as? String != "floating", try !stillEligible() { continue }
                if let actual = zoneRect(window), !zoneSame(actual, target) {
                    // An unseen window on another screen with no unambiguous
                    // restore destination must not be teleported as a fallback.
                    if action == "sync", !knownWindowKeys.contains(key),
                       let physical = zonePhysicalMonitor(actual, screens: screenSnapshot), physical != monitor,
                       !pinnedIDs.contains(id) {
                        WindowDiagnostics.shared.record("geometry.skip", context.merging(["reason": "unresolved-new-window-monitor-mismatch"]) { _, new in new })
                        state.windows.removeValue(forKey: key)
                        continue
                    }
                    if zoneSetFrame(window, target, context: context) { changed += 1 } else { failed += 1; continue }
                }
            }
            // Do not mark a new window as settled when a stale/fullscreen
            // guard skipped it. A later pass must still reconcile its screen.
            state.windows[key] = placement
            let actual = zoneRect(window) ?? .zero
            let constrained = !zoneSame(actual, target) &&
                (zoneConstrainedFrame(target, size: actual.size).map { zoneSame(actual, $0) } ?? false)
            report.append(["id": id, "monitor": monitor, "workspace": workspace, "layout": layout.rawValue, "slot": placement.slot,
                           "target": [target.minX, target.minY, target.width, target.height],
                           "actual": [actual.minX, actual.minY, actual.width, actual.height],
                           "matches": zoneSame(actual, target), "constrained": constrained])
        }
        state.windows = state.windows.filter { liveKeys.contains($0.key) }
        WindowDiagnostics.shared.record("zones.end", ["pass": pass, "changed": changed, "failed": failed])
        if action != "status" {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(state)
            if data != original { try data.write(to: url, options: .atomic) }
        }
        if action != "sync" || failed > 0 {
            let output: [String: Any] = ["layout": state.layout(focusedWorkspace).rawValue, "workspace": focusedWorkspace, "layouts": (state.layouts ?? [:]).mapValues { $0.rawValue }, "changed": changed, "failed": failed, "windows": report]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        }
        if failed > 0 { exit(1) }
        if let request { try request.write(to: completedURL, options: .atomic) }
    } catch { fail("\(error)") }
}
