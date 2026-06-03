import SwiftUI

struct DiffView: View {
	// MARK: - State / Dependencies
	@ObservedObject var viewModel: DiffViewModel
	@ObservedObject var promptViewModel: PromptViewModel
	@State private var isErrorPopoverVisible = false
	@State private var showDelegateInfo     = false
	@State private var showPromptSettings   = false
	@State private var editorUpdateTick: Int = 0
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	// Layout properties
	var availableWidth: CGFloat
	var availableHeight: CGFloat

	// MARK: - View
	var body: some View {
		// Determine layout mode based on available width
		let isVerticalLayout = availableWidth < 832 // Threshold for switching to vertical
		let hideHeading = availableHeight < 400 // Hide heading when height is less than 400
		
		ScrollView {
			VStack(spacing: 16) {
				
				// Heading (conditionally shown)
				if !hideHeading {
					VStack(alignment: .leading, spacing: 4) {
						Text("Generate & Apply AI Code Changes")
							.font(fontPreset.headlineFont)
							.foregroundColor(.primary)
						Text("Use the **XML Edit** preset to copy your prompt, send it to a web-based AI chatbot, then paste its XML response here to parse and apply the changes.")
							.font(fontPreset.subheadlineFont)
							.foregroundColor(.secondary)
							.fixedSize(horizontal: false, vertical: true)
					}
					.padding(.bottom, 10)
					.frame(maxWidth: .infinity, alignment: .leading)
				} else {
					// Compact title for small window sizes
					Text("XML Edit Preset — Paste XML-formatted AI responses to apply file edits")
						.font(fontPreset.captionFont)
						.foregroundColor(.secondary)
						.frame(maxWidth: .infinity, alignment: .leading)
				}
				
				// MAIN COLUMNS - Adaptive layout
				if isVerticalLayout {
					VStack(alignment: .leading, spacing: 16) {
						aiResponseColumn
						
					promptControls
						.frame(maxWidth: .infinity)
				}
			} else {
				HStack(alignment: .top, spacing: 16) {
					aiResponseColumn
					
					promptControls
						.frame(minWidth: 200, idealWidth: 380, maxWidth: .infinity, alignment: .trailing)
				}
			}
				
				// Parsed files list or tutorial
				if viewModel.xmlInput.isEmpty || viewModel.parsedFiles.isEmpty {
					tutorialView
				} else {
					parsedFilesView
				}
				
				/*
				// Token counter
				Text("Approx. Token Total: ~\(promptViewModel.totalTokenCountWithDiff)")
					.font(.caption)
					.foregroundColor(tokenWarningColor)
					.help(tokenWarningHelp)
					.padding(.vertical, 4)
					.frame(maxWidth: .infinity, alignment: .center)
				*/
			}
			.padding()
			.onChange(of: viewModel.parsedFiles) { _, _ in
				viewModel.loadFilesStaged()
			}
		}
	}
}

// MARK: - Private subviews
private extension DiffView {
	var aiResponseColumn: some View {
		VStack(spacing: 0) {
			// Controls at the top
			HStack(spacing: 8) {
				// Dynamic title that shows status when available
				dynamicTitleView
				
				Spacer()

				Button { viewModel.parseChanges() }
				label: { Image(systemName: "arrow.clockwise") }
					.buttonStyle(CustomButtonStyle())
					.disabled(viewModel.xmlInput.isEmpty ||
								!(viewModel.parsingStatus == .success ||
								viewModel.parsingStatus == .failure))
					.hoverTooltip("Reparse the XML input to update changes")
				
			let canTriggerProEdit = viewModel.hasDelegateEdits
				Button {
				if viewModel.hasDelegateEdits {
						// Trigger Pro Edit flow
						viewModel.triggerProEdit(instructions: promptViewModel.promptText)
					} else {
						viewModel.mergeChanges()
					}
				} label: {
					Label(canTriggerProEdit
						? "Trigger Pro Edit in Chat"
						: "Review Changes",
						systemImage: viewModel.hasDelegateEdits
						? "bolt.square"
						: "arrow.triangle.merge")
				}
				.buttonStyle(CustomButtonStyle())
				.disabled((!viewModel.hasSelectedChanges || viewModel.parsingStatus != .success)
							&& !canTriggerProEdit)
				.hoverTooltip(canTriggerProEdit
					? "Send delegate edits to specialized models via the API"
					: "Review and apply the selected changes to your files")
				
				Button {
					viewModel.clearXMLInput()
					editorUpdateTick &+= 1
				}
				label: { Image(systemName: "xmark.circle.fill") }
					.buttonStyle(PlainButtonStyle())
					.disabled(viewModel.xmlInput.isEmpty)
					.foregroundColor(viewModel.xmlInput.isEmpty ? .gray : .secondary)
					.hoverTooltip("Clear the XML input")
			}
			.padding(.horizontal, 10)
			.padding(.vertical, 8)
			
			Divider()
			
			TextKitView(text: $viewModel.xmlInput, isEditable: true, fontSize: CGFloat(fontPreset.rawValue), externalUpdateTick: editorUpdateTick)
				.frame(minHeight: 150)
				.overlay(
					Text(" Paste AI response with XML-formatted changes here…")
						.foregroundColor(.secondary)
						.opacity(viewModel.xmlInput.isEmpty ? 1 : 0)
						.padding(10),
					alignment: .topLeading
				)
				.onChange(of: viewModel.xmlInput) { _, _ in
					viewModel.debouncedParseChanges(viewModel.xmlInput)
				}
		}
		.overlay(RoundedRectangle(cornerRadius: 8)
			.stroke(Color(NSColor.systemGray), lineWidth: 0.5))
		.frame(maxWidth: .infinity, alignment: .leading)
	}

