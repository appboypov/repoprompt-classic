import SwiftUI
import SwiftTreeSitter

struct FilePreviewPopover: View {
	let file: FileViewModel
	let fileSlices: [LineRange]?
	let showCodeMap: Bool // New parameter to indicate codemap mode
	@Binding var showPreview: Bool

	@State private var previewContent: String = "Loading..."
	@State private var previewHighlightRanges: [NamedRange]? = nil
	@State private var loadingTask: Task<Void, Never>? = nil // Task handle
	@State private var showSlicesOnly: Bool = true // Default to showing slices if available
	@State private var viewRefreshID = UUID() // Force view refresh
	@State private var previewMode: FilePreviewMode = .syntaxHighlighted
	@State private var statusMessage: String? = nil

	var body: some View {
		VStack(spacing: 0) {
			// Header with file path and controls
			headerView
			
			// Status banner for SVG safety or truncation warnings
			if let message = statusMessage {
				statusBannerView(message: message)
			}

			// Main content area
			contentView
		}
		.frame(width: 1000, height: 800)
		.background(Color(NSColor.windowBackgroundColor).opacity(0.1))
		.onAppear {
			reloadPreview()
		}
		.onDisappear {
			// Cancel the loading task if the popover is dismissed
			loadingTask?.cancel()
		}
	}
	
	// MARK: - Subviews
	
	private var headerView: some View {
		HStack {
			Text(file.relativePath)
				.font(.headline)
			Spacer()
			// Show toggle if file has slices
			if let slices = fileSlices, !slices.isEmpty {
				Toggle(isOn: $showSlicesOnly) {
					Text("Show slices only")
						.font(.subheadline)
				}
				.toggleStyle(.switch)
				.onChange(of: showSlicesOnly) { _ in
					reloadPreview()
				}
			}
		}
		.padding()
	}
	
	private func statusBannerView(message: String) -> some View {
		HStack {
			Image(systemName: "exclamationmark.triangle.fill")
				.foregroundColor(.orange)
			Text(message)
				.font(.subheadline)
				.foregroundColor(.secondary)
			Spacer()
		}
		.padding(.horizontal)
		.padding(.vertical, 6)
		.background(Color.orange.opacity(0.1))
	}
	
	@ViewBuilder
	private var contentView: some View {
		switch previewMode {
		case .disabled:
			// Show disabled state with message
			disabledPreviewView
		case .plainText, .syntaxHighlighted:
			// Show content (plain or highlighted based on available ranges)
			if previewContent != "Loading..." {
				textPreviewView
			} else {
				ProgressView()
					.frame(maxWidth: .infinity, maxHeight: .infinity)
			}
		}
	}
	
	private var disabledPreviewView: some View {
		VStack(spacing: 16) {
			Image(systemName: "exclamationmark.shield.fill")
				.font(.system(size: 48))
				.foregroundColor(.orange)
			Text("Preview Disabled")
				.font(.title2)
				.fontWeight(.semibold)
			Text(previewContent)
				.font(.body)
				.foregroundColor(.secondary)
				.multilineTextAlignment(.center)
			Text("Open the file in your editor to view its contents safely.")
				.font(.caption)
				.foregroundColor(.secondary)
		}
		.padding(40)
		.frame(maxWidth: .infinity, maxHeight: .infinity)
	}
	
	@ViewBuilder
	private var textPreviewView: some View {
		// Only use syntax highlighting if mode allows and ranges are available
		if previewMode == .syntaxHighlighted,
		let ranges = previewHighlightRanges, !ranges.isEmpty {
			HighlightedTextKitView(
				text: $previewContent,
				highlightRanges: ranges,
				isEditable: false // Previews are read-only
			)
			.id(viewRefreshID)
		} else {
			// Plain text view - safer for large SVGs
			TextKitView(
				text: $previewContent,
				isEditable: false, // Previews are read-only
				isSpellCheckEnabled: false,
				useMonospacedFont: true // Ensure monospaced font for code
			)
			.id(viewRefreshID)
		}
	}
	
