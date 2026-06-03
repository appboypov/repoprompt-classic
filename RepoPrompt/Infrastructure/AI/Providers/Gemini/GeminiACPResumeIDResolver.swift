import Foundation

enum GeminiACPResumeIDResolver {
	struct Query: Sendable {
		let expectedRuntimeSessionID: String
		let workspacePath: String?
		let promptText: String?
		let notBefore: Date?
		let requireLoadableMessages: Bool
	}

	struct Resolution: Sendable, Equatable {
		let loadSessionID: String
		let matchKind: MatchKind
	}

	enum MatchKind: Sendable, Equatable {
		case exactSessionIDChatFile
		case promptMatchedChatFile
	}

	private struct ChatFileSummary {
		let fileURL: URL
		let sessionID: String
		let kind: String?
		let startTime: Date?
		let lastUpdated: Date?
		let modificationDate: Date?
		let hasUserOrAssistantMessage: Bool
		let firstUserText: String?
		let workspacePath: String?
	}

	#if DEBUG
	private nonisolated(unsafe) static var testGeminiDirectoryURL: URL?

	static func test_setGlobalGeminiDirectoryURL(_ url: URL?) {
		testGeminiDirectoryURL = url
	}
	#endif

	static func resolve(_ query: Query) async -> Resolution? {
		let expected = normalizedNonEmpty(query.expectedRuntimeSessionID)
		guard let expected else { return nil }

		let attempts: [UInt64] = [0, 100_000_000, 250_000_000, 500_000_000]
		for delay in attempts {
			if delay > 0 {
				try? await Task.sleep(nanoseconds: delay)
			}
			if let resolution = await Task.detached(priority: .utility) { () -> Resolution? in
				resolveOnce(query, expectedRuntimeSessionID: expected)
			}.value {
				return resolution
			}
		}
		return nil
	}

	private static func resolveOnce(_ query: Query, expectedRuntimeSessionID expected: String) -> Resolution? {
		let summaries = chatFileSummaries()
		if let exact = summaries.first(where: { summary in
			summary.sessionID == expected
				&& summary.kind?.lowercased() != "subagent"
				&& (!query.requireLoadableMessages || summary.hasUserOrAssistantMessage)
		}) {
			return Resolution(loadSessionID: exact.sessionID, matchKind: .exactSessionIDChatFile)
		}

		guard let prompt = normalizedPrompt(query.promptText), !prompt.isEmpty else { return nil }
		guard let queryWorkspacePath = normalizedWorkspacePath(query.workspacePath) else { return nil }
		let earliest = query.notBefore?.addingTimeInterval(-10)
		let matches = summaries.filter { summary in
			guard summary.kind?.lowercased() != "subagent" else { return false }
			guard !query.requireLoadableMessages || summary.hasUserOrAssistantMessage else { return false }
			guard normalizedWorkspacePath(summary.workspacePath) == queryWorkspacePath else { return false }
			if let earliest {
				let observed = summary.startTime ?? summary.lastUpdated ?? summary.modificationDate ?? .distantPast
				guard observed >= earliest else { return false }
			}
			return normalizedPrompt(summary.firstUserText) == prompt
		}
		let uniqueSessionIDs = Array(Set(matches.map(\.sessionID)))
		guard uniqueSessionIDs.count == 1, let loadID = uniqueSessionIDs.first else { return nil }
		return Resolution(loadSessionID: loadID, matchKind: .promptMatchedChatFile)
	}

	private static func chatFileSummaries() -> [ChatFileSummary] {
		let root = geminiDirectoryURL().appendingPathComponent("tmp", isDirectory: true)
		guard let projectURLs = try? FileManager.default.contentsOfDirectory(
			at: root,
			includingPropertiesForKeys: nil,
			options: [.skipsHiddenFiles]
		) else { return [] }

		var summaries: [ChatFileSummary] = []
		for projectURL in projectURLs {
			let chatsURL = projectURL.appendingPathComponent("chats", isDirectory: true)
			guard let fileURLs = try? FileManager.default.contentsOfDirectory(
				at: chatsURL,
				includingPropertiesForKeys: [.contentModificationDateKey],
				options: [.skipsHiddenFiles]
			) else { continue }
			for fileURL in fileURLs where fileURL.lastPathComponent.hasPrefix("session-") {
				let ext = fileURL.pathExtension.lowercased()
				guard ext == "jsonl" || ext == "json" else { continue }
				if let summary = parseChatFile(fileURL) {
					summaries.append(summary)
				}
			}
		}
		return summaries.sorted { lhs, rhs in
			(lhs.modificationDate ?? .distantPast) > (rhs.modificationDate ?? .distantPast)
		}
	}

	private static func parseChatFile(_ fileURL: URL) -> ChatFileSummary? {
		let modificationDate = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
		guard let data = try? Data(contentsOf: fileURL) else { return nil }
		if fileURL.pathExtension.lowercased() == "json" {
			return parseJSONChatFile(data, fileURL: fileURL, modificationDate: modificationDate)
		}
		guard let text = String(data: data, encoding: .utf8) else { return nil }
		return parseJSONLChatFile(text, fileURL: fileURL, modificationDate: modificationDate)
	}

