// Pure policy: a newly restored window may choose a different physical display
// from the launching app's workspace. Reconcile membership before geometry.
import Foundation
import CoreGraphics

struct ZoneMonitor: Equatable {
    let name: String
    let frame: CGRect // CG / AX coordinates, including negative origins.
}

func zonePhysicalMonitor(_ rect: CGRect, screens: [ZoneMonitor]) -> String? {
    guard rect.width > 0, rect.height > 0 else { return nil }
    let area = rect.width * rect.height
    let matches = screens.filter {
        let intersection = rect.intersection($0.frame)
        return !intersection.isNull && intersection.width * intersection.height / area >= 0.7
    }
    // Ambiguous/mostly hidden windows, mirrored screens and stashed slivers
    // are not evidence of a restore destination.
    return matches.count == 1 ? matches[0].name : nil
}

func zoneRestoreDestination(action: String, known: Bool, pinned: Bool, fullscreen: Bool,
                            workspace: String, monitor: String, frame: CGRect,
                            screens: [ZoneMonitor], visible: [String: [String]]) -> String? {
    guard action == "sync", !known, !pinned, !fullscreen, screens.count > 1,
          visible[monitor] == [workspace],
          let physical = zonePhysicalMonitor(frame, screens: screens), physical != monitor,
          let targets = visible[physical], targets.count == 1, let target = targets.first,
          target != workspace else { return nil }
    return target
}

// One pure predicate is also used by the last check immediately before writes.
func zoneWindowStillEligible(id: Int, pid: Int, workspace: String, monitor: String,
                              current: [String: Any]?, fullscreen: Bool?, minimized: Bool?) -> Bool {
    guard let current, fullscreen == false, minimized == false else { return false }
    return current["window-id"] as? Int == id && current["app-pid"] as? Int == pid &&
        current["workspace"] as? String == workspace && current["monitor-name"] as? String == monitor &&
        current["window-layout"] as? String != "macos_native_fullscreen"
}
