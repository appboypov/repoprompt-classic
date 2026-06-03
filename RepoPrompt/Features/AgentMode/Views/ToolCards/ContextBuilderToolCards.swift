import SwiftUI

struct ContextBuilderCallCard: View {
	let item: AgentChatItem
	private let context: ContextBuilderCardContext
	@ObservedObject private var discoverAgentVM: DiscoverAgentViewModel
	@State private var isExpanded = false

	init(item: AgentChatItem, context: ContextBuilderCardContext) {
		self.item = item
		self.context = context
		self._discoverAgentVM = ObservedObject(wrappedValue: context.discoverAgentVM)
	}

	private var isRunningForTab: Bool {
		guard let tabID = context.tabID else { return false }
		return discoverAgentVM.tabsWithActiveDiscoverRun.contains(tabID)
	}

	private var isActiveCallCard: Bool {
		context.activeContextBuilderCallItemID == item.id
	}

	private var planStatusForTab: DiscoverPlanStatus {
		discoverAgentVM.planStatus(for: context.tabID)
	}

	private var isPlanGeneratingForTab: Bool {
		if case .generating = planStatusForTab {
			return true
		}
		return false
	}

	private var phase: ContextBuilderCardPhase {
		if isActiveCallCard && isRunningForTab {
			return .running
		}
		if isActiveCallCard && isPlanGeneratingForTab {
			return .generatingPlan
		}
		return .completed
	}

	private var detailLine: String? {
		contextBuilderCardDetailLine(discoverAgentVM: discoverAgentVM)
	}

	private var summary: String {
		contextBuilderCardSubtitle(
			discoverAgentVM: discoverAgentVM,
			fallbackStatus: nil,
			phase: phase
		)
	}

	private var status: ToolCardStatus {
		switch phase {
		case .running, .generatingPlan:
			return .running
		case .completed:
			return .success
		}
	}

	private var canCancelRunningContextBuilder: Bool {
		context.cancelActiveToolsAction != nil || context.tabID != nil
	}

	private var showsHeaderCancelButton: Bool {
		phase == .running
			&& context.showRunScopedToolCancel
			&& canCancelRunningContextBuilder
	}

	private func cancelRun() {
		cancelContextBuilderRun(
			discoverAgentVM: discoverAgentVM,
			tabID: context.tabID,
			cancelActiveToolsAction: context.cancelActiveToolsAction
		)
	}

	var body: some View {
		ToolCardContainer(
			iconName: toolIcon(for: item.toolName),
			iconColor: ToolCardAccentResolver.color(for: item.toolName),
			title: "Context Builder",
			detailText: detailLine,
			subtitle: summary,
			status: status,
			timestamp: item.timestamp,
			showsTimestamp: !showsHeaderCancelButton,
			headerTrailingView: showsHeaderCancelButton ? AnyView(ToolCardCancelButton(action: cancelRun)) : nil,
			managesOwnExpansion: true,
			isExpanded: $isExpanded
		) {
			switch phase {
			case .running:
				ContextBuilderRunDetailsView(
					discoverAgentVM: discoverAgentVM,
					tabID: context.tabID,
					maxLogEntries: 6,
					showQuestionCard: true,
					showCancelRunButton: true,
					onCancelRun: cancelRun
				)
			case .generatingPlan:
				ContextBuilderPlanProgressView(
					discoverAgentVM: discoverAgentVM,
					tabID: context.tabID,
					followUpLabel: contextBuilderFollowUpLabel(discoverAgentVM: discoverAgentVM),
					oracleOpenContext: context.oracleOpenContext,
					onCancelPlan: {
						discoverAgentVM.cancelBackgroundPlanGeneration(forTabID: context.tabID)
					}
				)
			case .completed:
				Text("Context builder run completed.")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}
		}
		.onAppear {
			performAgentToolCardExpansionStateUpdateWithoutAnimation {
				isExpanded = phase == .running || phase == .generatingPlan
			}
		}
		.onChange(of: phase) { _, newPhase in
			performAgentToolCardExpansionStateUpdateWithoutAnimation {
				switch newPhase {
				case .running, .generatingPlan:
					isExpanded = true
				case .completed:
					isExpanded = false
				}
			}
		}
	}
}

