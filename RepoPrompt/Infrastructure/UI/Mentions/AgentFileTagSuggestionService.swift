import Foundation

@MainActor
final class AgentFileTagSuggestionService {
	private struct FileCandidate: Sendable {
		let displayName: String
		let disambiguationLabel: String?
		let commitDisplayText: String
		let matchName: String
		let tokenRelativePath: String
		let scoreRelativePath: String
		let nameLower: String
		let scorePathLower: String
	}

	private nonisolated static let excludedPathComponent = "_git_data"
	private nonisolated static let fuzzyThreshold: Double = 0.85
	private nonisolated static let indexCandidateMultiplier = 8
	private nonisolated static let minimumIndexCandidateLimit = 64

	private weak var fileManager: RepoFileManagerViewModel?
	private let maxResults: Int

	private var cachedCandidates: [FileCandidate] = []
	private var cachedGenerationSignature: UInt64?
	private var cachedHasMultipleRoots: Bool = false
	private var pathSearchIndex: PathSearchIndex?

	init(fileManager: RepoFileManagerViewModel?, maxResults: Int = 5) {
		self.fileManager = fileManager
		self.maxResults = maxResults
	}

	func updateFileManager(_ manager: RepoFileManagerViewModel?) {
		if manager !== fileManager {
			fileManager = manager
			cachedCandidates.removeAll()
			cachedGenerationSignature = nil
			cachedHasMultipleRoots = false
			pathSearchIndex = nil
		}
	}

	func suggestions(for rawQuery: String) async -> [MentionSuggestion] {
		guard let fileManager else { return [] }

		// Parse the query BEFORE triggering a full candidate refresh. A bare
		// `@` produces an empty query and only needs the cheap selected /
		// already-cached suggestions, so we intentionally skip the heavy
		// allFilesSnapshot + sort + PathSearchIndex build on this path.
		// See docs/investigations/agent-mode-file-mention-large-repo-crash-2026-04-21.md.
		let query = RepoSearchQueryFactory.make(rawQuery, supportsWildcards: false)
		if query.isEmpty {
			let selected = selectedSuggestionsForEmptyQuery(fileManager: fileManager)
			if !selected.isEmpty {
				return Array(selected.prefix(maxResults))
			}
			if !cachedCandidates.isEmpty {
				return Array(cachedCandidates.prefix(maxResults)).map(Self.makeSuggestion(from:))
			}
			return []
		}

		await refreshCandidatesIfNeeded(fileManager: fileManager)
		let indexed = await indexedCandidates(for: query)
		guard !indexed.isEmpty else { return [] }
		return scoredSuggestions(from: indexed, query: query)
	}

	private func refreshCandidatesIfNeeded(fileManager: RepoFileManagerViewModel) async {
		let generationSignature = fileManager.currentHierarchyGenerationSignature()
		if cachedGenerationSignature == generationSignature, !cachedCandidates.isEmpty {
			return
		}

		let files = fileManager.allFilesSnapshot(sorted: false)
		cachedHasMultipleRoots = Set(files.map(\.rootFolderPath)).count > 1

		let candidateFiles = files.filter {
			!Self.shouldExcludeFromSuggestions(relativePath: $0.relativePath)
		}

		var rootNamesByFileName: [String: Set<String>] = [:]
		var countByFileName: [String: Int] = [:]
		rootNamesByFileName.reserveCapacity(candidateFiles.count)
		countByFileName.reserveCapacity(candidateFiles.count)
		for file in candidateFiles {
			let fileNameKey = file.name.lowercased()
			countByFileName[fileNameKey, default: 0] += 1
			rootNamesByFileName[fileNameKey, default: []]
				.insert(file.rootFolderName.lowercased())
		}

		cachedCandidates = candidateFiles.map { file in
			let tokenRelativePath = cachedHasMultipleRoots ? file.uniqueRelativePath : file.relativePath
			let scoreRelativePath = file.relativePath
			let fileNameKey = file.name.lowercased()
			let isDuplicateName = (countByFileName[fileNameKey] ?? 0) > 1
			let spansMultipleRoots = (rootNamesByFileName[fileNameKey]?.count ?? 0) > 1
			let rootLabel = file.rootFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
			let displayName = file.name
			let disambiguationLabel: String?
			if isDuplicateName {
				if spansMultipleRoots, !rootLabel.isEmpty {
					disambiguationLabel = rootLabel
				} else if let parentLabel = Self.parentDirectoryLabel(for: scoreRelativePath), !parentLabel.isEmpty {
					disambiguationLabel = parentLabel
				} else if !rootLabel.isEmpty {
					disambiguationLabel = rootLabel
				} else {
					disambiguationLabel = nil
				}
			} else {
				disambiguationLabel = nil
			}

			return FileCandidate(
				displayName: displayName,
				disambiguationLabel: disambiguationLabel,
				commitDisplayText: Self.commitDisplayText(
					fileName: file.name,
					tokenRelativePath: tokenRelativePath,
					isDuplicateName: isDuplicateName
				),
				matchName: file.name,
				tokenRelativePath: tokenRelativePath,
				scoreRelativePath: scoreRelativePath,
				nameLower: file.name.lowercased(),
				scorePathLower: scoreRelativePath.lowercased()
			)
		}
		cachedCandidates.sort { lhs, rhs in
			if lhs.scorePathLower != rhs.scorePathLower {
				return lhs.scorePathLower < rhs.scorePathLower
			}
			return lhs.tokenRelativePath < rhs.tokenRelativePath
		}
		cachedGenerationSignature = generationSignature
		pathSearchIndex = cachedCandidates.isEmpty
			? nil
			: await PathSearchIndex(paths: cachedCandidates.map(\.scoreRelativePath))
	}

