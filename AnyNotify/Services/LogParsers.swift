import Foundation

struct ClaudeLogParser: Sendable {
    private(set) var sessionID: String?
    private(set) var workingDirectory: String?
    private var activeTurnID: String?

    mutating func parse(line: Data) -> [TaskEvent] {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            !isFilteredSession(object)
        else { return [] }

        sessionID = string(object["sessionId"]) ?? string(object["session_id"]) ?? sessionID
        workingDirectory = string(object["cwd"]) ?? workingDirectory
        let timestamp = parseDate(object["timestamp"]) ?? Date()
        let type = string(object["type"]) ?? ""

        if type == "user", let message = object["message"] as? [String: Any], isHumanMessage(message) {
            activeTurnID = string(object["promptId"]) ?? string(object["uuid"]) ?? UUID().uuidString
            return [event(status: .started, summary: "Claude Code 开始处理任务", timestamp: timestamp)]
        }

        if type == "assistant", let message = object["message"] as? [String: Any] {
            let content = message["content"]
            let toolNames = extractToolNames(content)
            if toolNames.contains(where: { Self.waitingTools.contains($0) }) {
                return [event(status: .waiting, summary: "Claude Code 正在等待你的确认或输入", timestamp: timestamp)]
            }

            let stopReason = string(message["stop_reason"]) ?? ""
            guard stopReason == "end_turn" || stopReason == "stop_sequence" else { return [] }
            let text = extractText(content).shortenedForNotification
            let status: TaskStatus = Self.looksLikeFailure(text) ? .failed : .completed
            return [event(status: status, summary: text, timestamp: timestamp)]
        }

        if type == "system", string(object["subtype"]) == "agents_killed" {
            return [event(status: .interrupted, summary: "Claude Code 任务已中断", timestamp: timestamp)]
        }

        return []
    }

    private func event(status: TaskStatus, summary: String, timestamp: Date) -> TaskEvent {
        TaskEvent(
            source: .claude,
            status: status,
            sessionID: sessionID,
            turnID: activeTurnID,
            workingDirectory: workingDirectory,
            summary: summary.shortenedForNotification,
            timestamp: timestamp
        )
    }

    private func isFilteredSession(_ object: [String: Any]) -> Bool {
        if (object["isSidechain"] as? Bool) == true { return true }
        let entrypoint = string(object["entrypoint"]) ?? ""
        return entrypoint == "sdk-cli" || entrypoint == "sdk"
    }

    private func isHumanMessage(_ message: [String: Any]) -> Bool {
        guard string(message["role"]) == "user" else { return false }
        if message["content"] is String { return true }
        guard let blocks = message["content"] as? [[String: Any]] else { return false }
        let hasText = blocks.contains { string($0["type"]) == "text" }
        let hasToolResult = blocks.contains { string($0["type"]) == "tool_result" }
        return hasText && !hasToolResult
    }

    private func extractToolNames(_ content: Any?) -> [String] {
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard string(block["type"]) == "tool_use" else { return nil }
            return string(block["name"])
        }
    }

    private func extractText(_ content: Any?) -> String {
        if let text = content as? String { return text.trimmed }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block -> String? in
            guard string(block["type"]) == "text" else { return nil }
            return string(block["text"])
        }.joined(separator: "\n").trimmed
    }

    private static let waitingTools: Set<String> = [
        "AskUserQuestion",
        "RequestUserInput",
        "request_user_input"
    ]

    static func looksLikeFailure(_ text: String) -> Bool {
        let value = text.lowercased()
        return [
            "api error:", "error:", "错误：", "request failed", "request error",
            "authentication failed", "authentication error", "connection failed",
            "connection error", "network error", "rate limit", "timed out",
            "permission denied", "overloaded", "over capacity", "internal server error"
        ].contains(where: value.contains)
    }
}

struct CodexLogParser: Sendable {
    private(set) var sessionID: String?
    private(set) var workingDirectory: String?
    private var activeTurnID: String?
    private var lastAssistantText = ""
    private var pendingInputCalls: Set<String> = []
    private var isSubagent = false

    mutating func parse(line: Data) -> [TaskEvent] {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = string(object["type"]),
            let payload = object["payload"] as? [String: Any]
        else { return [] }

        let timestamp = parseDate(object["timestamp"]) ?? Date()

        if type == "session_meta" {
            sessionID = string(payload["session_id"]) ?? string(payload["id"]) ?? sessionID
            workingDirectory = string(payload["cwd"]) ?? workingDirectory
            isSubagent = describesSubagent(payload["thread_source"]) || describesSubagent(payload["source"])
            return []
        }

        if type == "turn_context" {
            activeTurnID = string(payload["turn_id"]) ?? activeTurnID
            workingDirectory = string(payload["cwd"]) ?? workingDirectory
            return []
        }

        if type == "event_msg" {
            return parseEventMessage(payload, timestamp: timestamp)
        }

        if type == "response_item" {
            return parseResponseItem(payload, timestamp: timestamp)
        }

        return []
    }

