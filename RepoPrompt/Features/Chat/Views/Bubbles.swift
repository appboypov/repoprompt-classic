//
//  Bubbles.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-10-30.
//

import SwiftUI
import AppKit
import Markdown

// MARK: - Token Usage Indicator
private struct TokenUsageIndicator: View {
	let inputTokens: Int
	let outputTokens: Int
	let modelName: String?
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	// helper: 1 k = 1000 tokens, always 2 decimals
	private func format(_ tokens: Int) -> String {
		String(format: "%.2fk", Double(tokens) / 1_000.0)
	}
	
	var body: some View {
		HStack(spacing: 4) {
			if let modelName = modelName {
				Text(modelName)
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary.opacity(0.6))
			}
			Text("Tokens: \(format(inputTokens)) in | \(format(outputTokens)) out")
				.font(fontPreset.captionFont)
				.foregroundColor(.secondary.opacity(0.8))
		}
		.padding(.vertical, 3)
		.padding(.horizontal, 5)
	}
}

private struct FileSelectionIndicator: View {
	let message: AIChatMessage
	@ObservedObject var viewModel: ChatViewModel
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	@State private var isHovering = false
	@State private var showPopover = false

	// Helper: truncated path (keep last 3 segments)
	private func truncated(_ path: String, keep last: Int = 3) -> String {
		let comps = path.split(separator: "/")
		guard comps.count > last else { return path }
		let tail = comps.suffix(last).joined(separator: "/")
		return "…/" + tail
	}

	var body: some View {
		Button(action: { showPopover.toggle() }) {
			HStack(spacing: 4) {
				Image(systemName: "folder")
					.font(fontPreset.captionFont)
				Text("\(message.selectedFileCount) file\(message.selectedFileCount == 1 ? "" : "s")")
					.font(fontPreset.captionFont)
			}
			.padding(.vertical, 4)
			.padding(.horizontal, 6)
			.background(
				RoundedRectangle(cornerRadius: 6)
					.fill(isHovering
							? BubbleColors.mediumBlue
							: BubbleColors.lightBlue.opacity(0.6))
			)
			.overlay(
				RoundedRectangle(cornerRadius: 6)
					.stroke(BubbleColors.borderBlue, lineWidth: 1)
					.opacity(isHovering ? 1 : 0.5)
			)
		}
		.buttonStyle(PlainButtonStyle())
		.onHover { hovering in
			withAnimation(.easeInOut(duration: 0.2)) {
				isHovering = hovering
			}
		}
		.hoverTooltip("View & restore file selection")
		.popover(isPresented: $showPopover, arrowEdge: .bottom) {
			FileSelectionPopover(message: message, viewModel: viewModel)
		}
	}

	// ────────────────────────────────────────────────
	// MARK: – Pop-over content
	// ────────────────────────────────────────────────
	private struct FileSelectionPopover: View {
		let message: AIChatMessage
		@ObservedObject var viewModel: ChatViewModel
		@ObservedObject private var fontScale = FontScaleManager.shared
		private var fontPreset: FontScalePreset { fontScale.preset }

		// Convenience
		private var paths: [String] { message.allowedFilePaths }

		// Local cache that drives the check-mark UI
		@State private var selectedPaths = Set<String>()

		@Environment(\.colorScheme) private var scheme

		var body: some View {
			VStack(alignment: .leading, spacing: 0) {
				VStack(alignment: .leading, spacing: 6) {
					Text("Saved file selection")
						.font(fontPreset.headlineFont)
					Text("The list below shows every file that was selected when this message was generated.")
						.font(fontPreset.captionFont)
						.foregroundColor(.secondary)
					
					HStack {
						Button("Add all to selection") {
							Task { await viewModel.addFileSelection(from: message) }
							selectedPaths = Set(paths)      // mark all rows selected
						}
						.hoverTooltip("Keep current selection and add these files")
						
						Button("Replace current selection") {
							Task { await viewModel.restoreFileSelection(from: message) }
							selectedPaths = Set(paths)      // mark all rows selected
						}
						.hoverTooltip("Clear current selection and select these files instead")
						
						Spacer()
					}
				}
				.padding(8)
				.background(BubbleColors.lightBlue(colorScheme: scheme))
				
				Divider()

				// ───────── File list ─────────
				ScrollView {
					VStack(alignment: .leading, spacing: 6) {
						ForEach(paths, id: \.self) { path in
							FileRow(
								path: path,
								isSelected: Binding(
									get: { selectedPaths.contains(path) },
									set: { newVal in
										if newVal {
											selectedPaths.insert(path)
										} else {
											selectedPaths.remove(path)
										}
									}
								),
								fontPreset: fontPreset
							) { newVal in
								// Relay change to view model
								Task {
									await viewModel.toggleFileSelection(path: path, select: newVal)
								}
							}
							.frame(maxWidth: .infinity, alignment: .leading)
						}
					}
					.padding(8)
				}
				.frame(maxHeight: fontPreset.scaledClamped(400, max: 560))
			}
			.frame(width: fontPreset.scaledClamped(450, max: 600))
			.frame(minHeight: fontPreset.scaledMetric(200), maxHeight: fontPreset.scaledClamped(500, max: 660))
			.onAppear {
				// Initialise check-marks from actual selection state
				selectedPaths = Set(
					paths.filter { viewModel.isFileSelected($0) }
				)
			}
		}

		// ─────────────────────────────────────────────────────────────
		// MARK: – Nested row view
		// ─────────────────────────────────────────────────────────────
		private struct FileRow: View {
			let path: String
			@Binding var isSelected: Bool
			let fontPreset: FontScalePreset
			let onToggle: (Bool) -> Void

			var body: some View {
				Button(action: {
					isSelected.toggle()
					onToggle(isSelected)
				}) {
					HStack(spacing: 6) {
						Image(systemName: isSelected ? "checkmark.square.fill" : "square")
							.font(fontPreset.font)
						Text(truncated(path))
							.font(fontPreset.font)
							.lineLimit(1)
							.truncationMode(.tail)
						Spacer()
					}
				}
				.buttonStyle(PlainButtonStyle())
				.frame(maxWidth: .infinity, alignment: .leading)
			}

