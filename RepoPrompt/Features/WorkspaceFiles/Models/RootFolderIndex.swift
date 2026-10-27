import Foundation

/// Every file and folder of one root folder that the ignore rules allow, by path relative to the root.
///
/// Reading fills it and changes on disk keep it current, whether or not the tree shows a folder.
/// Each folder knows how many files lie under it at any depth, how many of those are selected and
/// whether reading has listed every folder under it. The root folder itself has the empty relative path.
@MainActor
final class RootFolderIndex {
	/// One folder of the index.
	final class Folder {
		fileprivate unowned let parent: Folder?
		fileprivate(set) var childFolderPaths: Set<String> = []
		fileprivate(set) var childFilePaths: Set<String> = []
		/// Folders at or under this folder whose entries reading has not listed yet.
		fileprivate var unreadFolderCount = 0

		/// Files under this folder at any depth.
		fileprivate(set) var fileCount = 0

		/// Selected files under this folder at any depth.
		fileprivate(set) var selectedFileCount = 0

		/// Whether reading has listed this folder and every folder under it.
		var isSubtreeRead: Bool { unreadFolderCount == 0 }

		/// Whether reading has listed this folder and every folder under it and found no file.
		var isKnownEmpty: Bool { isSubtreeRead && fileCount == 0 }

		fileprivate init(parent: Folder?) {
			self.parent = parent
		}
	}

	let rootPath: String
	private(set) var filePaths: Set<String> = []
	/// The files of the selection.
	private(set) var selectedFilePaths: Set<String> = []
	private(set) var folders: [String: Folder]
	private var unreadFolderPaths: Set<String> = [""]
	private let root: Folder
	/// The last generation any index took.
	private static var latestGeneration: UInt64 = 0

	/// Changes whenever the files or folders of the index or their read state change, to a value no index had before.
	private(set) var generation: UInt64 = 0

	/// Whether reading has listed every folder of the root folder.
	var isReadingComplete: Bool { unreadFolderPaths.isEmpty }

	/// Whether reading has listed the direct entries of a folder.
	func isListed(_ path: String) -> Bool {
		folders[path] != nil && !unreadFolderPaths.contains(path)
	}

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
		advanceGeneration()
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
		advanceGeneration()
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
		advanceGeneration()
		var current: Folder? = folder
		while let node = current {
			node.unreadFolderCount -= 1
			current = node.parent
		}
	}

	/// Marks every folder as read once reading of the root folder has finished.
	func finishReading() {
		advanceGeneration()
		for folder in folders.values {
			folder.unreadFolderCount = 0
		}
		unreadFolderPaths.removeAll()
	}

	/// Adds a file of the index to the selection.
	func select(_ path: String) {
		guard filePaths.contains(path), selectedFilePaths.insert(path).inserted else { return }
		addToSelectedFileCounts(1, from: Self.parentPath(of: path))
	}

	/// Removes a file from the selection.
	func deselect(_ path: String) {
		guard selectedFilePaths.remove(path) != nil else { return }
		addToSelectedFileCounts(-1, from: Self.parentPath(of: path))
	}

	/// The checkbox state of a folder: ticked when every file under it is selected, mixed when some are,
	/// and empty when none are.
	func checkboxState(ofFolder path: String) -> CheckboxState {
		guard let folder = folders[path], folder.selectedFileCount > 0 else { return .unchecked }
		return folder.selectedFileCount == folder.fileCount ? .checked : .mixed
	}

	/// Removes a file, or a folder with everything under it.
	func remove(_ path: String) {
		guard !path.isEmpty else { return }
		if filePaths.remove(path) != nil {
			advanceGeneration()
			guard let parent = folders[Self.parentPath(of: path)] else { return }
			parent.childFilePaths.remove(path)
			let selectedCount = selectedFilePaths.remove(path) == nil ? 0 : 1
			var current: Folder? = parent
			while let node = current {
				node.fileCount -= 1
				node.selectedFileCount -= selectedCount
				current = node.parent
			}
			return
		}
		guard let folder = folders[path], let parent = folder.parent else { return }
		advanceGeneration()
		parent.childFolderPaths.remove(path)
		var current: Folder? = parent
		while let node = current {
			node.fileCount -= folder.fileCount
			node.selectedFileCount -= folder.selectedFileCount
			node.unreadFolderCount -= folder.unreadFolderCount
			current = node.parent
		}
		var pending: [String] = [path]
		while let folderPath = pending.popLast() {
			guard let removed = folders.removeValue(forKey: folderPath) else { continue }
			unreadFolderPaths.remove(folderPath)
			filePaths.subtract(removed.childFilePaths)
			selectedFilePaths.subtract(removed.childFilePaths)
			pending.append(contentsOf: removed.childFolderPaths)
		}
	}

	private func addToSelectedFileCounts(_ delta: Int, from folderPath: String) {
		var current = folders[folderPath]
		while let node = current {
			node.selectedFileCount += delta
			current = node.parent
		}
	}

	private func folder(at path: String) -> Folder {
		if let folder = folders[path] {
			return folder
		}
		addFolder(path, isRead: true)
		return folders[path] ?? root
	}

	private func advanceGeneration() {
		Self.latestGeneration &+= 1
		generation = Self.latestGeneration
	}

	private static func parentPath(of path: String) -> String {
		guard let slash = path.lastIndex(of: "/") else { return "" }
		return String(path[..<slash])
	}
}
