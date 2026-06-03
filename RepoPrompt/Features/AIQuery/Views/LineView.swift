import SwiftUI

struct LineView: View {
	let lineNumber: Int?
	let content: String
	let change: FileChange
	let changeLineIndex: Int?
	let lineNumberWidth: CGFloat
	let symbolWidth: CGFloat
	let changeState: ChangeState
	let showSummary: Bool
	let isSelected: Bool
	let lineIndex: Int
	let onHover: (Int) -> Void
	let onDragUpdate: (Int) -> Void
	
	// New properties for change actions
	let isChangeApplied: Bool
	let isChangeRejected: Bool
	let onAccept: () -> Void
	let onReject: () -> Void
	let onUndoAccept: () -> Void
	let onUndoReject: () -> Void
	
	@State private var isHovered = false
	
	private var isSelectable: Bool {
		!showSummary // Skip selection for summary lines
	}
	
	private let additionColor = Color(red: 0.2, green: 0.8, blue: 0.2)
	private let removalColor = Color(red: 0.8, green: 0.2, blue: 0.2)
	private let rejectedChangeColor = Color.gray.opacity(0.3)
	
	var body: some View {
		ZStack(alignment: .topLeading) {
			HStack(spacing: 0) {
				if let lineNumber = lineNumber {
					Text("\(lineNumber + 1)")
						.foregroundColor(.secondary)
						.frame(width: lineNumberWidth, alignment: .trailing)
						.lineLimit(1)
						.truncationMode(.head)
				} else {
					Text("")
						.frame(width: lineNumberWidth, alignment: .trailing)
				}
				
				Text(getLinePrefix())
					.frame(width: symbolWidth, alignment: .center)
					.foregroundColor(getLinePrefixColor())

				Text(content)
				Spacer()
			}
			.font(.system(.body, design: .monospaced))
			.frame(height: showSummary ? nil : CodeViewMetrics.lineHeight)
			.background(
				ZStack {
					getBackgroundColor()
					if isHovered && isSelectable {
						Color.gray.opacity(0.1)
					}
					if isSelected {
						Color.blue.opacity(0.1)
					}
				}
			)
			.onHover { hovering in
				// Keep hover highlight only for selectable lines; still report index for all to support drag selection across summaries.
				if isSelectable {
					isHovered = hovering
				}
				if hovering {
					onHover(lineIndex)
				}
			}
			// Removed per-row DragGesture - selection is now handled by parent container
			
			if showSummary {
				changeSummaryView
					.zIndex(1)
			}
		}
		.frame(maxWidth: .infinity, alignment: .leading)
		.contentShape(Rectangle()) // Ensure entire row is hoverable/clickable
	}
	
	private var changeSummaryView: some View {
		VStack(spacing: 0) {
			HStack {
				Spacer()
				Text(change.description)
					.font(.caption)
					.foregroundColor(.secondary)
				
				if isChangeApplied {
					Button("Undo", action: onUndoAccept)
						.buttonStyle(.bordered)
						.foregroundColor(.blue)
				} else if isChangeRejected {
					Button("Undo Reject", action: onUndoReject)
						.buttonStyle(.bordered)
						.foregroundColor(.blue)
				} else {
					Button("Accept", action: onAccept)
						.buttonStyle(.bordered)
						.foregroundColor(.blue)
					
					Button("Reject", action: onReject)
						.buttonStyle(.bordered)
						.foregroundColor(.red)
				}
			}
			.padding(.horizontal, 8)
			.padding(.bottom, 4)
			
			Rectangle()
				.fill(getOverlayColor())
				.frame(height: 1)
		}
	}
}

extension LineView {
	private func getLinePrefix() -> String {
		guard let index = changeLineIndex,
			  index < change.diffChunk.lines.count else {
			return " "
		}

		switch changeState {
		case .pending, .accepted:
			return change.diffChunk.lines[index].prefix
		case .rejected:
			return " "
		}
	}
	
	private func getLinePrefixColor() -> Color {
		guard let index = changeLineIndex,
			  index < change.diffChunk.lines.count else {
			return .primary
		}

		let line = change.diffChunk.lines[index]
		let base: Color

		switch line.type {
		case .addition:
			base = additionColor
		case .removal:
			base = removalColor
		case .context:
			base = .secondary
		}

		switch changeState {
		case .pending:
			return base
		case .accepted:
			// Same hue, softer intensity
			return base.opacity(0.7)
		case .rejected:
			return .secondary
		}
	}
	
	private func getBackgroundColor() -> Color {
		guard let index = changeLineIndex,
			  index < change.diffChunk.lines.count else {
			// For accepted lines that aren't tied to a diff entry, keep a very subtle hint
			if changeState == .accepted {
				return Color.green.opacity(0.04)
			}
			return .clear
		}

		let line = change.diffChunk.lines[index]
		switch changeState {
		case .pending:
			switch line.type {
			case .addition:
				return additionColor.opacity(0.1)
			case .removal:
				return removalColor.opacity(0.1)
			case .context:
				return .clear
			}
		case .accepted:
			// Keep the diff visible but calmer
			switch line.type {
			case .addition:
				return additionColor.opacity(0.06)
			case .removal:
				return removalColor.opacity(0.06)
			case .context:
				return .clear
			}
		case .rejected:
			return rejectedChangeColor
		}
	}
	
	private func getOverlayColor() -> Color {
		if isChangeApplied {
			let hasAdditions = change.diffChunk.lines.contains { $0.type == .addition }
			return hasAdditions ? additionColor : removalColor
		} else if isChangeRejected {
			return rejectedChangeColor
		} else {
			return .blue.opacity(0.75)
		}
	}
	
}

enum ChangeState {
	case pending, accepted, rejected
}
