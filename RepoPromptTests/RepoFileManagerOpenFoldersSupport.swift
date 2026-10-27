@testable import RepoPrompt

extension RepoFileManagerViewModel {
	/// Builds the tree items of folders of a root folder by their paths relative to it, each folder on the way first,
	/// as opening them in the file tree does. The root is the first root folder unless one is given.
	@MainActor
	func openFolders(_ relativePaths: [String], inRoot root: FolderViewModel? = nil) async {
		guard let root = root ?? rootFolders.first else { return }
		for relativePath in relativePaths {
			var folder = root
			await buildChildren(of: folder)
			for component in relativePath.split(separator: "/") {
				let childPath = StandardizedPath.join(
					standardizedRoot: folder.standardizedFullPath,
					standardizedRelativePath: String(component)
				)
				guard let child = findFolderByFullPath(childPath) else { break }
				await buildChildren(of: child)
				folder = child
			}
		}
	}
}
