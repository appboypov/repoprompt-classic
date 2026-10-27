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
///
/// A folder read from an index builds its children each time they are read, so a tree costs only the folders a reader visits.
struct FileTreeFolderSnapshot: Sendable, Hashable {
	private enum ChildrenSource: Sendable {
		case nodes([FileTreeNodeSnapshot])
		case index(IndexFileTree, relativePath: String)
	}

	let id: String
	let name: String
	let nameSortKey: String
	let fullPath: String
	let standardizedFullPath: String
	let standardizedRootPath: String
	private let source: ChildrenSource

	var children: [FileTreeNodeSnapshot] {
		switch source {
		case .nodes(let nodes): nodes
		case .index(let tree, let relativePath): tree.children(ofFolder: relativePath)
		}
	}

	/// The folders directly in this folder, and only those of its files whose ids `fileIDs` holds.
	/// A folder read from an index skips its other files without building them.
	func children(keepingFilesIn fileIDs: Set<String>) -> [FileTreeNodeSnapshot] {
		switch source {
		case .nodes(let nodes):
			nodes.filter { node in
				guard case .file(let file) = node else { return true }
				return fileIDs.contains(file.id)
			}
		case .index(let tree, let relativePath):
			tree.children(ofFolder: relativePath, keepingFilesIn: fileIDs)
		}
	}

	init(
		id: String,
		name: String,
		nameSortKey: String,
		fullPath: String,
		standardizedFullPath: String,
		standardizedRootPath: String,
		children: [FileTreeNodeSnapshot]
	) {
		self.id = id
		self.name = name
		self.nameSortKey = nameSortKey
		self.fullPath = fullPath
		self.standardizedFullPath = standardizedFullPath
		self.standardizedRootPath = standardizedRootPath
		self.source = .nodes(children)
	}

	init(
		id: String,
		name: String,
		nameSortKey: String,
		fullPath: String,
		standardizedFullPath: String,
		standardizedRootPath: String,
		indexTree: IndexFileTree,
		relativePath: String
	) {
		self.id = id
		self.name = name
		self.nameSortKey = nameSortKey
		self.fullPath = fullPath
		self.standardizedFullPath = standardizedFullPath
		self.standardizedRootPath = standardizedRootPath
		self.source = .index(indexTree, relativePath: relativePath)
	}

	/// The ids of this folder and the folders under it that hold a selected file at any depth.
	/// A folder read from an index finds them from the selected paths alone, without visiting its subtree.
	func folderIDsHoldingFiles(_ fileIDs: Set<String>) -> Set<String> {
		guard !fileIDs.isEmpty else { return [] }
		if case .index(let tree, let relativePath) = source {
			return tree.folderIDsHoldingFiles(fileIDs, under: relativePath)
		}
		var result = Set<String>()
		var visited = Set<String>()

		@discardableResult
		func dfs(_ folder: FileTreeFolderSnapshot) -> Bool {
			if Task.isCancelled { return false }
			guard visited.insert(folder.id).inserted else { return false }

			var contains = false
			for child in folder.children {
				if Task.isCancelled { return false }
				switch child {
				case .file(let file):
					if fileIDs.contains(file.id) {
						contains = true
					}
				case .folder(let subfolder):
					if dfs(subfolder) {
						contains = true
					}
				}
			}

			if contains {
				result.insert(folder.id)
			}
			return contains
		}

		dfs(self)
		return result
	}

	static func == (lhs: FileTreeFolderSnapshot, rhs: FileTreeFolderSnapshot) -> Bool {
		lhs.id == rhs.id
			&& lhs.name == rhs.name
			&& lhs.nameSortKey == rhs.nameSortKey
			&& lhs.fullPath == rhs.fullPath
			&& lhs.standardizedFullPath == rhs.standardizedFullPath
			&& lhs.standardizedRootPath == rhs.standardizedRootPath
			&& lhs.children == rhs.children
	}

	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
}

/// The folders and files of one root folder's index, read as tree nodes one folder at a time.
struct IndexFileTree: Sendable {
	let contents: RootFolderIndex.Contents
	let showEmptyFolders: Bool
	/// The codemaps of scanned code files by standardized full path, for files with and without a tree item.
	let codemapPaths: [String: FileAPI]
	/// Whether the tree item of a file has a codemap the prompt accepts, by standardized full path.
	let treeItemCodeMaps: [String: Bool]

