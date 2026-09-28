// omacosy-ffm — focus follows mouse for the omacosy tiling setup.
// Event-driven: a global mouseMoved monitor (rides the Accessibility
// grant this binary needs anyway) hit-tests the topmost normal window
// under the cursor and asks AeroSpace to focus its exact window ID without raising it.
// Hover changes the key window without raising it. A parked cursor
// generates no events and cannot steal focus from a launching window.
//
// Deliberately boring: no focus changes while any mouse button is down
// (drags deliver mouseDragged, not mouseMoved), a ~100ms dwell before
// a new window takes focus (no flicker when crossing windows), and
// only layer-0 windows count (menus, popups and the bar never steal
// focus).
import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
func AXWindowID(_ element: AXUIElement, _ wid: UnsafeMutablePointer<UInt32>) -> AXError

// AeroSpace owns both the focus request and its native acknowledgement.
// Never activate an application independently of the workspace model.
var focusProcess: Process?
func requestHoverFocus(wid: UInt32, completion: @escaping (Bool) -> Void) {
    guard focusProcess == nil else { completion(false); return }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/aerospace")
    process.arguments = ["focus", "--window-id", String(wid), "--no-raise"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { child in
        DispatchQueue.main.async {
            guard focusProcess === child else { return }
            focusProcess = nil
            completion(child.terminationStatus == 0)
        }
    }
    focusProcess = process
    do { try process.run() }
    catch { focusProcess = nil; completion(false) }
}

// Apps that hover must never focus (omarchy's JetBrains-style
// no_follow_mouse). One app name per line, # comments.
let ignoredApps: Set<String> = {
    let f = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/omacosy/ffm-ignore")
    guard let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
    return Set(text.split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") })
}()

// Event-driven: a global mouseMoved monitor replaces the old 80ms
// poll. "Focus follows mouse MOVEMENT, not hover position" (Hyprland
// semantics) is structural now — a stationary cursor produces no
// events, so it can never steal focus (a freshly launched window that
// self-activates under an idle pointer keeps its focus; the poll used
// to deactivate System Settings mid-launch and sink it behind the
// tiles). Drags are excluded for free too: dragging delivers
// mouseDragged, never mouseMoved.
let processMinInterval = 0.04 // hit-test at most ~25Hz during motion
let dwellSeconds = 0.10 // hover this long over a new window to focus it

var pendingKey = ""
var lastProcessAt = 0.0
var dwellWork: DispatchWorkItem? = nil

func displayBounds() -> [CGRect] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var n: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &n) == .success else { return [] }
    return (0..<Int(n)).map { CGDisplayBounds(ids[$0]) }
}

// Only a display-sized Dock backing window above an AX-confirmed
// fullscreen content window is transparent to hover hit-testing.
// Ordinary Dock UI and all application panels remain blockers.
func fullscreenBackdrop(_ owner: String, _ layer: Int, _ rect: CGRect,
                        _ screens: [CGRect], _ windows: [[String: Any]]) -> Bool {
    guard owner == "Dock", layer == 20, screens.contains(rect) else { return false }
    for candidate in windows {
        guard candidate["kCGWindowLayer"] as? Int == 0,
              let bounds = candidate["kCGWindowBounds"] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary), frame == rect,
              let pid = candidate["kCGWindowOwnerPID"] as? pid_t,
              let wid = candidate["kCGWindowNumber"] as? UInt32 else { continue }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let elements = value as? [AXUIElement] else { continue }
        for element in elements {
            var id: UInt32 = 0
            guard AXWindowID(element, &id) == .success, id == wid else { continue }
            var fullscreen: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, "AXFullScreen" as CFString, &fullscreen) == .success,
               fullscreen as? Bool == true { return true }
        }
    }
    return false
}

typealias Cand = (pid: pid_t, num: Int, rect: CGRect, owner: String, blocking: Bool)

