import SwiftUI

struct AgentModeDetailWithSidebarView: View {
	let agentModeVM: AgentModeViewModel
	let runtimeVM: AgentRuntimeSidebarViewModel
	@ObservedObject var statusPillsUI: AgentStatusPillsUIStore
	let discoverAgentVM: DiscoverAgentViewModel
	let chatViewModel: ChatViewModel
	let promptManager: PromptViewModel
	#if DEBUG
	let stressHarness: AgentChatStressHarness?
	#endif
	let windowID: Int
	let currentTabID: UUID?
	let codexManagedLoginAction: CodexManagedLoginAction

	@State private var isContextBuilderQuestionPresented = false

	#if DEBUG
	init(
		agentModeVM: AgentModeViewModel,
		runtimeVM: AgentRuntimeSidebarViewModel,
		statusPillsUI: AgentStatusPillsUIStore,
		discoverAgentVM: DiscoverAgentViewModel,
		chatViewModel: ChatViewModel,
		promptManager: PromptViewModel,
		stressHarness: AgentChatStressHarness?,
		windowID: Int,
		currentTabID: UUID?,
		codexManagedLoginAction: @escaping CodexManagedLoginAction
	) {
		self.agentModeVM = agentModeVM
		self.runtimeVM = runtimeVM
		self._statusPillsUI = ObservedObject(wrappedValue: statusPillsUI)
		self.discoverAgentVM = discoverAgentVM
		self.chatViewModel = chatViewModel
		self.promptManager = promptManager
		self.stressHarness = stressHarness
		self.windowID = windowID
		self.currentTabID = currentTabID
		self.codexManagedLoginAction = codexManagedLoginAction
	}

	init(
		agentModeVM: AgentModeViewModel,
		runtimeMetricsUI: AgentRuntimeMetricsUIStore,
		statusPillsUI: AgentStatusPillsUIStore,
		discoverAgentVM: DiscoverAgentViewModel,
		chatViewModel: ChatViewModel,
		promptManager: PromptViewModel,
		stressHarness: AgentChatStressHarness?,
		windowID: Int,
		currentTabID: UUID?,
		codexManagedLoginAction: @escaping CodexManagedLoginAction
	) {
		self.init(
			agentModeVM: agentModeVM,
			runtimeVM: runtimeMetricsUI.runtimeVM,
			statusPillsUI: statusPillsUI,
			discoverAgentVM: discoverAgentVM,
			chatViewModel: chatViewModel,
			promptManager: promptManager,
			stressHarness: stressHarness,
			windowID: windowID,
			currentTabID: currentTabID,
			codexManagedLoginAction: codexManagedLoginAction
		)
	}
	#else
	init(
		agentModeVM: AgentModeViewModel,
		runtimeVM: AgentRuntimeSidebarViewModel,
		statusPillsUI: AgentStatusPillsUIStore,
		discoverAgentVM: DiscoverAgentViewModel,
		chatViewModel: ChatViewModel,
		promptManager: PromptViewModel,
		windowID: Int,
		currentTabID: UUID?,
		codexManagedLoginAction: @escaping CodexManagedLoginAction
	) {
		self.agentModeVM = agentModeVM
		self.runtimeVM = runtimeVM
		self._statusPillsUI = ObservedObject(wrappedValue: statusPillsUI)
		self.discoverAgentVM = discoverAgentVM
		self.chatViewModel = chatViewModel
		self.promptManager = promptManager
		self.windowID = windowID
		self.currentTabID = currentTabID
		self.codexManagedLoginAction = codexManagedLoginAction
	}

	init(
		agentModeVM: AgentModeViewModel,
		runtimeMetricsUI: AgentRuntimeMetricsUIStore,
		statusPillsUI: AgentStatusPillsUIStore,
		discoverAgentVM: DiscoverAgentViewModel,
		chatViewModel: ChatViewModel,
		promptManager: PromptViewModel,
		windowID: Int,
		currentTabID: UUID?,
		codexManagedLoginAction: @escaping CodexManagedLoginAction
	) {
		self.init(
			agentModeVM: agentModeVM,
			runtimeVM: runtimeMetricsUI.runtimeVM,
			statusPillsUI: statusPillsUI,
			discoverAgentVM: discoverAgentVM,
			chatViewModel: chatViewModel,
			promptManager: promptManager,
			windowID: windowID,
			currentTabID: currentTabID,
			codexManagedLoginAction: codexManagedLoginAction
		)
	}
	#endif