	/// The folders and then the files directly in a folder. A read folder without files is left out unless empty folders show.
	/// With `fileIDs`, only the files whose ids it holds.
	func children(ofFolder relativePath: String, keepingFilesIn fileIDs: Set<String>? = nil) -> [FileTreeNodeSnapshot] {
		guard let folder = contents.folders[relativePath] else { return [] }
		let rootPath = contents.rootPath
		var nodes: [FileTreeNodeSnapshot] = []
		nodes.reserveCapacity(folder.childFolderPaths.count + (fileIDs == nil ? folder.childFilePaths.count : 0))
		for childPath in folder.childFolderPaths {
			guard let subfolder = contents.folders[childPath] else { continue }
			if !showEmptyFolders, subfolder.isKnownEmpty { continue }
			let fullPath = StandardizedPath.join(standardizedRoot: rootPath, standardizedRelativePath: childPath)
			let name = (childPath as NSString).lastPathComponent
			nodes.append(.folder(FileTreeFolderSnapshot(
				id: fullPath,
				name: name,
				nameSortKey: name.lowercased(),
				fullPath: fullPath,
				standardizedFullPath: fullPath,
				standardizedRootPath: rootPath,
				indexTree: self,
				relativePath: childPath
			)))
		}
		func fileNode(_ childPath: String) -> FileTreeNodeSnapshot {
			let fullPath = StandardizedPath.join(standardizedRoot: rootPath, standardizedRelativePath: childPath)
			let name = (childPath as NSString).lastPathComponent
			let fileExtension = (name as NSString).pathExtension
			return .file(FileTreeFileSnapshot(
				id: fullPath,
				name: name,
				nameSortKey: name.lowercased(),
				fileExtension: fileExtension.isEmpty ? nil : fileExtension,
				hasCodeMap: treeItemCodeMaps[fullPath] ?? (codemapPaths[fullPath] != nil)
			))
		}
		if let fileIDs {
			for childPath in filePaths(of: folder, at: relativePath, keepingFilesIn: fileIDs) {
				nodes.append(fileNode(childPath))
			}
		} else {
			for childPath in folder.childFilePaths {
				nodes.append(fileNode(childPath))
			}
		}
		return nodes
	}

	/// The paths of the files directly in a folder whose ids `fileIDs` holds.
	/// Walks whichever is smaller: the folder's files or `fileIDs`.
	private func filePaths(
		of folder: RootFolderIndex.Contents.Folder,
		at relativePath: String,
		keepingFilesIn fileIDs: Set<String>
	) -> [String] {
		let rootPath = contents.rootPath
		guard fileIDs.count < folder.childFilePaths.count else {
			return folder.childFilePaths.compactMap { childPath in
				fileIDs.contains(StandardizedPath.join(standardizedRoot: rootPath, standardizedRelativePath: childPath)) ? childPath : nil
			}
		}
		let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
		return fileIDs.compactMap { fileID in
			guard fileID.hasPrefix(rootPrefix) else { return nil }
			let filePath = String(fileID.dropFirst(rootPrefix.count))
			guard Self.parentPath(of: filePath) == relativePath, folder.childFilePaths.contains(filePath) else { return nil }
			return filePath
		}
	}

	/// The ids of a folder and the folders under it that hold one of the files at any depth,
	/// found from the files' paths and the folders above them.
	func folderIDsHoldingFiles(_ fileIDs: Set<String>, under relativePath: String) -> Set<String> {
		let rootPath = contents.rootPath
		let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
		let folderPrefix = relativePath.isEmpty ? "" : relativePath + "/"
		var result = Set<String>()
		for fileID in fileIDs where fileID.hasPrefix(rootPrefix) {
			let filePath = String(fileID.dropFirst(rootPrefix.count))
			guard filePath.hasPrefix(folderPrefix) else { continue }
			var folderPath = Self.parentPath(of: filePath)
			guard contents.folders[folderPath]?.childFilePaths.contains(filePath) == true else { continue }
			while result.insert(StandardizedPath.join(standardizedRoot: rootPath, standardizedRelativePath: folderPath)).inserted,
				folderPath != relativePath {
				folderPath = Self.parentPath(of: folderPath)
			}
		}
		return result
	}

	private static func parentPath(of path: String) -> String {
		guard let slash = path.lastIndex(of: "/") else { return "" }
		return String(path[..<slash])
	}
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