			// Helper to keep only the last 3 components
			private func truncated(_ path: String, keep last: Int = 3) -> String {
				let comps = path.split(separator: "/")
				guard comps.count > last else { return path }
				let tail = comps.suffix(last).joined(separator: "/")
				return "…/" + tail
			}
		}
	}
}

/// A compact circular progress indicator that places an SF-symbol
/// in the centre of the ring. The ring animates any time the
/// `progress` value changes. This implementation uses a slimmer ring
/// and a smaller centered icon for a more subtle look.
private struct MiniProgressRing: View {
	/// 0 – 1 (outside these bounds will be clamped)
	var progress: Double
	/// SF-symbol to draw inside the ring
	var iconSystemName: String
	/// Overall diameter
	var size: CGFloat = 14

	private var clampedProgress: Double { min(max(progress, 0), 1) }
	/// Ring thickness – reduced for slimmer look
	private var lineWidth: CGFloat       { size * 0.14 }
	/// Icon size – slightly smaller to add inner padding
	private var iconSize: CGFloat        { size * 0.48 }

	var body: some View {
		ZStack {
			// Background track
			Circle()
				.stroke(lineWidth: lineWidth)
				.foregroundColor(Color.secondary.opacity(0.25))
			
			// Animated progress arc
			Circle()
				.trim(from: 0, to: clampedProgress)
				.stroke(style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
				.foregroundColor(Color.accentColor)
				.rotationEffect(.degrees(-90))
				.animation(.easeInOut(duration: 0.25), value: clampedProgress)
			
			// Centre icon
			Image(systemName: iconSystemName)
				.resizable()
				.scaledToFit()
				.frame(width: iconSize, height: iconSize)
		}
		.frame(width: size, height: size)
	}
}

struct MessageBubble: View {
	let message: AIChatMessage
	@ObservedObject var viewModel: ChatViewModel
	let isLatestMessage: Bool
	@ObservedObject private var fontScale = FontScaleManager.shared

	// Flags for hover states
	@State private var isHoveringDelete = false
	@State private var isHoveringCopy = false
	@State private var showingDeleteConfirmation = false
	@State private var isHoveringFork = false // Add state for fork button hover
	@State private var isHoveringEdit = false // Add state for edit button hover

	// Edit mode state
	@State private var isEditingMessage = false
	@State private var editedText = ""

	// For adaptive colors
	@Environment(\.colorScheme) private var colorScheme

	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		// Stack them vertically, letting each sub-bubble
		// handle alignment to trailing/leading
		VStack(spacing: 0) {
			if message.isUser {
				userBubble
			} else {
				assistantMessage
			}
		}
		.frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
	}
	
	private var userBubble: some View {
		VStack(alignment: .trailing, spacing: 4) {

			// The user bubble content
			Group {
				if isEditingMessage {
					// Edit mode: show text editor
					VStack(alignment: .leading, spacing: 8) {
						ZStack {
							TextEditor(text: $editedText)
								.font(fontPreset.font)
								.frame(minHeight: 60)
								.scrollContentBackground(.hidden)
								.background(Color.clear)

							// Invisible buttons to capture keyboard shortcuts
							Button("") {
								isEditingMessage = false
								editedText = message.content
							}
							.keyboardShortcut(.escape, modifiers: [])
							.hidden()

							Button("") {
								if !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
									Task {
										await viewModel.editAndResendMessage(messageId: message.id, newContent: editedText)
										isEditingMessage = false
									}
								}
							}
							.keyboardShortcut(.return, modifiers: .command)
							.hidden()
						}

						// Submit and Cancel buttons
						HStack(spacing: 8) {
							Button {
								isEditingMessage = false
								editedText = message.content
							} label: {
								HStack(spacing: 4) {
									Text("Cancel")
									Text("⎋")
										.foregroundColor(.secondary.opacity(0.6))
								}
							}
							.buttonStyle(CustomButtonStyle())

							Button {
								Task {
									await viewModel.editAndResendMessage(messageId: message.id, newContent: editedText)
									isEditingMessage = false
								}
							} label: {
								HStack(spacing: 4) {
									Text("Submit")
									Text("⌘⏎")
										.foregroundColor(.secondary.opacity(0.6))
								}
							}
							.buttonStyle(CustomButtonStyle())
							.disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
						}
					}
				} else {
					// Normal view mode
					CollapsibleUserMessage(text: message.content)
				}
			}
			.padding(12)
			.background(BubbleColors.lightBlue)
			.cornerRadius(20)
			
			// Buttons below the bubble
			HStack { // Outer container to align trailing without forcing inner to expand
				HStack(spacing: 8) {
					// Token indicator for user messages - always render to prevent layout shifts
					Group {
						if let inTok = message.promptTokens,
							let outTok = message.completionTokens {
							TokenUsageIndicator(inputTokens: inTok, outputTokens: outTok, modelName: nil)
						} else {
							// Invisible placeholder with same height to maintain stable layout
							Color.clear
								.frame(width: 0, height: 20)
						}
					}

					// Always show copy for user messages
					CopyButtonOverlay(
						message: message,
						viewModel: viewModel,
						showCopyButton: true,
						isHoveringCopy: $isHoveringCopy,
						showingDeleteConfirmation: $showingDeleteConfirmation
					)

					// Edit button for user messages
					EditButtonOverlay(
						isHoveringEdit: $isHoveringEdit,
						isEditingMessage: $isEditingMessage,
						editedText: $editedText,
						messageContent: message.content,
						isDisabled: viewModel.isSessionStreaming(viewModel.currentSessionID)
					)

					DeleteButtonOverlay(
						message: message,
						viewModel: viewModel,
						isHoveringDelete: $isHoveringDelete,
						showingConfirmation: $showingDeleteConfirmation
					)
				}
				.padding(.vertical, 4)
				.padding(.horizontal, 8)
				.background(.thinMaterial)
				.cornerRadius(8)
				.shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)
			}
			.frame(maxWidth: .infinity, alignment: .trailing)
		}
		.padding(.bottom, 8)
	}
	
	private var assistantMessage: some View {
		VStack(alignment: .leading, spacing: 0) { // Remove spacing between bubble and footer

			// main content - no background to avoid re-renders
			MessageBubbleContent(
				message: message,
				viewModel: viewModel,
				isLatestMessage: isLatestMessage
			)
			.padding(12)
			.frame(maxWidth: .infinity, alignment: .leading)

			// footer section - always rendered with fixed height to prevent layout thrashing
			footerBar
				.frame(height: fontPreset.scaledMetric(36))
				.opacity(message.isFinalized ? 1 : 0)
				.animation(.easeInOut(duration: 0.2), value: message.isFinalized)
				.allowsHitTesting(message.isFinalized)
		}
		.padding(.bottom, 8)
	}

	@ViewBuilder
	private var footerBar: some View {
		HStack(alignment: .center, spacing: 8) {
			ZStack {
				Rectangle()
					.fill(.thinMaterial)
					.cornerRadius(20)
					.shadow(color: .black.opacity(0.2), radius: 3, x: 0, y: 1)

				HStack(spacing: 8) {
					CopyButtonOverlay(
						message: message,
						viewModel: viewModel,
						showCopyButton: message.isFinalized,
						isHoveringCopy: $isHoveringCopy,
						showingDeleteConfirmation: $showingDeleteConfirmation
					)

					ForkButtonOverlay(
						message: message,
						viewModel: viewModel,
						isHoveringFork: $isHoveringFork
					)

					DeleteButtonOverlay(
						message: message,
						viewModel: viewModel,
						isHoveringDelete: $isHoveringDelete,
						showingConfirmation: $showingDeleteConfirmation
					)

					if message.selectedFileCount > 0 {
						FileSelectionIndicator(message: message, viewModel: viewModel)
					}

					if let inTok = message.promptTokens,
					   let outTok = message.completionTokens {
						TokenUsageIndicator(
							inputTokens: inTok,
							outputTokens: outTok,
							modelName: message.modelName
						)
					} else if let modelName = message.modelName {
						Text(modelName)
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary.opacity(0.6))
					}
				}
				.padding(.vertical, 6)
				.padding(.horizontal, 12)
			}
			.fixedSize(horizontal: true, vertical: false)
		}
		.padding(.vertical, 4)
	}
}