    private mutating func parseEventMessage(_ payload: [String: Any], timestamp: Date) -> [TaskEvent] {
        let payloadType = string(payload["type"]) ?? ""
        switch payloadType {
        case "task_started":
            activeTurnID = string(payload["turn_id"]) ?? activeTurnID ?? UUID().uuidString
            lastAssistantText = ""
            pendingInputCalls.removeAll()
            return isSubagent ? [] : [event(status: .started, summary: "Codex 开始处理任务", timestamp: timestamp)]

        case "agent_message":
            lastAssistantText = (string(payload["message"]) ?? lastAssistantText).shortenedForNotification
            if string(payload["phase"]) == "final_answer", !isSubagent, pendingInputCalls.isEmpty {
                return [event(status: .completed, summary: lastAssistantText, timestamp: timestamp)]
            }

        case "task_complete":
            activeTurnID = string(payload["turn_id"]) ?? activeTurnID
            let summary = string(payload["last_agent_message"]) ?? lastAssistantText
            guard !isSubagent else { return [] }
            if !pendingInputCalls.isEmpty {
                return [event(status: .waiting, summary: "Codex 正在等待你的确认或输入", timestamp: timestamp)]
            }
            return [event(status: .completed, summary: summary, timestamp: timestamp)]

        case "turn_aborted", "task_aborted", "turn_cancelled":
            activeTurnID = string(payload["turn_id"]) ?? activeTurnID
            let reason = string(payload["reason"]) ?? "Codex 任务已中断"
            return isSubagent ? [] : [event(status: .interrupted, summary: reason, timestamp: timestamp)]

        case "turn_error", "task_error", "error":
            let message = string(payload["message"]) ?? string(payload["error"]) ?? "Codex 任务失败"
            return isSubagent ? [] : [event(status: .failed, summary: message, timestamp: timestamp)]

        default:
            break
        }
        return []
    }

    private mutating func parseResponseItem(_ payload: [String: Any], timestamp: Date) -> [TaskEvent] {
        let payloadType = string(payload["type"]) ?? ""
        switch payloadType {
        case "function_call", "custom_tool_call", "tool_use":
            let name = string(payload["name"]) ?? string(payload["tool_name"]) ?? ""
            guard name == "request_user_input" else { return [] }
            let callID = string(payload["call_id"]) ?? string(payload["tool_call_id"]) ?? string(payload["id"]) ?? UUID().uuidString
            pendingInputCalls.insert(callID)
            return isSubagent ? [] : [event(status: .waiting, summary: questionSummary(from: payload), timestamp: timestamp)]

        case "function_call_output", "custom_tool_call_output", "tool_result":
            if let callID = string(payload["call_id"]) ?? string(payload["tool_call_id"]) ?? string(payload["id"]) {
                pendingInputCalls.remove(callID)
            }

        case "message":
            guard string(payload["role"]) == "assistant" else { return [] }
            let text = extractMessageText(payload["content"])
            if !text.isEmpty { lastAssistantText = text.shortenedForNotification }
            if string(payload["phase"]) == "final_answer", !isSubagent, pendingInputCalls.isEmpty {
                return [event(status: .completed, summary: lastAssistantText, timestamp: timestamp)]
            }

        default:
            break
        }
        return []
    }

    private func event(status: TaskStatus, summary: String, timestamp: Date) -> TaskEvent {
        TaskEvent(
            source: .codex,
            status: status,
            sessionID: sessionID,
            turnID: activeTurnID,
            workingDirectory: workingDirectory,
            summary: summary.shortenedForNotification,
            timestamp: timestamp
        )
    }

    private func questionSummary(from payload: [String: Any]) -> String {
        let rawArguments = payload["arguments"] ?? payload["input"]
        var arguments: [String: Any]?
        if let dictionary = rawArguments as? [String: Any] {
            arguments = dictionary
        } else if let text = rawArguments as? String,
                  let data = text.data(using: .utf8) {
            arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        }

        if let questions = arguments?["questions"] as? [[String: Any]],
           let first = questions.first,
           let question = string(first["question"]), !question.isEmpty {
            return question.shortenedForNotification
        }
        return "Codex 正在等待你的确认或输入"
    }

    private func extractMessageText(_ content: Any?) -> String {
        if let text = content as? String { return text.trimmed }
        guard let blocks = content as? [[String: Any]] else { return "" }
        return blocks.compactMap { block in
            string(block["text"]) ?? string(block["content"])
        }.joined(separator: "\n").trimmed
    }

    private func describesSubagent(_ value: Any?) -> Bool {
        if let text = value as? String { return text.lowercased().contains("subagent") }
        if let dictionary = value as? [String: Any] {
            if dictionary.keys.contains(where: { $0.lowercased().contains("subagent") }) { return true }
            return dictionary.values.contains { describesSubagent($0) }
        }
        return false
    }
}

private func string(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    if let value = value as? NSNumber { return value.stringValue }
    return nil
}

private func parseDate(_ value: Any?) -> Date? {
    guard let value = string(value) else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
}
