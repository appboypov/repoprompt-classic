import Foundation
import SwiftUI

private extension String {
	var nonEmpty: String? {
		isEmpty ? nil : self
	}

	var singleLineSummary: String? {
		let normalized = replacingOccurrences(of: "\r", with: " ")
			.replacingOccurrences(of: "\n", with: " ")
			.replacingOccurrences(of: "\t", with: " ")
			.replacingOccurrences(of: "  ", with: " ")
			.trimmingCharacters(in: .whitespacesAndNewlines)
		return normalized.isEmpty ? nil : normalized
	}
}

struct ChatSendResultCardPresentation: Equatable {
	let title: String
	let subtitle: String?
	let status: ToolCardStatus
	let chatID: String?

	static func build(for item: AgentChatItem, payloadSource: ToolResultPayloadSource) -> ChatSendResultCardPresentation {
		let normalizedName = (normalizedToolCardName(item.toolName) ?? item.toolName ?? "").lowercased()
		let isOracleTool = normalizedName == "ask_oracle" || normalizedName == "oracle_send"
		let dto = ToolJSON.decodeResult(ToolResultDTOs.ChatSendDTO.self, from: payloadSource)
		let raw = payloadSource.preferredPayload
		let resultObject = ToolJSON.structuredResultObject(from: raw)
		let storedPresentation = StoredToolCardPresentation.fromSummaryOnly(raw: item.toolResultJSON)
		let subtitle = summary(dto: dto, resultObject: resultObject)
			?? storedPresentation?.inlineSubtitle
			?? storageStatusSubtitle(for: item)
		let status = status(for: item, dto: dto, resultObject: resultObject, raw: raw)
		return ChatSendResultCardPresentation(
			title: isOracleTool ? "Oracle" : "Chat",
			subtitle: subtitle,
			status: status,
			chatID: dto?.chatID?.nonEmpty ?? stringValue(resultObject, keys: ["chat_id", "chatID"])
		)
	}

	private static func summary(
		dto: ToolResultDTOs.ChatSendDTO?,
		resultObject: [String: Any]?
	) -> String? {
		var parts: [String] = []
		if let mode = dto?.mode?.nonEmpty ?? stringValue(resultObject, keys: ["mode"]) {
			parts.append(mode)
		}
		let diffCount = dto?.diffs?.count ?? intValue(resultObject, keys: ["diff_count", "diffCount"])
		let chatID = dto?.chatID?.nonEmpty ?? stringValue(resultObject, keys: ["chat_id", "chatID"])
		if let chatID, parts.isEmpty || (diffCount ?? 0) == 0 {
			parts.append(chatID)
		}
		if let diffCount, diffCount > 0 {
			parts.append("\(diffCount) \(diffCount == 1 ? "diff" : "diffs")")
		}
		if parts.isEmpty,
			let errorSummary = errorSummary(dto: dto, resultObject: resultObject) {
			parts.append(errorSummary)
		}
		guard !parts.isEmpty else { return nil }
		return parts.joined(separator: " • ")
	}

	private static func status(
		for item: AgentChatItem,
		dto: ToolResultDTOs.ChatSendDTO?,
		resultObject: [String: Any]?,
		raw: String?
	) -> ToolCardStatus {
		if item.toolIsError == true { return .failure }
		if let errors = dto?.errors, !errors.isEmpty { return .failure }
		if intValue(resultObject, keys: ["error_count", "errorCount"]).map({ $0 > 0 }) == true { return .failure }
		if let errors = resultObject?["errors"] as? [Any], !errors.isEmpty { return .failure }
		let mappedStatus = ToolResultStatusResolver.mapStatusWord(stringValue(resultObject, keys: ["status"]))
		if mappedStatus == .failure {
			return .failure
		}
		let diffCount = dto?.diffs?.count ?? intValue(resultObject, keys: ["diff_count", "diffCount"])
		let response = dto?.response?.nonEmpty
		let hasResponse = boolValue(resultObject, keys: ["has_response", "hasResponse"])
		if (response == nil && hasResponse != true), let diffCount, diffCount > 0 {
			return .warning
		}
		if let mappedStatus {
			return mappedStatus
		}
		if dto != nil || hasResponse == true || stringValue(resultObject, keys: ["chat_id", "chatID", "mode"]) != nil {
			return .success
		}
		return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: raw, fallback: .neutral)
	}

	private static func errorSummary(
		dto: ToolResultDTOs.ChatSendDTO?,
		resultObject: [String: Any]?
	) -> String? {
		if let first = dto?.errors?.first?.nonEmpty { return first.singleLineSummary }
		if let first = (resultObject?["errors"] as? [String])?.first?.nonEmpty { return first.singleLineSummary }
		if let count = intValue(resultObject, keys: ["error_count", "errorCount"]), count > 0 {
			return "\(count) \(count == 1 ? "error" : "errors")"
		}
		return nil
	}

	private static func stringValue(_ object: [String: Any]?, keys: [String]) -> String? {
		guard let object else { return nil }
		for key in keys {
			guard let value = ToolRawJSON.string(object, key: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { continue }
			return value
		}
		return nil
	}

	private static func intValue(_ object: [String: Any]?, keys: [String]) -> Int? {
		guard let object else { return nil }
		for key in keys {
			if let value = ToolRawJSON.int(object, key: key) {
				return value
			}
		}
		return nil
	}

	private static func boolValue(_ object: [String: Any]?, keys: [String]) -> Bool? {
		guard let object else { return nil }
		for key in keys {
			if let value = ToolRawJSON.bool(object, key: key) {
				return value
			}
		}
		return nil
	}
}

