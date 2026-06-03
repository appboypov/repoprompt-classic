import SwiftUI
import AppKit

struct FileTreePrefTag: View {
	@ObservedObject var promptManager: PromptViewModel
	var context: SettingsContext = .copy
	var isLocked: Bool = false

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	@State private var showPopover = false
	@State private var isHovering = false

	private var currentFileTreeOption: FileTreeOption {
		switch context {
		case .copy: return promptManager.fileTreeOption
		case .chat: return promptManager.fileTreeOptionForChat
		}
	}
	
	private var fileTreeTooltip: String {
		var tooltip = "File Tree: ASCII representation of your directory structure\n"
		tooltip += "Helps AI understand project organization and file locations"
		
		return tooltip
	}
	
	var body: some View {
		FileTreeTagContent(
			fontPreset: fontPreset,
			isHovering: isHovering,
			fileTreeOption: currentFileTreeOption,
			isLocked: isLocked
		)
		.onTapGesture { showPopover.toggle() }
		.hoverTooltip(fileTreeTooltip)
		.popover(isPresented: $showPopover, arrowEdge: .leading) {
			FileTreePopoverContent(
				promptManager: promptManager,
				context: context,
				fontPreset: fontPreset
			)
		}
		.onHover { hovering in
			withAnimation(.easeInOut(duration: 0.1)) {
				isHovering = hovering
			}
		}
	}
}

// MARK: - Tag Content Component
struct FileTreeTagContent: View {
	let fontPreset: FontScalePreset
	let isHovering: Bool
	let fileTreeOption: FileTreeOption
	var isLocked: Bool = false

	private var tagHorizontalPadding: CGFloat { fontPreset.scaledClamped(8, min: 8, max: 12) }
	private var tagVerticalPadding: CGFloat { fontPreset.scaledClamped(4, min: 4, max: 7) }
	private var tagMinHeight: CGFloat { fontPreset.scaledClamped(28, min: 28, max: 36) }
	private var tagCornerRadius: CGFloat { fontPreset.scaledClamped(16, min: 16, max: 20) }
	private var iconSize: CGFloat { fontPreset.scaledClamped(12, min: 12, max: 15) }
	private var iconFrame: CGFloat { fontPreset.scaledClamped(16, min: 16, max: 21) }
	
	private var isActive: Bool {
		fileTreeOption != .none
	}
	
	var body: some View {
		HStack(spacing: fontPreset.scaledClamped(8, min: 8, max: 10)) {
			Text("File Tree")
				.font(fontPreset.standardFont)
				.foregroundColor(.primary)
				.lineLimit(1)
				.layoutPriority(1)
			
			FileTreeStatusIndicator(
				fontPreset: fontPreset,
				fileTreeOption: fileTreeOption
			)
		}
		.padding(.horizontal, tagHorizontalPadding)
		.padding(.vertical, tagVerticalPadding)
		.frame(minHeight: tagMinHeight)
		.background(backgroundView)
		.cornerRadius(tagCornerRadius)
		.overlay(borderView)
	}
	
	@ViewBuilder
	private var backgroundView: some View {
		if isActive {
			Color.blue.opacity(isHovering ? 0.2 : 0.1)
		} else {
			Color.gray.opacity(isHovering ? 0.2 : 0.1)
		}
	}
	
	@ViewBuilder
	private var borderView: some View {
		RoundedRectangle(cornerRadius: tagCornerRadius)
			.stroke(
				isActive ? Color.blue.opacity(0.3) : Color.gray.opacity(0.3),
				lineWidth: 1
			)
	}
}

// MARK: - Status Indicator Component
struct FileTreeStatusIndicator: View {
	let fontPreset: FontScalePreset
	let fileTreeOption: FileTreeOption
	
	var body: some View {
		Image(systemName: iconName)
			.font(.system(size: fontPreset.scaledClamped(12, min: 12, max: 15)))
			.frame(width: fontPreset.scaledClamped(16, min: 16, max: 21), height: fontPreset.scaledClamped(16, min: 16, max: 21))
			.foregroundColor(.primary)
	}
	
	private var iconName: String {
		switch fileTreeOption {
		case .auto:
			return "arrow.triangle.2.circlepath.circle"
		case .files:
			return "list.bullet.rectangle"
		case .selected:
			return "target"
		case .none:
			return "xmark.circle"
		}
	}
}

// MARK: - Popover Content Component
struct FileTreePopoverContent: View {
	@ObservedObject var promptManager: PromptViewModel
	let context: SettingsContext
	let fontPreset: FontScalePreset
	@ObservedObject var tokenCounter: TokenCountingViewModel
	
	@State private var didCopy: Bool = false
	
	init(promptManager: PromptViewModel, context: SettingsContext, fontPreset: FontScalePreset, tokenCounter: TokenCountingViewModel? = nil) {
		self._promptManager = ObservedObject(wrappedValue: promptManager)
		self.context = context
		self.fontPreset = fontPreset
		self._tokenCounter = ObservedObject(wrappedValue: tokenCounter ?? promptManager.tokenCountingViewModel)
	}

