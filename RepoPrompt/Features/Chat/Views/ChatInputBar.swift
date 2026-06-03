import SwiftUI
import Combine

struct ChatComposerProps: Equatable {
	let sessionID: UUID?
	let isBusy: Bool
	let hasMessages: Bool
	let mcpModelInfo: String?
	let mcpOverrideModelName: String?
	let mcpOverrideChatPresetName: String?
	let upcomingTokensText: String
	let sessionTokensText: String
	let shouldFocusInput: Bool
}

struct ChatComposerActions {
	let send: () -> Void
	let cancel: () -> Void
	let resend: () -> Void
	let clear: () -> Void
	let storeDraft: (UUID?, String) -> Void
	let retrieveDraft: (UUID?) -> String
	let setInputText: (String) -> Void
	let consumeFocusRequest: () -> Void
}

struct ChatInputBar: View {
	@ObservedObject var viewModel: ChatViewModel
	@ObservedObject var promptViewModel: PromptViewModel
	let windowID: Int
	@Binding var autoScrollEnabled: Bool
	@Binding var resetTextFieldTrigger: Bool
	@Binding var bottomOcclusion: CGFloat
	@Binding var showSettingsPopover: Bool
	
	@FocusState var isFocused: Bool
	
	let onSend: () -> Void
	
	var body: some View {
		let props = ChatComposerProps(
			sessionID: viewModel.currentSessionID,
			isBusy: viewModel.isSessionStreaming(viewModel.currentSessionID),
			hasMessages: !viewModel.messages.isEmpty,
			mcpModelInfo: viewModel.mcpModelInfo,
			mcpOverrideModelName: viewModel.mcpOverrideModelName,
			mcpOverrideChatPresetName: viewModel.mcpOverrideChatPresetName,
			upcomingTokensText: viewModel.upcomingInputTokenText,
			sessionTokensText: viewModel.tokenDisplayText,
			shouldFocusInput: viewModel.focusInputField
		)
		
		let actions = ChatComposerActions(
			send: onSend,
			cancel: viewModel.cancelReponseForUI,
			resend: { viewModel.resendLastMessage() },
			clear: { Task { await viewModel.clearChat() } },
			storeDraft: { viewModel.storeDraftText(for: $0, $1) },
			retrieveDraft: { viewModel.retrieveDraftText(for: $0) },
			setInputText: { viewModel.inputText = $0 },
			consumeFocusRequest: { viewModel.focusInputField = false }
		)
		
		return ChatComposerView(
			props: props,
			promptViewModel: promptViewModel,
			windowID: windowID,
			autoScrollEnabled: $autoScrollEnabled,
			resetTextFieldTrigger: $resetTextFieldTrigger,
			bottomOcclusion: $bottomOcclusion,
			showSettingsPopover: $showSettingsPopover,
			programmaticSetTextPublisher: viewModel.programmaticSetText.eraseToAnyPublisher(),
			actions: actions,
			isFocused: _isFocused
		)
		.equatable()
		.id(props.sessionID)
	}
}

struct ChatComposerView: View, Equatable {
	let props: ChatComposerProps
	@ObservedObject var promptViewModel: PromptViewModel
	let windowID: Int
	@Binding var autoScrollEnabled: Bool
	@Binding var resetTextFieldTrigger: Bool
	@Binding var bottomOcclusion: CGFloat
	@Binding var showSettingsPopover: Bool
	let programmaticSetTextPublisher: AnyPublisher<String, Never>
	let actions: ChatComposerActions
	
	@FocusState var isFocused: Bool
	
	@State private var localInputText: String = ""
	@State private var isInputEmpty: Bool = true
	@State private var cancellables = Set<AnyCancellable>()
	@State private var textUpdateSubject = PassthroughSubject<String, Never>()
	@State private var textFieldHeight: CGFloat = ResizableTextField.height(forPresetIndex: 0, preset: .normal)
	@State private var showSelectedFilesPopover = false
	
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	static func == (lhs: Self, rhs: Self) -> Bool {
		lhs.props == rhs.props
	}
	
	private var isManualMode: Bool {
		promptViewModel.currentChatPreset().id == ChatPreset.BuiltIn.manual.id
	}