struct ContextBuilderResultCard: View {
	let item: AgentChatItem
	private let context: ContextBuilderCardContext
	@ObservedObject private var discoverAgentVM: DiscoverAgentViewModel
	@Environment(\.agentRawToolResultPayloadResolver) private var rawToolResultPayloadResolver
	@Environment(\.agentRawToolResultPayloadRenderRevision) private var rawPayloadRenderRevision
	@State private var isExpanded = false

	init(item: AgentChatItem, context: ContextBuilderCardContext) {
		self.item = item
		self.context = context
		self._discoverAgentVM = ObservedObject(wrappedValue: context.discoverAgentVM)
	}

	private var payloadSource: ToolResultPayloadSource {
		ToolJSON.resultPayloadSource(
			for: item,
			rawPayload: rawToolResultPayloadResolver?(item.id)
		)
	}

	private var dto: ToolResultDTOs.ContextBuilderDTO? {
		_ = rawPayloadRenderRevision
		return ToolJSON.decodeResult(ToolResultDTOs.ContextBuilderDTO.self, from: payloadSource)
	}

	private var isActiveResultCard: Bool {
		return context.activeContextBuilderResultItemID == item.id
	}

	private var isRunningForTab: Bool {
		guard let tabID = context.tabID else { return false }
		return discoverAgentVM.tabsWithActiveDiscoverRun.contains(tabID)
	}

	private var planStatusForTab: DiscoverPlanStatus {
		return discoverAgentVM.planStatus(for: context.tabID)
	}

	private var isPlanGeneratingForTab: Bool {
		if case .generating = planStatusForTab {
			return true
		}
		return false
	}

	private var phase: ContextBuilderCardPhase {
		if isActiveResultCard && isRunningForTab {
			return .running
		}
		if isActiveResultCard && isPlanGeneratingForTab {
			return .generatingPlan
		}
		return .completed
	}

	private var detailLine: String? {
		contextBuilderCardDetailLine(discoverAgentVM: discoverAgentVM)
	}

	private var summary: String {
		if isActiveResultCard {
			return contextBuilderCardSubtitle(
				discoverAgentVM: discoverAgentVM,
				fallbackStatus: dto?.status,
				phase: phase
			)
		}
		return contextBuilderFinalStatusLabel(dto?.status)
	}

	private var status: ToolCardStatus {
		if phase == .running || phase == .generatingPlan { return .running }
		if item.toolIsError == true { return .failure }
		if let dto {
			switch dto.status?.lowercased() {
			case "error": return .failure
			case "partial", "warning": return .warning
			case "running", "in_progress", "pending":
				return .success
			case "success", "completed": return .success
			default: break
			}
		}
		return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: payloadSource.preferredPayload, fallback: .neutral)
	}

	private var isExpandable: Bool {
		if phase == .completed {
			return dto != nil || context.oracleOpenContext != nil
		}
		return true
	}

	private var canCancelRunningContextBuilder: Bool {
		context.cancelActiveToolsAction != nil || context.tabID != nil
	}

	private var showsHeaderCancelButton: Bool {
		phase == .running
			&& context.showRunScopedToolCancel
			&& canCancelRunningContextBuilder
	}

	private func cancelRun() {
		cancelContextBuilderRun(
			discoverAgentVM: discoverAgentVM,
			tabID: context.tabID,
			cancelActiveToolsAction: context.cancelActiveToolsAction
		)
	}

	var body: some View {
		ToolCardContainer(
			iconName: toolIcon(for: item.toolName),
			iconColor: ToolCardAccentResolver.color(for: item.toolName),
			title: "Context Builder",
			detailText: detailLine,
			subtitle: summary,
			status: status,
			timestamp: item.timestamp,
			showsTimestamp: !showsHeaderCancelButton,
			headerTrailingView: showsHeaderCancelButton ? AnyView(ToolCardCancelButton(action: cancelRun)) : nil,
			isExpandable: isExpandable,
			managesOwnExpansion: true,
			rawPayloadItemID: item.id,
			isExpanded: $isExpanded
		) {
			if phase == .running {
				ContextBuilderRunDetailsView(
					discoverAgentVM: discoverAgentVM,
					tabID: context.tabID,
					maxLogEntries: 6,
					showQuestionCard: true,
					showCancelRunButton: true,
					onCancelRun: cancelRun
				)
			} else if phase == .generatingPlan {
				ContextBuilderPlanProgressView(
					discoverAgentVM: discoverAgentVM,
					tabID: context.tabID,
					followUpLabel: contextBuilderFollowUpLabel(discoverAgentVM: discoverAgentVM),
					oracleOpenContext: context.oracleOpenContext,
					onCancelPlan: {
						discoverAgentVM.cancelBackgroundPlanGeneration(forTabID: context.tabID)
					}
				)
			} else {
				ContextBuilderCompletedSummaryView(
					dto: dto,
					oracleOpenContext: context.oracleOpenContext
				)
			}
		}
		.onAppear {
			performAgentToolCardExpansionStateUpdateWithoutAnimation {
				isExpanded = phase == .running || phase == .generatingPlan
			}
		}
		.onChange(of: phase) { _, newPhase in
			performAgentToolCardExpansionStateUpdateWithoutAnimation {
				switch newPhase {
				case .running, .generatingPlan:
					isExpanded = true
				case .completed:
					if isActiveResultCard {
						isExpanded = false
					}
				}
			}
		}
	}
}

