import Foundation
import Darwin

enum ClaudeHookError: LocalizedError {
    case invalidConfiguration(URL)
    case configurationReadFailed(URL, Error)
    case configurationWriteFailed(URL, Error)
    case lockFailed(URL, Int32)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let url):
            return "Claude 配置文件不是有效的 JSON 对象：\(url.path)"
        case .configurationReadFailed(let url, let error):
            return "读取 Claude 配置失败：\(url.path)（\(error.localizedDescription)）"
        case .configurationWriteFailed(let url, let error):
            return "写入 Claude 配置失败：\(url.path)（\(error.localizedDescription)）"
        case .lockFailed(let url, let code):
            return "锁定 Claude 配置失败：\(url.path)（errno \(code)）"
        }
    }
}

struct ClaudeHookManager {
    private let fileManager = FileManager.default
    private let settingsURL: URL

    private var backupURL: URL {
        settingsURL.appendingPathExtension("anynotify.backup")
    }

    private var lockURL: URL {
        settingsURL.appendingPathExtension("anynotify.lock")
    }

    private let stopCommand = "/usr/bin/open -g 'anynotify://hook?source=claude&status=completed'"
    private let permissionCommand = "/usr/bin/open -g 'anynotify://hook?source=claude&status=waiting'"

    init(settingsURL: URL? = nil) {
        self.settingsURL = settingsURL
            ?? fileManager.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
    }

    func isInstalled() -> Bool {
        guard let root = try? readSettings(), let hooks = root["hooks"] as? [String: Any] else { return false }
        return contains(command: stopCommand, in: hooks["Stop"])
            && contains(command: permissionCommand, in: hooks["PermissionRequest"])
    }

    func install() throws {
        try withFileLock {
            let existingData = try readExistingData()
            var root = try readSettings() ?? [:]
            if let existingData {
                try writeBackup(existingData)
            }
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            hooks["Stop"] = adding(command: stopCommand, to: hooks["Stop"])
            hooks["PermissionRequest"] = adding(command: permissionCommand, to: hooks["PermissionRequest"])
            root["hooks"] = hooks
            try writeSettings(root)
        }
    }

    func uninstall() throws {
        try withFileLock {
            guard let existingData = try readExistingData(), var root = try readSettings() else { return }
            try writeBackup(existingData)
            var hooks = root["hooks"] as? [String: Any] ?? [:]
            hooks["Stop"] = removing(command: stopCommand, from: hooks["Stop"])
            hooks["PermissionRequest"] = removing(command: permissionCommand, from: hooks["PermissionRequest"])
            root["hooks"] = hooks
            try writeSettings(root)
        }
    }

    private func readExistingData() throws -> Data? {
        guard fileManager.fileExists(atPath: settingsURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: settingsURL)
            guard !data.isEmpty else { throw ClaudeHookError.invalidConfiguration(settingsURL) }
            return data
        } catch let error as ClaudeHookError {
            throw error
        } catch {
            throw ClaudeHookError.configurationReadFailed(settingsURL, error)
        }
    }

    private func readSettings() throws -> [String: Any]? {
        guard let data = try readExistingData() else { return nil }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ClaudeHookError.invalidConfiguration(settingsURL)
            }
            return object
        } catch let error as ClaudeHookError {
            throw error
        } catch {
            throw ClaudeHookError.invalidConfiguration(settingsURL)
        }
    }

    private func writeBackup(_ data: Data) throws {
        do {
            try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: backupURL, options: .atomic)
        } catch {
            throw ClaudeHookError.configurationWriteFailed(backupURL, error)
        }
    }

    private func writeSettings(_ object: [String: Any]) throws {
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try data.write(to: settingsURL, options: .atomic)
        } catch {
            throw ClaudeHookError.configurationWriteFailed(settingsURL, error)
        }
    }

    private func withFileLock<T>(_ body: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ClaudeHookError.lockFailed(lockURL, errno)
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw ClaudeHookError.lockFailed(lockURL, errno)
        }
        return try body()
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