	private func indexedCandidates(for query: RepoSearchQuery) async -> [FileCandidate] {
		guard let pathSearchIndex, !cachedCandidates.isEmpty else { return [] }
		let candidateLimit = max(maxResults * Self.indexCandidateMultiplier, Self.minimumIndexCandidateLimit)
		let indexCandidates = await pathSearchIndex.search(query.raw, limit: candidateLimit)
		guard !indexCandidates.isEmpty else { return [] }

		var seen = Set<Int>()
		var results: [FileCandidate] = []
		results.reserveCapacity(indexCandidates.count)

		for candidate in indexCandidates {
			guard seen.insert(candidate.index).inserted else { continue }
			guard cachedCandidates.indices.contains(candidate.index) else { continue }
			results.append(cachedCandidates[candidate.index])
		}

		return results
	}

	private func scoredSuggestions(from candidates: [FileCandidate], query: RepoSearchQuery) -> [MentionSuggestion] {
		let scoringCandidates = candidates.map {
			RepoSearchBatchScorer.Candidate(
				name: $0.matchName,
				path: $0.scoreRelativePath,
				nameLower: $0.nameLower,
				pathLower: $0.scorePathLower
			)
		}
		let rawScores = RepoSearchBatchScorer.scores(
			for: scoringCandidates,
			query: query,
			fuzzyThreshold: Self.fuzzyThreshold
		)

		var scored: [(candidate: FileCandidate, score: Int32)] = []
		scored.reserveCapacity(candidates.count)
		for (index, score) in rawScores.enumerated() where score > 0 {
			guard candidates.indices.contains(index) else { continue }
			scored.append((candidates[index], score))
		}

		guard !scored.isEmpty else { return [] }

		scored.sort { lhs, rhs in
			if lhs.score != rhs.score {
				return lhs.score > rhs.score
			}
			if lhs.candidate.scoreRelativePath.count != rhs.candidate.scoreRelativePath.count {
				return lhs.candidate.scoreRelativePath.count < rhs.candidate.scoreRelativePath.count
			}
			return lhs.candidate.scorePathLower < rhs.candidate.scorePathLower
		}

		return scored
			.prefix(maxResults)
			.map { Self.makeSuggestion(from: $0.candidate) }
	}

