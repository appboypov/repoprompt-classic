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

	/// The files of the index, read from the folders that hold them. Files are kept per folder only,
	/// so a growing index never copies the paths of all its files at once.
	struct FilePaths: Sequence {
		fileprivate let folders: [String: Folder]
		/// The number of files.
		let count: Int

		var isEmpty: Bool { count == 0 }

		func contains(_ path: String) -> Bool {
			folders[RootFolderIndex.parentPath(of: path)]?.childFilePaths.contains(path) == true
		}

		func makeIterator() -> Iterator {
			Iterator(folders: folders.values.makeIterator())
		}

		struct Iterator: IteratorProtocol {
			fileprivate var folders: Dictionary<String, Folder>.Values.Iterator
			fileprivate var files: Set<String>.Iterator?

			fileprivate init(folders: Dictionary<String, Folder>.Values.Iterator) {
				self.folders = folders
			}

			mutating func next() -> String? {
				while true {
					if let file = files?.next() { return file }
					guard let folder = folders.next() else { return nil }
					files = folder.childFilePaths.makeIterator()
				}
			}
		}
	}

	/// The files and folders of an index at one generation, as values that can be read off the main actor.
	struct Contents: Sendable {
		struct Folder: Sendable {
			let childFolderPaths: Set<String>
			let childFilePaths: Set<String>
			let isKnownEmpty: Bool
		}

		let rootPath: String
		let generation: UInt64
		let folders: [String: Folder]
	}

	/// A file or folder path the index gained or lost.
	enum PathChange: Sendable, Equatable {
		case added(String, isFolder: Bool)
		/// A removed folder takes everything under it along.
		case removed(String)
	}

	let rootPath: String
	var filePaths: FilePaths { FilePaths(folders: folders, count: root.fileCount) }
	/// The files of the selection.
	private(set) var selectedFilePaths: Set<String> = []
	/// How many files of the index have each lowercased file extension; the empty string counts files without one.
	private(set) var fileCountsByExtension: [String: Int] = [:]
	/// Selected files reading has not found yet. Each is selected once reading adds it.
	private var pendingSelectedFilePaths: Set<String> = []
	/// Folders ticked before reading listed their subtree. Each gets every file under it selected once its subtree is read.
	private(set) var waitingFolderPaths: Set<String> = []
	private(set) var folders: [String: Folder]
	private var unreadFolderPaths: Set<String> = [""]
	private let root: Folder
	/// The last generation any index took.
	private static var latestGeneration: UInt64 = 0

	/// Changes whenever the files or folders of the index or their read state change, to a value no index had before.
	private(set) var generation: UInt64 = 0
	private var cachedContents: Contents?
	/// The path changes in the order they happened, each with the generation it brought.
	private var pathChangeLog: [(generation: UInt64, change: PathChange)] = []
	/// The log holds every path change after this generation.
	private var pathChangeLogStart: UInt64
	/// The number of changes the log keeps at least once it trims its oldest ones.
	private let pathChangeLimit: Int

	/// The files and folders of the index now. Built once per generation; the sets are shared, not copied.
	var contents: Contents {
		if let cachedContents { return cachedContents }
		var nativeRootPath = rootPath
		nativeRootPath.makeContiguousUTF8()
		let contents = Contents(
			rootPath: nativeRootPath,
			generation: generation,
			folders: folders.mapValues { folder in
				Contents.Folder(
					childFolderPaths: folder.childFolderPaths,
					childFilePaths: folder.childFilePaths,
					isKnownEmpty: folder.isKnownEmpty
				)
			}
		)
		cachedContents = contents
		return contents
	}

	/// Whether reading has listed every folder of the root folder.
	var isReadingComplete: Bool { unreadFolderPaths.isEmpty }

	/// Whether reading has listed the direct entries of a folder.
	func isListed(_ path: String) -> Bool {
		folders[path] != nil && !unreadFolderPaths.contains(path)
	}

	init(rootPath: String, pathChangeLimit: Int = 100_000) {
		self.rootPath = rootPath
		self.pathChangeLimit = pathChangeLimit
		let root = Folder(parent: nil)
		root.unreadFolderCount = 1
		self.root = root
		self.folders = ["": root]
		self.pathChangeLogStart = 0
		advanceGeneration()
		pathChangeLogStart = generation
	}

	/// The paths added and removed after a generation of this index, in order. Nil when the log no longer
	/// reaches back that far or the generation is not one of this index.
	func pathChanges(after generation: UInt64) -> [PathChange]? {
		guard generation >= pathChangeLogStart, generation <= self.generation else { return nil }
		var low = 0
		var high = pathChangeLog.count
		while low < high {
			let mid = (low + high) / 2
			if pathChangeLog[mid].generation > generation {
				high = mid
			} else {
				low = mid + 1
			}
		}
		return pathChangeLog[low...].map(\.change)
	}

	/// Adds the entries of one reading chunk and marks the folders it finished listing as read.
	/// Returns the files it selected because they or a folder above them were waiting to be selected.
	@discardableResult
	func add(_ chunk: FSPreparedChunk) -> [String] {
		for folder in chunk.folders {
			addFolder(folder.relativePath, isRead: false)
		}
		var selectedFromPending: [String] = []
		for file in chunk.files {
			addFile(file.relativePath)
			if pendingSelectedFilePaths.remove(file.relativePath) != nil {
				select(file.relativePath)
				selectedFromPending.append(file.relativePath)
			}
		}
		for path in chunk.readFolders {
			markFolderRead(path)
		}
		let readWaitingFolders = waitingFolderPaths.filter { folders[$0]?.isSubtreeRead != false }
		return selectedFromPending + selectFiles(underWaitingFolders: readWaitingFolders)
	}

	/// Lets a folder whose subtree is not read wait, so every file under it is selected once its subtree is read.
	func waitToSelect(folder path: String) {
		guard folders[path]?.isSubtreeRead == false else { return }
		waitingFolderPaths.insert(path)
	}

	/// Stops a folder from waiting, so reading its subtree selects nothing.
	func stopWaiting(folder path: String) {
		waitingFolderPaths.remove(path)
	}

	/// Selects every file under the waiting folders that are still in the index, stops them waiting,
	/// and returns the files it selected.
	private func selectFiles(underWaitingFolders paths: Set<String>) -> [String] {
		guard !paths.isEmpty else { return [] }
		waitingFolderPaths.subtract(paths)
		var selected: [String] = []
		var stack = paths.compactMap { folders[$0] }
		while let folder = stack.popLast() {
			for file in folder.childFilePaths where !selectedFilePaths.contains(file) {
				select(file)
				selected.append(file)
			}
			stack.append(contentsOf: folder.childFolderPaths.compactMap { folders[$0] })
		}
		return selected
	}

	/// Adds a folder. Missing folders above it are added as read.
	func addFolder(_ path: String, isRead: Bool) {
		guard !path.isEmpty, folders[path] == nil else { return }
		advanceGeneration()
		if hasFile(path) {
			remove(path)
		}
		let parentPath = Self.parentPath(of: path)
		let parent = folder(at: parentPath)
		parent.childFolderPaths.insert(path)
		let folder = Folder(parent: parent)
		folders[path] = folder
		logPathChange(.added(path, isFolder: true))
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
		guard !path.isEmpty, !hasFile(path) else { return }
		advanceGeneration()
		if folders[path] != nil {
			remove(path)
		}
		let parent = folder(at: Self.parentPath(of: path))
		parent.childFilePaths.insert(path)
		fileCountsByExtension[Self.fileExtension(of: path), default: 0] += 1
		logPathChange(.added(path, isFolder: false))
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
	/// Returns the files of waiting folders it selected.
	@discardableResult
	func finishReading() -> [String] {
		advanceGeneration()
		for folder in folders.values {
			folder.unreadFolderCount = 0
		}
		unreadFolderPaths.removeAll()
		pendingSelectedFilePaths.removeAll()
		return selectFiles(underWaitingFolders: waitingFolderPaths)
	}

	/// Adds a file of the index to the selection. While reading runs, a file reading has not found yet
	/// waits and is selected once reading adds it.
	func select(_ path: String) {
		guard hasFile(path) else {
			if !isReadingComplete {
				pendingSelectedFilePaths.insert(path)
			}
			return
		}
		guard selectedFilePaths.insert(path).inserted else { return }
		addToSelectedFileCounts(1, from: Self.parentPath(of: path))
	}

	/// Removes a file from the selection.
	func deselect(_ path: String) {
		pendingSelectedFilePaths.remove(path)
		guard selectedFilePaths.remove(path) != nil else { return }
		addToSelectedFileCounts(-1, from: Self.parentPath(of: path))
	}

	/// Replaces the selected files reading has not found yet and stops every folder from waiting.
	/// Does nothing once reading is complete.
	func setPendingSelection(_ paths: Set<String>) {
		guard !isReadingComplete else { return }
		pendingSelectedFilePaths = paths
		waitingFolderPaths.removeAll()
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
		if let parent = folders[Self.parentPath(of: path)], parent.childFilePaths.remove(path) != nil {
			uncountExtensions(of: [path])
			advanceGeneration()
			logPathChange(.removed(path))
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
		logPathChange(.removed(path))
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
			uncountExtensions(of: removed.childFilePaths)
			unreadFolderPaths.remove(folderPath)
			selectedFilePaths.subtract(removed.childFilePaths)
			pending.append(contentsOf: removed.childFolderPaths)
		}
	}

	private func uncountExtensions<S: Sequence>(of paths: S) where S.Element == String {
		for path in paths {
			let fileExtension = Self.fileExtension(of: path)
			guard let count = fileCountsByExtension[fileExtension] else { continue }
			if count <= 1 {
				fileCountsByExtension.removeValue(forKey: fileExtension)
			} else {
				fileCountsByExtension[fileExtension] = count - 1
			}
		}
	}

	private func addToSelectedFileCounts(_ delta: Int, from folderPath: String) {
		var current = folders[folderPath]
		while let node = current {
			node.selectedFileCount += delta
			current = node.parent
		}
	}

	private func hasFile(_ path: String) -> Bool {
		folders[Self.parentPath(of: path)]?.childFilePaths.contains(path) == true
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
		cachedContents = nil
	}

	private func logPathChange(_ change: PathChange) {
		pathChangeLog.append((generation, change))
		guard pathChangeLog.count > pathChangeLimit * 2 else { return }
		let dropped = pathChangeLog.count - pathChangeLimit
		pathChangeLogStart = pathChangeLog[dropped - 1].generation
		pathChangeLog.removeFirst(dropped)
	}

	nonisolated static func parentPath(of path: String) -> String {
		guard let slash = path.lastIndex(of: "/") else { return "" }
		return String(path[..<slash])
	}

	private nonisolated static func fileExtension(of path: String) -> String {
		(path as NSString).pathExtension.lowercased()
	}
}