	private func reloadPreview() {
		// Cancel any previous task before starting a new one
		loadingTask?.cancel()

		loadingTask = Task {
			// If showing codemap, display the API description
			if showCodeMap {
				let codeMapText = file.fileAPI?.apiDescription ?? "No codemap available for this file"
				if !Task.isCancelled {
					await MainActor.run {
						self.previewContent = codeMapText
						self.previewHighlightRanges = nil
						self.previewMode = .syntaxHighlighted // Codemaps are safe
						self.statusMessage = nil
						self.viewRefreshID = UUID()
					}
				}
				return
			}

			// Load the full content first
			let fullContent = await file.latestContent ?? "Error loading file content"
			if Task.isCancelled { return }

			// Trigger syntax highlighting only when snapshot mode needs it
			let previewSnapshot = await MainActor.run { file.previewSnapshot }
			let shouldLoadHighlight = (previewSnapshot?.mode ?? .syntaxHighlighted) == .syntaxHighlighted
			if shouldLoadHighlight {
				_ = await file.latestNamedRanges
				if Task.isCancelled { return }
			}

			// Decide whether to show slices or full content
			let shouldShowSlices = showSlicesOnly && fileSlices != nil && !(fileSlices?.isEmpty ?? true)

			if shouldShowSlices, let slices = fileSlices {
				// Get SVG safety info from previewSnapshot first
				let snapshot = await MainActor.run { file.previewSnapshot }
				let svgMode = snapshot?.mode ?? .syntaxHighlighted
				
				// For disabled SVGs, don't render slices at all - use snapshot message
				if svgMode == .disabled {
					if !Task.isCancelled {
						await MainActor.run {
							self.previewMode = .disabled
							self.previewContent = snapshot?.previewText ?? "[SVG preview disabled for safety]"
							self.previewHighlightRanges = nil
							self.statusMessage = snapshot?.statusMessage
							self.viewRefreshID = UUID()
						}
					}
					return
				}
				
				// Extract sliced content
				let assembly = FileViewModel.buildSliceAssembly(from: fullContent, ranges: slices)
				
				// Format slices with line ranges and descriptions (matching prompt format)
				let formattedContent = formatSlicesForDisplay(segments: assembly.segments, fileName: file.name)
				
				// For plainText SVGs, show content but without syntax highlighting
				let formattedRanges: [NamedRange]?
				if svgMode == .syntaxHighlighted, let ext = file.fileExtension {
					formattedRanges = try? SyntaxManager.shared.highlight(
						content: formattedContent,
						fileExtension: ext,
						origin: .previewSlice(
							relativePath: file.relativePath,
							sliceCount: slices.count
						)
					)
				} else {
					formattedRanges = nil
				}

				if !Task.isCancelled {
					await MainActor.run {
						self.previewContent = formattedContent
						self.previewHighlightRanges = formattedRanges
						self.previewMode = svgMode
						self.statusMessage = snapshot?.statusMessage
						self.viewRefreshID = UUID()
					}
				}
			} else {
				// Show full content using previewSnapshot for SVG-safe rendering
				let snapshot = await MainActor.run { file.previewSnapshot }
				
				if let snapshot = snapshot {
					// Use the SVG-safe snapshot
					if !Task.isCancelled {
						await MainActor.run {
							self.previewMode = snapshot.mode
							self.previewContent = snapshot.previewText
							self.previewHighlightRanges = snapshot.namedRanges
							self.statusMessage = snapshot.statusMessage
							self.viewRefreshID = UUID()
						}
					}
				} else {
					// Fallback to legacy behavior if no snapshot available
					let loadedPreviewContent = await MainActor.run { file.previewContent ?? fullContent }
					let loadedPreviewRanges = await MainActor.run { file.previewNamedRanges }

					if !Task.isCancelled {
						await MainActor.run {
							self.previewMode = .syntaxHighlighted
							self.previewContent = loadedPreviewContent
							self.previewHighlightRanges = loadedPreviewRanges
							self.statusMessage = nil
							self.viewRefreshID = UUID()
						}
					}
				}
			}
		}
	}
	
	private func formatSlicesForDisplay(segments: [FileViewModel.SliceSegment], fileName: String) -> String {
		let ext = URL(fileURLWithPath: fileName).pathExtension
		let commentPrefix = commentPrefixForExtension(ext)
		
		var lines: [String] = []
		for (index, segment) in segments.enumerated() {
			let label = formatRange(segment.range)
			if let desc = segment.range.description, !desc.isEmpty {
				lines.append("\(commentPrefix) (lines \(label): \(desc))")
			} else {
				lines.append("\(commentPrefix) (lines \(label))")
			}
			lines.append(segment.text)
			if index != segments.count - 1 {
				lines.append("") // Add blank line between segments
			}
		}
		return lines.joined(separator: "\n")
	}
	
	private func commentPrefixForExtension(_ ext: String) -> String {
		switch ext.lowercased() {
		case "swift", "js", "ts", "jsx", "tsx", "c", "cpp", "cc", "cxx", "h", "hpp",
			"m", "mm", "java", "kt", "kts", "go", "rs", "cs", "php", "scala", "dart":
			return "//"
		case "py", "rb", "sh", "bash", "zsh", "fish", "pl", "r", "yaml", "yml", "toml":
			return "#"
		case "sql", "lua", "hs", "elm":
			return "--"
		case "html", "xml", "svg":
			return "<!--"
		case "css", "scss", "sass", "less":
			return "/*"
		default:
			return "//" // Default to C-style comments
		}
	}
	
	private func formatRange(_ range: LineRange) -> String {
		if range.start == range.end {
			return "\(range.start)"
		}
		return "\(range.start)-\(range.end)"
	}
	

}