// MARK: - Subviews

// Add the new ForkButtonOverlay struct
private struct ForkButtonOverlay: View {
	let message: AIChatMessage
	@ObservedObject var viewModel: ChatViewModel
	@Binding var isHoveringFork: Bool
	
	var body: some View {
		Button(action: {
			Task {
				await viewModel.forkChatSession(from: message.id)
			}
		}) {
			Image(systemName: "arrow.triangle.branch") // Fork icon
				.foregroundColor(isHoveringFork ? BubbleColors.highContrastCopyIconHover : BubbleColors.copyIconNormal) // Use higher contrast
				.frame(width: 20, height: 20)
		}
		.buttonStyle(PlainButtonStyle())
		.onHover { hovering in
			withAnimation(.easeInOut(duration: 0.2)) {
				isHoveringFork = hovering
			}
		}
		.hoverTooltip("Fork chat from this message")
	}
}


private struct BubbleContainer<Content: View>: View {
	let message: AIChatMessage
	let content: Content
	
	init(message: AIChatMessage, @ViewBuilder content: () -> Content) {
		self.message = message
		self.content = content()
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			content
		}
		.padding(12)
		.background(message.isUser ? BubbleColors.userBubbleBackground : BubbleColors.assistantBubbleBackground)
		.cornerRadius(20)
	}
}

private struct EditButtonOverlay: View {
	@Binding var isHoveringEdit: Bool
	@Binding var isEditingMessage: Bool
	@Binding var editedText: String
	let messageContent: String
	let isDisabled: Bool

	var body: some View {
		Button(action: {
			editedText = messageContent
			isEditingMessage = true
		}) {
			Image(systemName: "pencil")
				.foregroundColor(isDisabled ? BubbleColors.copyIconNormal.opacity(0.3) : (isHoveringEdit ? BubbleColors.highContrastCopyIconHover : BubbleColors.copyIconNormal))
				.frame(width: 20, height: 20)
		}
		.buttonStyle(PlainButtonStyle())
		.disabled(isDisabled)
		.onHover { hovering in
			withAnimation(.easeInOut(duration: 0.2)) {
				isHoveringEdit = hovering
			}
		}
		.hoverTooltip(isDisabled ? "Cannot edit while AI is responding" : "Edit message")
	}
}

private struct DeleteButtonOverlay: View {
	let message: AIChatMessage
	@ObservedObject var viewModel: ChatViewModel
	@Binding var isHoveringDelete: Bool
	@Binding var showingConfirmation: Bool
	@Environment(\.colorScheme) private var colorScheme
	
	var body: some View {
		HStack(spacing: 8) {
			if showingConfirmation {
				// Confirm button
				Button(action: {
					let id = message.id
					Task {
						await viewModel.removeMessage(id)
					}
				}) {
					Image(systemName: "checkmark")
						.foregroundColor(BubbleColors.errorRed.opacity(0.8))
						.frame(width: 20, height: 20)
				}
				.buttonStyle(PlainButtonStyle())
				.hoverTooltip("Confirm delete")
				
				// Cancel button
				Button(action: {
					showingConfirmation = false
				}) {
					Image(systemName: "xmark")
						.foregroundColor(BubbleColors.neutralGray.opacity(0.8))
						.frame(width: 20, height: 20)
				}
				.buttonStyle(PlainButtonStyle())
				.hoverTooltip("Cancel")
				
			} else {
				// Initial delete button
				Button(action: {
					showingConfirmation = true
				}) {
					Image(systemName: "trash.fill")
						.foregroundColor(isHoveringDelete ? BubbleColors.deleteIconHover : BubbleColors.deleteIconNormal)
						.frame(width: 20, height: 20)
				}
				.buttonStyle(PlainButtonStyle())
				.onHover { hovering in
					withAnimation(.easeInOut(duration: 0.2)) {
						isHoveringDelete = hovering
					}
				}
				.hoverTooltip("Delete message")
			}
		}
		.animation(.easeInOut(duration: 0.2), value: showingConfirmation)
	}
}