	var promptControls: some View {
		EmptyView()
	}
	
	var dynamicTitleView: some View {
		let diffCount       = viewModel.generatedChangesCount
		let fileCount       = viewModel.parsedFiles.count
		let hasDelegates    = viewModel.hasDelegateEdits
		let delegateCount   = viewModel.delegateEditCount
		let delegateOnly    = hasDelegates && fileCount == 0      // hide ParsingStatusBox in this case
		
		return HStack(spacing: 8) {
			// ─── Static title ───
			if viewModel.parsingStatus == .idle || viewModel.parsingStatus == .failure {
				Text("AI Response")
					.font(.headline)
			}
			
			// ─── Dynamic summary (only when something was parsed) ───
			if !viewModel.xmlInput.isEmpty && (fileCount > 0 || hasDelegates) {
				if fileCount > 0 {
					Text("▷ \(diffCount) diff\(diffCount == 1 ? "" : "s") • \(fileCount) file\(fileCount == 1 ? "" : "s")")
						.font(fontPreset.captionFont)
						.foregroundColor(.secondary)
				}
				
				if hasDelegates {
					Text("⚡︎ \(delegateCount) delegate edit\(delegateCount == 1 ? "" : "s") (API cost)")
						.font(fontPreset.captionFont.bold())
						.foregroundColor(.accentColor)
				}
			}
			
			// ─── Parsing status ───
			if !delegateOnly {
				ParsingStatusBox(
					status: viewModel.parsingStatus,
					errorMessage: viewModel.errorMessage,
					fileLoadingWarning: viewModel.fileLoadingWarning
				)
			}
		}
	}
	
	var tutorialView: some View {
		VStack(spacing: 16) {
			Text("How to use Apply Mode")
				.font(fontPreset.headlineFont)
				.frame(maxWidth: .infinity, alignment: .leading)
			
			//LazyVGrid(columns: columns, spacing: 16) {
			HStack {
				InstructionStep(
					number: 1,
					title: "Prepare & Send to AI",
					description: "Write your instructions, select the code files to update, then copy the generated XML prompt and send it to your AI assistant."
				)
				Spacer()
				InstructionStep(
					number: 2,
					title: "Review & Apply Changes",
					description: "Copy the AI’s XML response into this window, then tap 'Review Changes' to inspect the edits and apply them to your files."
				)

			}
		}
		//.padding()
		.frame(maxWidth: .infinity, alignment: .leading)
		//.background(Color(NSColor.controlBackgroundColor).opacity(0.6))
		.cornerRadius(8)
	}
	
	var parsedFilesView: some View {
		LazyVStack(spacing: 16) {
			ForEach(viewModel.parsedFiles) { file in
				FileCard(file: file, viewModel: viewModel)
					.background(Color.gray.opacity(0.1))
					.cornerRadius(8)
					.opacity(viewModel.visibleFileIds.contains(file.id) ? 1 : 0)
					.animation(.easeIn(duration: 0.3),
								value: viewModel.visibleFileIds.contains(file.id))
			}
		}
	}
}

// MARK: - Extracted Components
struct InstructionStep: View {
	let number: Int
	let title: String
	let description: String

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(spacing: 12) {
				Circle()
					.fill(Color.blue)
					.frame(width: 28, height: 28)
					.overlay(
						Text("\(number)")
							.foregroundColor(.white)
							.font(fontPreset.subHeadlineBoldFont)
					)
				
				Text(title)
					.font(fontPreset.headlineFont)
			}
			
			Text(description)
				.font(fontPreset.font)
				.foregroundColor(.secondary)
				.lineLimit(4)
				.truncationMode(.tail)
				//.fixedSize(horizontal: false, vertical: true)
		}
		.padding()
		.frame(maxWidth: .infinity, alignment: .leading)
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(Color.gray.opacity(0.3), lineWidth: 1)
		)
	}
}