	var body: some View {
		#if DEBUG
		AgentModeChatDetailView(
			agentModeVM: agentModeVM,
			transcriptUI: agentModeVM.ui.transcript,
			runInteractionUI: agentModeVM.ui.runInteraction,
			statusPillsUI: statusPillsUI,
			discoverAgentVM: discoverAgentVM,
			isContextBuilderQuestionPresented: isContextBuilderQuestionPresented,
			chatViewModel: chatViewModel,
			promptManager: promptManager,
			stressHarness: stressHarness,
			runtimeVM: runtimeVM,
			windowID: windowID,
			currentTabID: currentTabID,
			codexManagedLoginAction: codexManagedLoginAction
		)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.overlay(alignment: .topTrailing) {
			if let stressHarness, stressHarness.configuration.showOverlay {
				AgentChatStressHarnessPanel(harness: stressHarness, currentTabID: currentTabID)
					.padding(.top, 14)
					.padding(.trailing, 14)
			}
		}
		.onAppear {
			syncContextBuilderQuestionPresentation()
			agentModeVM.syncComposerUIState(tabID: currentTabID)
			agentModeVM.syncTranscriptUIState()
			agentModeVM.syncRunInteractionUIState()
			agentModeVM.syncStatusPillsUIState()
			agentModeVM.syncRuntimeMetricsUIState(
				liveSelectedFileCount: promptManager.fileManager.selectedFiles.count
			)
			stressHarness?.bootstrapIfNeeded(currentTabID: currentTabID)
		}
		.onReceive(discoverAgentVM.$pendingAskUser) { _ in
			syncContextBuilderQuestionPresentation()
		}
		.onReceive(promptManager.fileManager.$selectedFiles.map(\.count).removeDuplicates()) { count in
			agentModeVM.syncRuntimeMetricsUIState(liveSelectedFileCount: count)
		}
		.onChange(of: currentTabID) { _, tabID in
			syncContextBuilderQuestionPresentation()
			agentModeVM.syncComposerUIState(tabID: tabID)
			agentModeVM.syncTranscriptUIState()
			agentModeVM.syncRunInteractionUIState()
			agentModeVM.syncStatusPillsUIState()
			agentModeVM.syncRuntimeMetricsUIState(
				liveSelectedFileCount: promptManager.fileManager.selectedFiles.count
			)
			stressHarness?.bootstrapIfNeeded(currentTabID: tabID)
		}
		.onDisappear { stressHarness?.pause() }
		#else
		AgentModeChatDetailView(
			agentModeVM: agentModeVM,
			transcriptUI: agentModeVM.ui.transcript,
			runInteractionUI: agentModeVM.ui.runInteraction,
			statusPillsUI: statusPillsUI,
			discoverAgentVM: discoverAgentVM,
			isContextBuilderQuestionPresented: isContextBuilderQuestionPresented,
			chatViewModel: chatViewModel,
			promptManager: promptManager,
			runtimeVM: runtimeVM,
			windowID: windowID,
			currentTabID: currentTabID,
			codexManagedLoginAction: codexManagedLoginAction
		)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.onAppear {
			syncContextBuilderQuestionPresentation()
			agentModeVM.syncComposerUIState(tabID: currentTabID)
			agentModeVM.syncTranscriptUIState()
			agentModeVM.syncRunInteractionUIState()
			agentModeVM.syncStatusPillsUIState()
			agentModeVM.syncRuntimeMetricsUIState(
				liveSelectedFileCount: promptManager.fileManager.selectedFiles.count
			)
		}
		.onReceive(discoverAgentVM.$pendingAskUser) { _ in
			syncContextBuilderQuestionPresentation()
		}
		.onReceive(promptManager.fileManager.$selectedFiles.map(\.count).removeDuplicates()) { count in
			agentModeVM.syncRuntimeMetricsUIState(liveSelectedFileCount: count)
		}
		.onChange(of: currentTabID) { _, tabID in
			syncContextBuilderQuestionPresentation()
			agentModeVM.syncComposerUIState(tabID: tabID)
			agentModeVM.syncTranscriptUIState()
			agentModeVM.syncRunInteractionUIState()
			agentModeVM.syncStatusPillsUIState()
			agentModeVM.syncRuntimeMetricsUIState(
				liveSelectedFileCount: promptManager.fileManager.selectedFiles.count
			)
		}
		#endif
	}

	private func syncContextBuilderQuestionPresentation() {
		isContextBuilderQuestionPresented = discoverAgentVM.pendingAskUser(for: currentTabID) != nil
	}
}