private struct ContextBuilderRunDetailsView: View {
	@ObservedObject var discoverAgentVM: DiscoverAgentViewModel
	let tabID: UUID?
	let maxLogEntries: Int
	let showQuestionCard: Bool
	let showCancelRunButton: Bool
	let onCancelRun: (() -> Void)?
	private let logViewportHeight: CGFloat = 100

	private var pendingAskUser: AgentAskUserPendingState? {
		discoverAgentVM.pendingAskUser(for: tabID)
	}

	private var visibleLogEntries: [AgentLogEntry] {
		let hasPendingQuestion = pendingAskUser != nil
		let entries = discoverAgentVM.agentLog
		guard hasPendingQuestion else { return entries }
		return entries.filter { !$0.message.hasPrefix("🤔 Agent is asking:") }
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			if !visibleLogEntries.isEmpty {
				ScrollView {
					VStack(alignment: .leading, spacing: 3) {
						ForEach(Array(visibleLogEntries.suffix(maxLogEntries))) { entry in
							AgentLogEntryRowView(entry: entry, style: .compact)
						}
					}
					.frame(maxWidth: .infinity, alignment: .leading)
				}
				.frame(height: logViewportHeight, alignment: .top)
				.clipped()
			} else {
				Text("No recent discovery activity for this tab.")
					.font(.system(size: 11))
					.foregroundStyle(.secondary)
			}

			if showQuestionCard, let pendingAskUser {
				Text("Context Builder Question")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(.secondary)
					.padding(.top, 2)
				AgentAskUserWizardCard(
					pending: pendingAskUser,
					onDraftChange: { questionID, draft in
						guard let tabID else { return }
						discoverAgentVM.updateAskUserDraft(
							tabID: tabID,
							interactionID: pendingAskUser.interaction.id,
							questionID: questionID,
							draft: draft
						)
					},
					onIndexChange: { index in
						guard let tabID else { return }
						discoverAgentVM.updateAskUserQuestionIndex(
							tabID: tabID,
							interactionID: pendingAskUser.interaction.id,
							index: index
						)
					},
					onSubmit: {
						guard let tabID else { return }
						discoverAgentVM.submitAskUserResponse(tabID: tabID)
					},
					onSkipAll: {
						guard let tabID else { return }
						discoverAgentVM.skipAskUser(tabID: tabID)
					},
					onUserActivity: {
						guard let tabID else { return }
						discoverAgentVM.noteAskUserCardActivity(tabID: tabID, interactionID: pendingAskUser.interaction.id)
					}
				)
			}

			if showCancelRunButton, let onCancelRun {
				Button("Cancel Run", action: onCancelRun)
					.buttonStyle(.bordered)
					.controlSize(.small)
			}
		}
	}
}

private struct ContextBuilderPlanProgressView: View {
	@ObservedObject var discoverAgentVM: DiscoverAgentViewModel
	let tabID: UUID?
	let followUpLabel: String
	let oracleOpenContext: AgentOracleOpenContext?
	let onCancelPlan: () -> Void

