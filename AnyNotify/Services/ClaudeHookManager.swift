import Foundation

struct ClaudeHookManager {
    private let fileManager = FileManager.default

    private var settingsURL: URL {
        fileManager.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    }

    private let stopCommand = "/usr/bin/open -g 'anynotify://hook?source=claude&status=completed'"
    private let permissionCommand = "/usr/bin/open -g 'anynotify://hook?source=claude&status=waiting'"

    func isInstalled() -> Bool {
        guard let root = readSettings(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return contains(command: stopCommand, in: hooks["Stop"])
            && contains(command: permissionCommand, in: hooks["PermissionRequest"])
    }

    func install() throws {
        var root = readSettings() ?? [:]
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        hooks["Stop"] = adding(command: stopCommand, to: hooks["Stop"])
        hooks["PermissionRequest"] = adding(command: permissionCommand, to: hooks["PermissionRequest"])
        root["hooks"] = hooks
        try writeSettings(root)
    }

    func uninstall() throws {
        guard var root = readSettings() else { return }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        hooks["Stop"] = removing(command: stopCommand, from: hooks["Stop"])
        hooks["PermissionRequest"] = removing(command: permissionCommand, from: hooks["PermissionRequest"])
        root["hooks"] = hooks
        try writeSettings(root)
    }

    private func readSettings() -> [String: Any]? {
        guard let data = try? Data(contentsOf: settingsURL), !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: settingsURL, options: .atomic)
    }

    private func adding(command: String, to value: Any?) -> [[String: Any]] {
        var entries = value as? [[String: Any]] ?? []
        guard !contains(command: command, in: entries) else { return entries }
        entries.append([
            "hooks": [[
                "type": "command",
                "command": command
            ]]
        ])
        return entries
    }

    private func removing(command: String, from value: Any?) -> [[String: Any]] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard var nested = entry["hooks"] as? [[String: Any]] else { return entry }
            nested.removeAll { ($0["command"] as? String) == command }
            guard !nested.isEmpty else { return nil }
            var updated = entry
            updated["hooks"] = nested
            return updated
        }
    }

    private func contains(command: String, in value: Any?) -> Bool {
        guard let entries = value as? [[String: Any]] else { return false }
        return entries.contains { entry in
            guard let nested = entry["hooks"] as? [[String: Any]] else { return false }
            return nested.contains { ($0["command"] as? String) == command }
        }
    }
}
