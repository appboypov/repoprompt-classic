import SwiftUI

struct ChangeItem: View {
	let change: Change
	@ObservedObject var viewModel: DiffViewModel
	let fileId: UUID
	let canBeLoaded: Bool
	
	private let maxLines = 5
	
	var body: some View {
		VStack(alignment: .leading, spacing: 12) {
			// Summary with blue background styling
			HStack(alignment: .center) {
				if canBeLoaded {
					CheckboxView(isChecked: viewModel.changeSelectionState(for: fileId, changeId: change.id)) {
						viewModel.toggleChangeSelection(fileId: fileId, changeId: change.id)
					}
				}
				
				Text(change.summary)
					.font(.subheadline)
					.lineLimit(1)
					.padding(8)
					.frame(maxWidth: .infinity, alignment: .leading)
					.background(Color.blue.opacity(0.1))
					.cornerRadius(8)
					.overlay(
						RoundedRectangle(cornerRadius: 8)
							.stroke(Color.blue.opacity(0.3), lineWidth: 1)
					)
			}
			
			// Preview of change contents - now fills available width
			VStack(alignment: .leading, spacing: 2) {
				ForEach(0..<maxLines, id: \.self) { index in
					if let content = change.content, index < content.count {
						Text(trimLeadingWhitespace(content)[index])
							.font(.system(size: 12, design: .monospaced))
							.foregroundColor(.secondary)
							.lineLimit(1)
							.truncationMode(.tail)
							.frame(maxWidth: .infinity, alignment: .leading)
					} else {
						Text(" ")
							.font(.system(size: 12, design: .monospaced))
							.foregroundColor(.clear)
							.frame(maxWidth: .infinity, alignment: .leading)
					}
				}
			}
			.frame(maxWidth: .infinity)
			.frame(height: CGFloat(maxLines) * 14) // Approximate line height
			.padding(8)
			.background(Color.gray.opacity(0.1))
			.cornerRadius(8)
		}
		.padding()
		.background(Color(NSColor.textBackgroundColor).opacity(0.5))
		.cornerRadius(8)
		.overlay(
			RoundedRectangle(cornerRadius: 8)
				.stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
		)
	}
	
	func trimLeadingWhitespace(_ lines: [String]) -> [String] {
		let decodedLines = lines.map { String.decodeIndentation($0) }
		let minWhitespace = decodedLines.compactMap { line -> Int? in
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : line.prefix(while: { $0.isWhitespace }).count
		}.min() ?? 0
		
		return decodedLines.map { line in
			let index = line.index(line.startIndex, offsetBy: min(minWhitespace, line.count))
			return String(line[index...])
		}
	}
}
