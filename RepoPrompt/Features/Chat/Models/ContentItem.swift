import Foundation

/// Represents an individual piece of content (text, code, file, etc.) within a chat message.
public struct ContentItem: Identifiable, Equatable {
	/// A **string** ID that remains stable across partial parses if you provide an offset.
	/// Otherwise, it is a fallback hash-based ID so older code can still create items easily.
	public let id: String

	/// The overall content type (text, code, file, etc.).
	public let type: ContentType

	/// The user-facing "raw" content.
	public var content: String

	/// Optional file path if relevant.
	public var filePath: String

	/// The action if this is a file-based change (e.g. "modify", "create", "delete", etc.).
	public var action: String

	/// Lines of "change" text, if any.
	public var changes: [String]

	/// Descriptions for each change, if any.
	public var descriptions: [String]

	// MARK: - Word-based line logic (approximate lines for preview)

	/// Approximate line-equivalent count (for UI previews).
	public let approximateLineEquivalentCount: Int

	/// A joined string of the first 10 line-equivalents (for UI previews).
	public let firstTenLineEquivalents: String

	// MARK: - Initializers

	/// Creates a new `ContentItem`. If `startIndexInStream` is provided, we build a stable
	/// ID from `(offset, type, filePath)`. Otherwise, we compute a fallback hash-based ID
	/// from the content + file path to keep older code working.
	///
	/// - Parameters:
	///   - startIndexInStream: Optional offset from the parser. If `nil`, we use a fallback hash-based ID.
	///   - type: The kind of content (text, code, file, etc.).
	///   - content: The extracted substring from the message (or entire text).
	///   - filePath: File path if relevant.
	///   - action: Action verb, if file-based.
	///   - changes: Array of change snippets, if parsed.
	///   - descriptions: Text descriptions for each change, if parsed.
	public init(
		startIndexInStream: Int? = nil,
		type: ContentType,
		content: String,
		filePath: String = "",
		action: String = "",
		changes: [String] = [],
		descriptions: [String] = []
	) {
		self.type = type
		self.content = content
		self.filePath = filePath
		self.action = action
		self.changes = changes
		self.descriptions = descriptions

		// 1) Build ID
		if let offset = startIndexInStream {
			// "Stable ID" mode
			self.id = Self.buildStableID(
				startIndex: offset,
				contentType: type,
				filePath: filePath
			)
		} else {
			// Fallback: older code path
			self.id = Self.buildFallbackHashID(
				content: content,
				filePath: filePath,
				contentType: type
			)
		}

		// 2) Word-based line logic
		let (count, preview) = Self.calculateLineData(from: content)
		self.approximateLineEquivalentCount = count
		self.firstTenLineEquivalents = preview
	}

	// MARK: - ID Builders

	/// A "stable" string ID if you have a known parser offset.
	/// Note: Does not include contentType so that if an item's type changes during streaming
	/// (e.g., from .text to .code), SwiftUI can maintain view identity and avoid flicker.
	private static func buildStableID(
		startIndex: Int,
		contentType: ContentType,
		filePath: String
	) -> String {
		if filePath.isEmpty {
			return "item(\(startIndex))"
		} else {
			return "item(\(startIndex))|\(filePath)"
		}
	}

	/// A fallback ID if `startIndexInStream` is nil. We use hash-based approach
	/// from the `content`, `filePath`, and `contentType`.
	private static func buildFallbackHashID(
		content: String,
		filePath: String,
		contentType: ContentType
	) -> String {
		// Combine the relevant pieces into one big string, then hash it.
		let combinedString = "\(contentType.rawValue)|\(filePath)|\(content)"
		let hash = combinedString.hashValue
		return "\(contentType.rawValue)-hash:\(hash)"
	}

	// MARK: - Approximate line logic

	/// Computing approximate line equivalences for UI previews.
	private static func calculateLineData(
		from content: String
	) -> (lineEquivalentCount: Int, joinedPreview: String) {
		let physicalLines = content.components(separatedBy: .newlines)
		var cumulativeEquivalents = 0
		var previewLines = [String]()
		var reachedLimit = false

		for line in physicalLines {
			let wordCount = line.split { $0.isWhitespace }.count
			let lineEquivalent = max(1, Int(ceil(Double(wordCount) / 10.0)))

			if cumulativeEquivalents + lineEquivalent > 10 {
				reachedLimit = true
				break
			}
			previewLines.append(line)
			cumulativeEquivalents += lineEquivalent
		}

		let finalCount = reachedLimit ? 11 : cumulativeEquivalents
		let joinedPreview = previewLines.joined(separator: "\n")

		return (finalCount, joinedPreview)
	}
}

// MARK: - ContentType
public enum ContentType: String, Codable {
	case text
	case code
	case file
}

// MARK: - DelegateEditItem (used for file editing)
struct DelegateEditItem {
	var filePath: String
	var changes: [Change]

	struct Change {
		let description: String
		let codeSnippet: String
		let complexity: Int
	}

	func formattedString(encodeIndentation: Bool = false) -> String {
		var result = "<changes-to-apply>\n"
		for (index, change) in changes.enumerated() {
			result += "\nChange \(index + 1):\n"
			result += "\(change.description)\n"
			result += "```\n\(change.codeSnippet)\n```\n"
		}
		result += "</changes-to-apply>"
		return result
	}

	static func buildRequestKey(path: String, changes: [Change]) -> String {
		let normalizedPath = ((path as NSString).standardizingPath).lowercased()
		var key = normalizedPath + "\n"
		for change in changes {
			let desc = change.description.trimmingCharacters(in: .whitespacesAndNewlines)
			let body = change.codeSnippet
				.replacingOccurrences(of: "\r\n", with: "\n")
				.replacingOccurrences(of: "\r", with: "\n")
				.trimmingCharacters(in: .whitespacesAndNewlines)
			key += "DESC:\(desc)\nCODE:\(body)\n--\n"
		}
		return key
	}
}