private struct CopyButtonOverlay: View {
	let message: AIChatMessage
	@ObservedObject var viewModel: ChatViewModel
	let showCopyButton: Bool
	@Binding var isHoveringCopy: Bool
	@Binding var showingDeleteConfirmation: Bool
	
	var body: some View {
		if showCopyButton {
			Button(action: {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(
					message.content,
					forType: .string
				)
				
				// Cancel delete confirmation if active
				showingDeleteConfirmation = false
			}) {
				Image(systemName: "doc.on.doc.fill")
					.foregroundColor(isHoveringCopy ? BubbleColors.highContrastCopyIconHover : BubbleColors.copyIconNormal)
					.frame(width: 20, height: 20)
			}
			.buttonStyle(PlainButtonStyle())
			.onHover { hovering in
				withAnimation(.easeInOut(duration: 0.2)) {
					isHoveringCopy = hovering
				}
			}
			.hoverTooltip("Copy message to clipboard")
		}
	}
}

// MARK: - Updated Reasoning Popover and Button

private struct ReasoningPopover: View {
	@Binding var reasoningContent: String
	var externalUpdateTick: Int = 0
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			popoverHeader
			Divider()
			popoverContent
		}
	}

	// MARK: - ReasoningPopover (only popoverHeader changes)
	private var popoverHeader: some View {
		HStack {
			Text("AI Reasoning")
				.font(fontPreset.headlineFont)
				.padding()
			Spacer()
		}
		//.background(Color.blue.opacity(0.1))
	}

	private var popoverContent: some View {
		TextKitView(
			text: $reasoningContent,
			isEditable: false,
			isSpellCheckEnabled: false,
			externalUpdateTick: externalUpdateTick
		)
		.frame(width: fontPreset.scaledClamped(500, max: 660), height: fontPreset.scaledClamped(300, max: 440))
		.padding()
	}
}

// MARK: – Delegate-edit Response Popover
/// Displays the raw XML / diff returned by a delegate-edit task.
private struct EditResponsePopover: View {
	let task: DelegateEditTask
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	// Format integer tokens as "#.##k"
	private func format(_ tokens: Int) -> String {
		String(format: "%.2fk", Double(tokens) / 1_000.0)
	}

	// Build the token usage text to display in the header
	private func tokenDisplay() -> String? {
		if let p = task.promptTokens,
		let c = task.completionTokens,
		(p != 0 || c != 0) {
			return "\(format(p)) in | \(format(c)) out"
		} else if task.tokenEstimate > 0 {
			return "~\(format(task.tokenEstimate)) tokens"
		}
		return nil
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			// Header with status icon, tokens and copy button
			HStack(spacing: 8) {
				Text("File-edit Response")
					.font(fontPreset.headlineFont)

				ProgressIndicator(status: task.status)
					.frame(width: 14, height: 14)

				if let tok = tokenDisplay() {
					Text("· \(tok)")
						.font(fontPreset.captionFont)
						.foregroundColor(.secondary)
				}

				Spacer()

				Button(action: {
					NSPasteboard.general.clearContents()
					NSPasteboard.general.setString(task.accumulatedOutput,
												forType: .string)
				}) {
					Image(systemName: "doc.on.doc")
						.foregroundColor(.secondary)
				}
				.buttonStyle(PlainButtonStyle())
				.hoverTooltip("Copy full response to clipboard")
			}
			.padding()
			.background(Color.blue.opacity(0.1))

			// Content – use TextKitView for efficient large text rendering
			TextKitView(
				text: .constant(task.accumulatedOutput),
				isEditable: false,
				isSpellCheckEnabled: false,
				useMonospacedFont: true,
				wrapLines: true
			)
			.frame(width: fontPreset.scaledClamped(600, max: 760), height: fontPreset.scaledClamped(400, max: 560))
			.padding()
		}
	}
}

private struct ReasoningButton: View {
	@Binding var reasoningContent: String
	let isStreaming: Bool
	var externalUpdateTick: Int = 0

	@State private var showReasoningPopover = false
	@State private var isHovering = false
	@Environment(\.colorScheme) private var colorScheme
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	var body: some View {
		Button(action: {
			showReasoningPopover.toggle()
		}) {
			buttonContent
		}
		.buttonStyle(PlainButtonStyle())
		.onHover { hovering in
			withAnimation(.easeInOut(duration: 0.2)) {
				isHovering = hovering
			}
		}
		.popover(isPresented: $showReasoningPopover) {
			ReasoningPopover(
				reasoningContent: $reasoningContent,
				externalUpdateTick: externalUpdateTick
			)
		}
	}
	
	@ViewBuilder
	private var buttonContent: some View {
		HStack(spacing: 4) {
			Image(systemName: "brain").font(fontPreset.captionFont)
			Text("Reasoning").font(fontPreset.captionFont)
			if isStreaming {
				ProgressView()
					.progressViewStyle(CircularProgressViewStyle())
					.scaleEffect(0.6)
					.frame(width: 12, height: 12)
			}
		}
		.padding(.vertical, 4)
		.padding(.horizontal, 6)
		.background(RoundedRectangle(cornerRadius: 6).fill(isHovering ? BubbleColors.mediumBlue : BubbleColors.lightBlue))
		.overlay(RoundedRectangle(cornerRadius: 6).stroke(BubbleColors.borderBlue, lineWidth: 1))
	}
}

