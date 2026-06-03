import Foundation
import Combine

/// Supplies folder / file suggestions for "@" mentions.
/// All public APIs are @MainActor because they touch Swift-UI view models.
@MainActor
final class MentionSuggestionService {

	// MARK: – Constants
	/// Internal sentinel path that represents the synthetic "Selected" folder.
	private let selectedSentinel = "__selected__"

	// MARK: – Stored refs
    private weak var fileManager: RepoFileManagerViewModel?
    private let maxResults: Int

	init(fileManager: RepoFileManagerViewModel?, maxResults: Int = 5) {
        self.fileManager = fileManager
        self.maxResults  = maxResults
    }

	func updateFileManager(_ manager: RepoFileManagerViewModel?) {
        self.fileManager = manager
    }

	// MARK: – Public entry-point
	/// - Parameters:
	///   - query:  Current query string (already *inside* the mention).
	///   - parent: Folder under which we are browsing – `nil` means repo root.
	///
	/// The method fulfils three user journeys:
	///   1. Empty query at repo root  ►  "Selected" pseudo-folder + all roots
	///   2. Empty query inside a real folder  ► list its direct children
	///   3. Any non-empty query  ► regular search, but with Selected-file
	///      matches prepended when browsing at the repo root.
    public func suggestions(
        for query: String,
        under parent: MentionSuggestion? = nil
    ) -> [MentionSuggestion] {

		guard let fm = fileManager else { return [] }
		let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)

		// ------------------------------------------------------------------
		// ❶  Special pseudo-folder: "Selected"
		// ------------------------------------------------------------------
		if let parent = parent,
			parent.relativePath == selectedSentinel
		{
			return selectedFileRows(
				matching: trimmed,
				in: fm
			)
		}

		// ------------------------------------------------------------------
		// ❷  Empty-query behaviour
		// ------------------------------------------------------------------
		if trimmed.isEmpty {

			if let parent = parent, parent.kind == .folder {
				// Inside a *real* folder  → list its direct children
				if let folderVM = fm.findFolderByRelativePath(parent.relativePath) {
					return directChildren(of: folderVM, limit: maxResults)
				}

				// Fallback when the folder is a *root* not present in the index
				if parent.relativePath.isEmpty,
					let rootByName = fm.rootFolders
						.first(where: { $0.name == parent.displayName })
				{
					return directChildren(of: rootByName, limit: maxResults)
				}

				// Unknown folder
				return []
			}

			// Repo root  → "Selected" row + all root folders
			var rows: [MentionSuggestion] = []

			rows.append(
				MentionSuggestion(
					displayName: "Selected",
					relativePath: selectedSentinel,
					kind: .folder
				)
			)

			// Append every loaded root folder (order preserved)
			rows.append(contentsOf:
				fm.rootFolders.map {
					MentionSuggestion(
						displayName: $0.name,
						relativePath: $0.relativePath,
						kind: .folder
					)
				}
			)

			return rows
		}

		// ------------------------------------------------------------------
		// ❸  Non-empty query  → normal search
		//     (but prepend Selected-file matches when at repo root)
		// ------------------------------------------------------------------
		let searchQuery = trimmed
		var searchBases: [FolderViewModel]

		if let parent = parent,
			parent.kind == .folder,
			let folder = fm.findFolderByRelativePath(parent.relativePath) {
			searchBases = [folder]
        } else {
			searchBases = fm.rootFolders
        }

		// Gather matches from the tree
        var collected: [MentionSuggestion] = []
		for folder in searchBases {
			collectMatches(in: folder,
							matching: searchQuery,
							into: &collected)
            if collected.count >= maxResults { break }
        }

		// Prepend matching Selected-file rows when browsing at repo root
		if parent == nil {
			var selectedMatches: [MentionSuggestion] = []
			for file in fm.selectedFiles {
				guard selectedMatches.count < maxResults else { break }
				if file.name.range(of: searchQuery, options: .caseInsensitive) != nil ||
					file.relativePath.range(of: searchQuery, options: .caseInsensitive) != nil {
					selectedMatches.append(
						MentionSuggestion(
							displayName: file.name,
							relativePath: file.relativePath,
							kind: .file
						)
					)
				}
			}

			// Merge & deduplicate by relativePath while preserving order
			var seen = Set<String>()
			let merged = (selectedMatches + collected).filter { row in
				if seen.contains(row.relativePath) { return false }
				seen.insert(row.relativePath)
				return true
			}
			return Array(merged.prefix(maxResults))
		}

		return collected
    }

	// MARK: – Helper: rows inside the pseudo "Selected" folder
	private func selectedFileRows(matching query: String,
									in fm: RepoFileManagerViewModel) -> [MentionSuggestion]
	{
		let files: [FileViewModel]
		if query.isEmpty {
			// Full list in user selection order
			files = fm.selectedFiles
		} else {
			// Filter inside selected files
			files = fm.selectedFiles.filter {
				$0.name.range(of: query, options: .caseInsensitive) != nil ||
				$0.relativePath.range(of: query, options: .caseInsensitive) != nil
			}
		}

		return files.map {
			MentionSuggestion(
				displayName: $0.name,
				relativePath: $0.relativePath,
				kind: .file
			)
		}
	}

	// MARK: – Helper: direct children rows of a folder
	private func directChildren(of folder: FolderViewModel,
								limit: Int) -> [MentionSuggestion] {
		var rows: [MentionSuggestion] = []

		for sub in folder.subfolders {
			rows.append(
				MentionSuggestion(
					displayName: sub.name,
					relativePath: sub.relativePath,
					kind: .folder
				)
			)
			if rows.count >= limit { return rows }
		}
		for file in folder.files where rows.count < limit {
			rows.append(
				MentionSuggestion(
					displayName: file.name,
					relativePath: file.relativePath,
					kind: .file
				)
			)
			if rows.count >= limit { break }
		}
		return rows
	}

	// MARK: – Helper: recursive search
	/// Depth-first search that collects folders & files whose *name* contains
	/// `query` (case-insensitive), stopping when `results` has ≥ `maxResults`.
    private func collectMatches(
        in folder: FolderViewModel,
		matching query: String,
		into results: inout [MentionSuggestion]
	) {
		guard results.count < maxResults else { return }

		// (1) Folder itself  (skip repo root which has empty relativePath)
        if !folder.relativePath.isEmpty,
			folder.name.range(of: query, options: .caseInsensitive) != nil {
            results.append(
                MentionSuggestion(
                    displayName: folder.name,
                    relativePath: folder.relativePath,
                    kind: .folder
                )
            )
			if results.count >= maxResults { return }
        }

		// (2) Files
		for file in folder.files where results.count < maxResults {
			if file.name.range(of: query, options: .caseInsensitive) != nil {
                results.append(
                    MentionSuggestion(
                        displayName: file.name,
                        relativePath: file.relativePath,
                        kind: .file
                    )
                )
				if results.count >= maxResults { return }
            }
        }

		// (3) Recurse into sub-folders
		for sub in folder.subfolders where results.count < maxResults {
			collectMatches(in: sub, matching: query, into: &results)
        }
    }
}