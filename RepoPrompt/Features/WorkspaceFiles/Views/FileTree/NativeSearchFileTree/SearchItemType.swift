import Foundation

/// Mirrors `FileSystemItemType` but uses the *search* view-models.
/// This lets the native OutlineView differentiate between files & folders.
enum SearchItemType: Hashable {
    case folder(SearchFolderViewModel)
    case file(SearchFileViewModel)

    // MARK: - Hashable & Equatable
    static func == (lhs: SearchItemType, rhs: SearchItemType) -> Bool {
        switch (lhs, rhs) {
        case let (.folder(a), .folder(b)):
            return a.id == b.id
        case let (.file(a), .file(b)):
            return a.id == b.id
        default:
            return false
        }
    }

    func hash(into hasher: inout Hasher) {
        switch self {
        case .folder(let folder):
            hasher.combine(folder.id)
        case .file(let file):
            hasher.combine(file.id)
        }
    }
}