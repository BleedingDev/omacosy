// Pinned floating windows. AeroSpace emulates workspaces by stashing the
// windows of every inactive workspace in a screen corner. A floating HUD
// that belongs to another window — a game overlay — is dragged there too
// and then fights the app that keeps re-placing it over the game.
// AeroSpace has no "ignore this window" concept, so the pin is emulated
// instead: the window keeps its rule's workspace and therefore stashes
// and returns together with it.
//
// Config: ~/.config/omacosy/pinned-windows, one rule per line,
// '#' comments:
//
//     <matcher>                keeps the FOCUSED workspace
//     <matcher> >> <anchor>    keeps the workspace of the first window
//                              matching <anchor>
//
// Matchers are case-insensitive substrings of "<AppName> <WindowTitle>".
import Foundation

private struct PinRule {
    let matcher: String
    let anchor: String?
}

private let pinFormat = "%{window-id} %{app-name} %{window-title} %{workspace}"

private func parsePins(_ text: String) -> [PinRule] {
    text.split(separator: "\n").compactMap { raw -> PinRule? in
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
        let parts = line.components(separatedBy: ">>").map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        }
        guard let matcher = parts.first, !matcher.isEmpty else { return nil }
        return PinRule(matcher: matcher, anchor: parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil)
    }
}

private func pinRules() -> [PinRule] {
    let f = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/omacosy/pinned-windows")
    guard let text = try? String(contentsOf: f, encoding: .utf8) else { return [] }
    return parsePins(text)
}

// Explicit targets only; never inherit a hook's stale AEROSPACE_* context.
private func pinCommand(_ args: [String]) throws -> String {
    let p = Process(), out = Pipe(), err = Pipe()
    let bin = ["/opt/homebrew/bin/aerospace", "/usr/local/bin/aerospace"]
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "aerospace"
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = args
    p.environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("AEROSPACE_") }
    p.standardOutput = out; p.standardError = err
    try p.run()
    let limit = Date().addingTimeInterval(3)
    while p.isRunning && Date() < limit { Thread.sleep(forTimeInterval: 0.01) }
    if p.isRunning { p.terminate(); throw NSError(domain: "pins: AeroSpace timeout", code: 1) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    guard p.terminationStatus == 0 else {
        let reason = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw NSError(domain: "pins: \(reason)", code: Int(p.terminationStatus))
    }
    return String(data: data, encoding: .utf8) ?? ""
}

private func pinRows(_ args: [String]) throws -> [[String: Any]] {
    let text = try pinCommand(args + ["--json"])
    guard let data = text.data(using: .utf8),
          let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else { throw NSError(domain: "pins: invalid AeroSpace response", code: 1) }
    return rows
}

private func pinText(_ row: [String: Any]) -> String {
    "\(row["app-name"] as? String ?? "") \(row["window-title"] as? String ?? "")".lowercased()
}

private func pinTarget(_ rule: PinRule, rows: [[String: Any]], focused: String) -> String? {
    guard let anchor = rule.anchor else { return focused }
    return rows.first { pinText($0).contains(anchor) }?["workspace"] as? String
}

/// Move every pinned window whose workspace differs from its rule's
/// target. Best effort: a missing anchor or a failed move leaves the
/// window alone. Returns one report row per matched window. The empty
/// config is the common case and costs no AeroSpace query at all.
func reconcilePins(dryRun: Bool = false) -> [[String: Any]] {
    let rules = pinRules()
    guard !rules.isEmpty else { return [] }
    guard let rows = try? pinRows(["list-windows", "--all", "--format", pinFormat]),
          let focused = try? pinCommand(["list-workspaces", "--focused"])
              .trimmingCharacters(in: .whitespacesAndNewlines)
    else { return [] }
    var report: [[String: Any]] = []
    for row in rows {
        guard let id = row["window-id"] as? Int,
              let workspace = row["workspace"] as? String else { continue }
        let text = pinText(row)
        guard let rule = rules.first(where: { text.contains($0.matcher) }),
              let target = pinTarget(rule, rows: rows, focused: focused)
        else { continue }
        let move = target != workspace
        if move && !dryRun {
            let operation = UUID().uuidString
            let context: [String: Any] = ["operation": operation, "id": id, "from": workspace, "to": target]
            WindowDiagnostics.shared.record("pin.move.begin", context)
            let accepted = (try? pinCommand(["move-node-to-workspace", "--window-id", String(id), target])) != nil
            WindowDiagnostics.shared.record("pin.move.end", context.merging(["command_accepted": accepted]) { _, new in new })
        }
        report.append(["id": id, "rule": rule.matcher, "from": workspace, "to": target, "move": move])
    }
    return report
}

func runPins(_ args: [String]) {
    let action = args.first ?? "sync"
    if action == "self-test" {
        let rules = parsePins("""
        # comment
        Firestone Overlay >> Hearthstone
        Picture in Picture
        """)
        precondition(rules.count == 2)
        precondition(rules[0].matcher == "firestone overlay" && rules[0].anchor == "hearthstone")
        precondition(rules[1].matcher == "picture in picture" && rules[1].anchor == nil)
        let rows: [[String: Any]] = [
            ["window-id": 1, "app-name": "Hearthstone", "window-title": "Hearthstone", "workspace": "3"],
            ["window-id": 2, "app-name": "Firestone", "window-title": "Firestone Overlay", "workspace": "2"],
        ]
        precondition(pinTarget(rules[0], rows: rows, focused: "2") == "3")
        precondition(pinTarget(rules[1], rows: rows, focused: "7") == "7")
        precondition(!pinText(rows[1]).contains("hearthstone"))
        print("PASS: pinned-window rules parse, match and resolve their anchor")
        return
    }
    guard ["sync", "status"].contains(action) else { fail("pins: unknown action \(action)") }
    let report = reconcilePins(dryRun: action == "status")
    // `status` shows every matched window (the dry-run plan); `sync`
    // reports only the moves it actually made, and stays silent otherwise.
    let rows = action == "status" ? report : report.filter { $0["move"] as? Bool == true }
    if !rows.isEmpty {
        let data = try! JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
        print(String(data: data, encoding: .utf8)!)
    }
}
