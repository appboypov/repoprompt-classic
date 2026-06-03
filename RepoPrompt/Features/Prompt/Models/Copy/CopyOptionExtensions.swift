import Foundation

// MARK: - FileTreeOption Caption Extension
extension FileTreeOption {
    var caption: String {
        switch self {
        case .none:
            return "No file tree structure"
        case .auto:
            return "Automatically include file tree for folders"
        case .files:
            return "Show all files in tree"
        case .selected:
            return "Show only selected files in tree"
        }
    }
}

// MARK: - CodeMapUsage Caption Extension  
extension CodeMapUsage {
    var caption: String {
        switch self {
        case .none:
            return "No code structure extraction"
        case .selected:
            return "Replaces full file contents with codemaps"
        case .auto:
            return "Automatically extract for supported languages"
        case .complete:
            return "Extract complete structure from all files"
        }
    }
}
