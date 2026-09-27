// Shared, bounded diagnostics. Never query AeroSpace from this logger.
// Callers pass IDs/state, never window titles, URLs or input contents.
import AppKit
import ApplicationServices
import Darwin

final class WindowDiagnostics {
    static let shared = WindowDiagnostics(root: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".local/state/omacosy"))
    private let root: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private let session = UUID().uuidString
    private var sequence = 0
    private var reportedFailure = false

    init(root: URL, maxBytes: Int = 2 * 1024 * 1024) {
        self.root = root
        self.maxBytes = maxBytes
    }

    func record(_ event: String, _ fields: [String: Any] = [:]) {
        lock.lock()
        defer { lock.unlock() }
        sequence += 1
        var entry = fields
        entry["schema"] = 1
        entry["event"] = event
        entry["time"] = Date().timeIntervalSince1970
        entry["uptime"] = ProcessInfo.processInfo.systemUptime
        entry["writer_pid"] = Int(getpid())
        entry["actor"] = ProcessInfo.processInfo.processName
        entry["session"] = session
        entry["sequence"] = sequence
        do {
            var data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            data.append(0x0a)
            // Bound individual records too. Callers use small, fixed schemas.
            guard data.count <= maxBytes else { throw NSError(domain: "diagnostics.record-too-large", code: 1) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let fd = open(root.appendingPathComponent("window-events.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw NSError(domain: "diagnostics.lock", code: Int(errno)) }
            defer { close(fd) }
            guard flock(fd, LOCK_EX) == 0 else { throw NSError(domain: "diagnostics.flock", code: Int(errno)) }
            defer { flock(fd, LOCK_UN) }
            let file = root.appendingPathComponent("window-events.jsonl")
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
            if size + data.count > maxBytes {
                // Active file plus three archives, at most 8 MiB by default.
                for suffix in stride(from: 3, through: 1, by: -1) {
                    let destination = URL(fileURLWithPath: file.path + ".\(suffix)")
                    let source = suffix == 1 ? file : URL(fileURLWithPath: file.path + ".\(suffix - 1)")
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    if FileManager.default.fileExists(atPath: source.path) { try FileManager.default.moveItem(at: source, to: destination) }
                }
            }
            let output = open(file.path, O_CREAT | O_WRONLY | O_APPEND | O_NOFOLLOW, 0o600)
            guard output >= 0 else { throw NSError(domain: "diagnostics.open", code: Int(errno)) }
            defer { close(output) }
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(output, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw NSError(domain: "diagnostics.write", code: Int(errno)) }
                    offset += count
                }
            }
        } catch {
            if !reportedFailure {
                reportedFailure = true
                FileHandle.standardError.write(Data("omacosy: window diagnostics unavailable: \(error)\n".utf8))
            }
        }
    }
}

func diagnosticRect(_ rect: CGRect) -> [Double] {
    [Double(rect.minX), Double(rect.minY), Double(rect.width), Double(rect.height)]
}

// Front-to-back ordering is evidence of occlusion, independent of app focus.
func diagnosticStack(_ rows: [[String: Any]]) -> [[String: Any]] {
    rows.filter { $0["kCGWindowLayer"] as? Int == 0 }.prefix(64).compactMap { row in
        guard let id = row["kCGWindowNumber"] as? Int, let pid = row["kCGWindowOwnerPID"] as? Int,
              let bounds = row["kCGWindowBounds"] as? [String: Any],
              let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return ["id": id, "pid": pid, "frame": diagnosticRect(frame), "onscreen": row["kCGWindowIsOnscreen"] as? Bool ?? false]
    }
}

func diagnosticNativeStack() -> [[String: Any]] {
    diagnosticStack(CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
        kCGNullWindowID) as? [[String: Any]] ?? [])
}

func diagnosticAXWindow(_ element: AXUIElement) -> [String: Any] {
    AXUIElementSetMessagingTimeout(element, 0.1)
    var result: [String: Any] = [:]
    var pid: pid_t = 0
    AXUIElementGetPid(element, &pid)
    result["pid"] = Int(pid)
    for name in [kAXPositionAttribute, kAXSizeAttribute, kAXMinimizedAttribute, "AXFullScreen"] {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        result[name + "_error"] = error.rawValue
        guard error == .success, let value else { continue }
        if name == kAXPositionAttribute, CFGetTypeID(value) == AXValueGetTypeID() {
            var point = CGPoint.zero
            if AXValueGetValue(value as! AXValue, .cgPoint, &point) { result[name] = [point.x, point.y] }
        } else if name == kAXSizeAttribute, CFGetTypeID(value) == AXValueGetTypeID() {
            var size = CGSize.zero
            if AXValueGetValue(value as! AXValue, .cgSize, &size) { result[name] = [size.width, size.height] }
        } else if let flag = value as? Bool { result[name] = flag }
    }
    return result
}