private struct MessageBubbleContent: View {
	let message: AIChatMessage
	@ObservedObject var viewModel: ChatViewModel
	let isLatestMessage: Bool
	@Environment(\.colorScheme) private var colorScheme
	@State private var isCollapsed = true
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	// Render markdown for assistant messages to handle code blocks natively
	private var shouldRenderMarkdown: Bool {
		return !message.isUser
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			reasoningButtonIfNeeded

			// Extract parsed content rendering into separate view to minimize re-renders
			if message.parsedContent.isEmpty && message.content.isEmpty && !shouldShowReasoningButton && !message.isFinalized {
				loadingView
			} else if viewModel.debugMode {
				debugContent
			} else if message.isUser {
				userContent
			} else {
				AssistantContentView(
					parsedContent: message.parsedContent,
					shouldRenderMarkdown: shouldRenderMarkdown,
					isFinalized: message.isFinalized,
					totalLineCountFromContentItems: totalLineCountFromContentItems,
					combinedAssistantTextAndCode: combinedAssistantTextAndCode,
					shouldShowCollapsedView: shouldShowCollapsedAssistantView,
					isLatestMessage: isLatestMessage,
					message: message,
					viewModel: viewModel
				)
			}

			// If we have merges or parse status, show them
			MergeReadinessWrapper(
				message: message,
				viewModel: viewModel,
				isLatestMessage: isLatestMessage
			)
		}
		.frame(maxWidth: .infinity, alignment: .topLeading)
	}
	
	@ViewBuilder
	private var reasoningButtonIfNeeded: some View {
		// Always render container to prevent layout shifts
		Group {
			if shouldShowReasoningButton {
				// Get binding from ephemeral state instead of requiring an optional binding
				let binding = viewModel.bindingForReasoningContent(of: message.id)
				ReasoningButton(
					reasoningContent: binding,
					isStreaming: isStreamingWithEmptyContent,
					externalUpdateTick: viewModel.reasoningUpdateTick
				)
			} else {
				// Invisible placeholder
				Color.clear
					.frame(width: 0, height: 0)
			}
		}
	}
	
	private var shouldShowReasoningButton: Bool {
		// Check both ephemeral state and message for compatibility
		!message.isUser &&
		(!message.reasoningContent.isEmpty ||
			!viewModel.ephemeralState.reasoningContent(for: message.id).isEmpty)
	}
	
	private var isStreamingWithEmptyContent: Bool {
		!message.isFinalized && message.content.isEmpty
	}
	
	/// Sum of approximateLineEquivalentCount for all text/code items
	private var totalLineCountFromContentItems: Int {
		message.parsedContent
			.filter { $0.type == .text || $0.type == .code }
			.map(\.approximateLineEquivalentCount)
			.reduce(0, +)
	}

	/// Whether to show a collapsed block:
	/// - It's an assistant message (not user)
	/// - Not the latest message
	/// - Contains no `.file` items
	/// - The sum of approximate line counts across text/code items is > 10
	private var shouldShowCollapsedAssistantView: Bool {
		guard !message.isUser,
				!isLatestMessage,
				!message.parsedContent.contains(where: { $0.type == .file })
		else {
			return false
		}
		return totalLineCountFromContentItems > 10
	}

	/// Creates a single text chunk from all `.text` or `.code` items
	private var combinedAssistantTextAndCode: String {
		message.parsedContent
			.filter { $0.type == .text || $0.type == .code }
			.map(\.firstTenLineEquivalents)
			.joined(separator: "\n\n")
	}

	private var loadingView: some View {
		ProgressView()
			.progressViewStyle(CircularProgressViewStyle())
			.scaleEffect(0.7)
			.frame(height: 20)
	}

	private var debugContent: some View {
		CodeBlock(
			content: message.content,
			allowTextInteraction: isLatestMessage && message.isFinalized
		)
	}

	private var userContent: some View {
		Text(message.content)
			.font(fontPreset.font)
			.textSelection(.enabled)
			.allowsHitTesting(isLatestMessage && message.isFinalized)
	}
}

/// Extracted view for assistant content to minimize re-renders during streaming
private struct AssistantContentView: View {
	let parsedContent: [ContentItem]
	let shouldRenderMarkdown: Bool
	let isFinalized: Bool
	let totalLineCountFromContentItems: Int
	let combinedAssistantTextAndCode: String
	let shouldShowCollapsedView: Bool
	let isLatestMessage: Bool
	let message: AIChatMessage
	@ObservedObject var viewModel: ChatViewModel
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	@State private var isCollapsed = true

	var body: some View {
		if shouldShowCollapsedView {
			collapsibleContent
		} else {
			assistantContent
		}
	}

	@ViewBuilder
	private var collapsibleContent: some View {
		VStack(alignment: .leading, spacing: 6) {
			if isCollapsed {
				Text(combinedAssistantTextAndCode)
					.textSelection(.enabled)
					.allowsHitTesting(isFinalized)
					.lineLimit(10)
			} else {
				assistantContent
			}

			Button {
				if isCollapsed {
					// Expanding - no animation
					isCollapsed = false
				} else {
					// Collapsing - with animation
					withAnimation(.easeInOut(duration: 0.3)) {
						isCollapsed = true
					}
				}
			} label: {
				Text(isCollapsed ? "Show more…" : "Show less")
					.font(fontPreset.subheadlineFont)
					.foregroundColor(.blue)
			}
			.buttonStyle(.plain)
		}
	}

	@ViewBuilder
	private var assistantContent: some View {
		VStack(alignment: .leading, spacing: 8) {
			ForEach(parsedContent, id: \.id) { item in
				contentItem(for: item)
			}
		}
		.frame(maxWidth: .infinity, alignment: .topLeading)
	}

	@ViewBuilder
	private func contentItem(for item: ContentItem) -> some View {
		switch item.type {
		case .text:
			TextContentView(
				text: item.content,
				isMarkdown: shouldRenderMarkdown,
				allowInteraction: isFinalized
			)
			.equatable()
		case .code:
			// Code blocks are no longer split out by the parser
			// They're embedded in .text items and rendered by markdown
			// Keep this case for backwards compatibility
			TextContentView(
				text: item.content,
				isMarkdown: false,
				allowInteraction: isFinalized
			)
			.equatable()
		case .file:
			let isLastContentItem = parsedContent.last?.id == item.id
			FileChangeView(
				fileChange: item,
				message: message,
				viewModel: viewModel,
				isLatestMessage: isLatestMessage,
				isLastContentItem: isLastContentItem
			)
			.equatable()
		}
	}
}

/// TextContentView is now defined in Common/Markdown/MarkdownTextView.swift
private typealias TextContentView = MarkdownTextView

// MARK: - Additional Views

/// MARK: - Updated to pass in `hasFailedDelegateEdits` from parent

