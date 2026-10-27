import Foundation

struct FileTreeSelectionSnapshot: Sendable {
	let roots: [FileTreeFolderSnapshot]
	let selectedFilePaths: Set<String>
	let mode: String
	let showFullPaths: Bool
	let onlyIncludeRootsWithSelectedFiles: Bool
	let includeLegend: Bool
	let showCodeMapMarkers: Bool

	init(
		roots: [FileTreeFolderSnapshot],
		selectedFilePaths: Set<String>,
		mode: String,
		showFullPaths: Bool,
		onlyIncludeRootsWithSelectedFiles: Bool,
		includeLegend: Bool,
		showCodeMapMarkers: Bool = true
	) {
		self.roots = roots
		self.selectedFilePaths = selectedFilePaths
		self.mode = mode
		self.showFullPaths = showFullPaths
		self.onlyIncludeRootsWithSelectedFiles = onlyIncludeRootsWithSelectedFiles
		self.includeLegend = includeLegend
		self.showCodeMapMarkers = showCodeMapMarkers
	}
}

/// A folder of the tree. Its id is its standardized full path.
struct FileTreeFolderSnapshot: Sendable, Hashable {
	let id: String
	let name: String
	let nameSortKey: String
	let fullPath: String
	let standardizedFullPath: String
	let standardizedRootPath: String
	let children: [FileTreeNodeSnapshot]
}

/// A file of the tree. Its id is its standardized full path.
struct FileTreeFileSnapshot: Sendable, Hashable {
	let id: String
	let name: String
	let nameSortKey: String
	let fileExtension: String?
	let hasCodeMap: Bool
}

indirect enum FileTreeNodeSnapshot: Sendable, Hashable {
	case folder(FileTreeFolderSnapshot)
	case file(FileTreeFileSnapshot)

	var id: String {
		switch self {
		case .folder(let folder): return folder.id
		case .file(let file): return file.id
		}
	}

	var name: String {
		switch self {
		case .folder(let folder): return folder.name
		case .file(let file): return file.name
		}
	}

	var nameSortKey: String {
		switch self {
		case .folder(let folder): return folder.nameSortKey
		case .file(let file): return file.nameSortKey
		}
	}
}