// Front-to-back layer-0 windows that pass the visibility filter.
// (Side effect vs the old single pass: an ignore-listed
// offscreen-stashed sliver no longer blocks focus — it's filtered
// before the ignore check, which is the behaviour we always wanted.)
func windowCandidates() -> [Cand] {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] else { return [] }
    let screens = displayBounds()
    var cands: [Cand] = []
    for w in list { // list is front-to-back
        guard let layer = w["kCGWindowLayer"] as? Int,
            let b = w["kCGWindowBounds"] as? [String: Any],
            let x = b["X"] as? CGFloat, let y = b["Y"] as? CGFloat,
            let wd = b["Width"] as? CGFloat, let h = b["Height"] as? CGFloat,
            let pid = w["kCGWindowOwnerPID"] as? pid_t,
            let num = w["kCGWindowNumber"] as? Int
        else { continue }
        let owner = (w["kCGWindowOwnerName"] as? String) ?? ""
        // Windows ABOVE layer 0 are floating panels — 1Password's Touch
        // ID prompt sits at 101 — and hover-focus must not tunnel
        // through them to the tile underneath, which is precisely how
        // that prompt kept losing focus to whatever it covered. They
        // are not focus targets either, so they are carried as blockers:
        // hovering one leaves focus exactly where it is.
        //
        // Two things above layer 0 are emphatically NOT panels, and
        // treating them as such would freeze focus everywhere: our own
        // border overlay, which sits at layer 3 stretched over the
        // focused window, and the Window Server's own windows — the
        // CURSOR is one of them, at layer 2147483630, and it covers the
        // hit-test point by definition.
        let blocking = layer > 0
            && !owner.hasPrefix("omacosy-borders")
            && owner != "Window Server"
        guard layer == 0 || blocking else { continue }
        let rect = CGRect(x: x, y: y, width: wd, height: h)
        if fullscreenBackdrop(owner, layer, rect, screens, list) { continue }
        // AeroSpace hides inactive-workspace windows mostly offscreen
        // with a sliver visible — ignore anything <30% on-screen
        let visible = screens.reduce(CGFloat(0)) { acc, scr in
            let i = rect.intersection(scr)
            return acc + (i.isNull ? 0 : i.width * i.height)
        }
        if rect.width * rect.height > 0, visible / (rect.width * rect.height) < 0.3 {
            continue
        }
        cands.append((pid, num, rect, owner, blocking))
    }
    return cands
}

func topWindowUnder(_ p: CGPoint, _ cands: [Cand]) -> (pid: pid_t, key: String, rect: CGRect, wid: UInt32)? {
    for c in cands {
        guard c.rect.contains(p) else { continue }
        // a floating panel is under the cursor: same stance as the
        // ignore list — leave focus exactly where it is rather than
        // falling through to whatever it covers
        if c.blocking { return nil }
        // topmost window is ignore-listed: leave focus alone entirely
        // (don't fall through to the window beneath)
        if ignoredApps.contains(c.owner.lowercased()) { return nil }
        return (c.pid, "\(c.pid):\(c.num)", c.rect, UInt32(c.num))
    }
    return nil
}

// Hit-testing uses filtered CG windows; focus resolves that exact window ID.
// AX positional hit-testing can return offscreen-stashed windows.
let debug = ProcessInfo.processInfo.environment["OMACOSY_FFM_DEBUG"] != nil
func dbg(_ m: String) {
    if debug { FileHandle.standardError.write((m + "\n").data(using: .utf8)!) }
}

// Shared by motion events and the dwell confirmation: hit-test the
// cursor and either focus (dwell confirmed) or arm the dwell timer.
// The timer path exists because events stop when the cursor stops —
// "glide into a window and rest" must still confirm ~100ms later.
let overlayFlag = "/tmp/omacosy-overlay-active-\(getuid())"

// OmniWM has its own focus-follows-mouse, and the two fight. launchd
// starts this agent at every login whichever manager runs, so it stands
// down by itself while OmniWM runs, however it was started.
let omniwmBundleID = "com.barut.OmniWM"
// Cached for 0.5 s, as in borders.swift: process() runs up to ~25 times a
// second while the mouse moves, and the lookup walks every running app.
var omniwmCached = false
var omniwmCheckedAt = Date.distantPast
func omniwmRunning() -> Bool {
    if Date().timeIntervalSince(omniwmCheckedAt) < 0.5 { return omniwmCached }
    omniwmCheckedAt = Date()
    omniwmCached = !NSRunningApplication.runningApplications(withBundleIdentifier: omniwmBundleID).isEmpty
    return omniwmCached
}