private struct MergeReadinessWrapper: View {
	let message: AIChatMessage
	@ObservedObject var viewModel: ChatViewModel
	let isLatestMessage: Bool
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	private func hasFailedDelegateEdits(for message: AIChatMessage) -> Bool {
		guard let tasks = viewModel.delegateEditTasks[message.id] else { return false }
		return tasks.contains { task in
			switch task.status {
			case .failed,
				.partialFailed:
				return true
			default:
				return false
			}
		}
	}
	
	var body: some View {
		let failedEdits = hasFailedDelegateEdits(for: message)
		let shouldShowMergeContent = message.isFinalized && (message.hasParseableContent || failedEdits)
		let shouldShowProgress = !message.isFinalized && !message.content.isEmpty && !message.isUser

		// Always render container to minimize layout thrashing in List
		VStack(alignment: .leading, spacing: 6) {
			if shouldShowMergeContent {
				HStack {
					Text("Merge Readiness:").bold()

					ParsingStatusIndicatorView(
						message: message,
						hasFailedDelegateEdits: failedEdits
					)

					if message.parsedFileCount > 0 || message.totalChangeCount > 0 {
						Text("Parsed \(message.parsedFileCount) file(s), created \(message.totalChangeCount) change(s)")
							.font(fontPreset.captionFont)
							.foregroundColor(.secondary)
					}
				}

				if message.parsingStatus == .partiallyParsed {
					Text("Not all parsed changes produced diffs (model may have rewritten without changes)")
						.font(fontPreset.captionFont)
						.foregroundColor(BubbleColors.warningYellow)
						.padding(.top, 2)
				}

				// Only show buttons when parsing is done or there are failed edits
				if message.parsingStatus != .notYetParsed || failedEdits {
					MergeButtonsWrapper(
						message: message,
						viewModel: viewModel,
						isLatestMessage: isLatestMessage,
						hasFailedDelegateEdits: failedEdits
					)
				}

				if !message.loadErrors.isEmpty {
					ErrorMessagesBubbleView(errors: message.loadErrors)
						.padding(.vertical, 4)
				}
			} else if shouldShowProgress {
				ProgressView()
					.scaleEffect(0.4)
					.frame(height: 20)
					.frame(maxWidth: .infinity, alignment: .leading)
			}
		}
		.frame(height: (shouldShowMergeContent || shouldShowProgress) ? nil : 0)
		.clipped()
		.opacity((shouldShowMergeContent || shouldShowProgress) ? 1 : 0)
	}
}

// MARK: - Modified ParsingStatusIndicatorView

private struct ParsingStatusIndicatorView: View {
	let message: AIChatMessage
	let hasFailedDelegateEdits: Bool
	
	var body: some View {
		if message.parsingStatus == .notYetParsed && hasFailedDelegateEdits {
			Image(systemName: "xmark.circle.fill").foregroundColor(BubbleColors.errorRed)
		} else {
			switch message.parsingStatus {
			case .notYetParsed:
				ProgressView()
					.scaleEffect(0.4)
			case .fullyParsed:
				Image(systemName: "checkmark.circle.fill")
					.foregroundColor(BubbleColors.successGreen)
			case .partiallyParsed:
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundColor(BubbleColors.warningYellow)
			case .notParsed:
				Image(systemName: "xmark.circle.fill")
					.foregroundColor(BubbleColors.errorRed)
			}
		}
	}
}

// MARK: - MergeButtonsWrapper

private struct MergeButtonsWrapper: View {
	let message: AIChatMessage
	@ObservedObject var viewModel: ChatViewModel
	let isLatestMessage: Bool
	
	/// Pass it in from the parent so we only compute once
	let hasFailedDelegateEdits: Bool
	
	// MARK: – Aggregate progress helpers
	private var changeStats: (accepted: Int, total: Int) {
		guard
			let files = viewModel.aiResponseViewModel.getChangedFiles(forQueryId: message.id)
		else { return (0, 0) }
		
		let accepted = files.reduce(0) { $0 + $1.acceptedChangeCount }
		let total    = files.reduce(0) { $0 + $1.proposedChangeCount }
		return (accepted, total)
	}
	
	/// Accepted-ratio for the "Accept All" button
	private var acceptProgress: Double {
		let (a, t) = changeStats
		guard t > 0 else { return 0 }
		return Double(a) / Double(t)
	}
	
	/// Remaining-ratio for the "Restore" button (0 when fully restored)
	private var restoreProgress: Double {
		let (a, t) = changeStats
		guard t > 0 else { return 0 }
		return Double(t - a) / Double(t)
	}
	
	func triggerButtonAction() {
		Task {
			await viewModel.parseAndMergeChanges(forMessageId: message.id)

			/*
			if isLatestMessage {
				await viewModel.parseAndMergeChanges(forMessageId: message.id)
			} else {
				await viewModel.restoreChanges(forMessageId: message.id)
			}
			*/
		}
	}
	
