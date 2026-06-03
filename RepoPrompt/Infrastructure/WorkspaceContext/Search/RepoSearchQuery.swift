import Foundation

struct RepoSearchQuery: Sendable, Equatable {
	let raw: String
	let lowered: String
	let hasSlash: Bool
	let isWildcard: Bool

	var isEmpty: Bool {
		raw.isEmpty
	}
}

enum RepoSearchQueryFactory {
	private static let defaultMaxLength = 1_000

	static func make(
		_ input: String,
		maxLength: Int = defaultMaxLength,
		supportsWildcards: Bool = true
	) -> RepoSearchQuery {
		let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
		let bounded: String
		if trimmed.count > maxLength {
			bounded = String(trimmed.prefix(maxLength))
		} else {
			bounded = trimmed
		}

		let normalized: String
		if supportsWildcards {
			normalized = bounded
		} else {
			normalized = bounded
				.replacingOccurrences(of: "*", with: "")
				.replacingOccurrences(of: "?", with: "")
				.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		let lowered = normalized.lowercased()
		return RepoSearchQuery(
			raw: normalized,
			lowered: lowered,
			hasSlash: normalized.contains("/"),
			isWildcard: supportsWildcards && (normalized.contains("*") || normalized.contains("?"))
		)
	}
}
