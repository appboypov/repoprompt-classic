import Foundation

protocol FileSystemItem: Identifiable, Equatable, Sendable {
	var id: UUID { get }
	var name: String { get }
	var path: String { get }
	var modificationDate: Date { get }
}

struct Folder: FileSystemItem {
	let id = UUID()
	let name: String
	let path: String
	let modificationDate: Date
	
	static func == (lhs: Folder, rhs: Folder) -> Bool {
		return lhs.path == rhs.path
	}
}

extension FileSystemItem {
	func relativePath(rootPath: String) -> String {
		RelativePath.from(absolutePath: self.path, rootPath: rootPath)
	}
}

struct File: FileSystemItem {
	let id = UUID()
	let name: String
	let path: String
	let modificationDate: Date
	
	static func == (lhs: File, rhs: File) -> Bool {
		return lhs.path == rhs.path
	}
}

enum FileTreeItem: Identifiable {
	case folder(String, [FileViewModel])
	case file(FileViewModel)
	
	var id: String {
		switch self {
		case .folder(let path, _):
			return "folder_\(path)"
		case .file(let file):
			return "file_\(file.id)"
		}
	}
	
	var path: String {
		switch self {
		case .folder(let name, _): return name
		case .file(let file): return file.relativePath
		}
	}
}