struct ChatSendResultCard: View {
	let item: AgentChatItem
	let oracleOpenContext: AgentOracleOpenContext?
	@Environment(\.agentRawToolResultPayloadResolver) private var rawToolResultPayloadResolver
	@Environment(\.agentRawToolResultPayloadRenderRevision) private var rawPayloadRenderRevision

	private var payloadSource: ToolResultPayloadSource {
		ToolJSON.resultPayloadSource(
			for: item,
			rawPayload: rawToolResultPayloadResolver?(item.id)
		)
	}

	private var presentation: ChatSendResultCardPresentation {
		_ = rawPayloadRenderRevision
		return ChatSendResultCardPresentation.build(for: item, payloadSource: payloadSource)
	}

	private var onTap: (() -> Void)? {
		guard let oracleOpenContext else { return nil }
		let source = payloadSource
		let presentation = self.presentation
		return {
			var userInfo: [AnyHashable: Any] = ["windowID": oracleOpenContext.windowID]
			if let tabID = oracleOpenContext.tabID
				?? AgentOracleToolRouting.stringValue(from: source.preferredPayload, keys: ["context_id", "tab_id", "tabID"]).flatMap(UUID.init(uuidString:)) {
				userInfo["tabID"] = tabID
			}
			if let chatID = presentation.chatID ?? oracleOpenContext.chatID {
				userInfo["chatID"] = chatID
			}
			NotificationCenter.default.post(name: .showAgentOraclePopover, object: nil, userInfo: userInfo)
		}
	}

	var body: some View {
		let presentation = presentation
		StaticToolCardContainer(
			iconName: toolIcon(for: item.toolName),
			iconColor: ToolCardAccentResolver.color(for: item.toolName),
			title: presentation.title,
			subtitle: presentation.subtitle,
			status: presentation.status,
			timestamp: item.timestamp,
			onTap: onTap
		) {
			EmptyView()
		}
	}
}

struct ChatsResultCard: View {
	let item: AgentChatItem
	@State private var isExpanded = false

	private var dto: ChatsReplyDTO? {
		ToolJSON.decode(ChatsReplyDTO.self, from: item.toolResultJSON)
	}

	private var detailText: String? {
		if let chats = dto?.chats, !chats.isEmpty {
			let visible = chats.prefix(2).compactMap { chat -> String? in
				let trimmed = chat.name?.trimmingCharacters(in: .whitespacesAndNewlines)
				return trimmed?.isEmpty == false ? trimmed : chat.id
			}
			guard !visible.isEmpty else { return nil }
			var parts = visible
			if chats.count > visible.count {
				parts.append("(+\(chats.count - visible.count) more)")
			}
			return parts.joined(separator: " • ")
		}
		return nil
	}

	private var summary: String {
		if let dto {
			if dto.action?.lowercased() == "log" {
				let chatID = dto.chatID ?? "chat"
				let messageCount = dto.messages?.count ?? 0
				return "\(chatID) • \(messageCount) messages"
			}
			if let count = dto.chats?.count {
				return "\(count) chats"
			}
		}
		if let action = ToolJSON.decodeArgs(ToolArgsDTOs.ChatsArgs.self, from: item.toolArgsJSON)?.action,
			!action.isEmpty {
			return action
		}
		return ""
	}

	private var status: ToolCardStatus {
		if item.toolIsError == true { return .failure }
		if let dto {
			if dto.action?.lowercased() == "log" {
				return .success
			}
			if dto.chats != nil {
				return .success
			}
		}
		return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
	}

	var body: some View {
		let normalizedName = normalizedToolCardName(item.toolName)?.lowercased()
		let title = (normalizedName == "oracle_chat_log") ? "Oracle Log" : "Chats"
		ToolCardContainer(
			iconName: toolIcon(for: item.toolName),
			iconColor: ToolCardAccentResolver.color(for: item.toolName),
			title: title,
			detailText: nil,
			subtitle: inlineToolCardSummary(summary, detailText),
			status: status,
			timestamp: item.timestamp,
			isExpandable: toolResultHasPayload(item),
			rawPayloadItemID: item.id,
			isExpanded: $isExpanded
		) {
			ToolMarkdownExpandedContent(item: item)
		}
	}
}

