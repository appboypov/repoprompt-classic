import SwiftUI
import AppKit

struct PastePathsSheet: View {
	@ObservedObject var fileManager: RepoFileManagerViewModel
	@Environment(\.dismiss) private var dismiss

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	// Wizard state
	@State private var currentStep: Int = 1

	// Step 1: Paste
	@State private var pastedText: String = ""

	// Cached extraction (prevents rescanning huge text on every SwiftUI re-render)
	@State private var extractedPathsCache: [ParsedPath] = []
	@State private var isExtractingPaths = false
	@State private var extractionGeneration = 0
	@State private var extractPathsTask: Task<Void, Never>? = nil

	// Step 2: Review - validated items
	@State private var validatedItems: [ValidatedPath] = []
	@State private var isValidating = false
	@State private var notFoundCount = 0

	// Options
	@State private var clearSelection = false
	@State private var expandFolders = true

	// Selection state
	@State private var isSelecting = false

	var body: some View {
		VStack(spacing: 0) {
			header
			Divider()
			stepIndicator
			Divider()
			stepContent
		}
		.frame(width: 640, height: 480)
		.background(Color(NSColor.windowBackgroundColor))
		.onDisappear {
			// Cancel any in-flight extraction when sheet closes
			extractPathsTask?.cancel()
			extractPathsTask = nil
		}
	}

	// MARK: - Header