	private var currentFileTreeOption: FileTreeOption {
		switch context {
		case .copy: return promptManager.fileTreeOption
		case .chat: return promptManager.fileTreeOptionForChat
		}
	}
	
	var body: some View {
		VStack(spacing: 16 * fontPreset.scaleFactor) {
			// Existing controls
			FileTreeControls(
				promptManager: promptManager,
				context: context,
				fontPreset: fontPreset
			)

			Divider()

			// Preview header with Copy button
			HStack(spacing: 8 * fontPreset.scaleFactor) {
				Text("File-tree preview")
					.font(fontPreset.subheadlineFont)
				Spacer()
				if didCopy {
					Label("Copied", systemImage: "checkmark.circle.fill")
						.font(fontPreset.captionFont)
						.foregroundColor(.green)
						.transition(.opacity)
				}
				Button(action: copyPreviewToClipboard) {
					Label("Copy", systemImage: "doc.on.doc")
						.font(fontPreset.captionFont)
				}
				.buttonStyle(CustomButtonStyle())
				.help("Copy the file-tree preview to the clipboard")
			}

			// Preview content (fixed height; constant layout)
			if !tokenCounter.fileTreeContent.isEmpty {
				TextKitView(
					text: Binding(
						get: { tokenCounter.fileTreeContent },
						set: { _ in }
					),
					isEditable: false,
					isSpellCheckEnabled: false,
					fontSize: 12 * fontPreset.scaleFactor,
					useMonospacedFont: true,
					wrapLines: false
				)
				.frame(height: 150 * fontPreset.scaleFactor)
				.border(Color.gray.opacity(0.3))
			} else {
				Text("File-tree data will appear here once available.")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
					.frame(maxWidth: .infinity, alignment: .leading)
					.frame(height: 150 * fontPreset.scaleFactor) // reserve same height
					.border(Color.gray.opacity(0.3))
			}
		}
		.padding()
		.frame(width: 325 * fontPreset.scaleFactor,
				height: 320 * fontPreset.scaleFactor)
	}
	
	private func copyPreviewToClipboard() {
		let content = tokenCounter.fileTreeContent
		guard !content.isEmpty else {
			NSSound.beep()
			return
		}
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(content, forType: .string)
		withAnimation { didCopy = true }
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
			withAnimation { didCopy = false }
		}
	}
}

// MARK: - Controls Component
struct FileTreeControls: View {
	@ObservedObject var promptManager: PromptViewModel
	let context: SettingsContext
	let fontPreset: FontScalePreset
	
	private var currentFileTreeOption: FileTreeOption {
		switch context {
		case .copy: return promptManager.fileTreeOption
		case .chat: return promptManager.fileTreeOptionForChat
		}
	}
	
	var body: some View {
		VStack(alignment: .leading, spacing: 4 * fontPreset.scaleFactor) {
			Text("File Tree")
				.font(fontPreset.headlineFont)
			
			HStack {
				FileTreePicker(
					promptManager: promptManager,
					context: context,
					fontPreset: fontPreset
				)
				Spacer()
			}
			
			FileTreeCaptionText(
				text: currentFileTreeOption.caption,
				fontPreset: fontPreset
			)
			
			FileTreeToggle(
				promptManager: promptManager,
				fontPreset: fontPreset
			)
		}
		.padding(.horizontal)
	}
}

// MARK: - Picker Component
struct FileTreePicker: View {
	@ObservedObject var promptManager: PromptViewModel
	let context: SettingsContext
	let fontPreset: FontScalePreset

	var body: some View {
		Picker("", selection: Binding(
			get: {
				switch context {
				case .copy: return promptManager.fileTreeOption
				case .chat: return promptManager.fileTreeOptionForChat
				}
			},
			set: { newValue in
				// Use wrapper method to auto-switch to Manual mode
				switch context {
				case .copy:
					promptManager.updateFileTreeOption(newValue)
				case .chat:
					promptManager.updateFileTreeOptionForChat(newValue)
				}
			}
		)) {
			ForEach(FileTreeOption.allCases) { option in
				Text(option.rawValue)
					.font(fontPreset.standardFont)
					.tag(option)
			}
		}
		.pickerStyle(SegmentedPickerStyle())
		.labelsHidden()
	}
}

// MARK: - Toggle Component
struct FileTreeToggle: View {
	@ObservedObject var promptManager: PromptViewModel
	let fontPreset: FontScalePreset
	
	var body: some View {
		Toggle("Only include roots with selected files", isOn: $promptManager.onlyIncludeRootsWithSelectedFiles)
			.font(fontPreset.captionFont)
			.onChange(of: promptManager.onlyIncludeRootsWithSelectedFiles) { _, _ in
				// Root filtering changed - affects baseline
				promptManager.markSettingsDirty()
			}
	}
}

// MARK: - Caption Text Component
struct FileTreeCaptionText: View {
	let text: String
	let fontPreset: FontScalePreset
	
	var body: some View {
		Text(text)
			.font(fontPreset.captionFont)
			.foregroundColor(.secondary)
	}
}
