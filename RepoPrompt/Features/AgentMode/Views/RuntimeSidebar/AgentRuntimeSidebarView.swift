import SwiftUI

struct AgentRuntimeSidebarView: View {
	@ObservedObject var discoverAgentVM: DiscoverAgentViewModel
	@ObservedObject var chatViewModel: ChatViewModel
	@ObservedObject var promptManager: PromptViewModel
	@ObservedObject var runtimeVM: AgentRuntimeSidebarViewModel
	let currentTabID: UUID?
	let activeAgentSessionID: UUID?
	let activeRunID: UUID?
	let onCollapse: () -> Void

	@State private var oracleAutoScrollEnabled: Bool = false
	@State private var selectedOracleSessionID: UUID?

	private var isContextBuilderRunning: Bool {
		guard let tabID = currentTabID else { return false }
		return discoverAgentVM.tabsWithActiveDiscoverRun.contains(tabID)
	}

	private var isOracleStreaming: Bool {
		let tabSessionIDs = Set(tabChatSessions.map(\.id))
		guard !tabSessionIDs.isEmpty else { return false }
		return !chatViewModel.streamingSessions.isDisjoint(with: tabSessionIDs)
	}

	private var hasContextBuilderLog: Bool {
		!discoverAgentVM.agentLog.isEmpty
	}

	private var tabChatSessions: [ChatSession] {
		guard let tabID = currentTabID else { return [] }
		return AgentOraclePillLogic.eligibleSessions(
			sessions: chatViewModel.sessions(forTabID: tabID),
			streamingSessionIDs: chatViewModel.streamingSessions,
			liveMessageCount: { chatViewModel.liveMessageCount(for: $0) },
			activeAgentSessionID: activeAgentSessionID,
			activeRunID: activeRunID
		)
	}

	private var selectedOracleSession: ChatSession? {
		guard let selectedID = AgentOraclePillLogic.selectedSessionID(
			currentSelectionID: selectedOracleSessionID,
			in: tabChatSessions,
			streamingSessionIDs: chatViewModel.streamingSessions
		) else { return nil }
		return tabChatSessions.first { $0.id == selectedID }
	}

	var body: some View {
		VStack(spacing: 0) {
			sidebarHeader

			ScrollView {
				VStack(alignment: .leading, spacing: 10) {
					// Context builder - shown when running or has recent log
					if isContextBuilderRunning || hasContextBuilderLog {
						contextBuilderSection
					}

					// Oracle chat - shown when there are any sessions for this tab
					if !tabChatSessions.isEmpty {
						oracleChatSection
					}

					// File context summary
					fileContextSection

					// Context usage
					contextUsageSection

					// Export context
					exportContextSection
				}
				.padding(10)
			}
		}
		.frame(minWidth: 300, idealWidth: 320, maxWidth: 360, maxHeight: .infinity)
		.onChange(of: currentTabID) { _, _ in
			selectedOracleSessionID = nil
			selectLatestOracleSessionIfNeeded()
		}
	}

	// MARK: - Header (matches pill visual style, collapse on left)