	var body: some View {
		VStack(spacing: 0) {
			ZStack(alignment: .bottomLeading) {
				composerBubble

				// Floating mode indicator for Manual mode
				if isManualMode && props.mcpModelInfo == nil {
					ManualModeIndicator(
						promptViewModel: promptViewModel,
						windowID: windowID
					)
					.padding(.leading, 20)
					.offset(y: bubbleOffset - bubbleHeight - 12)
					.zIndex(2)
				}
			}
			.frame(height: minBarHeight)
			
			TokenFooterLine(
				upcomingText: props.upcomingTokensText,
				sessionText: props.sessionTokensText,
				warningColor: tokenWarningColor(promptViewModel)
			)
			.padding(.top, 16)
			.padding(.horizontal, 16)
			.padding(.bottom, 4)
		}
		.onChange(of: localInputText) { newValue in
			isInputEmpty = newValue.isEmpty
			textUpdateSubject.send(newValue)
		}
		.onChange(of: textFieldHeight) { _, _ in
			updateBottomOcclusion()
		}
		.onChange(of: fontPreset.scaleFactor) { _, _ in
			updateBottomOcclusion()
		}
		.onAppear {
			localInputText = actions.retrieveDraft(props.sessionID)
			isInputEmpty = localInputText.isEmpty
			updateBottomOcclusion()
			
			programmaticSetTextPublisher
				.receive(on: RunLoop.main)
				.sink { newText in
					localInputText = newText
					isInputEmpty = newText.isEmpty
				}
				.store(in: &cancellables)
			
			textUpdateSubject
				.debounce(for: .milliseconds(100), scheduler: RunLoop.main)
				.sink { newText in
					actions.setInputText(newText)
				}
				.store(in: &cancellables)
		}
		.onDisappear {
			actions.setInputText(localInputText)
			actions.storeDraft(props.sessionID, localInputText)
			cancellables.removeAll()
		}
		.onChange(of: props.shouldFocusInput) { _, newValue in
			if newValue {
				DispatchQueue.main.async {
					isFocused = true
					actions.consumeFocusRequest()
				}
			}
		}
	}

	private var composerBubble: some View {
		ZStack {
			RoundedRectangle(cornerRadius: bubbleCornerRadius)
				.fill(Color(NSColor.windowBackgroundColor))
				.shadow(color: Color.black.opacity(0.12), radius: 5, x: 0, y: 3)
			
			VStack(spacing: bubbleInnerSpacing) {
				if let mcpInfo = props.mcpModelInfo {
					mcpControlRow(mcpInfo)
				} else {
					ResizableTextField(
						text: $localInputText,
						placeholder: "Reply...",
						onReturn: {
							checkTokensAndSend()
						},
						resetTrigger: $resetTextFieldTrigger,
						features: .chatInputBar,
						onHeightChange: { newHeight in
							if newHeight < textFieldHeight {
								withAnimation(.easeInOut) {
									textFieldHeight = newHeight
								}
							} else {
								textFieldHeight = newHeight
							}
						}
					)
					.frame(height: textFieldHeight)
					.focused($isFocused)
					.overlay(
						Text("Reply...")
							.font(fontPreset.standardFont)
							.foregroundColor(.secondary)
							.opacity(isInputEmpty ? 1 : 0)
							.padding(.leading, 5)
							.padding(.top, 8)
							.allowsHitTesting(false),
						alignment: .topLeading
					)
				}
				
				Divider()
					.frame(height: dividerHeight)
				
				controlStrip
			}
			.padding(.horizontal, bubbleHorizontalPadding)
			.padding(.vertical, bubbleVerticalPadding)
		}
		.frame(height: bubbleHeight)
		.padding(.horizontal, 16)
		.padding(.bottom, bubbleBottomPadding)
		.offset(y: bubbleOffset)
		.zIndex(1)
	}
	
	private func mcpControlRow(_ info: String) -> some View {
		HStack(spacing: 10) {
			Image(systemName: "server.rack")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 14, weight: .medium))
				.foregroundColor(.orange)
			
			Text("MCP Controlled")
				.font(fontPreset.standardFont)
				.foregroundColor(.secondary)
			
			Text("•")
				.foregroundColor(.secondary)
			
			Text(info)
				.font(fontPreset.standardFont)
				.foregroundColor(.primary)
			
