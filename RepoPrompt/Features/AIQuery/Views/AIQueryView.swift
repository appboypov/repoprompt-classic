import SwiftUI

struct FirstResponderView: NSViewRepresentable {
	func makeNSView(context: Context) -> NSView {
		let view = NSView()
		//view.canBecomeKeyView = true
		return view
	}
	
	func updateNSView(_ nsView: NSView, context: Context) {
		DispatchQueue.main.async {
			if let window = nsView.window,
			   window.firstResponder != nsView {
				window.makeFirstResponder(nsView)
			}
		}
	}
}


struct AIQueryView: View {
	@StateObject var viewModel: AIResponseViewModel
	@StateObject var promptViewModel: PromptViewModel
	@Binding var showSettings: Bool
	@Binding var currentView: ViewType
	
	@State private var isLoading = false
	@State private var error: Error?
	@State private var hasAppeared = false
	
	@State private var mouseIsDown: Bool = false
	@State private var mouseMonitor: Any?
	@State private var lastKnownMousePosition: NSPoint = .zero
	
	var body: some View {
		VStack(spacing: 0) {
			TopBarView(viewModel: viewModel, isLoading: $isLoading, handleBackButton: handleBackButton)
			
			HStack(spacing: 0) {
				FileListView(viewModel: viewModel)
					.frame(width: 300)
				
				Divider()
				
				FilePreviewContainerView(viewModel: viewModel, isLoading: isLoading, overallSummary: viewModel.overallSummary)
			}
		}
		.id(promptViewModel.queryIdentifier)
		.overlay(ErrorOverlay(error: error))
		.onAppear {
			//setupMouseMonitor()
		}
		.onDisappear {
			//removeMouseMonitor()
		}
	}
	
	private func handleBackButton() {
		stopAndDiscard()
	}
	
	@MainActor
	private func stopAndDiscard() {
		viewModel.notifyExit()          // 🔔 NEW – let listeners know we're leaving
		currentView = .fileManager
	}
}

struct TopBarView: View {
	@ObservedObject var viewModel: AIResponseViewModel
	@Binding var isLoading: Bool
	var handleBackButton: () -> Void
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		HStack {
			Button(action: handleBackButton) {
				HStack {
					Image(systemName: "chevron.left")
					Text("Exit Review")
				}
			}
			.buttonStyle(CustomButtonStyle())
			.hoverTooltip("Exit AI review and return to main view")
			
			HStack {
				acceptAllAndSaveButton
				resetAllButton
			}
			.padding(.horizontal)
			.padding(.vertical, 8)
			.background(Color.clear)
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(Color.secondary, lineWidth: 0.3)
			)
			
			Spacer()
			
			Text("AI Suggested Changes")
				.font(fontPreset.titleFont)
			
			Spacer()
		}
		.padding()
		.background(Color(NSColor.controlBackgroundColor).opacity(0.5))
	}
	
	private var acceptAllAndSaveButton: some View {
		Button(action: {
			Task {
				await viewModel.acceptAllAndSave()
			}
		}) {
			HStack(spacing: 4) {
				Image(systemName: "checkmark.circle")
				Text("Accept All Files")
					.lineLimit(1)
					.truncationMode(.tail)
			}
		}
		.buttonStyle(CustomButtonStyle())
		.disabled(viewModel.responses.isEmpty)
		.hoverTooltip("Accept all AI changes and save to files")
	}
	
	private var resetAllButton: some View {
		Button(action: {
			Task {
				await viewModel.resetAllAndSave()
			}
		}) {
			HStack(spacing: 4) {
				Image(systemName: "arrow.counterclockwise")
				Text("Reset All Files")
					.lineLimit(1)
					.truncationMode(.tail)
			}
		}
		.buttonStyle(CustomButtonStyle())
		.disabled(viewModel.responses.isEmpty)
		.hoverTooltip("Reset all files to original state")
	}
}

struct FileListView: View {
	@ObservedObject var viewModel: AIResponseViewModel
	@Namespace private var listNamespace
	
	var body: some View {
		List(viewModel.responses, id: \.id, selection: $viewModel.selectedFileId) { response in
			FileItemView(response: response, isSelected: viewModel.selectedFileId == response.id, viewModel: viewModel)
				.listRowInsets(EdgeInsets())
				.listRowBackground(viewModel.selectedFileId == response.id ? Color.blue.opacity(0.1) : Color.clear)
				.onChange(of: viewModel.selectedFileId) { _, newValue in
					if newValue == response.id {
						viewModel.selectFileAndNavigateToFirstChange(response.id)
					}
				}
		}
		.listStyle(PlainListStyle())
		.scrollContentBackground(.hidden)
		.background(Color.clear)
		.id(viewModel.objectWillChangeCount)
	}
}