	private var sidebarHeader: some View {
		HStack(spacing: 6) {
			AgentRuntimeSidebarCollapseButton(onCollapse: onCollapse)

			AgentRuntimeSidebarHeaderStatusView(state: headerState)

			Spacer(minLength: 4)
		}
		.padding(.horizontal, 10)
		.padding(.vertical, 7)
		.background(.ultraThinMaterial)
		.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 16, style: .continuous)
				.stroke(headerState.borderColor, lineWidth: 0.5)
		)
		.padding(.horizontal, 10)
		.padding(.top, 10)
		.padding(.bottom, 4)
	}

	private var headerState: RuntimeSidebarHeaderState {
		if isContextBuilderRunning { return .init(mode: .contextBuilder) }
		if isOracleStreaming { return .init(mode: .oracle) }
		return .init(
			mode: .idle(
				fileCount: runtimeVM.snapshot.selectionFileCount ?? 0,
				selectionTokens: runtimeVM.snapshot.selectionTokens
			)
		)
	}

	// MARK: - Context Builder

	private var contextBuilderSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				if isContextBuilderRunning {
					ProgressView()
						.controlSize(.mini)
						.scaleEffect(0.7)
				} else {
					Image(systemName: "checkmark.circle.fill")
						.font(.system(size: 11))
						.foregroundStyle(.green)
				}
				Text("Context Builder")
					.font(.system(size: 11, weight: .semibold))

				Spacer()

				if discoverAgentVM.toolCallCount > 0 {
					Text("\(discoverAgentVM.toolCallCount) tools")
						.font(.system(size: 10))
						.foregroundStyle(.secondary)
				}
			}

			VStack(alignment: .leading, spacing: 3) {
				ForEach(Array(discoverAgentVM.agentLog.suffix(6))) { entry in
					AgentLogEntryRowView(entry: entry, style: .compact)
				}
			}
		}
		.sidebarCard(highlight: isContextBuilderRunning ? .blue : nil)
	}

	// MARK: - Oracle Chat

	private var oracleChatSection: some View {
		VStack(alignment: .leading, spacing: 6) {
			HStack(spacing: 6) {
				if isOracleStreaming {
					ProgressView()
						.controlSize(.mini)
						.scaleEffect(0.7)
				}
				Text("Oracle")
					.font(.system(size: 11, weight: .semibold))

				Text("·")
					.font(.system(size: 9))
					.foregroundStyle(.quaternary)

				Text("\(tabChatSessions.count) session\(tabChatSessions.count == 1 ? "" : "s")")
					.font(.system(size: 10))
					.foregroundStyle(.secondary)

				Spacer()
			}

			// Always show the chat transcript when there are sessions
			ChatMessagesView(
				viewModel: chatViewModel,
				autoScrollEnabled: $oracleAutoScrollEnabled,
				bottomOcclusion: 0,
				showsScrollControls: false,
				autoScrollOnAppear: isOracleStreaming,
				sessionIDOverride: selectedOracleSession?.id
			)
			.frame(minHeight: 160, idealHeight: 260, maxHeight: 340)
			.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

			// Session list for switching
			if tabChatSessions.count > 1 {
				VStack(spacing: 2) {
					ForEach(tabChatSessions.suffix(5)) { session in
						oracleSessionRow(session)
					}
				}
			}
		}
		.sidebarCard(highlight: isOracleStreaming ? .purple : nil)
		.onAppear { selectLatestOracleSessionIfNeeded() }
	}

	/// Select the latest oracle session for rendering only when the local
	/// sidebar selection is missing or no longer belongs to this tab.
	private func selectLatestOracleSessionIfNeeded() {
		let resolvedID = AgentOraclePillLogic.selectedSessionID(
			currentSelectionID: selectedOracleSessionID,
			in: tabChatSessions,
			streamingSessionIDs: chatViewModel.streamingSessions
		)
		if resolvedID == selectedOracleSessionID { return }
		guard let resolvedID else { return }
		selectedOracleSessionID = resolvedID
	}

	private func oracleSessionRow(_ session: ChatSession) -> some View {
		Button {
			selectedOracleSessionID = session.id
		} label: {
			HStack(spacing: 6) {
				Image(systemName: "bubble.left.and.text.bubble.right")
					.font(.system(size: 10))
					.foregroundStyle(.secondary)
				Text(session.name)
					.font(.system(size: 11))
					.lineLimit(1)
					.truncationMode(.tail)
				Spacer()
				if chatViewModel.streamingSessions.contains(session.id) {
					ProgressView()
						.controlSize(.mini)
						.scaleEffect(0.6)
				} else {
					Text(session.messageCountLabel)
						.font(.system(size: 10))
						.foregroundStyle(.tertiary)
				}
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.background(
				RoundedRectangle(cornerRadius: 8, style: .continuous)
					.fill(selectedOracleSession?.id == session.id
						? Color.accentColor.opacity(0.1)
						: Color.clear)
			)
			.contentShape(Rectangle())
		}
		.buttonStyle(.plain)
	}

	// MARK: - File Context

	private var fileContextSection: some View {
		HStack(spacing: 10) {
			VStack(alignment: .leading, spacing: 2) {
				Text("Selected files")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
				Text("\(runtimeVM.snapshot.selectionFileCount ?? 0)")
					.font(.system(size: 14, weight: .semibold, design: .rounded))
			}

			Spacer()

			VStack(alignment: .trailing, spacing: 2) {
				Text("Selection tokens")
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
				if let tokens = runtimeVM.snapshot.selectionTokens {
					Text("~\(AgentContextIndicator.formatTokens(tokens))")
						.font(.system(size: 14, weight: .semibold, design: .rounded))
				} else {
					Text("—")
						.font(.system(size: 14, weight: .semibold, design: .rounded))
						.foregroundStyle(.tertiary)
				}
			}
		}
		.sidebarCard()
	}

	// MARK: - Context Usage

	/// Estimates used tokens from the agent transcript character count when codex usage isn't available.
	private var estimatedUsedTokens: Int? {
		runtimeVM.snapshot.usedTokens ?? runtimeVM.snapshot.estimatedTranscriptTokens
	}

	private var contextWindowTokens: Int {
		runtimeVM.snapshot.effectiveContextWindowTokens
	}

	private var contextUsageSection: some View {
		Group {
			if let usedTokens = estimatedUsedTokens {
				AgentContextIndicator(
					contextWindowTokens: contextWindowTokens,
					usedTokens: usedTokens,
					sourceLabel: runtimeVM.snapshot.usedTokens != nil
						? runtimeVM.snapshot.usageSource.label
						: "Estimated",
					style: .labeled
				)
				.sidebarCard()
			}
		}
	}

	// MARK: - Export Context

	private var exportContextSection: some View {
		AgentExportCard(
			promptManager: promptManager,
			tokenCounter: promptManager.tokenCountingViewModel,
			fileCount: runtimeVM.snapshot.selectionFileCount,
			selectionTokens: runtimeVM.snapshot.selectionTokens
		)
		.sidebarCard()
	}
}