	var body: some View {
		HStack(spacing: 8) {
			Button("Review Changes", action: triggerButtonAction)
				.buttonStyle(CustomButtonStyle())
				.disabled(
					message.parsingStatus == .notYetParsed
					|| message.parsingStatus == .notParsed
				)
			
			// NEW: Accept All
			Button(action: {
				Task { await viewModel.acceptAllAndSave(forMessageId: message.id) }
			}) {
				HStack(spacing: 6) {
					MiniProgressRing(progress: acceptProgress,
										iconSystemName: "checkmark")
					Text("Accept All")
				}
			}
			.buttonStyle(CustomButtonStyle())
			.disabled(message.parsingStatus == .notYetParsed
						|| message.parsingStatus == .notParsed
						|| !message.hasAnyFileChanges)
			.hoverTooltip("Apply every change in this message and save")
			
			// NEW: Restore Checkpoint
			Button(action: {
				Task { await viewModel.restoreCheckpoint(forMessageId: message.id) }
			}) {
				HStack(spacing: 6) {
					MiniProgressRing(progress: restoreProgress,
										iconSystemName: "arrow.uturn.backward")
					Text("Restore Checkpoint")
				}
			}
			.buttonStyle(CustomButtonStyle())
			.disabled(message.parsingStatus == .notYetParsed
						|| message.parsingStatus == .notParsed
						|| !message.hasAnyFileChanges)
			.hoverTooltip("Restore to the file state captured\nwhen this message was created")
			
			// Retry failed edits (if any)
			if hasFailedDelegateEdits {
				Button(action: {
					viewModel.retriggerDelegateEdits(forMessageId: message.id)
				}) {
					HStack(spacing: 4) {
						Image(systemName: "arrow.counterclockwise")
						Text("Retry Failed Edits")
					}
				}
				.buttonStyle(CustomButtonStyle())
				.hoverTooltip("Retry failed code edits")
			}
			
			// Refresh
			Button(action: {
				viewModel.refreshFileChanges(forMessageId: message.id)
			}) {
				Image(systemName: "arrow.clockwise")
			}
			.buttonStyle(CustomButtonStyle())
			.hoverTooltip("Refresh file changes")
		}
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

// MARK: - Additional Views

struct FileChangeView: View, Equatable {
	let fileChange: ContentItem
	let message: AIChatMessage
	@ObservedObject var viewModel: ChatViewModel
	let isLatestMessage: Bool
	let isLastContentItem: Bool
	@Environment(\.colorScheme) private var colorScheme
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	// NEW: toggles the delegate-edit response popover
	@State private var showEditResponse = false

	static func == (lhs: FileChangeView, rhs: FileChangeView) -> Bool {
		lhs.fileChange.id == rhs.fileChange.id &&
		lhs.fileChange.changes == rhs.fileChange.changes &&
		lhs.isLatestMessage == rhs.isLatestMessage &&
		lhs.isLastContentItem == rhs.isLastContentItem &&
		lhs.message.isFinalized == rhs.message.isFinalized
	}
	
	// Extracted error message lookup
	private func errorMessage(for status: DelegateEditTask.TaskStatus) -> String? {
		switch status {
		case .failed(reason: .fileNotSelected):
			return "File is not selected - Please select the file and try again"
		case .failed(reason: .streamError):
			return "Stream resulted in error. This may be a rate limit issue."
		case .failed(reason: .fileLoadError):
			return "Failed to load file content - Please try again"
		case .noChangesMade:
			return "No changes were made"
		case .partialFailed:
			return "Some requested edits failed or were not applied"
		default:
			return nil
		}
	}
	
	// Header section
	private var header: some View {
		HStack {
			Text(fileChange.filePath)
				.font(fontPreset.subheadlineFont)
				.lineLimit(1)
				.truncationMode(.head)
			Spacer()
			ActionLabel(action: fileChange.action)
		}
	}

	private var changesSection: some View {
		ForEach(fileChange.changes.indices, id: \.self) { index in
			let change = fileChange.changes[index]
			let isLastChange = index == fileChange.changes.count - 1
			let shouldShowProgressIndicator = !message.isFinalized && isLastChange && isLastContentItem

			CollapsibleChangeRow(
				index: index,
				fileChange: fileChange,
				change: change,
				isLatestMessage: isLatestMessage,
				message: message,
				shouldShowProgressIndicator: shouldShowProgressIndicator
			)
			.padding(.vertical, 4)
		}
	}

	private struct CollapsibleChangeRow: View {
		let index: Int
		let fileChange: ContentItem
		let change: String
		let isLatestMessage: Bool
		let message: AIChatMessage
		let shouldShowProgressIndicator: Bool
		@ObservedObject private var fontScale = FontScaleManager.shared
		private var fontPreset: FontScalePreset { fontScale.preset }

		@State private var isCollapsed: Bool

		init(
			index: Int,
			fileChange: ContentItem,
			change: String,
			isLatestMessage: Bool,
			message: AIChatMessage,
			shouldShowProgressIndicator: Bool = false
		) {
			self.index = index
			self.fileChange = fileChange
			self.change = change
			self.isLatestMessage = isLatestMessage
			self.message = message
			self.shouldShowProgressIndicator = shouldShowProgressIndicator
			// Auto-collapse if not the latest message
			_isCollapsed = State(initialValue: !isLatestMessage)
		}

		var body: some View {
			VStack(alignment: .leading, spacing: 6) {
				Text("Change \(index + 1)")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)

				// Description box - entire area is clickable
				if index < fileChange.descriptions.count,
					!fileChange.descriptions[index].isEmpty {
					HStack(alignment: .center) {
						Text(fileChange.descriptions[index])
							.font(fontPreset.font)
							.textSelection(.disabled) // so you can click anywhere
							.lineLimit(1)

						Spacer()

						// Show progress indicator if needed
						if shouldShowProgressIndicator {
							ProgressView()
								.progressViewStyle(CircularProgressViewStyle())
								.scaleEffect(0.5)
								.frame(width: 16, height: 16)
								.padding(.trailing, 4)
						}

						// Chevron icon, rotates when expanded
						Image(systemName: "chevron.right")
							.rotationEffect(.degrees(isCollapsed ? 0 : 90))
					}
					.padding(8)
					.background(BubbleColors.lightBlue)
					.cornerRadius(8)
					.overlay(
						RoundedRectangle(cornerRadius: 8)
							.stroke(BubbleColors.borderBlue, lineWidth: 1)
					)
					// Make the entire rectangle clickable
					.onTapGesture {
						isCollapsed.toggle()
					}
				}

				// Code block: expands beneath the description
				if !isCollapsed && !change.isEmpty {
					CodeBlockView(
						code: change,
						allowInteraction: message.isFinalized
					)
					.padding(.vertical, 4)
				}
			}
			.onChange(of: isLatestMessage) { _, newValue in
				if !newValue {
					// When no longer the latest message, collapse instantly
					isCollapsed = true
				}
			}
		}
	}
	
// ─────────────────────────────────────────────────────────────
/// Clickable pill that shows token use, status & error on one line,
/// highlights on hover, and opens the edit-response pop-over.
private struct EditTaskClickableView: View {
	let task: DelegateEditTask
	let tokenText: String
	let errorText: String?
	@Binding var showPopover: Bool

	@State private var isHovering = false
	@Environment(\.colorScheme) private var colorScheme
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	var body: some View {
		Button(action: { showPopover.toggle() }) {
			HStack(spacing: 6) {
				// Leading icon to denote "view details"
				Image(systemName: "doc.text.magnifyingglass")
					.foregroundColor(isHovering ? .primary : .secondary)

				Text(tokenText)
					.font(fontPreset.captionFont)
					.foregroundColor(.primary)
	
				// Show tool usage with orange gear icon when in progress
				if task.status == .inProgress, let tool = task.lastToolUsed {
					Image(systemName: "gearshape.fill")
						.font(fontPreset.swiftUIFont(sizeAtNormal: 10))
						.foregroundColor(.orange)
					Text(tool)
						.font(fontPreset.captionFont)
						.foregroundColor(.orange)
						.transition(.opacity.combined(with: .scale(scale: 0.8)))
						.id("tool-\(tool)") // Force re-render when tool changes
				}
	
				ProgressIndicator(status: task.status)
					.frame(width: 12, height: 12)

				// Inline error text if any
				if let err = errorText {
					Text("— \(err)")
						.font(fontPreset.captionFont)
						.foregroundColor(BubbleColors.errorRed)
				}
			}
			.padding(.horizontal, 4)
			.padding(.vertical, 2)
			.fixedSize(horizontal: false, vertical: true) // keep intrinsic width to avoid full-row stretch
			.background(isHovering ? BubbleColors.mediumBlue : BubbleColors.lightBlue)
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(BubbleColors.borderBlue, lineWidth: 1)
			)
			.cornerRadius(8)
		}
		.buttonStyle(PlainButtonStyle())
		.onHover { hovering in
			withAnimation(.easeInOut(duration: 0.1)) {
				isHovering = hovering
			}
		}
		.popover(isPresented: $showPopover) {
			EditResponsePopover(task: task)
		}
	}
}
// ─────────────────────────────────────────────────────────────
	// Helper to format token display
	private func tokenDisplay(for task: DelegateEditTask) -> String {
		func fmt(_ n: Int) -> String { String(format: "%.2fk", Double(n) / 1_000.0) }

		// Show agent/model name directly (not "File edit using X")
		let agentName = task.modelDisplayName.isEmpty ? "Delegate edit" : task.modelDisplayName

		// During progress, just show "In progress..." (tool shown separately with gear icon)
		if task.status == .inProgress {
			return "\(agentName): In progress..."
		}

		// When completed, prefer the final token counts if non-zero
		if (task.status == .completed || task.status == .noChangesMade),
		   let p = task.promptTokens,
		   let c = task.completionTokens,
		   (p != 0 || c != 0) {
			return "\(agentName): \(fmt(p)) in | \(fmt(c)) out"
		}

		// Fallback: show the rough streamed estimate
		if task.tokenEstimate > 0 {
			return "\(agentName): ~\(fmt(task.tokenEstimate)) tokens"
		}

		return agentName
	}
	
