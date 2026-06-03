import SwiftUI
import Combine
import AppKit

struct FilePreviewView: View {
	@ObservedObject var viewModel: AIResponseViewModel
	@ObservedObject var response: ChangedFile
	let fileManager: RepoFileManagerViewModel
	@State private var isEditing: Bool = false
	@State private var editedContent: String = ""
	@State private var allDisplayLines: [DisplayLine] = []
	@State private var currentChangeIndex: Int = 0
	
	@State private var currentHoveredLineIndex: Int?
	@State private var isPerformingDrag = false
	
	@State var currentScrollProxy: ScrollViewProxy?
	@State private var showingChangePopover = false
	@State private var showingSvgWarning = false
	@State private var pendingRebuildTask: Task<Void, Never>? = nil
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }


	// New multi-mode selection model (supports Cmd/Shift/erase)
	@State private var selectedIndices: Set<Int> = []
	@State private var anchorIndex: Int? = nil
	@State private var dragInitialSelection: Set<Int> = []
	@State private var dragAnchorIndex: Int? = nil
	private enum DragMode { case select, erase }
	@State private var dragMode: DragMode? = nil

	// Scroll throttling coordinator – persist across view reloads
	private final class ScrollState: ObservableObject {
		var lastSavedScrollY: CGFloat = 0
	}
	@StateObject private var scrollState = ScrollState()
	


	private func lineCountFromPixelDelta(_ delta: CGFloat) -> Int {
		Int(ceil(delta / CodeViewMetrics.lineHeight))
	}
	
	private func onScroll(origin: CGPoint) {
		if abs(origin.y - scrollState.lastSavedScrollY) >= CodeViewMetrics.lineHeight {
			scrollState.lastSavedScrollY = origin.y
			response.updateScrollPosition(-origin.y)
		}
	}
	
	private func resetDragState() {
		isPerformingDrag = false
	}
	
	var body: some View {
		ZStack(alignment: .topLeading) {
			mainContent()
			// Removed copyButtonIfNeeded from here - moved to ScrollView overlay
		}
		.contentShape(Rectangle())
		.onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
			resetDragState()
		}
		.onAppear {
			resetSelectionState()
			updateAllDisplayLines()
		}
		.onDisappear {
			resetDragState()
			pendingRebuildTask?.cancel()
			pendingRebuildTask = nil
		}
	}
	
	private func mainContent() -> some View {
		let scrollContent = makeScrollContent()
		
		return VStack(spacing: 0) {
			Divider()
			topBarView
			
			// For extremely large files, show disabled view instead of rendering full diff
			if response.isPreviewDisabled {
				svgDisabledView
			} else {
				ScrollViewReader { scrollProxy in
					makeScrollView(scrollProxy: scrollProxy, content: scrollContent)
				}
			}
		}
		.onChange(of: response.fileContent) { _, _ in
			scheduleRebuildLines()
		}
		.onChange(of: response.appliedChanges) { _, _ in
			scheduleRebuildLines()
		}
		.onChange(of: response.rejectedChanges) { _, _ in
			scheduleRebuildLines()
		}
		.onChange(of: response.changes) { _, _ in
			scheduleRebuildLines()
		}
		.onChange(of: response.relativePath) { _, _ in
			scheduleRebuildLines()
		}
	}
	
	private func makeScrollContent() -> some View {
		LineListView(
			allDisplayLines: allDisplayLines,
			response: response,
			currentChangeIndex: currentChangeIndex,
lineNumberWidth: CodeViewMetrics.lineNumberWidth,
								symbolWidth: CodeViewMetrics.symbolWidth,
			isPerformingDrag: isPerformingDrag,
			selectedIndices: selectedIndices,
			currentHoveredLineIndex: $currentHoveredLineIndex,
			viewModel: viewModel,
			onDragUpdate: { _ in }, // legacy per-row drag no-op
			onUpdateDragSelection: { idx in
				updateDragSelection(to: idx) // explicit label avoids ambiguity
			}
		)
	}
	
	private func makeScrollView(scrollProxy: ScrollViewProxy, content: some View) -> some View {
		ScrollView(.vertical, showsIndicators: true) {
			content
				.contentShape(Rectangle()) // Ensure full-area hit testing
				.coordinateSpace(name: "codeContent") // Coordinate space for gesture
				.contextMenu {
					if !selectedIndices.isEmpty {
						Button("Copy selected lines", action: copySelectedLines)
						Divider()
						Button("Clear selection", action: clearSelection)
					}
				}
				// Selection drag gesture across rows (non-preemptive; respects buttons)
				.simultaneousGesture(
					DragGesture(minimumDistance: 3)
						.onChanged { value in
							if !isPerformingDrag {
								// Prefer the last known hovered line to match user intent exactly.
								if let hovered = currentHoveredLineIndex,
									let start = nearestSelectableIndex(from: hovered) {
									onDragBegan(at: start)
								} else {
									// Fallback: use the gesture's startLocation mapped to an index.
									let guess = indexForLocation(value.startLocation)
									if let start = nearestSelectableIndex(from: guess) {
										onDragBegan(at: start)
									}
								}
							} else {
								// Ongoing drag – update to current pointer location mapped to index.
								let idx = indexForLocation(value.location)
								updateDragSelection(to: idx)
							}
						}
						.onEnded { _ in
							onDragEnded()
						}
				)
				// High-priority double-click to select the logical diff block (ensures it wins over single-click)
				.highPriorityGesture(
					TapGesture(count: 2)
						.onEnded {
							if let idx = currentHoveredLineIndex {
								selectLogicalBlock(at: idx)
							}
						}
				)
				// Single-click handling (Cmd/Shift toggles) without interfering with double-click
				.simultaneousGesture(
					TapGesture(count: 1)
						.onEnded {
							guard !isPerformingDrag else { return }
							if let idx = currentHoveredLineIndex {
								let mods = NSApp.currentEvent?.modifierFlags ?? []
								handleClick(at: idx, modifiers: mods)
							}
						}
				)
		}
		.coordinateSpace(name: "scroll")
		.overlay {
			ScrollOffsetReader { origin in
				onScroll(origin: origin)
			}
			.allowsHitTesting(false) // Critical: don't block mouse events
		}
		.overlay(alignment: .topTrailing) {
			if !selectedIndices.isEmpty {
				SelectionHUDView(
					selectedCount: selectedIndices
						.filter { idx in
							idx >= 0 && idx < allDisplayLines.count && !allDisplayLines[idx].showSummary
						}
						.count,
					linePreview: selectionLineNumbersPreview(),
					onCopy: copySelectedLines,
					onClear: clearSelection
				)
				.padding(.top, 8)
				.padding(.trailing, 8)
				.transition(.move(edge: .top).combined(with: .opacity))
				.zIndex(10)
			}
		}
		.overlay {
			// Hidden keyboard target for Cmd+C
			Button("", action: copySelectedLines)
				.keyboardShortcut("c", modifiers: .command)
				.opacity(0)
				.allowsHitTesting(false)
		}
		.onChange(of: currentChangeIndex) { _, newIndex in
			scrollToChange(newIndex, proxy: scrollProxy)
		}
		.onAppear {
			handleInitialScroll(proxy: scrollProxy)
		}
		.onChange(of: viewModel.selectedFileId) { _, newId in
			// Clear any existing selection when switching files
			clearSelection()
			if let newId = newId {
				handleFileChange(newId: newId, proxy: scrollProxy)
			}
		}
	}
	
	private struct LineListView: View {
		let allDisplayLines: [DisplayLine]
		let response: ChangedFile
		let currentChangeIndex: Int
		let lineNumberWidth: CGFloat
		let symbolWidth: CGFloat
		let isPerformingDrag: Bool
		let selectedIndices: Set<Int>
		@Binding var currentHoveredLineIndex: Int?
		let viewModel: AIResponseViewModel
		let onDragUpdate: (Int) -> Void  // Keep original signature
		let onUpdateDragSelection: (Int) -> Void  // Add this parameter
		
		var body: some View {
			LazyVStack(alignment: .leading, spacing: 0) {
				ForEach(Array(allDisplayLines.enumerated()), id: \.element.id) { index, displayLine in
					LineView(
						lineNumber: displayLine.lineNumber,
						content: displayLine.content,
						change: displayLine.change,
						changeLineIndex: displayLine.changeLineIndex,
						lineNumberWidth: lineNumberWidth,
						symbolWidth: symbolWidth,
						changeState: displayLine.changeState,
						showSummary: displayLine.showSummary,
						isSelected: selectedIndices.contains(index),
						lineIndex: index,
						onHover: { index in
							currentHoveredLineIndex = index
							if isPerformingDrag {
								onUpdateDragSelection(index)  // Call the passed function
							}
						},
						onDragUpdate: onDragUpdate,
						isChangeApplied: displayLine.changeState == .accepted,
						isChangeRejected: displayLine.changeState == .rejected,
						onAccept: {
							Task { await viewModel.acceptChangeAndSave(displayLine.change, in: response) }
						},
						onReject: {
							Task { await viewModel.rejectChangeAndSave(displayLine.change, in: response) }
						},
						onUndoAccept: {
							viewModel.undoChange(displayLine.change, in: response)
							Task { try? await viewModel.saveChanges(for: response) }
						},
						onUndoReject: {
							Task { await viewModel.undoRejectChangeAndSave(displayLine.change, in: response) }
						}
					)
					.id(displayLine.id)
					.background(
						displayLine.change.id == response.changes[safe: currentChangeIndex]?.id ?
						Color.gray.opacity(0.01) : Color.clear
					)
				}
			}
			//.contentShape(Rectangle())
		}
	}
	
	private func copySelectedLines() {
		guard !selectedIndices.isEmpty else { return }
		let text = selectedIndices
			.sorted()
			.compactMap { idx -> String? in
				guard idx >= 0 && idx < allDisplayLines.count else { return nil }
				let line = allDisplayLines[idx]
				return line.showSummary ? nil : line.content
			}
			.joined(separator: "\n")
		
		let pasteboard = NSPasteboard.general
		pasteboard.clearContents()
		pasteboard.setString(text, forType: .string)
	}
	
	
	private func handleInitialScroll(proxy: ScrollViewProxy) {
		currentScrollProxy = proxy
		DispatchQueue.main.async {
			if let selectedChangeId = viewModel.selectedChangeId,
				let changeIndex = response.changes.firstIndex(where: { $0.id == selectedChangeId }) {
				currentChangeIndex = changeIndex
				scrollToChange(changeIndex, proxy: proxy)
			} else {
				currentChangeIndex = 0
				scrollToChange(0, proxy: proxy)
			}
		}
	}
	
	private func handleFileChange(newId: UUID, proxy: ScrollViewProxy) {
		// Response is now passed from parent view, so we just reset state
		currentChangeIndex = 0
		resetFullState()
		resetDragState()
		DispatchQueue.main.async {
			scrollToChange(0, proxy: proxy)
		}
	}
	
	func onLineHovered(index: Int) {
		currentHoveredLineIndex = index
		if isPerformingDrag {
			updateDragSelection(to: index)
		}
	}
	
	private func resetSelectionState() {
		selectedIndices.removeAll()
		anchorIndex = nil
	}
	
	private func resetFullState() {
		resetSelectionState()
		updateAllDisplayLines()
	}
	
	private func findLineIndex(at windowPoint: NSPoint) -> Int? {
		guard let window = NSApplication.shared.mainWindow,
				let contentView = window.contentView,
				let scrollView = findScrollView(in: contentView) else {
			print("Could not find scroll view")
			return nil
		}
		
		// Convert window coordinates to scroll view's document coordinate space
		let localPoint = scrollView.documentView?.convert(windowPoint, from: nil) ?? .zero
		
		// Create view point accounting for scroll
		let viewPoint = NSPoint(
			x: localPoint.x,
			y: localPoint.y
		)
		
		// Calculate index based on Y position
		let lineIndex = Int(viewPoint.y / CodeViewMetrics.lineHeight)
		if lineIndex >= 0 && lineIndex < allDisplayLines.count &&
			!allDisplayLines[lineIndex].showSummary {
			return lineIndex
		}
		
		return nil
	}

	// Helper function to find the ScrollView in the view hierarchy
	private func findScrollView(in view: NSView) -> NSScrollView? {
		if let scrollView = view as? NSScrollView {
			return scrollView
		}
		
		for subview in view.subviews {
			if let found = findScrollView(in: subview) {
				return found
			}
		}
		
		return nil
	}
	
	
	private var topBarView: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Row 1: full-width path (leading) with optional SVG warning
			HStack(spacing: 6) {
				Text(response.relativePath)
					.font(fontPreset.headlineFont)
					.textSelection(.enabled)
					.lineLimit(1)
					.truncationMode(.head)

				// SVG warning indicator - always in tree, opacity controlled
				Button {
					showingSvgWarning = true
				} label: {
					Image(systemName: "exclamationmark.triangle.fill")
						.foregroundColor(.orange)
						.font(.subheadline)
				}
				.buttonStyle(.plain)
				.opacity(response.isSvgHighRisk && !response.isPreviewDisabled ? 1 : 0)
				.popover(isPresented: $showingSvgWarning) {
					VStack(alignment: .leading, spacing: 8) {
						Text("Large SVG File")
							.font(fontPreset.headlineFont)
						Text("Diff view may be slow. Consider reviewing in your editor.")
							.font(fontPreset.subheadlineFont)
							.foregroundColor(.secondary)
					}
					.padding()
					.frame(width: fontPreset.scaledMetric(250))
				}

				Spacer()
			}

			// Row 2: controls below
			HStack(alignment: .center, spacing: 16) {
				// Left: processed count and optional change overview
				VStack(alignment: .leading, spacing: 4) {
					Text("Processed: \(processedChangeCount)/\(response.proposedChangeCount)")
						.font(fontPreset.subheadlineFont)
						.foregroundColor(.secondary)
						.lineLimit(1)
						.truncationMode(.head)
					
					if let contentItem = response.contentItem {
						Button {
							showingChangePopover = true
						} label: {
							HStack {
								Image(systemName: "list.bullet.rectangle")
								Text("Change Overview")
									.lineLimit(1)
									.truncationMode(.tail)
							}
						}
						.buttonStyle(CustomButtonStyle())
						.popover(isPresented: $showingChangePopover) {
							FileChangePopoverView(contentItem: contentItem)
						}
					}
				}
				
				Spacer()
				
				// Center: navigation cluster
				VStack(spacing: 4) {
					HStack(spacing: 8) {
						Button(action: navigateToPreviousChange) {
							Image(systemName: "chevron.up")
						}
						.buttonStyle(SmallRoundButtonStyle())
						.keyboardShortcut(.upArrow, modifiers: .command)
						
						VStack(spacing: 2) {
							Text("Navigate changes")
								.font(fontPreset.swiftUIFont(sizeAtNormal: 11))
								.foregroundColor(.secondary)
								.lineLimit(1)
								.truncationMode(.tail)
							Text("⌘ ↑/↓")
								.font(fontPreset.captionFont)
								.foregroundColor(.secondary)
						}
						
						Button(action: navigateToNextChange) {
							Image(systemName: "chevron.down")
						}
						.buttonStyle(SmallRoundButtonStyle())
						.keyboardShortcut(.downArrow, modifiers: .command)
					}
					.padding(.horizontal, 12)
					.padding(.vertical, 6)
					.background(Color.clear)
					.overlay(
						RoundedRectangle(cornerRadius: 8)
							.stroke(Color.secondary, lineWidth: 0.3)
					)
				}
				
				Spacer()
				
				// Right: action buttons
				HStack(spacing: 8) {
					Button(action: acceptAllAndSave) {
						HStack(spacing: 4) {
							Image(systemName: "checkmark.circle")
							Text(acceptAllButtonTitle)
								.lineLimit(1)
								.truncationMode(.tail)
						}
					}
					.buttonStyle(CustomButtonStyle())
					.disabled(isAcceptAllDisabled)

					Button(action: resetAndSave) {
						HStack(spacing: 4) {
							Image(systemName: "arrow.counterclockwise")
							Text("Reset")
								.lineLimit(1)
								.truncationMode(.tail)
						}
					}
					.buttonStyle(CustomButtonStyle())
				}
				.padding(.horizontal, 12)
				.padding(.vertical, 6)
				.background(Color.clear)
				.overlay(
					RoundedRectangle(cornerRadius: 8)
						.stroke(Color.secondary, lineWidth: 0.3)
				)
			}
		}
		.padding()
		.background(Color(NSColor.controlBackgroundColor).opacity(0.5))
	}

	/// Disabled view shown for extremely large SVG files to prevent hangs.
	private var svgDisabledView: some View {
		VStack(spacing: 16) {
			Image(systemName: "exclamationmark.shield.fill")
				.font(.system(size: 48))
				.foregroundColor(.orange)
			Text("Diff Preview Disabled")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 22, weight: .semibold))
			Text("This SVG file is too large to safely render in the diff view.")
				.font(fontPreset.standardFont)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
			Text("Use the Accept/Reject controls above, or review the changes in your editor.")
				.font(fontPreset.captionFont)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
			
			// Still show change count info
			Text("\(response.proposedChangeCount) change(s) proposed")
				.font(fontPreset.subheadlineFont)
				.foregroundColor(.secondary)
				.padding(.top, 8)
		}
		.padding(40)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
		.background(Color(NSColor.windowBackgroundColor).opacity(0.5))
	}
	
	/*
		HStack {
		
		Button(action: undoLastChangeAndSave) {
		Image(systemName: "arrow.uturn.backward")
		}
		.buttonStyle(SmallRoundButtonStyle())
		.disabled(viewModel.changeHistory.isEmpty)
		Button(action: redoLastChangeAndSave) {
		Image(systemName: "arrow.uturn.forward")
		}
		.buttonStyle(SmallRoundButtonStyle())
		.disabled(viewModel.redoStack.isEmpty)
		Button(action: { isEditing.toggle() }) {
		Text(isEditing ? "Done" : "Edit")
		}
		.buttonStyle(CustomButtonStyle())
		
		}
		*/
	 
	private var editingView: some View {
		TextEditor(text: $editedContent)
			.font(.system(.body, design: .monospaced))
			.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	
	// Removed legacy fileContentView - no longer used
	
	private func scrollToChange(_ index: Int, proxy: ScrollViewProxy) {
		if let change = response.changes[safe: index],
			let lineIndex = allDisplayLines.firstIndex(where: { $0.change.id == change.id }) {
			withAnimation {
				proxy.scrollTo(allDisplayLines[lineIndex].id, anchor: .top)
			}
		}
	}
	
	private var navigationButtons: some View {
		HStack {
			Button(action: navigateToPreviousChange) {
				Image(systemName: "chevron.up")
			}
			.buttonStyle(SmallRoundButtonStyle())
			.keyboardShortcut(.upArrow, modifiers: .command)
			
			Button(action: navigateToNextChange) {
				Image(systemName: "chevron.down")
			}
			.buttonStyle(SmallRoundButtonStyle())
			.keyboardShortcut(.downArrow, modifiers: .command)
		}
	}
	
	private func updateAllDisplayLines() {
		allDisplayLines = getDisplayLines()
	}
	
	private func getDisplayLines() -> [DisplayLine] {
		return Self.buildDisplayLines(
			fileContent: response.fileContent,
			changes: response.changes,
			applied: response.appliedChanges,
			rejected: response.rejectedChanges
		)
	}
	
	// Pure function for building display lines - can be run off main thread
	static func buildDisplayLines(
		fileContent: [String],
		changes: [FileChange],
		applied: Set<UUID>,
		rejected: Set<UUID>
	) -> [DisplayLine] {
		var displayLines: [DisplayLine] = []
		var fileLineIndex = 0
		var adjustedLineNumber = 0
		
		// Sort changes by their startLine to ensure stable rendering order
		let sortedChanges = changes.sorted { $0.startLine < $1.startLine }
		
		for change in sortedChanges {
			// Add lines up to this change
			while fileLineIndex < change.startLine {
				if fileLineIndex < fileContent.count {
					displayLines.append(DisplayLine(
						id: .content(adjustedLineNumber),
						lineNumber: adjustedLineNumber,
						content: fileContent[fileLineIndex],
						change: FileChange.dummy,
						changeLineIndex: nil,
						changeState: .pending,
						showSummary: false
					))
					fileLineIndex += 1
					adjustedLineNumber += 1
				}
			}
			
			let changeState: ChangeState = {
				if applied.contains(change.id) {
					return .accepted
				} else if rejected.contains(change.id) {
					return .rejected
				} else {
					return .pending
				}
			}()
			
			// Always show summary for the change
			displayLines.append(DisplayLine(
				id: .summary(change.id),
				lineNumber: nil,
				content: "",
				change: change,
				changeLineIndex: nil,
				changeState: changeState,
				showSummary: true
			))
			
			switch changeState {
			case .accepted:
				// For accepted changes, show the "new" side of the diff, but keep diff metadata
				for (lineIndex, line) in change.diffChunk.lines.enumerated()
				where line.type != .removal {
					guard fileLineIndex < fileContent.count else { break }

					let contentToShow: String
					switch line.type {
					case .addition:
						// Show the added text from the diff
						contentToShow = line.content
					case .context:
						// For context lines, show the actual file content (post-change)
						contentToShow = fileContent[fileLineIndex]
					case .removal:
						// filtered out by where-clause
						continue
					}

					displayLines.append(DisplayLine(
						id: .diff(change.id, lineIndex),
						lineNumber: adjustedLineNumber,
						content: contentToShow,
						change: change,
						changeLineIndex: lineIndex,
						changeState: .accepted,
						showSummary: false
					))

					fileLineIndex += 1
					adjustedLineNumber += 1
				}
			case .pending:
				// For pending changes, show the diff
				for (lineIndex, line) in change.diffChunk.lines.enumerated() {
					displayLines.append(DisplayLine(
						id: .diff(change.id, lineIndex),
						lineNumber: line.type != .addition ? adjustedLineNumber : nil,
						content: line.content,
						change: change,
						changeLineIndex: lineIndex,
						changeState: .pending,
						showSummary: false
					))
					if line.type != .addition {
						fileLineIndex += 1
						adjustedLineNumber += 1
					}
				}
			case .rejected:
				// For rejected changes, skip the change and continue with the original file content
				let linesInChange = change.diffChunk.lines.filter { $0.type != .addition }.count
				for _ in 0..<linesInChange {
					if fileLineIndex < fileContent.count {
						displayLines.append(DisplayLine(
							id: .content(adjustedLineNumber),
							lineNumber: adjustedLineNumber,
							content: fileContent[fileLineIndex],
							change: FileChange.dummy,
							changeLineIndex: nil,
							changeState: .pending,
							showSummary: false
						))
						fileLineIndex += 1
						adjustedLineNumber += 1
					}
				}
			}
		}
		
		// Add remaining lines after the last change
		while fileLineIndex < fileContent.count {
			displayLines.append(DisplayLine(
				id: .content(adjustedLineNumber),
				lineNumber: adjustedLineNumber,
				content: fileContent[fileLineIndex],
				change: FileChange.dummy,
				changeLineIndex: nil,
				changeState: .pending,
				showSummary: false
			))
			fileLineIndex += 1
			adjustedLineNumber += 1
		}
		
		return displayLines
	}
	
	
	private func calculateScrollToId() -> DisplayLine.Key {
		let lineIndex = Int(response.lastScrollPosition / CodeViewMetrics.lineHeight)
		return allDisplayLines[safe: lineIndex]?.id ?? allDisplayLines.first?.id ?? .content(0)
	}
	
	private func navigateToPreviousChange() {
		guard !response.changes.isEmpty else { return }
		let newIndex = (currentChangeIndex - 1 + response.changes.count) % response.changes.count
		// If the index isn't changing (single change case), call scroll directly
		if newIndex == currentChangeIndex {
			if let proxy = currentScrollProxy {
				scrollToChange(newIndex, proxy: proxy)
			}
		}
		currentChangeIndex = newIndex
		viewModel.selectedChangeId = response.changes[currentChangeIndex].id
	}
	
	private func navigateToNextChange() {
		guard !response.changes.isEmpty else { return }
		let newIndex = (currentChangeIndex + 1) % response.changes.count
		// If the index isn't changing (single change case), call scroll directly
		if newIndex == currentChangeIndex {
			if let proxy = currentScrollProxy {
				scrollToChange(newIndex, proxy: proxy)
			}
		}
		currentChangeIndex = newIndex
		viewModel.selectedChangeId = response.changes[currentChangeIndex].id
	}
	
	private func acceptAllAndSave() {
		Task {
			await viewModel.acceptAllAndSave(for: response)
		}
	}
	
	private func rejectAllAndSave() {
		Task {
			await viewModel.rejectAllAndSave(for: response)
		}
	}
	
	private func resetAndSave() {
		Task {
			await viewModel.resetAllAndSave(for: response)
		}
	}
	
	private func undoLastChangeAndSave() {
		Task {
			await viewModel.undoLastChangeAndSave()
		}
	}
	
	private func redoLastChangeAndSave() {
		Task {
			await viewModel.redoLastChangeAndSave()
		}
	}
	
	private func acceptAllChanges() {
		Task {
			await viewModel.acceptAllChangesAndSave(for: response)
		}
	}
	
	private func rejectAllChanges() {
		Task {
			await viewModel.rejectAllChangesAndSave(for: response)
		}
	}
	
	private func saveChanges() {
		Task {
			do {
				try await viewModel.saveChanges(for: response)
			} catch {
				print("Error saving changes: \(error)")
			}
		}
	}
	
	
	private func updateSelection(from startIndex: Int, to endIndex: Int) {
		let clampedStart = max(0, min(startIndex, allDisplayLines.count - 1))
		let clampedEnd = max(0, min(endIndex, allDisplayLines.count - 1))
		let range = clampedStart <= clampedEnd ? clampedStart...clampedEnd : clampedEnd...clampedStart

		var newSet: Set<Int> = []
		for idx in range {
			if idx >= 0 && idx < allDisplayLines.count && !allDisplayLines[idx].showSummary {
				newSet.insert(idx)
			}
		}
		selectedIndices = newSet
	}
	
	private var saveButtonText: String {
		switch response.fileAction {
		case .create:
			return "Create & Save"
		case .delete:
			return "Delete File"
		case .rewrite, .delegateEdit:
			return "Save Changes"
		case .modify:
			return "Save Changes"
		}
	}
	
	private var confirmationDialogTitle: String {
		switch response.fileAction {
		case .create:
			return "Create File"
		case .delete:
			return "Delete File"
		case .rewrite, .delegateEdit:
			return "Save Changes"
		case .modify:
			return "Save Changes"
		}
	}
	
	private var confirmationDialogMessage: String {
		switch response.fileAction {
		case .create:
			return "Are you sure you want to create this file?"
		case .delete:
			return "Are you sure you want to delete this file?"
		case .rewrite, .delegateEdit:
			return "Are you sure you want to save the changes to this file?"
		case .modify:
			return "Are you sure you want to save the changes to this file?"
		}
	}
	
	private func initializeSelection(at index: Int) {
		selectedIndices = [index]
		anchorIndex = index
	}
	
	/*
	// In FilePreviewView.swift, add this function
	private func setupMouseMonitor() {
		mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
			switch event.type {
			case .leftMouseDown:
				mouseIsDown = true
				if let index = currentHoveredLineIndex,
					index < allDisplayLines.count,
					!allDisplayLines[index].showSummary {
					selectionDragStart = index
					initializeSelection(at: index)
				}
			case .leftMouseUp:
				mouseIsDown = false
				selectionDragStart = nil
			default:
				break
			}
			return event
		}
	}
	
	private func removeMouseMonitor() {
		if let monitor = mouseMonitor {
			NSEvent.removeMonitor(monitor)
			mouseMonitor = nil
		}
	}
	
	*/
	

	
	
	
	
	
	private func clearSelection() {
		selectedIndices.removeAll()
		anchorIndex = nil
	}

	private var rejectedChangeCount: Int {
		response.rejectedChanges.count
	}

	private var pendingNonRejectedChangeCount: Int {
		response.changes.filter {
			!response.appliedChanges.contains($0.id) &&
			!response.rejectedChanges.contains($0.id)
		}.count
	}

	private var acceptAllButtonTitle: String {
		if rejectedChangeCount > 0 {
			return "Accept Non-Rejected"
		} else {
			return "Accept All"
		}
	}

	private var isAcceptAllDisabled: Bool {
		pendingNonRejectedChangeCount == 0
	}

	private var processedChangeCount: Int {
		response.acceptedChangeCount + rejectedChangeCount
	}
	
	
	private func selectionCount(_ r: ClosedRange<Int>) -> Int {
		var count = 0
		for idx in r {
			guard idx >= 0 && idx < allDisplayLines.count else { continue }
			if !allDisplayLines[idx].showSummary {
				count += 1
			}
		}
		return count
	}
	
	
	private func indexForLocation(_ pt: CGPoint) -> Int {
		// pt is in "codeContent" coordinate space (the LazyVStack)
		let y = max(0, pt.y)
		// Simple version assuming fixed line height (will refine later for summary rows)
		let idx = Int(y / CodeViewMetrics.lineHeight)
		return max(0, min(idx, allDisplayLines.count - 1))
	}
	
	private func scheduleRebuildLines() {
		// Cancel any pending rebuild to coalesce multiple @Published updates
		pendingRebuildTask?.cancel()
		
		// Capture the current response reference to avoid capturing the entire View
		let currentResponse = self.response
		
		pendingRebuildTask = Task {
			// Debounce
			try? await Task.sleep(nanoseconds: 150_000_000) // 150ms
			guard !Task.isCancelled else { return }
			
			// Snapshot inputs on the main actor
			let snapshot = await MainActor.run {
				(
					content: currentResponse.fileContent,
					changes: currentResponse.changes,
					applied: currentResponse.appliedChanges,
					rejected: currentResponse.rejectedChanges
				)
			}
			guard !Task.isCancelled else { return }
			
			// Compute off-main (pure function, no self capture)
			let lines = await Task.detached(priority: .userInitiated) {
				await FilePreviewView.buildDisplayLines(
					fileContent: snapshot.content,
					changes: snapshot.changes,
					applied: snapshot.applied,
					rejected: snapshot.rejected
				)
			}.value
			guard !Task.isCancelled else { return }
			
			// Publish result on main
			await MainActor.run {
				// Clear hover and drag state before replacing lines to prevent callbacks from accessing destroyed views
				self.currentHoveredLineIndex = nil
				if self.isPerformingDrag {
					self.isPerformingDrag = false
					self.dragMode = nil
					self.dragAnchorIndex = nil
				}
				self.allDisplayLines = lines
			}
		}
	}
	
	private func handleClick(at index: Int, modifiers: NSEvent.ModifierFlags) {
		guard index >= 0 && index < allDisplayLines.count else { return }
		// Clicking on a summary row should clear any active selection, then exit (keeps buttons interactive)
		if allDisplayLines[index].showSummary {
			if !selectedIndices.isEmpty { clearSelection() }
			return
		}
		if modifiers.contains(.command) {
			// Cmd+Click toggles without changing the anchor
			toggleIndex(index)
		} else if modifiers.contains(.shift), let anchor = anchorIndex {
			// Shift+Click extends from the current anchor
			extendSelection(from: anchor, to: index)
		} else {
			// Plain click: if there is an active selection and the clicked line is not selected, clear it.
			if !selectedIndices.isEmpty && !selectedIndices.contains(index) {
				clearSelection()
			} else {
				setSingleSelection(index)
			}
		}
	}

	private func setSingleSelection(_ index: Int) {
		selectedIndices = [index]
		anchorIndex = index
	}

	private func toggleIndex(_ index: Int) {
		if selectedIndices.contains(index) {
			selectedIndices.remove(index)
		} else {
			selectedIndices.insert(index)
		}
	}

	private func extendSelection(from anchor: Int, to index: Int) {
		let start = min(anchor, index)
		let end   = max(anchor, index)
		var newSel: Set<Int> = []
		if start <= end {
			for i in start...end where i >= 0 && i < allDisplayLines.count {
				if !allDisplayLines[i].showSummary {
					newSel.insert(i)
				}
			}
		}
		selectedIndices = newSel
	}

	private func onDragBegan(at index: Int) {
		dragInitialSelection = selectedIndices
		dragAnchorIndex = index
		dragMode = selectedIndices.contains(index) ? .erase : .select
		isPerformingDrag = true
	}

	private func updateDragSelection(to index: Int) {
		guard let start = dragAnchorIndex, let mode = dragMode else { return }
		let a = min(start, index)
		let b = max(start, index)
		var paint: Set<Int> = []
		if a <= b {
			for i in a...b where i >= 0 && i < allDisplayLines.count {
				if !allDisplayLines[i].showSummary {
					paint.insert(i)
				}
			}
		}
		switch mode {
		case .select:
			selectedIndices = dragInitialSelection.union(paint)
		case .erase:
			selectedIndices = dragInitialSelection.subtracting(paint)
		}
	}

	private func onDragEnded() {
		isPerformingDrag = false
		dragMode = nil
		dragAnchorIndex = nil
		dragInitialSelection = []
	}

	private func selectLogicalBlock(at idx: Int) {
		guard !allDisplayLines.isEmpty else { return }
		let index = idx
		guard index >= 0 && index < allDisplayLines.count else {
			return
		}

		// Disallow summary-row double-clicks (no normalization). Must be on a content line.
		if allDisplayLines[index].showSummary {
			return
		}

		// Must be part of a change (not dummy). If not within a change, do nothing.
		let lineAtIndex = allDisplayLines[index]
		let targetChangeId = lineAtIndex.change.id
		if targetChangeId == FileChange.dummy.id {
			return
		}

		// Expand to the full contiguous hunk for this change (skip summary rows)
		var start = index
		var end = index

		while start > 0 {
			let prev = allDisplayLines[start - 1]
			if prev.showSummary || prev.change.id != targetChangeId { break }
			start -= 1
		}
		while end + 1 < allDisplayLines.count {
			let next = allDisplayLines[end + 1]
			if next.showSummary || next.change.id != targetChangeId { break }
			end += 1
		}

		// Require the double-click to be at least one line inside the hunk (not on boundaries).
		// If the clicked index is the very first or very last content line of the hunk, do nothing.
		guard index - start >= 1 && end - index >= 1 else {
			return
		}

		// Apply selection for the entire hunk
		selectedIndices = Set(start...end)
		anchorIndex = start
	}

	private func isSummary(_ index: Int) -> Bool {
		guard index >= 0 && index < allDisplayLines.count else { return false }
		return allDisplayLines[index].showSummary
	}
	
	private func nearestSelectableIndex(from idx: Int) -> Int? {
		guard !allDisplayLines.isEmpty else { return nil }
		let clamped = max(0, min(idx, allDisplayLines.count - 1))
		if !allDisplayLines[clamped].showSummary { return clamped }
		// Prefer searching forward first to align with scroll direction, then backward
		var f = clamped + 1
		while f < allDisplayLines.count {
			if !allDisplayLines[f].showSummary { return f }
			f += 1
		}
		var b = clamped - 1
		while b >= 0 {
			if !allDisplayLines[b].showSummary { return b }
			b -= 1
		}
		return nil
	}
	
	private func selectionLineNumbersPreview() -> String? {
		// Gather 1-based line numbers for selected, non-summary lines that have a line number
		guard !selectedIndices.isEmpty else { return nil }
		
		let sortedIndices = selectedIndices.sorted()
		var numbers: [Int] = []
		var newCount = 0
		
		for idx in sortedIndices {
			guard idx >= 0 && idx < allDisplayLines.count else { continue }
			let line = allDisplayLines[idx]
			guard !line.showSummary else { continue }
			
			if let ln = line.lineNumber {
				numbers.append(ln + 1) // 1-based
			} else {
				// Added (unnumbered) lines
				newCount += 1
			}
		}
		
		// If only new lines are selected, show a concise "N new" preview
		if numbers.isEmpty {
			return newCount > 0 ? "\(newCount) new" : nil
		}
		
		// Collapse contiguous numbered lines into ranges
		numbers.sort()
		var segments: [String] = []
		var start = numbers[0]
		var prev = numbers[0]
		for n in numbers.dropFirst() {
			if n == prev + 1 {
				prev = n
			} else {
				if start == prev {
					segments.append("\(start)")
				} else {
					segments.append("\(start)-\(prev)")
				}
				start = n
				prev = n
			}
		}
		if start == prev {
			segments.append("\(start)")
		} else {
			segments.append("\(start)-\(prev)")
		}
		
		let base = segments.joined(separator: ", ")
		// If there are also new lines in the selection, append a compact descriptor
		return newCount > 0 ? "\(base) (+\(newCount) new)" : base
	}
}

struct DisplayLine: Identifiable {
	enum Key: Hashable {
		case content(Int)        // adjusted line number
		case summary(UUID)       // change.id
		case diff(UUID, Int)     // change.id + per-line index in the diff
	}
	let id: Key
	let lineNumber: Int?
	let content: String
	let change: FileChange
	let changeLineIndex: Int?
	let changeState: ChangeState
	let showSummary: Bool
}

extension Collection {
	subscript(safe index: Index) -> Element? {
		return indices.contains(index) ? self[index] : nil
	}
}
