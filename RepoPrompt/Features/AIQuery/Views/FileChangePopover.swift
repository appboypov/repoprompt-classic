//
//  FileChangePopover.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-11-10.
//

import SwiftUI

struct FileChangePopoverView: View {
	let contentItem: ContentItem
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	var body: some View {
		VStack(alignment: .leading, spacing: 8) {
			// Header with file path and action
			HStack {
				Text(contentItem.filePath)
					.font(fontPreset.headlineFont)
					.lineLimit(1)
					.truncationMode(.head)
				Spacer()
				ActionLabel(action: contentItem.action)
			}
			.padding(.bottom, 4)
			
			ScrollView {
				changesList
			}
		}
		.padding()
		.frame(width: fontPreset.scaledMetric(500))
	}
	
	private var changesList: some View {
		VStack(alignment: .leading, spacing: 12) {
			let unIndedentedChanges = contentItem.getTrimmedWhiteSpaceChanges()
			ForEach(Array(zip(contentItem.changes.indices, contentItem.changes)), id: \.0) { index, change in
				VStack(alignment: .leading, spacing: 4) {
					if index < contentItem.descriptions.count, !contentItem.descriptions[index].isEmpty {
						// Description box
						Text(contentItem.descriptions[index])
							.padding(8)
							.frame(maxWidth: .infinity, alignment: .leading)
							.background(Color.blue.opacity(0.1))
							.cornerRadius(8)
							.overlay(
								RoundedRectangle(cornerRadius: 8)
									.stroke(Color.blue.opacity(0.3), lineWidth: 1)
							)
					}
					
					// Code block
					if !change.isEmpty {
						CodeBlockWithIndendation(content: unIndedentedChanges[index], indendedContent: contentItem.changes[index])
					}
				}
			}
		}
	}
}


struct CodeBlockWithIndendation: View {
	let content: String
	let indendedContent: String
	var allowTextInteraction: Bool = true
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }
	
	@State private var isCopyHovering = false
	
	var body: some View {
		ZStack(alignment: .topTrailing) {
			Text(content)
				.textSelection(.enabled)
				.allowsHitTesting(allowTextInteraction)
				.font(fontPreset.codeFont)
				.padding(8)
				.frame(maxWidth: .infinity, alignment: .leading)
				.lineLimit(nil)
				.fixedSize(horizontal: false, vertical: true)
			
			Button(action: {
				NSPasteboard.general.clearContents()
				NSPasteboard.general.setString(indendedContent, forType: .string)
			}) {
				Image(systemName: "doc.on.clipboard")
					.foregroundColor(.secondary)
					.frame(width: 24, height: 24)
					.contentShape(Rectangle())
			}
			.buttonStyle(PlainButtonStyle())
			.opacity(isCopyHovering ? 1 : 0.6)
			.onHover { hovering in
				withAnimation(.easeInOut(duration: 0.1)) {
					isCopyHovering = hovering
				}
			}
			.padding(4)
		}
		.background(Color.black.opacity(0.05))
		.cornerRadius(4)
	}
}

// MARK: - ContentItem Extension for Trimming Whitespace

extension ContentItem {
	/// Returns a trimmed version of the changes array with leading whitespace removed.
	func getTrimmedWhiteSpaceChanges() -> [String] {
		let encoded = changes.map { String.encodeIndentationAsSpaces($0) }
		return Self.trimLeadingWhitespace(encoded)
	}

	/// Trim leading whitespace from an array of lines by detecting
	/// the smallest common leading indentation and removing it.
	private static func trimLeadingWhitespace(_ lines: [String]) -> [String] {
		let decodedLines = lines.map { String.decodeIndentation($0) }

		let minWhitespaceCount = decodedLines.compactMap { line -> Int? in
			let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : line.prefix(while: { $0.isWhitespace }).count
		}.min() ?? 0

		return decodedLines.map { line in
			let index = line.index(line.startIndex, offsetBy: min(minWhitespaceCount, line.count))
			return String(line[index...])
		}
	}
}