	// Tasks section
private var tasksSection: some View {
	Group {
		if let tasks = viewModel.delegateEditTasks[message.id],
		let task = tasks.first(where: { $0.filePath == fileChange.filePath }) {
			
			EditTaskClickableView(
				task: task,
				tokenText: tokenDisplay(for: task),
				errorText: errorMessage(for: task.status),
				showPopover: $showEditResponse
			)
			// Disable until we have some streamed output or the task finishes
			.disabled(
				task.accumulatedOutput.isEmpty ||
				task.status == .pending ||
				task.status == .inProgress
			)
			.id(task.id)                // Force refresh when task changes
			.padding(.vertical, 4)
			.frame(maxWidth: .infinity, alignment: .leading) // keep row alignment while pill keeps fixed width
		}
	}
}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			header
			changesSection
			tasksSection
		}
		.padding(8)
		.background(BubbleColors.fileChangeBackground)
		.cornerRadius(8)
	}
}

struct ActionLabel: View {
	let action: String
	@Environment(\.colorScheme) private var colorScheme
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		Text(action)
			.font(fontPreset.captionFont)
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(BubbleColors.mediumBlue(colorScheme: colorScheme))
			.cornerRadius(4)
	}
}

struct ProgressIndicator: View {
	let status: DelegateEditTask.TaskStatus
	
	var body: some View {
		switch status {
		case .pending:
			Image(systemName: "circle")
				.foregroundColor(BubbleColors.neutralGray)
				//.font(fontPreset.captionFont)
		case .inProgress:
			ProgressView()
				.progressViewStyle(CircularProgressViewStyle())
				.scaleEffect(0.5)
		case .completed:
			Image(systemName: "checkmark.circle.fill")
				.foregroundColor(BubbleColors.successGreen)
				//.font(fontPreset.captionFont)
		case .noChangesMade:
			Image(systemName: "info.circle.fill")
				.foregroundColor(BubbleColors.mediumBlue)
		case .partialFailed:
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundColor(BubbleColors.warningYellow)
				//.font(fontPreset.captionFont)
		case .failed:
			Image(systemName: "xmark.circle.fill")
				.foregroundColor(BubbleColors.errorRed)
				//.font(fontPreset.captionFont)
		}
	}
}

/// CodeBlock and CodeBlockView are now defined in Common/CodeBlockView.swift
/// CodeBlockView is now SyntaxHighlightedCodeBlock in Common/CodeBlockView.swift
private typealias CodeBlockView = SyntaxHighlightedCodeBlock

/// A small bubble view for displaying errors (e.g. unloadable files).
private struct ErrorMessagesBubbleView: View {
	let errors: [String]
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		VStack(alignment: .leading, spacing: 4) {
			ForEach(errors, id: \.self) { errorMsg in
				Text(errorMsg)
					.font(fontPreset.captionFont)
			}
		}
		.padding(8)
		.background(BubbleColors.errorBackground)
		.cornerRadius(12)
		.frame(maxWidth: .infinity, alignment: .leading)
	}
}

// MARK: – Content-sized text view (reports both width and height)

// MARK: - Shared Components
// CollapsibleUserMessage and ContentSizedTextView are now in Common/CollapsibleUserMessage.swift
