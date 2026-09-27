import AppKit
import Foundation
import Darwin

@main
struct DiagnosticsTests {
    static func main() throws {
        // Explicit test root is mandatory. Never touch the user's log/state.
        guard let base = ProcessInfo.processInfo.environment["OWNED_TEMP_DIR"] else { fatalError("OWNED_TEMP_DIR required") }
        let root = URL(fileURLWithPath: base).appendingPathComponent("diagnostics-test")
        if CommandLine.arguments.contains("--writer") {
            let logger = WindowDiagnostics(root: root, maxBytes: 4096)
            for i in 0..<120 { logger.record("test", ["index": i]) }
            return
        }
        var checks = 0
        func check(_ value: Bool, _ name: String) { precondition(value, name); checks += 1 }
        let screens = [ZoneMonitor(name: "laptop", frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
                       ZoneMonitor(name: "CR9", frame: CGRect(x: -1796, y: -1440, width: 5120, height: 1440))]
        let movie = CGRect(x: -485, y: -1440, width: 2499, height: 1406)
        let visible = ["laptop": ["4"], "CR9": ["11"]]
        func destination(action: String = "sync", known: Bool = false, pinned: Bool = false, fullscreen: Bool = false,
                         frame: CGRect = movie, monitors: [ZoneMonitor]? = nil, spaces: [String: [String]]? = nil) -> String? {
            zoneRestoreDestination(action: action, known: known, pinned: pinned, fullscreen: fullscreen,
                workspace: "4", monitor: "laptop", frame: frame, screens: monitors ?? screens, visible: spaces ?? visible)
        }
        check(destination() == "11", "Edge on laptop must not pull newly restored CR9 video to laptop")
        check(destination(known: true) == nil, "existing windows preserve explicit workspace moves")
        check(destination(pinned: true) == nil, "pin policy takes precedence")
        check(destination(fullscreen: true) == nil, "native fullscreen remains app-owned")
        check(destination(action: "thirds") == nil, "layout shortcuts never change membership")
        check(destination(monitors: [screens[0]]) == nil, "undocking remains collapse-owned")
        check(destination(spaces: ["laptop": ["3"], "CR9": ["11"]]) == nil, "hidden workspace cannot be resurrected")
        check(destination(spaces: ["laptop": ["4"], "CR9": ["11", "12"]]) == nil, "ambiguous visible workspace is rejected")
        check(destination(frame: CGRect(x: 1511, y: 942, width: 1512, height: 948)) == nil, "stashed slivers are not restore evidence")
        check(destination(frame: CGRect(x: 0, y: 34, width: 1512, height: 948)) == nil, "same monitor stays assigned")
        check(zonePhysicalMonitor(movie, screens: screens + [screens[1]]) == nil, "mirrored or duplicate screens are ambiguous")
        check(zonePhysicalMonitor(CGRect(x: 0, y: -300, width: 600, height: 600), screens: screens) == nil, "spanning window is ambiguous")
        let current: [String: Any] = ["window-id": 42, "app-pid": 100, "workspace": "11", "monitor-name": "CR9", "window-layout": "floating"]
        func eligible(_ row: [String: Any]? = current, full: Bool? = false, minimized: Bool? = false) -> Bool {
            zoneWindowStillEligible(id: 42, pid: 100, workspace: "11", monitor: "CR9", current: row, fullscreen: full, minimized: minimized)
        }
        check(eligible(), "stable window can be written")
        check(!eligible(nil), "closed window cannot be written")
        check(!eligible(full: true), "fullscreen transition aborts write")
        check(!eligible(full: nil), "unreadable fullscreen state aborts write")
        check(!eligible(minimized: true), "minimized window cannot be revived")
        for (key, value) in [("workspace", "4"), ("monitor-name", "laptop"), ("window-layout", "macos_native_fullscreen")] {
            check(!eligible(current.merging([key: value]) { _, new in new }), "target change aborts despite stable global focus: \(key)")
        }
        check(!eligible(current.merging(["app-pid": 999]) { _, new in new }), "PID reuse rejected")
        let raw: [[String: Any]] = [["kCGWindowNumber": 42, "kCGWindowOwnerPID": 100, "kCGWindowLayer": 0,
            "kCGWindowBounds": ["X": 0, "Y": 1, "Width": 2, "Height": 3], "kCGWindowName": "SECRET VIDEO URL", "kCGWindowIsOnscreen": true]]
        let sanitized = diagnosticStack(raw)
        let json = try JSONSerialization.data(withJSONObject: sanitized)
        check(sanitized.count == 1 && !String(decoding: json, as: UTF8.self).contains("SECRET"), "native stack omits window titles")
        // Concurrent processes exercise the actual file lock and rotation.
        let children = try (0..<4).map { _ -> Process in
            let p = Process(); p.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); p.arguments = ["--writer"]
            try p.run(); return p
        }
        for child in children { child.waitUntilExit(); check(child.terminationStatus == 0, "writer completes") }
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("window-events.jsonl") }
        check(files.count == 4, "rotation retains active plus three archives")
        var records = [[String: Any]]()
        for file in files {
            let data = try Data(contentsOf: file)
            check(data.count <= 4096, "each log is bounded")
            for line in data.split(separator: 0x0a) {
                let row = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
                check(row["schema"] as? Int == 1 && row["writer_pid"] != nil && row["sequence"] != nil && row["uptime"] != nil, "complete JSON event")
                records.append(row)
            }
            let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
            check(mode.intValue & 0o777 == 0o600, "log remains private")
        }
        check(!records.isEmpty, "records survived rotation")
        print("PASS: \(checks) assertions; restore policy, target races, privacy, multiprocess JSONL rotation")
    }
}