			Spacer(minLength: 0)
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.padding(.top, -4)
		.padding(.bottom, 4)
	}
	
	private var controlStrip: some View {
		HStack(spacing: 0) {
			ScrollView(.horizontal, showsIndicators: false) {
				HStack(spacing: 8) {
					contextTags
				}
				.padding(.vertical, 2)
			}
			
			Divider()
				.frame(height: 20)
				.padding(.trailing, 8)
			
			HStack(spacing: 8) {
				ChatPresetPickerButton(
					promptViewModel: promptViewModel,
					mcpModelInfo: props.mcpModelInfo,
					mcpOverrideChatPresetName: props.mcpOverrideChatPresetName
				)
				
				ModelAreaView(
					state: modelControlState(),
					promptViewModel: promptViewModel,
					showSettingsPopover: $showSettingsPopover,
					windowID: windowID
				)
				
				if props.isBusy {
					CancelButton(source: .chatInput, action: actions.cancel)
				} else {
					SendOrResendButton(
						inputText: localInputText,
						hasMessages: props.hasMessages,
						sendAction: {
							checkTokensAndSend()
						},
						resendAction: {
							actions.resend()
							autoScrollEnabled = true
							resetTextFieldTrigger = true
						}
					)
				}
			}
		}
		.frame(height: controlStripHeight)
	}
	
	private var contextTags: some View {
		Group {
			selectedFilesButton
			
			GitPrefTag(
				gitViewModel: promptViewModel.gitViewModel,
				promptManager: promptViewModel,
				context: .chat,
				gitDiffTokenCount: promptViewModel.gitDiffTokenCount
			)
			
			FileTreePrefTag(
				promptManager: promptViewModel,
				context: .chat
			)
			
			ScanFilesPrefTag(
				fileManager: promptViewModel.fileManager,
				promptManager: promptViewModel,
				context: .chat,
				isChatContext: true
			)
		}
	}
	
	private var selectedFilesButton: some View {
		let hasSelectedFiles = promptViewModel.hasPromptSnapshotEntriesForChat()
		let selectionCount = promptViewModel.fileManager.selectedFiles.count
		
		return Button {
			showSelectedFilesPopover.toggle()
		} label: {
			HStack(spacing: 4) {
				Text("Files")
					.lineLimit(1)
					.foregroundColor(.primary)
				Text("(\(selectionCount))")
					.foregroundColor(.secondary)
					.font(fontPreset.captionFont)
			}
		}
		.buttonStyle(SelectorButtonStyle(hasSelection: hasSelectedFiles))
		.hoverTooltip("Show selected files", .top)
		.popover(isPresented: $showSelectedFilesPopover) {
			let promptEntries = promptViewModel.promptSnapshotEntriesForChatCached()
			SelectedFilesGrid(
				entries: promptEntries,
				fileManager: promptViewModel.fileManager,
				onRemove: { entry in
					if entry.isCodemap {
						if promptViewModel.fileManager.isAutoCodemapFile(entry.file) {
							promptViewModel.fileManager.removeCodemapFile(entry.file)
						} else {
							promptViewModel.fileManager.toggleFile(entry.file)
						}
					} else {
						promptViewModel.fileManager.toggleFile(entry.file)
					}
				}
			)
			.frame(width: fontPreset.scaledClamped(420, max: 560))
			.frame(
				minHeight: fontPreset.scaledMetric(200),
				idealHeight: min(
					fontPreset.scaledClamped(500, max: 660),
					fontPreset.scaledMetric(CGFloat(max(selectionCount, 1)) * 40 + 100)
				),
				maxHeight: fontPreset.scaledClamped(600, max: 760)
			)
		}
	}
	
	private var currentPreset: ChatPreset {
		promptViewModel.currentChatPreset()
	}
	
	private func modelControlState() -> ModelControlState {
		if props.mcpModelInfo != nil {
			let fallback = promptViewModel.preferredAIModel.displayName
			let display = props.mcpOverrideModelName ?? fallback
			return .mcp(displayName: String.truncateModelName(display))
		}
		
		if let modelName = ChatPresetManager.shared
			.resolvedPreset(with: currentPreset.id)?
			.modelPresetName,
			let model = AIModel.fromModelName(modelName) {
			return .presetOverride(
				displayName: String.truncateModelName(model.displayName),
				presetName: currentPreset.name
			)
		}
		
		return .dropdown
	}
	
	private func checkTokensAndSend() {
		if promptViewModel.availableModels.isEmpty {
			NotificationCenter.default.post(
				name: .showAPISettingsTab,
				object: nil,
				userInfo: ["windowID": windowID])
		} else {
			actions.storeDraft(props.sessionID, localInputText)
			actions.setInputText(localInputText)
			autoScrollEnabled = true
			actions.send()
			localInputText = ""
		}
	}
	
	private func updateBottomOcclusion() {
		// Preserve the original overlap-based push so overlays stay above the bubble.
		let topFromBottom = (bubbleHeight + bubbleBottomPadding) - bubbleOffset
		let currentOcclusion = topFromBottom - minBarHeight
		bottomOcclusion = max(0, currentOcclusion).rounded(.up)
	}
	
	/// The offset that nudges the bubble upward as it grows
	private var bubbleOffset: CGFloat {
		let heightDifference = defaultBubbleHeight - bubbleHeight
		let netHeight = heightDifference < 0 ? (heightDifference * 0.5) : 0
		return min(0, netHeight)
	}
	
	private func tokenWarningColor(_ promptModel: PromptViewModel) -> Color {
		if promptModel.totalTokenCountWithDiff > 20000 {
			return .orange
		}
		return .secondary
	}
	
	private var bubbleCornerRadius: CGFloat { 18 }
	private var bubbleHorizontalPadding: CGFloat { 12 }
	private var bubbleVerticalPadding: CGFloat { 8 * fontPreset.scaleFactor }
	private var bubbleInnerSpacing: CGFloat { 2 * fontPreset.scaleFactor }
	private var controlStripHeight: CGFloat { max(40, 40 * fontPreset.scaleFactor) }
	private var dividerHeight: CGFloat { 1 }
	private var bubbleBottomPadding: CGFloat { 8 * fontPreset.scaleFactor }
	private var minBarHeight: CGFloat { fontPreset.scaledMetric(60) }
	
	private var bubbleChromeHeight: CGFloat {
		(controlStripHeight
			+ (bubbleVerticalPadding * 2)
			+ (bubbleInnerSpacing * 2)
			+ dividerHeight)
	}
	
	private var bubbleHeight: CGFloat {
		textFieldHeight + bubbleChromeHeight
	}
	
	private var defaultBubbleHeight: CGFloat {
		ResizableTextField.height(forPresetIndex: 0, preset: fontPreset) + bubbleChromeHeight
	}
}