	/// Build the suggestion list for an empty (bare `@`) query.
	///
	/// Must never use `Dictionary(uniqueKeysWithValues:)` on `tokenRelativePath`
	/// — that key is NOT globally unique across workspaces (e.g. two roots
	/// with the same basename containing the same relative file path produce
	/// identical `uniqueRelativePath` values). Duplicate keys would trap.
	/// Related: docs/investigations/agent-mode-file-mention-large-repo-crash-2026-04-21.md.
	///
	/// This path is designed to be cheap: it does NOT trigger
	/// `refreshCandidatesIfNeeded`, and it works correctly whether or not a
	/// previous non-empty search already populated `cachedCandidates`.
	private func selectedSuggestionsForEmptyQuery(fileManager: RepoFileManagerViewModel) -> [MentionSuggestion] {
		let hasMultipleRoots: Bool
		if !cachedCandidates.isEmpty {
			hasMultipleRoots = cachedHasMultipleRoots
		} else {
			// Cache not yet populated (empty-query fast path). Fall back to
			// cheap checks so we still pick the correct token-path style.
			hasMultipleRoots = fileManager.rootFolders.count > 1
				|| Set(fileManager.selectedFiles.map(\.rootFolderPath)).count > 1
		}
		let candidateByPath = makeCandidateByTokenPath()
		var seenIdentities = Set<String>()
		return fileManager.selectedFiles.compactMap { file in
			guard !Self.shouldExcludeFromSuggestions(relativePath: file.relativePath) else { return nil }
			// Dedupe by stable file identity (standardized absolute path), NOT
			// by tokenRelativePath — the latter can collide in multi-root
			// workspaces with same-basename roots.
			guard seenIdentities.insert(file.standardizedFullPath).inserted else { return nil }
			let tokenRelativePath = hasMultipleRoots ? file.uniqueRelativePath : file.relativePath
			if let candidate = candidateByPath[tokenRelativePath] {
				return Self.makeSuggestion(from: candidate)
			}
			return MentionSuggestion(
				displayName: file.name,
				relativePath: tokenRelativePath,
				kind: .file,
				commitDisplayText: file.name
			)
		}
	}

	/// Duplicate-tolerant lookup for cached candidates. Keep the first
	/// candidate seen for a given token path so we still pick up any
	/// precomputed disambiguation / display text when we do have a hit.
	private func makeCandidateByTokenPath() -> [String: FileCandidate] {
		Dictionary(
			cachedCandidates.map { ($0.tokenRelativePath, $0) },
			uniquingKeysWith: { existing, _ in existing }
		)
	}

	private static func makeSuggestion(from candidate: FileCandidate) -> MentionSuggestion {
		MentionSuggestion(
			displayName: candidate.displayName,
			relativePath: candidate.tokenRelativePath,
			kind: .file,
			subtitle: candidate.disambiguationLabel,
			commitDisplayText: candidate.commitDisplayText
		)
	}

	nonisolated static func commitDisplayText(
		fileName: String,
		tokenRelativePath: String,
		isDuplicateName: Bool
	) -> String {
		let trimmedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
		if !isDuplicateName, !trimmedFileName.isEmpty {
			return trimmedFileName
		}
		return tokenRelativePath
	}

	private nonisolated static func shouldExcludeFromSuggestions(relativePath: String) -> Bool {
		relativePath
			.split(whereSeparator: { $0 == "/" || $0 == "\\" })
			.contains { String($0).lowercased() == excludedPathComponent }
	}

	private nonisolated static func parentDirectoryLabel(for relativePath: String) -> String? {
		let normalized = relativePath.replacingOccurrences(of: "\\", with: "/")
		let components = normalized.split(separator: "/").map(String.init)
		guard components.count > 1 else { return nil }
		let parentComponents = components.dropLast()
		guard !parentComponents.isEmpty else { return nil }
		return parentComponents.joined(separator: "/")
	}

	// MARK: - Testing support

	/// Seed `cachedCandidates` from a list of token paths so tests can
	/// exercise duplicate-key dedupe behavior without standing up a full
	/// workspace. Kept in this file so tests can reach `FileCandidate`,
	/// which is intentionally private to the service.
	func seedCandidateCacheForTesting(tokenPaths: [String], hasMultipleRoots: Bool) {
		cachedHasMultipleRoots = hasMultipleRoots
		cachedCandidates = tokenPaths.map { tokenPath in
			let basename = (tokenPath as NSString).lastPathComponent
			return FileCandidate(
				displayName: basename,
				disambiguationLabel: nil,
				commitDisplayText: tokenPath,
				matchName: basename,
				tokenRelativePath: tokenPath,
				scoreRelativePath: tokenPath,
				nameLower: basename.lowercased(),
				scorePathLower: tokenPath.lowercased()
			)
		}
	}

	var cachedCandidateCountForTesting: Int { cachedCandidates.count }

	var pathSearchIndexIsBuiltForTesting: Bool { pathSearchIndex != nil }
}