	private var header: some View {
		HStack(alignment: .center, spacing: 12) {
			VStack(alignment: .leading, spacing: 2) {
				Text("Paste Paths")
					.font(fontPreset.headlineFont)
				Text(stepSubtitle)
					.font(fontPreset.subheadlineFont)
					.foregroundColor(.secondary)
			}

			Spacer()

			Button(action: { dismiss() }) {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 20))
					.foregroundColor(.secondary)
			}
			.buttonStyle(.plain)
			.hoverTooltip("Close", .top)
		}
		.padding(16)
	}

	private var stepSubtitle: String {
		switch currentStep {
		case 1: return "Paste text containing file or folder paths"
		case 2: return "Review and select the paths to add"
		default: return ""
		}
	}

	// MARK: - Step Indicator

	private var stepIndicator: some View {
		HStack(spacing: 0) {
			stepBubble(number: 1, title: "Paste")
			stepConnector(active: currentStep >= 2)
			stepBubble(number: 2, title: "Select")
		}
		.padding(.horizontal, 40)
		.padding(.vertical, 12)
	}

	private func stepBubble(number: Int, title: String) -> some View {
		VStack(spacing: 4) {
			ZStack {
				Circle()
					.fill(number <= currentStep ? Color.accentColor : Color.gray.opacity(0.3))
					.frame(width: 28, height: 28)

				if number < currentStep {
					Image(systemName: "checkmark")
						.font(.system(size: 12, weight: .bold))
						.foregroundColor(.white)
				} else {
					Text("\(number)")
						.font(.system(size: 13, weight: .semibold))
						.foregroundColor(number <= currentStep ? .white : .secondary)
				}
			}

			Text(title)
				.font(fontPreset.captionFont)
				.foregroundColor(number <= currentStep ? .primary : .secondary)
		}
	}

	private func stepConnector(active: Bool) -> some View {
		Rectangle()
			.fill(active ? Color.accentColor : Color.gray.opacity(0.3))
			.frame(height: 2)
			.frame(maxWidth: .infinity)
			.padding(.horizontal, 8)
			.offset(y: -10)
	}

	// MARK: - Step Content

	@ViewBuilder
	private var stepContent: some View {
		switch currentStep {
		case 1:
			step1PasteView
		case 2:
			step2ReviewView
		default:
			EmptyView()
		}
	}

	// MARK: - Step 1: Paste

	private var step1PasteView: some View {
		VStack(spacing: 12) {
			// Controls
			HStack(spacing: 8) {
				Button("Paste from Clipboard") {
					if let str = NSPasteboard.general.string(forType: .string) {
						pastedText = str
					}
				}
				.buttonStyle(CustomButtonStyle(verticalPadding: 4, horizontalPadding: 10, height: 28))

				Button("Clear") {
					pastedText = ""
				}
				.buttonStyle(CustomButtonStyle(verticalPadding: 4, horizontalPadding: 10, height: 28))

				Spacer()
			}

			// Text editor
			ZStack(alignment: .topLeading) {
				TextEditor(text: $pastedText)
					.font(.system(size: 12, weight: .regular, design: .monospaced))
					.scrollContentBackground(.hidden)
					.padding(8)

				if pastedText.isEmpty {
					Text(" Paste compiler errors, git diff output, file listings, or any text containing paths...")
						.font(fontPreset.font)
						.foregroundColor(.secondary.opacity(0.6))
						.padding(8)
						.allowsHitTesting(false)
				}
			}
			.background(Color(NSColor.textBackgroundColor))
			.clipShape(RoundedRectangle(cornerRadius: 8))
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(Color.gray.opacity(0.3), lineWidth: 1)
			)
			.frame(maxHeight: .infinity)

			// Navigation
			HStack {
				Spacer()

				let pathCount = extractedPathsCache.count
				let hasValidInput = pathCount > 0

				if isExtractingPaths {
					ProgressView()
						.scaleEffect(0.7)
					Text("Analyzing…")
						.font(fontPreset.captionFont)
						.foregroundColor(.secondary)
				} else if hasValidInput {
					Text("\(pathCount) path\(pathCount == 1 ? "" : "s") detected")
						.font(fontPreset.captionFont)
						.foregroundColor(.secondary)
				}

				Button {
					validateAndProceed()
				} label: {
					HStack(spacing: 6) {
						Text("Find Matches")
						Image(systemName: "arrow.right")
					}
				}
				.buttonStyle(ProminentButtonStyle(isActive: hasValidInput && !isExtractingPaths))
				.disabled(!hasValidInput || isValidating || isExtractingPaths)
			}
		}
		.padding(16)
		.onAppear { schedulePathExtraction(for: pastedText) }
		.onChange(of: pastedText) { _, newValue in
			schedulePathExtraction(for: newValue)
		}
	}

	private func schedulePathExtraction(for text: String) {
		// Cancel any in-flight extraction work
		extractPathsTask?.cancel()

		extractionGeneration += 1
		let generation = extractionGeneration

		// Never show stale results for old text
		extractedPathsCache = []

		// Empty/whitespace-only: clear state immediately
		guard text.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.inverted) != nil else {
			isExtractingPaths = false
			return
		}

		isExtractingPaths = true
		let snapshot = text

		extractPathsTask = Task(priority: .userInitiated) {
			// Debounce so we don't rescan while the user is still pasting/typing
			try? await Task.sleep(nanoseconds: 200_000_000)
			if Task.isCancelled { return }

			// Do the heavy scan off the main actor
			let extracted = await Task.detached(priority: .userInitiated) {
				PastedPathExtractor.extractPaths(from: snapshot)
			}.value

			if Task.isCancelled { return }

			await MainActor.run {
				guard extractionGeneration == generation else { return }
				extractedPathsCache = extracted
				isExtractingPaths = false
			}
		}
	}

	private func validateAndProceed() {
		guard !isValidating else { return }

		// Reuse cached extraction (prevents a second full scan of huge diffs)
		let parsed = extractedPathsCache
		guard !parsed.isEmpty else { return }

		isValidating = true

		Task {
			var validated: [ValidatedPath] = []
			var seen = Set<String>()
			var invalidCount = 0

			// Collect unique normalized paths
			var pathsToCheck: [(display: String, normalized: String)] = []
			pathsToCheck.reserveCapacity(parsed.count)

			for item in parsed {
				let normalized = fileManager.normalizeUserInputPath(item.path)
				guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
				seen.insert(normalized)
				pathsToCheck.append((display: item.displayPath, normalized: normalized))
			}

			// Bulk lookup files
			let fileHits = await fileManager.findFiles(atPaths: pathsToCheck.map(\.normalized))

			// Check each path for file or folder match
			for (display, normalized) in pathsToCheck {
				var resolvedPath: String? = nil
				var isFolder = false

				// Check if it's a file
				if let fileVM = fileHits[normalized] {
					resolvedPath = fileVM.relativePath
					isFolder = false
				}
				// Check if it's a folder (try both relative and absolute lookups)
				else if let folderVM = fileManager.findFolderByRelativePath(normalized) {
					resolvedPath = folderVM.relativePath
					isFolder = true
				} else if let folderVM = fileManager.findFolderByFullPath(normalized) {
					resolvedPath = folderVM.relativePath
					isFolder = true
				}
				// Also check file by full path if bulk lookup missed it
				else if let fileVM = fileManager.findFileByFullPath(normalized) {
					resolvedPath = fileVM.relativePath
					isFolder = false
				}

				if resolvedPath != nil {
					validated.append(ValidatedPath(
						displayPath: display,
						normalizedPath: normalized,
						resolvedPath: resolvedPath,
						isFolder: isFolder,
						isIncluded: true
					))
				} else {
					invalidCount += 1
				}
			}

			await MainActor.run {
				// Sort: folders before files, then alphabetically
				validatedItems = validated.sorted { a, b in
					if a.isFolder != b.isFolder { return a.isFolder }
					return a.displayPath < b.displayPath
				}
				notFoundCount = invalidCount
				isValidating = false
				currentStep = 2
			}
		}
	}

	// MARK: - Step 2: Review & Select

	private var step2ReviewView: some View {
		VStack(spacing: 12) {
			// Summary bar
			HStack(spacing: 16) {
				let stats = itemStats
				let totalFolders = validatedItems.filter { $0.isFolder }.count
				let totalFiles = validatedItems.filter { !$0.isFolder }.count
				let foldersAllOff = totalFolders > 0 && stats.folders == 0
				let filesAllOff = totalFiles > 0 && stats.files == 0

				// Clickable folder label - toggles all folders
				Button {
					let allFoldersOn = validatedItems.filter { $0.isFolder }.allSatisfy { $0.isIncluded }
					for i in validatedItems.indices where validatedItems[i].isFolder {
						validatedItems[i].isIncluded = !allFoldersOn
					}
				} label: {
					Label("\(stats.folders)/\(totalFolders) folder\(totalFolders == 1 ? "" : "s")", systemImage: "folder.fill")
						.font(fontPreset.font)
						.foregroundColor(foldersAllOff ? .secondary : (totalFolders > 0 ? .accentColor : .secondary))
						.strikethrough(foldersAllOff, color: .secondary)
				}
				.buttonStyle(.plain)
				.disabled(totalFolders == 0)
				.help(totalFolders > 0 ? "Click to toggle all folders" : "No folders found")

				// Clickable file label - toggles all files
				Button {
					let allFilesOn = validatedItems.filter { !$0.isFolder }.allSatisfy { $0.isIncluded }
					for i in validatedItems.indices where !validatedItems[i].isFolder {
						validatedItems[i].isIncluded = !allFilesOn
					}
				} label: {
					Label("\(stats.files)/\(totalFiles) file\(totalFiles == 1 ? "" : "s")", systemImage: "doc.fill")
						.font(fontPreset.font)
						.foregroundColor(filesAllOff ? .secondary : (totalFiles > 0 ? .accentColor : .secondary))
						.strikethrough(filesAllOff, color: .secondary)
				}
				.buttonStyle(.plain)
				.disabled(totalFiles == 0)
				.help(totalFiles > 0 ? "Click to toggle all files" : "No files found")

				if notFoundCount > 0 {
					Label("\(notFoundCount) not found", systemImage: "xmark.circle.fill")
						.font(fontPreset.font)
						.foregroundColor(.secondary)
						.help("These paths were not found in the workspace and are not shown")
				}

				Spacer()

				Button("All") {
					for i in validatedItems.indices {
						validatedItems[i].isIncluded = true
					}
				}
				.buttonStyle(.plain)
				.font(fontPreset.captionFont)
				.foregroundColor(.accentColor)

				Button("None") {
					for i in validatedItems.indices {
						validatedItems[i].isIncluded = false
					}
				}
				.buttonStyle(.plain)
				.font(fontPreset.captionFont)
				.foregroundColor(.accentColor)
			}

			// List - only show valid items
			List {
				// Folders section
				let folders = validatedItems.filter { $0.isFolder }
				if !folders.isEmpty {
					Section("Folders") {
						ForEach(folders) { item in
							reviewRow(for: item)
						}
					}
				}

				// Files section
				let files = validatedItems.filter { !$0.isFolder }
				if !files.isEmpty {
					Section("Files") {
						ForEach(files) { item in
							reviewRow(for: item)
						}
					}
				}
			}
			.listStyle(.inset)

			// Options row
			HStack(spacing: 16) {
				Toggle("Clear current selection", isOn: $clearSelection)
					.toggleStyle(.checkbox)
					.font(fontPreset.captionFont)

				Toggle("Expand folders", isOn: $expandFolders)
					.toggleStyle(.checkbox)
					.font(fontPreset.captionFont)

				Spacer()
			}

			// Navigation
			HStack {
				Button("Back") {
					currentStep = 1
				}
				.buttonStyle(CustomButtonStyle(verticalPadding: 4, horizontalPadding: 16, height: 30))

				Spacer()

				Button {
					Task { await commitSelection() }
				} label: {
					HStack(spacing: 6) {
						Text("Add \(includedCount) to Selection")
						Image(systemName: "checkmark")
					}
				}
				.buttonStyle(ProminentButtonStyle(isActive: includedCount > 0))
				.disabled(isSelecting || includedCount == 0)
			}
		}
		.padding(16)
	}

	private func reviewRow(for item: ValidatedPath) -> some View {
		HStack(spacing: 10) {
			Toggle("", isOn: binding(for: item))
				.toggleStyle(.checkbox)
				.labelsHidden()

			Image(systemName: item.isFolder ? "folder.fill" : "doc.fill")
				.foregroundColor(item.isFolder ? .accentColor : .secondary)
				.frame(width: 16)

			VStack(alignment: .leading, spacing: 1) {
				Text(item.displayPath)
					.font(.system(size: 12, weight: .regular, design: .monospaced))
					.foregroundColor(.primary)
					.lineLimit(1)
					.truncationMode(.middle)

				if let resolved = item.resolvedPath, resolved != item.normalizedPath {
					Text("→ \(resolved)")
						.font(fontPreset.captionFont)
						.foregroundColor(.secondary)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}

			Spacer()
		}
		.padding(.vertical, 2)
	}

	private func binding(for item: ValidatedPath) -> Binding<Bool> {
		Binding(
			get: { validatedItems.first { $0.id == item.id }?.isIncluded ?? false },
			set: { newValue in
				if let idx = validatedItems.firstIndex(where: { $0.id == item.id }) {
					validatedItems[idx].isIncluded = newValue
				}
			}
		)
	}

	private var itemStats: (folders: Int, files: Int) {
		var folders = 0
		var files = 0

		for item in validatedItems where item.isIncluded {
			if item.isFolder {
				folders += 1
			} else {
				files += 1
			}
		}

		return (folders, files)
	}

	private var includedCount: Int {
		validatedItems.filter { $0.isIncluded }.count
	}

	private func commitSelection() async {
		let pathsToSelect = validatedItems
			.filter { $0.isIncluded }
			.compactMap { $0.resolvedPath ?? $0.normalizedPath }

		guard !pathsToSelect.isEmpty else { return }

		isSelecting = true
		defer { isSelecting = false }

		_ = await fileManager.selectPaths(
			withPaths: pathsToSelect,
			clear: clearSelection,
			expandFolders: expandFolders,
			exact: true
		)

		dismiss()
	}
}

// MARK: - Models

private struct ValidatedPath: Identifiable {
	let id = UUID()
	let displayPath: String
	let normalizedPath: String
	let resolvedPath: String?
	let isFolder: Bool
	var isIncluded: Bool
}

// MARK: - Prominent Button Style

private struct ProminentButtonStyle: ButtonStyle {
	@Environment(\.isEnabled) private var isEnabled
	let isActive: Bool

	func makeBody(configuration: Configuration) -> some View {
		configuration.label
			.font(.system(size: 13, weight: .medium))
			.padding(.vertical, 6)
			.padding(.horizontal, 14)
			.background(
				RoundedRectangle(cornerRadius: 8)
					.fill(backgroundColor(isPressed: configuration.isPressed))
			)
			.foregroundColor(foregroundColor)
			.opacity(isEnabled ? 1 : 0.5)
	}

	private func backgroundColor(isPressed: Bool) -> Color {
		if !isEnabled || !isActive {
			return Color.gray.opacity(0.2)
		}
		if isPressed {
			return Color.accentColor.opacity(0.8)
		}
		return Color.accentColor
	}

	private var foregroundColor: Color {
		if !isEnabled || !isActive {
			return .secondary
		}
		return .white
	}
}
