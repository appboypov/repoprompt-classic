import SwiftUI

class ChatDebouncer {
	private let delay: TimeInterval
	private var workItem: DispatchWorkItem?
	private let workGate = WorkItemGate()
	
	init(delay: TimeInterval) {
		self.delay = delay
	}
	
	func debounce(action: @escaping () -> Void) {
		workItem?.cancel()
		workItem = workGate.schedule(after: delay) {
			action()
		}
	}
}

struct ChatView: View {
	@ObservedObject var viewModel: ChatViewModel
	@ObservedObject var promptViewModel: PromptViewModel
	let windowID: Int
	@Binding var showSettingsPopover: Bool
	
	@FocusState private var isFocused: Bool
	@State private var resetTextFieldTrigger = false
	
	// Moved from old scrolling logic
	@State private var autoScrollEnabled = true
	@State private var composerOcclusion: CGFloat = 0
	
	// WebKit chat view preference
	/*	@AppStorage("useWebKitChatView") */let useWebKitChatView: Bool = false
	
	
	var body: some View {
		VStack(spacing: 0) {
			ChatTopBar(
				viewModel: viewModel,
				promptViewModel: promptViewModel
			)
			
			Divider()
			
			/*
			// Conditional chat view based on user preference
			if useWebKitChatView {
				ChatMessagesWebViewRepresentable(
					viewModel: viewModel,
					autoScrollEnabled: $autoScrollEnabled
				)
			} else {
				ChatMessagesView(
					viewModel: viewModel,
					autoScrollEnabled: $autoScrollEnabled
				)
			}
			*/
			
			ChatMessagesView(
				viewModel: viewModel,
				autoScrollEnabled: $autoScrollEnabled,
				bottomOcclusion: composerOcclusion
			)
			
			ChatInputBar(
				viewModel: viewModel,
				promptViewModel: promptViewModel,
				windowID: windowID,
				autoScrollEnabled: $autoScrollEnabled,
				resetTextFieldTrigger: $resetTextFieldTrigger,
				bottomOcclusion: $composerOcclusion,
				showSettingsPopover: $showSettingsPopover,
				isFocused: _isFocused
			) {
				sendMessage()
			}
		}
		.disabled(viewModel.sessionSwitchInProgressID != nil)
	}
	
	private func sendMessage() {
		guard !viewModel.inputText.isEmpty else { return }
		let messageToSend = viewModel.inputText
		Task {
			await viewModel.sendMessage(messageToSend)
			self.resetTextFieldTrigger = true
		}
	}
}