	private var isReasoningOnly: Bool {
		let response = discoverAgentVM.backgroundPlanResponsePreviewText?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let reasoning = discoverAgentVM.backgroundPlanReasoningPreviewText?
			.trimmingCharacters(in: .whitespacesAndNewlines)
		let hasResponse = (response?.isEmpty == false)
		let hasReasoning = (reasoning?.isEmpty == false)
		return hasReasoning && !hasResponse
	}

	private var followUpChatID: String? {
		discoverAgentVM.currentFollowUpOracleChatID(for: tabID)
	}

	private func openOraclePreview() {
		guard let oracleOpenContext, let followUpChatID else { return }
		let userInfo = contextBuilderOraclePopoverUserInfo(
			openContext: oracleOpenContext,
			chatID: followUpChatID
		)
		NotificationCenter.default.post(name: .showAgentOraclePopover, object: nil, userInfo: userInfo)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			HStack(spacing: 6) {
				ProgressView()
					.controlSize(.mini)
					.scaleEffect(0.7)
				Text("Generating \(followUpLabel)...")
					.font(.system(size: 11, weight: .semibold))
					.foregroundStyle(.secondary)

				if isReasoningOnly {
					Image(systemName: "brain")
						.font(.system(size: 10))
						.foregroundStyle(.purple)
				}

				Spacer()
			}

			HStack(spacing: 8) {
				Button(action: openOraclePreview) {
					HStack(spacing: 4) {
						Image(systemName: "doc.text.magnifyingglass")
							.font(.system(size: 11))
						Text("Preview")
							.font(.system(size: 11))
					}
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
				.disabled(oracleOpenContext == nil || followUpChatID == nil)

				Button("Cancel") {
					onCancelPlan()
				}
				.buttonStyle(.bordered)
				.controlSize(.small)
			}
		}
	}
}

private struct ContextBuilderCompletedSummaryView: View {
	let dto: ToolResultDTOs.ContextBuilderDTO?
	let oracleOpenContext: AgentOracleOpenContext?

	private var followUpChatID: String? {
		contextBuilderFollowUpChatID(for: dto) ?? nonEmptyContextBuilderValue(oracleOpenContext?.chatID)
	}

	private var detailParts: [String] {
		var parts: [String] = []
		if let fileCount = dto?.fileCount {
			parts.append("\(fileCount) files")
		}
		if let totalTokens = dto?.totalTokens {
			parts.append("\(totalTokens) tokens")
		}
		if let raw = dto?.responseType?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
			parts.append(raw)
		}
		return parts
	}

	private var selectionSummary: String? {
		guard let selection = dto?.selection?.trimmingCharacters(in: .whitespacesAndNewlines), !selection.isEmpty else {
			return nil
		}
		return selection
	}

	private func openOraclePreview() {
		guard let oracleOpenContext else { return }
		let userInfo = contextBuilderOraclePopoverUserInfo(
			openContext: oracleOpenContext,
			chatID: followUpChatID
		)
		NotificationCenter.default.post(name: .showAgentOraclePopover, object: nil, userInfo: userInfo)
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			Text("Context builder run completed.")
				.font(.system(size: 11))
				.foregroundStyle(.secondary)

			if !detailParts.isEmpty {
				Text(detailParts.joined(separator: " • "))
					.font(.system(size: 10))
					.foregroundStyle(.secondary)
			}

			if let selectionSummary {
				Text(selectionSummary)
					.font(.system(size: 10))
					.foregroundStyle(.secondary)
					.lineLimit(3)
			}

			if let followUpChatID, !followUpChatID.isEmpty {
				Text("Oracle chat: \(followUpChatID)")
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(.secondary)
			}

			Button("Open Oracle", action: openOraclePreview)
				.buttonStyle(.bordered)
				.controlSize(.small)
				.disabled(oracleOpenContext == nil || followUpChatID == nil)
		}
	}
}

private enum ContextBuilderCardPhase {
	case running
	case generatingPlan
	case completed
}

func contextBuilderOraclePopoverUserInfo(
	openContext: AgentOracleOpenContext,
	chatID: String?
) -> [AnyHashable: Any] {
	var userInfo: [AnyHashable: Any] = ["windowID": openContext.windowID]
	if let tabID = openContext.tabID {
		userInfo["tabID"] = tabID
	}
	if let resolvedChatID = nonEmptyContextBuilderValue(chatID) ?? nonEmptyContextBuilderValue(openContext.chatID) {
		userInfo["chatID"] = resolvedChatID
	}
	return userInfo
}