struct FileItemView: View {
	@ObservedObject var response: ChangedFile
	let isSelected: Bool
	@ObservedObject var viewModel: AIResponseViewModel
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	@State private var isHovered = false
	
	var body: some View {
		HStack {
			VStack(alignment: .leading, spacing: 4) {
				HStack {
					Text(URL(fileURLWithPath: response.relativePath).lastPathComponent)
						.fontWeight(.medium)
						.lineLimit(1)
					Text(response.fileAction.rawValue.capitalized)
						.font(fontPreset.captionFont)
						.padding(.horizontal, 6)
						.padding(.vertical, 2)
						.background(actionColor)
						.foregroundColor(.white)
						.cornerRadius(4)
				}
				Text("Processed: \(response.acceptedChangeCount)/\(response.proposedChangeCount)")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
			}
			Spacer()
			statusButton
		}
		.padding(.vertical, 8)
		.padding(.horizontal, 12)
		.onHover { hovering in
			isHovered = hovering
		}
	}
	
	private var statusButton: some View {
		Button(action: {
			if response.acceptedChangeCount > 0 || response.rejectedChanges.count > 0 {
				Task {
					await viewModel.resetAllAndSave(for: response)
				}
			} else if response.acceptedChangeCount < response.proposedChangeCount {
				Task {
					await viewModel.acceptAllAndSave(for: response)
				}
			}
		}) {
			Image(systemName: statusButtonImageName)
				.foregroundColor(statusButtonForegroundColor)
				.animation(.easeInOut(duration: 0.2), value: response.acceptedChangeCount)
				.animation(.easeInOut(duration: 0.2), value: response.rejectedChanges.count)
				.animation(.easeInOut(duration: 0.2), value: isHovered)
		}
		.buttonStyle(SmallRoundButtonStyle(size: 28, iconSize: 20))
	}
	
	private var statusButtonImageName: String {
		if response.acceptedChangeCount == 0 && response.rejectedChanges.count == 0 {
			// No changes accepted or rejected yet
			return "circle"
		} else if response.acceptedChangeCount == response.proposedChangeCount {
			// All changes accepted
			return isHovered ? "arrow.counterclockwise.circle" : "checkmark.circle.fill"
		} else {
			// Some changes accepted or rejected
			return "arrow.counterclockwise.circle"
		}
	}
	
	private var statusButtonForegroundColor: Color {
		if response.acceptedChangeCount == response.proposedChangeCount && !isHovered {
			return .green
		} else {
			return .secondary
		}
	}
	
	private var actionColor: Color {
		switch response.fileAction {
		case .create:
			return .green
		case .modify, .delegateEdit:
			return .blue
		case .rewrite:
			return .purple
		case .delete:
			return .red
		}
	}
}

struct FilePreviewContainerView: View {
	@ObservedObject var viewModel: AIResponseViewModel
	var isLoading: Bool
	var overallSummary: String?
	@State private var isSummaryVisible = false
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		ZStack(alignment: .bottom) {
			if let selectedResponse = viewModel.selectedResponse {
				FilePreviewView(viewModel: viewModel, response: selectedResponse, fileManager: viewModel.fileManager)
					.background(FirstResponderView())
			} else {
				VStack {
					if isLoading && viewModel.responses.isEmpty {
						ProgressView("Processing Changes...")
					} else {
						Image(systemName: "doc.text.magnifyingglass")
							.font(.system(size: 48))
							.foregroundColor(.secondary)
						Text("Select a file to preview changes")
							.font(fontPreset.headlineFont)
							.foregroundColor(.secondary)
					}
				}
				.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
			
			/*
			if let summary = overallSummary {
				GlassSummaryView(summary: summary, isVisible: $isSummaryVisible)
					.opacity(isSummaryVisible ? 1 : 0)
					.offset(y: isSummaryVisible ? 0 : 100)
					.padding(.horizontal)
					.padding(.bottom, 10)
			}
			*/
		}
		.onChange(of: overallSummary) { newValue in
			withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
				isSummaryVisible = newValue != nil
			}
		}
		.coordinateSpace(name: "filePreview")  // Add this
	}
}


struct ErrorOverlay: View {
	var error: Error?
	
	var body: some View {
		Group {
			if let error = error {
				Text("Error: \(error.localizedDescription)")
					.foregroundColor(.red)
					.padding()
			}
		}
	}
}