	private static func parseJSONLChatFile(_ text: String, fileURL: URL, modificationDate: Date?) -> ChatFileSummary? {
		var sessionID: String?
		var kind: String?
		var startTime: Date?
		var lastUpdated: Date?
		var hasUserOrAssistantMessage = false
		var firstUserText: String?
		var workspacePath: String?

		for line in text.split(whereSeparator: { $0.isNewline }) {
			guard let data = String(line).data(using: .utf8),
				let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
			applyMetadata(from: object, sessionID: &sessionID, kind: &kind, startTime: &startTime, lastUpdated: &lastUpdated, workspacePath: &workspacePath)
			let type = (object["type"] as? String)?.lowercased()
			if type == "user" || type == "gemini" || type == "assistant" {
				hasUserOrAssistantMessage = true
				if type == "user", firstUserText == nil {
					firstUserText = textContent(in: object)
				}
			}
			if let message = object["message"] as? [String: Any] {
				let role = ((message["type"] ?? message["role"]) as? String)?.lowercased()
				if role == "user" || role == "gemini" || role == "assistant" {
					hasUserOrAssistantMessage = true
					if role == "user", firstUserText == nil {
						firstUserText = textContent(in: message) ?? textContent(in: object)
					}
				}
			}
		}

		guard let sessionID = normalizedNonEmpty(sessionID) else { return nil }
		return ChatFileSummary(
			fileURL: fileURL,
			sessionID: sessionID,
			kind: kind,
			startTime: startTime,
			lastUpdated: lastUpdated,
			modificationDate: modificationDate,
			hasUserOrAssistantMessage: hasUserOrAssistantMessage,
			firstUserText: firstUserText,
			workspacePath: workspacePath
		)
	}

	private static func parseJSONChatFile(_ data: Data, fileURL: URL, modificationDate: Date?) -> ChatFileSummary? {
		guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
		var sessionID: String?
		var kind: String?
		var startTime: Date?
		var lastUpdated: Date?
		var workspacePath: String?
		applyMetadata(from: object, sessionID: &sessionID, kind: &kind, startTime: &startTime, lastUpdated: &lastUpdated, workspacePath: &workspacePath)
		let messages = (object["messages"] as? [[String: Any]]) ?? (object["records"] as? [[String: Any]]) ?? []
		var hasUserOrAssistantMessage = false
		var firstUserText: String?
		for message in messages {
			let role = ((message["type"] ?? message["role"]) as? String)?.lowercased()
			if role == "user" || role == "gemini" || role == "assistant" {
				hasUserOrAssistantMessage = true
				if role == "user", firstUserText == nil {
					firstUserText = textContent(in: message)
				}
			}
		}
		guard let sessionID = normalizedNonEmpty(sessionID) else { return nil }
		return ChatFileSummary(
			fileURL: fileURL,
			sessionID: sessionID,
			kind: kind,
			startTime: startTime,
			lastUpdated: lastUpdated,
			modificationDate: modificationDate,
			hasUserOrAssistantMessage: hasUserOrAssistantMessage,
			firstUserText: firstUserText,
			workspacePath: workspacePath
		)
	}

	private static func applyMetadata(
		from object: [String: Any],
		sessionID: inout String?,
		kind: inout String?,
		startTime: inout Date?,
		lastUpdated: inout Date?,
		workspacePath: inout String?
	) {
		let metadata = (object["metadata"] as? [String: Any]) ?? (object["$set"] as? [String: Any]) ?? object
		if sessionID == nil { sessionID = metadata["sessionId"] as? String ?? metadata["sessionID"] as? String }
		if kind == nil { kind = metadata["kind"] as? String }
		if startTime == nil { startTime = parseDate(metadata["startTime"] as? String) }
		if lastUpdated == nil { lastUpdated = parseDate(metadata["lastUpdated"] as? String) }
		if workspacePath == nil {
			workspacePath = metadata["workspacePath"] as? String
				?? metadata["projectRoot"] as? String
				?? metadata["projectPath"] as? String
				?? metadata["cwd"] as? String
				?? metadata["targetDir"] as? String
		}
	}

	private static func textContent(in object: [String: Any]) -> String? {
		if let value = object["displayContent"] as? String { return value }
		if let parts = object["displayContent"] as? [[String: Any]] { return text(fromParts: parts) }
		if let value = object["content"] as? String { return value }
		if let parts = object["content"] as? [[String: Any]] { return text(fromParts: parts) }
		if let content = object["content"] as? [String: Any] {
			if let text = content["text"] as? String { return text }
			if let parts = content["parts"] as? [[String: Any]] {
				return text(fromParts: parts)
			}
		}
		return nil
	}

	private static func text(fromParts parts: [[String: Any]]) -> String? {
		let text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
		return normalizedNonEmpty(text)
	}

	private static func normalizedPrompt(_ text: String?) -> String? {
		guard let text else { return nil }
		return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
	}

	private static func normalizedNonEmpty(_ text: String?) -> String? {
		let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed?.isEmpty == false ? trimmed : nil
	}

	private static func normalizedWorkspacePath(_ path: String?) -> String? {
		guard let path = normalizedNonEmpty(path) else { return nil }
		return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
	}

	private static func parseDate(_ value: String?) -> Date? {
		guard let value else { return nil }
		return ISO8601DateFormatter().date(from: value)
	}

	private static func geminiDirectoryURL() -> URL {
		#if DEBUG
		if let testGeminiDirectoryURL { return testGeminiDirectoryURL }
		#endif
		return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".gemini", isDirectory: true)
	}
}
