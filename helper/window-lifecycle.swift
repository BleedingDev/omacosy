// Native lifecycle notifications share the already-authorised FFM process.
// The bar only renders state; the zone helper remains the geometry writer.
import AppKit
import ApplicationServices

final class WindowLifecycle {
    private var observers: [pid_t: AXObserver] = [:]
    private var windowIDs: [pid_t: [(AXUIElement, UInt32)]] = [:]
    private var pending: DispatchWorkItem?
    private let queue = DispatchQueue(label: "com.omacosy.window-lifecycle")
    private var monitorCount = NSScreen.screens.count
    private var displayChange: DispatchWorkItem?
    private var foldRequired = false

    private func run(_ command: String, _ args: [String], cause: String) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.barut.OmniWM").isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: NSHomeDirectory() + "/.local/bin/" + command)
        p.arguments = args
        p.environment = ProcessInfo.processInfo.environment.merging(["OMACOSY_EVENT_ID": cause]) { _, new in new }
        WindowDiagnostics.shared.record("lifecycle.command.begin", ["cause": cause, "command": command, "args": args])
        do {
            try p.run()
            p.waitUntilExit()
            WindowDiagnostics.shared.record("lifecycle.command.end", ["cause": cause, "command": command, "exit": Int(p.terminationStatus)])
            if p.terminationStatus != 0 {
                FileHandle.standardError.write(Data("omacosy lifecycle: \(command) \(args) failed: \(p.terminationStatus)\n".utf8))
            }
        } catch {
            WindowDiagnostics.shared.record("lifecycle.command.error", ["cause": cause, "command": command, "error": String(describing: error)])
            FileHandle.standardError.write(Data("omacosy lifecycle: \(error)\n".utf8))
        }
    }

    private func displaysChanged(forceFold: Bool = false) {
        let cause = UUID().uuidString
        WindowDiagnostics.shared.record("displays.changed", ["cause": cause, "fold": forceFold,
            "screens": NSScreen.screens.map { ["name": $0.localizedName, "frame_appkit": diagnosticRect($0.frame)] }])
        foldRequired = foldRequired || forceFold
        displayChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let count = NSScreen.screens.count
            guard count > 0 else { return }
            let fold = self.foldRequired || count != self.monitorCount
            self.foldRequired = false
            self.monitorCount = count
            self.queue.async {
                if fold { self.run("omacosy-ws-collapse", ["sync", String(count)], cause: cause) }
                self.run("omacosy-helper", ["zones", "sync"], cause: cause)
            }
        }
        displayChange = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func changed(pid: pid_t, reason: String, cause: String = UUID().uuidString) {
        WindowDiagnostics.shared.record("lifecycle.sync.request", ["cause": cause, "pid": Int(pid), "reason": reason])
        subscribeWindows(pid)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.queue.async { [weak self] in
                self?.run("omacosy-helper", ["zones", "sync"], cause: cause)
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("com.omacosy.window-state"), object: nil,
                    userInfo: ["kind": "windows"], deliverImmediately: true)
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @discardableResult
    private func subscribeWindows(_ pid: pid_t) -> Bool {
        guard let observer = observers[pid] else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        windowIDs[pid] = windows.compactMap { window in
            var id: UInt32 = 0
            return AXWindowID(window, &id) == .success ? (window, id) : nil
        }
        for window in windows {
            for notification in [kAXTitleChangedNotification, kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification,
                                 kAXWindowDeminiaturizedNotification, kAXMovedNotification, kAXResizedNotification] {
                AXObserverAddNotification(observer, window, notification as CFString,
                                          Unmanaged.passUnretained(self).toOpaque())
            }
        }
        return !windows.isEmpty
    }

    private func publishMetadata(_ element: AXUIElement, focused: Bool) {
        var window = element, id: UInt32 = 0
        AXUIElementSetMessagingTimeout(element, 0.2)
        // AXFocusedWindowChanged can carry the window itself, while an
        // application activation gives us its application element.
        if AXWindowID(window, &id) != .success || id == 0 {
            var value: CFTypeRef?
            guard focused,
                  AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return }
            window = value as! AXUIElement
            guard AXWindowID(window, &id) == .success, id != 0 else { return }
        }
        var info: [String: Any] = ["kind": focused ? "focus" : "title", "id": Int(id)]
        var title: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
           let title = title as? String { info["title"] = title }
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name("com.omacosy.window-state"), object: nil,
            userInfo: info, deliverImmediately: true)
    }

    private func attach(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != getpid(), observers[pid] == nil, app.activationPolicy == .regular else { return }
        var observer: AXObserver?
        guard AXObserverCreate(pid, { _, element, notification, context in
            guard let context else { return }
            let lifecycle = Unmanaged<WindowLifecycle>.fromOpaque(context).takeUnretainedValue()
            let name = notification as String
            AXUIElementSetMessagingTimeout(element, 0.1)
            var pid: pid_t = 0, id: UInt32 = 0
            AXUIElementGetPid(element, &pid)
            _ = AXWindowID(element, &id)
            if id == 0 { id = lifecycle.windowIDs[pid]?.first(where: { CFEqual($0.0, element) })?.1 ?? 0 }
            var diagnosticElement = element
            if id == 0, name == kAXFocusedWindowChangedNotification || name == kAXMainWindowChangedNotification {
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
                   let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                    diagnosticElement = value as! AXUIElement
                    _ = AXWindowID(diagnosticElement, &id)
                }
            }
            let cause = UUID().uuidString
            if name != kAXTitleChangedNotification {
                var fields: [String: Any] = ["cause": cause, "notification": name, "pid": Int(pid), "id": Int(id)]
                if name != kAXUIElementDestroyedNotification { fields["ax"] = diagnosticAXWindow(diagnosticElement) }
                if name == kAXFocusedWindowChangedNotification || name == kAXWindowCreatedNotification || name == kAXMainWindowChangedNotification {
                    fields["stack"] = diagnosticNativeStack()
                    fields["front_pid"] = Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1)
                }
                WindowDiagnostics.shared.record("native.window", fields)
            }
            // Geometry notifications are evidence only. Reacting with layout
            // here would turn our own AX writes into another feedback loop.
            if name == kAXMovedNotification || name == kAXResizedNotification || name == kAXMainWindowChangedNotification { return }
            if name == kAXTitleChangedNotification || name == kAXFocusedWindowChangedNotification {
                lifecycle.publishMetadata(element, focused: name == kAXFocusedWindowChangedNotification)
                return
            }
            lifecycle.changed(pid: pid, reason: name, cause: cause)
        }, &observer) == .success, let observer else { return }
        let axApp = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(axApp, 0.2)
        guard AXObserverAddNotification(observer, axApp, kAXWindowCreatedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return }
        AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        AXObserverAddNotification(observer, axApp, kAXMainWindowChangedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        observers[pid] = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        // Catch windows created before the launch/activation notification.
        // An app with no windows is still starting; its AX creation event
        // will schedule layout when there is actually something to manage.
        if subscribeWindows(pid) { changed(pid: pid, reason: "attach-existing-windows") }
    }

    func start() {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: "com.barut.OmniWM").isEmpty else { return }
        NSWorkspace.shared.runningApplications.forEach(attach)
        let center = NSWorkspace.shared.notificationCenter
        // A display unplugged during sleep may not produce a useful count
        // transition until wake. Retry the same idempotent fold after unlock.
        for event in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            center.addObserver(forName: event, object: nil, queue: .main) { [weak self] _ in
                self?.displaysChanged(forceFold: true)
            }
        }
        center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.changed(pid: 0, reason: "native-space-changed")
        }
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didActivateApplicationNotification] {
            center.addObserver(forName: event, object: nil, queue: .main) { [weak self] note in
                if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                    WindowDiagnostics.shared.record("native.application", ["notification": event.rawValue,
                        "pid": Int(app.processIdentifier), "app": app.bundleIdentifier ?? "unknown",
                        "stack": diagnosticNativeStack()])
                    self?.attach(app)
                    if event == NSWorkspace.didActivateApplicationNotification {
                        self?.publishMetadata(AXUIElementCreateApplication(app.processIdentifier), focused: true)
                    }
                }
            }
        }
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let self, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            if let observer = self.observers.removeValue(forKey: app.processIdentifier) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            self.windowIDs.removeValue(forKey: app.processIdentifier)
            self.changed(pid: app.processIdentifier, reason: "application-terminated")
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            self?.displaysChanged()
        }
        WindowDiagnostics.shared.record("lifecycle.start", ["stack": diagnosticNativeStack()])
        changed(pid: 0, reason: "agent-start")
    }
}