private struct RuntimeSidebarHeaderState: Equatable {
	enum Mode: Equatable {
		case contextBuilder
		case oracle
		case idle(fileCount: Int, selectionTokens: Int?)
	}

	let mode: Mode

	var borderColor: Color {
		switch mode {
		case .contextBuilder:
			return Color.blue.opacity(0.3)
		case .oracle:
			return Color.purple.opacity(0.3)
		case .idle:
			return Color.secondary.opacity(0.15)
		}
	}
}

private struct AgentRuntimeSidebarCollapseButton: View {
	let onCollapse: () -> Void
	@State private var isHovered = false

	var body: some View {
		Button(action: onCollapse) {
			Image(systemName: "chevron.right")
				.font(.system(size: 9, weight: .bold))
				.foregroundStyle(isHovered ? .primary : .secondary)
				.frame(width: 24, height: 24)
				.background(
					Circle()
						.fill(isHovered ? Color.secondary.opacity(0.12) : Color.clear)
				)
				.contentShape(Circle())
		}
		.buttonStyle(.plain)
		.onHover { isHovered = $0 }
		.accessibilityLabel("Collapse runtime sidebar")
	}
}

private struct AgentRuntimeSidebarHeaderStatusView: View {
	let state: RuntimeSidebarHeaderState

	var body: some View {
		HStack(spacing: 6) {
			switch state.mode {
			case .contextBuilder:
				ProgressView()
					.controlSize(.mini)
					.scaleEffect(0.7)
				Text("Context Builder")
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(.primary)
					.lineLimit(1)
			case .oracle:
				ProgressView()
					.controlSize(.mini)
					.scaleEffect(0.7)
				Text("Oracle")
					.font(.system(size: 11, weight: .medium))
					.foregroundStyle(.primary)
			case let .idle(fileCount, selectionTokens):
				Image(systemName: "doc.on.doc")
					.font(.system(size: 10))
					.foregroundStyle(.secondary)
				if let selectionTokens {
					Text("\(fileCount) files · \(AgentContextIndicator.formatTokens(selectionTokens))")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(.secondary)
				} else if fileCount > 0 {
					Text("\(fileCount) files")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(.secondary)
				} else {
					Text("Runtime")
						.font(.system(size: 11, weight: .medium))
						.foregroundStyle(.secondary)
				}
			}
		}
	}
}

struct AgentExportCard: View {
	@ObservedObject var promptManager: PromptViewModel
	@ObservedObject var tokenCounter: TokenCountingViewModel
	let fileCount: Int?
	let selectionTokens: Int?

	@State private var showSelectedFilesPopover = false

	private var displayFileCount: Int {
		fileCount ?? 0
	}

	private var displayTokens: Int? {
		if let selectionTokens, selectionTokens > 0 {
			return selectionTokens
		}
		let fallbackTokens = tokenCounter.copyContextTotalTokens
		return fallbackTokens > 0 ? fallbackTokens : nil
	}

