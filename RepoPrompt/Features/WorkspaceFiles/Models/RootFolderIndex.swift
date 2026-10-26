import Foundation

/// Every file and folder of one root folder that the ignore rules allow, by path relative to the root.
///
/// Reading fills it and changes on disk keep it current, whether or not the tree shows a folder.
/// Each folder knows how many files lie under it at any depth and whether reading has listed
/// every folder under it. The root folder itself has the empty relative path.
@MainActor
final class RootFolderIndex {
	/// One folder of the index.
	final class Folder {
		fileprivate unowned let parent: Folder?
		fileprivate var childFolderPaths: Set<String> = []
		fileprivate var childFilePaths: Set<String> = []
		/// Folders at or under this folder whose entries reading has not listed yet.
		fileprivate var unreadFolderCount = 0

		/// Files under this folder at any depth.
		fileprivate(set) var fileCount = 0

		/// Whether reading has listed this folder and every folder under it.
		var isSubtreeRead: Bool { unreadFolderCount == 0 }

		fileprivate init(parent: Folder?) {
			self.parent = parent
		}
	}

	let rootPath: String
	private(set) var filePaths: Set<String> = []
	private(set) var folders: [String: Folder]
	private var unreadFolderPaths: Set<String> = [""]
	private let root: Folder

	/// Whether reading has listed every folder of the root folder.
	var isReadingComplete: Bool { unreadFolderPaths.isEmpty }

	init(rootPath: String) {
		self.rootPath = rootPath
		let root = Folder(parent: nil)
		root.unreadFolderCount = 1
		self.root = root
		self.folders = ["": root]
	}

	/// Adds the entries of one reading chunk and marks the folders it finished listing as read.
	func add(_ chunk: FSPreparedChunk) {
		for folder in chunk.folders {
			addFolder(folder.relativePath, isRead: false)
		}
		for file in chunk.files {
			addFile(file.relativePath)
		}
		for path in chunk.readFolders {
			markFolderRead(path)
		}
	}

	/// Adds a folder. Missing folders above it are added as read.
	func addFolder(_ path: String, isRead: Bool) {
		guard !path.isEmpty, folders[path] == nil else { return }
		if filePaths.contains(path) {
			remove(path)
		}
		let parentPath = Self.parentPath(of: path)
		let parent = folder(at: parentPath)
		parent.childFolderPaths.insert(path)
		let folder = Folder(parent: parent)
		folders[path] = folder
		guard !isRead else { return }
		unreadFolderPaths.insert(path)
		var current: Folder? = folder
		while let node = current {
			node.unreadFolderCount += 1
			current = node.parent
		}
	}

	/// Adds a file. Missing folders above it are added as read.
	func addFile(_ path: String) {
		guard !path.isEmpty, !filePaths.contains(path) else { return }
		if folders[path] != nil {
			remove(path)
		}
		let parent = folder(at: Self.parentPath(of: path))
		parent.childFilePaths.insert(path)
		filePaths.insert(path)
		var current: Folder? = parent
		while let node = current {
			node.fileCount += 1
			current = node.parent
		}
	}

	/// Marks that reading has listed the direct entries of a folder.
	func markFolderRead(_ path: String) {
		guard unreadFolderPaths.remove(path) != nil, let folder = folders[path] else { return }
		var current: Folder? = folder
		while let node = current {
			node.unreadFolderCount -= 1
			current = node.parent
		}
	}

	/// Marks every folder as read once reading of the root folder has finished.
	func finishReading() {
		for folder in folders.values {
			folder.unreadFolderCount = 0
		}
		unreadFolderPaths.removeAll()
	}

	/// Removes a file, or a folder with everything under it.
	func remove(_ path: String) {
		guard !path.isEmpty else { return }
		if filePaths.remove(path) != nil {
			guard let parent = folders[Self.parentPath(of: path)] else { return }
			parent.childFilePaths.remove(path)
			var current: Folder? = parent
			while let node = current {
				node.fileCount -= 1
				current = node.parent
			}
			return
		}
		guard let folder = folders[path], let parent = folder.parent else { return }
		parent.childFolderPaths.remove(path)
		var current: Folder? = parent
		while let node = current {
			node.fileCount -= folder.fileCount
			node.unreadFolderCount -= folder.unreadFolderCount
			current = node.parent
		}
		var pending: [String] = [path]
		while let folderPath = pending.popLast() {
			guard let removed = folders.removeValue(forKey: folderPath) else { continue }
			unreadFolderPaths.remove(folderPath)
			filePaths.subtract(removed.childFilePaths)
			pending.append(contentsOf: removed.childFolderPaths)
		}
	}

	private func folder(at path: String) -> Folder {
		if let folder = folders[path] {
			return folder
		}
		addFolder(path, isRead: true)
		return folders[path] ?? root
	}

	private static func parentPath(of path: String) -> String {
		guard let slash = path.lastIndex(of: "/") else { return "" }
		return String(path[..<slash])
	}
}