func process(confirmed: Bool) {
    if omniwmRunning() {
        pendingKey = ""
        dwellWork?.cancel()
        return
    }
    // the workspace overview is up: it holds key focus deliberately,
    // and it floats above layer 0 so the hit-test would tunnel through
    // it and focus the tile underneath — stealing key out from under
    // the user's click. Stand down entirely.
    if FileManager.default.fileExists(atPath: overlayFlag) {
        pendingKey = ""
        return
    }
    // never move focus mid-drag (belt — mouseMoved doesn't fire then,
    // but the dwell timer can)
    if CGEventSource.buttonState(.combinedSessionState, button: .left)
        || CGEventSource.buttonState(.combinedSessionState, button: .right) {
        pendingKey = ""
        return
    }
    guard let e = CGEvent(source: nil) else { return }
    let cands = windowCandidates()
    guard let hit = topWindowUnder(e.location, cands) else {
        pendingKey = ""
        dwellWork?.cancel()
        return
    }
    if confirmed && hit.key != pendingKey {
        // A dialog/player appeared after the mouse stopped. A dwell callback
        // is not new mouse intent and must not arm focus behind that window.
        pendingKey = ""
        dwellWork?.cancel()
        return
    }
    // judge "already focused" by reality, not our own bookkeeping — a
    // silently failed focus attempt must be retried, not remembered
    let frontPid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
    let app = AXUIElementCreateApplication(hit.pid)
    AXUIElementSetMessagingTimeout(app, 0.1)
    var focusedValue: CFTypeRef?
    var focusedID: UInt32 = 0
    if hit.pid == frontPid,
       AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedValue) == .success,
       let focusedValue, CFGetTypeID(focusedValue) == AXUIElementGetTypeID(),
       AXWindowID(focusedValue as! AXUIElement, &focusedID) == .success,
       focusedID == hit.wid {
        pendingKey = ""
        dwellWork?.cancel()
        return
    }
    if confirmed, hit.key == pendingKey {
        pendingKey = ""
        guard focusProcess == nil else { return }
        let focusID = UUID().uuidString
        WindowDiagnostics.shared.record("ffm.focus.begin", [
            "focus_request": focusID, "id": Int(hit.wid), "pid": Int(hit.pid),
            "front_pid": Int(frontPid), "cursor": [e.location.x, e.location.y],
            "target_frame": diagnosticRect(hit.rect), "stack": diagnosticNativeStack()])
        requestHoverFocus(wid: hit.wid) { accepted in
            WindowDiagnostics.shared.record("ffm.focus.end", [
                "focus_request": focusID, "id": Int(hit.wid), "pid": Int(hit.pid),
                "manager_accepted": accepted,
                "front_pid": Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1),
                "stack": diagnosticNativeStack()])
        }
        return
    }
    if hit.key != pendingKey {
        pendingKey = hit.key
        dwellWork?.cancel()
        let work = DispatchWorkItem { process(confirmed: true) }
        dwellWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dwellSeconds, execute: work)
    }
}

@main
struct OmacosyWindowAgent {
    static func main() {
        guard AXIsProcessTrustedWithOptions(
            ["AXTrustedCheckOptionPrompt": true] as CFDictionary) else {
            FileHandle.standardError.write(Data("omacosy-ffm: waiting for Accessibility permission\n".utf8))
            while !AXIsProcessTrusted() { Thread.sleep(forTimeInterval: 1) }
            exit(2)
        }
        FileHandle.standardError.write(Data("omacosy-ffm: ready; no-raise focus and window lifecycle events\n".utf8))
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let windowLifecycle = WindowLifecycle()
        windowLifecycle.start()
        var trailingWork: DispatchWorkItem?
        func cancelPendingFocus() {
            pendingKey = ""
            dwellWork?.cancel()
            trailingWork?.cancel()
            trailingWork = nil
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { cancelPendingFocus() }
        }
        NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { _ in
            cancelPendingFocus()
        }
        NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastProcessAt < processMinInterval {
                // trailing edge: a fast flick's FINAL event (the one actually
                // over the new window) can land inside the throttle window —
                // dropping it without a follow-up left the window unfocused
                // until the next twitch of the mouse
                if trailingWork == nil {
                    let work = DispatchWorkItem {
                        trailingWork = nil
                        lastProcessAt = CFAbsoluteTimeGetCurrent()
                        process(confirmed: false)
                    }
                    trailingWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + processMinInterval, execute: work)
                }
                return
            }
            trailingWork?.cancel()
            trailingWork = nil
            lastProcessAt = now
            process(confirmed: false)
        }
        withExtendedLifetime(windowLifecycle) { app.run() }
    }
}