// MARK: - Manual Mode Indicator
private struct ManualModeIndicator: View {
	@ObservedObject var promptViewModel: PromptViewModel
	let windowID: Int

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	@State private var isHovered = false

	private var modeColor: Color {
		if promptViewModel.proFileEdits && promptViewModel.planActMode == .edit {
			return .orange
		}
		switch promptViewModel.planActMode {
		case .chat: return .blue
		case .plan: return .purple
		case .edit: return .green
		case .review: return .teal
		}
	}

	private var modeLabel: String {
		if promptViewModel.proFileEdits && promptViewModel.planActMode == .edit {
			return "Pro"
		}
		switch promptViewModel.planActMode {
		case .chat: return "Chat"
		case .plan: return "Plan"
		case .edit: return "Edit"
		case .review: return "Review"
		}
	}

	var body: some View {
		Button {
			NotificationCenter.default.post(
				name: .showPromptsPopover,
				object: nil,
				userInfo: ["windowID": windowID]
			)
		} label: {
			HStack(spacing: 4) {
				Text("Sys:")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)

				// Mode indicator pill (matching PromptsButton style)
				Text(modeLabel)
					.font(fontPreset.captionFont.weight(.medium))
					.foregroundColor(modeColor)
					.padding(.horizontal, 5)
					.padding(.vertical, 1)
					.background(
						Capsule()
							.fill(modeColor.opacity(0.15))
					)
			}
			.padding(.horizontal, 8)
			.padding(.vertical, 4)
			.background(
				Capsule()
					.fill(Color(NSColor.windowBackgroundColor))
					.shadow(color: Color.black.opacity(isHovered ? 0.15 : 0.08), radius: isHovered ? 4 : 2, x: 0, y: 1)
			)
		}
		.buttonStyle(.plain)
		.onHover { isHovered = $0 }
		.hoverTooltip("Click to configure system prompts", .top)
	}
}

private struct TokenFooterLine: View {
	let upcomingText: String
	let sessionText: String
	let warningColor: Color
	
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		HStack(spacing: 4) {
			Text(upcomingText)
				.font(fontPreset.captionFont)
				.foregroundColor(warningColor)
				.lineLimit(1)
				.truncationMode(.head)
			
			if !sessionText.isEmpty {
				Text("|")
					.foregroundColor(.secondary)
				Text(sessionText)
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
					.lineLimit(1)
					.truncationMode(.tail)
			}
		}
		.padding(.horizontal, 12)
		.frame(height: fontPreset.scaledMetric(28))
		.frame(maxWidth: .infinity, alignment: .center)
	}
}
