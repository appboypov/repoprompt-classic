import Foundation

protocol FileSystemItemViewModel: Identifiable, Equatable {
	var id: UUID { get }
	var name: String { get }
	var nameSortKey: String { get }
	var relativePath: String { get }
	var fullPath: String { get }
	var modificationDate: Date { get }
	var fileExtension: String? { get }
}

enum FileSystemItemType: Identifiable, Equatable, Hashable {
	case folder(FolderViewModel)
	case file(FileViewModel)
	
	var id: UUID {
		switch self {
		case .folder(let folder): return folder.id
		case .file(let file): return file.id
		}
	}
	
	var relativePath: String {
		switch self {
		case .folder(let folder): return folder.relativePath
		case .file(let file): return file.relativePath
		}
	}
	
	var fullPath: String {
		switch self {
		case .folder(let folder): return folder.fullPath
		case .file(let file): return file.fullPath
		}
	}
	
	static func == (lhs: FileSystemItemType, rhs: FileSystemItemType) -> Bool {
		switch (lhs, rhs) {
		case (.folder(let lhsFolder), .folder(let rhsFolder)):
			return lhsFolder == rhsFolder
		case (.file(let lhsFile), .file(let rhsFile)):
			return lhsFile == rhsFile
		case (.folder, .file), (.file, .folder):
			return false
		}
	}
	
	func hash(into hasher: inout Hasher) {
		switch self {
		case .folder(let folder):
			hasher.combine("folder")
			hasher.combine(folder.id)
		case .file(let file):
			hasher.combine("file")
			hasher.combine(file.id)
		}
	}
}