	private var tokenColor: Color {
		guard let tokens = displayTokens else { return .secondary }
		if tokens > 100_000 { return .red }
		if tokens >= 60_000 { return .orange }
		return .green
	}


	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Row 1: "Export Context" + token count + files + Copy
			HStack(spacing: 6) {
				Text("Export Context")
					.font(.system(size: 10, weight: .semibold))
					.foregroundStyle(.tertiary)

				if let tokens = displayTokens {
					Text("~\(AgentContextIndicator.formatTokens(tokens))")
						.font(.system(size: 11, weight: .bold, design: .rounded))
						.foregroundStyle(tokenColor)
				}

				Spacer()

				filesButton

				Button {
					let cfg = promptManager.resolvePromptContext(BuiltInCopyPresets.standard, custom: nil)
					Task {
						let clipboard = await promptManager.buildClipboard(for: cfg)
						NSPasteboard.general.clearContents()
						NSPasteboard.general.setString(clipboard, forType: .string)
					}
				} label: {
					HStack(spacing: 5) {
						Image(systemName: "doc.on.clipboard")
							.font(.system(size: 10))
						Text("Copy")
							.font(.system(size: 11, weight: .medium))
					}
				}
				.buttonStyle(CustomButtonStyle(
					verticalPadding: 5,
					horizontalPadding: 10,
					height: 26
				))
			}

			// Row 2: Instructions editor (always visible)
			instructionsEditor
		}
	}

	// MARK: - Files Button (opens SelectedFilesGrid popover)

	private var filesButton: some View {
		let selectionCount = promptManager.fileManager.selectedFiles.count

		return Button {
			showSelectedFilesPopover.toggle()
		} label: {
			HStack(spacing: 4) {
				Image(systemName: "doc.on.doc")
					.font(.system(size: 10, weight: .medium))
					.foregroundStyle(.secondary)
				Text("\(selectionCount) file\(selectionCount == 1 ? "" : "s")")
					.font(.system(size: 10, weight: .medium))
					.lineLimit(1)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 5)
			.background(Color(NSColor.controlBackgroundColor).opacity(0.4))
			.clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
			.overlay(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
			)
		}
		.buttonStyle(.plain)
		.popover(isPresented: $showSelectedFilesPopover) {
			let promptEntries = promptManager.promptSnapshotEntriesForChatCached()
			SelectedFilesGrid(
				entries: promptEntries,
				fileManager: promptManager.fileManager,
				onRemove: { entry in
					if entry.isCodemap {
						if promptManager.fileManager.isAutoCodemapFile(entry.file) {
							promptManager.fileManager.removeCodemapFile(entry.file)
						} else {
							promptManager.fileManager.toggleFile(entry.file)
						}
					} else {
						promptManager.fileManager.toggleFile(entry.file)
					}
				}
			)
			.frame(width: 380)
			.frame(
				minHeight: 200,
				idealHeight: min(500, Double(max(selectionCount, 1)) * 40 + 100),
				maxHeight: 500
			)
		}
	}

	// MARK: - Instructions Editor

	private static let placeholderText = """
		Tell the receiving model what to do with this context — e.g. "Plan a fix for the login crash" or "Help me debug the auth flow".

		Tip: Ask the agent to write this prompt for you.
		"""

	private var instructionsEditor: some View {
		ZStack(alignment: .topLeading) {
			TextEditor(text: $promptManager.promptText)
				.font(.system(size: 11))
				.scrollContentBackground(.hidden)
				.frame(minHeight: 150, maxHeight: 150)

			if promptManager.promptText.isEmpty {
				Text(Self.placeholderText)
					.font(.system(size: 10))
					.foregroundStyle(.tertiary)
					.padding(.top, 6)
					.padding(.leading, 5)
					.allowsHitTesting(false)
			}
		}
		.padding(6)
		.background(Color(NSColor.textBackgroundColor).opacity(0.5))
		.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
		.overlay(
			RoundedRectangle(cornerRadius: 6, style: .continuous)
				.stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
		)
	}
}

// MARK: - Card Modifier

private extension View {
	func sidebarCard(highlight: Color? = nil) -> some View {
		self
			.padding(10)
			.frame(maxWidth: .infinity, alignment: .leading)
			.background(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.fill(Color(NSColor.controlBackgroundColor).opacity(0.35))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 10, style: .continuous)
					.stroke(highlight?.opacity(0.25) ?? Color.clear, lineWidth: 1)
			)
	}
}

private extension ChatSession {
	var messageCountLabel: String {
		let count = effectiveMessageCount
		return "\(count) msg\(count == 1 ? "" : "s")"
	}
}