struct ListModelsResultCard: View {
	let item: AgentChatItem
	@State private var isExpanded = false

	private var dto: ToolResultDTOs.ListModelsReply? {
		ToolJSON.decode(ToolResultDTOs.ListModelsReply.self, from: item.toolResultJSON)
	}

	private var detailText: String? {
		guard let models = dto?.models, !models.isEmpty else { return nil }
		let visible = models.prefix(2).map { $0.name }
		var parts = visible
		if models.count > visible.count {
			parts.append("(+\(models.count - visible.count) more)")
		}
		return parts.joined(separator: " • ")
	}

	private var summary: String {
		guard let dto else { return "" }
		return "\(dto.total) models"
	}

	private var status: ToolCardStatus {
		if item.toolIsError == true { return .failure }
		if let dto {
			return dto.total > 0 ? .success : .neutral
		}
		return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
	}

	var body: some View {
		ToolCardContainer(
			iconName: toolIcon(for: item.toolName),
			iconColor: ToolCardAccentResolver.color(for: item.toolName),
			title: "Models",
			detailText: nil,
			subtitle: inlineToolCardSummary(summary, detailText),
			status: status,
			timestamp: item.timestamp,
			isExpandable: toolResultHasPayload(item),
			rawPayloadItemID: item.id,
			isExpanded: $isExpanded
		) {
			ToolMarkdownExpandedContent(item: item)
		}
	}
}

struct ManageWorkspacesResultCard: View {
	let item: AgentChatItem
	@State private var isExpanded = false

	private var dto: ManageWorkspacesResponse? {
		ToolJSON.decode(ManageWorkspacesResponse.self, from: item.toolResultJSON)
	}

	private var detailText: String? {
		guard let dto else { return nil }
		if let workspaces = dto.workspaces, !workspaces.isEmpty {
			let visible = workspaces.prefix(2).map { $0.name }
			var parts = visible
			if workspaces.count > visible.count {
				parts.append("(+\(workspaces.count - visible.count) more)")
			}
			return parts.joined(separator: " • ")
		}
		if let tabs = dto.tabs, !tabs.isEmpty {
			let visible = tabs.prefix(2).map { $0.name }
			var parts = visible
			if tabs.count > visible.count {
				parts.append("(+\(tabs.count - visible.count) more)")
			}
			return parts.joined(separator: " • ")
		}
		return nil
	}

	private var headerStatusText: String? {
		nil
	}

	private var summary: String {
		if let dto {
			var parts: [String] = [dto.action]
			if let workspaces = dto.workspaces {
				parts.append("\(workspaces.count) workspaces")
			}
			if let tabs = dto.tabs {
				parts.append("\(tabs.count) tabs")
			}
			if let windowID = dto.windowID {
				parts.append("window \(windowID)")
			}
			if let closedWindowID = dto.closedWindowID {
				parts.append("closed \(closedWindowID)")
			}
			return parts.joined(separator: " • ")
		}
		if let action = ToolJSON.decodeArgs(ToolArgsDTOs.ManageWorkspacesArgs.self, from: item.toolArgsJSON)?.action {
			return action
		}
		return ""
	}

	private var status: ToolCardStatus {
		if item.toolIsError == true { return .failure }
		if let dto, let status = dto.status, let mapped = ToolResultStatusResolver.mapStatusWord(status) {
			return mapped
		}
		return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: item.toolResultJSON, fallback: .neutral)
	}

	var body: some View {
		ToolCardContainer(
			iconName: toolIcon(for: item.toolName),
			iconColor: ToolCardAccentResolver.color(for: item.toolName),
			title: "Workspaces",
			detailText: nil,
			subtitle: inlineToolCardSummary(summary, detailText),
			status: status,
			timestamp: item.timestamp,
			isExpandable: toolResultHasPayload(item),
			rawPayloadItemID: item.id,
			isExpanded: $isExpanded
		) {
			ToolMarkdownExpandedContent(item: item)
		}
	}
}

private struct ChatsReplyDTO: Decodable {
	let action: String?
	let chats: [ChatSummaryDTO]?
	let chatID: String?
	let messages: [ChatMessageDTO]?

	enum CodingKeys: String, CodingKey {
		case action
		case chats
		case chatID = "chat_id"
		case messages
	}
}

private struct ChatSummaryDTO: Decodable {
	let id: String?
	let name: String?
	let messageCount: Int?

	enum CodingKeys: String, CodingKey {
		case id
		case name
		case messageCount = "message_count"
	}
}

private struct ChatMessageDTO: Decodable {}