func contextBuilderFollowUpChatID(for dto: ToolResultDTOs.ContextBuilderDTO?) -> String? {
	guard let dto else { return nil }
	let planChatID = nonEmptyContextBuilderValue(dto.plan?.chatID)
	let reviewChatID = nonEmptyContextBuilderValue(dto.review?.chatID)
	let responseType = dto.responseType?
		.trimmingCharacters(in: .whitespacesAndNewlines)
		.lowercased()

	switch responseType {
	case "review":
		return reviewChatID ?? planChatID
	case "plan":
		return planChatID ?? reviewChatID
	default:
		// Legacy payloads did not always include response_type; preserve the prior
		// plan-first fallback unless the payload only contains a review branch.
		return planChatID ?? reviewChatID
	}
}

@MainActor
private func cancelContextBuilderRun(
	discoverAgentVM: DiscoverAgentViewModel,
	tabID: UUID?,
	cancelActiveToolsAction: (() -> Void)?
) {
	// Prefer the run-scoped MCP wrapper cancel when available. The wrapper now
	// propagates cancellation into the underlying discovery run, so avoid a
	// second direct VM cancellation racing the same session teardown.
	if let cancelActiveToolsAction {
		if let tabID {
			_ = discoverAgentVM.beginCancellation(forTabID: tabID)
		}
		cancelActiveToolsAction()
		return
	}

	if let tabID {
		guard discoverAgentVM.beginCancellation(forTabID: tabID) else { return }
		Task { await discoverAgentVM.cancelMCPDiscoverRun(forTabID: tabID) }
	} else {
		guard discoverAgentVM.beginCancellation() else { return }
		Task { await discoverAgentVM.cancelAgentRun() }
	}
}

@MainActor
private func contextBuilderCardDetailLine(discoverAgentVM: DiscoverAgentViewModel) -> String? {
	var detail = "Discover: \(discoverAgentVM.runModelDisplayName)"
	if let followUpType = nonEmptyContextBuilderValue(discoverAgentVM.mcpResponseType) {
		if let followUpModel = nonEmptyContextBuilderValue(discoverAgentVM.mcpPlanModel) {
			detail += " → \(followUpType): \(followUpModel)"
		} else {
			detail += " → \(followUpType)"
		}
	}
	return detail
}

@MainActor
private func contextBuilderCardSubtitle(
	discoverAgentVM: DiscoverAgentViewModel,
	fallbackStatus: String?,
	phase: ContextBuilderCardPhase
) -> String {
	var parts: [String] = []
	switch phase {
	case .running:
		parts.append("running")
		if discoverAgentVM.toolCallCount > 0 {
			parts.append("\(discoverAgentVM.toolCallCount) tools")
		}
	case .generatingPlan:
		parts.append("generating \(contextBuilderFollowUpLabel(discoverAgentVM: discoverAgentVM))")
	case .completed:
		if let fallbackStatus = nonEmptyContextBuilderValue(fallbackStatus) {
			let normalized = fallbackStatus.lowercased()
			switch normalized {
			case "running", "in_progress", "pending":
				parts.append("completed")
			default:
				parts.append(normalized)
			}
		} else {
			parts.append("completed")
		}
	}
	return parts.joined(separator: " • ")
}

@MainActor
private func contextBuilderFollowUpLabel(discoverAgentVM: DiscoverAgentViewModel) -> String {
	guard let responseType = nonEmptyContextBuilderValue(discoverAgentVM.mcpResponseType)?.lowercased() else {
		return "plan"
	}
	switch responseType {
	case "question":
		return "answer"
	case "review":
		return "review"
	case "plan":
		return "plan"
	default:
		return responseType
	}
}

private func contextBuilderFinalStatusLabel(_ raw: String?) -> String {
	guard let status = nonEmptyContextBuilderValue(raw)?.lowercased() else {
		return "completed"
	}
	switch status {
	case "running", "in_progress", "pending":
		return "completed"
	default:
		return status
	}
}

private func nonEmptyContextBuilderValue(_ value: String?) -> String? {
	guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
		return nil
	}
	return value
}
