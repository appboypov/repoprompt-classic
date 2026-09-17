import Foundation

/// Availability rule for a workspace: every root must exist as a directory.
enum WorkspaceAvailability {
	static func isAvailable(repoPaths: [String], fileManager: FileManager = .default) -> Bool {
		repoPaths.allSatisfy { path in
			var isDirectory: ObjCBool = false
			return fileManager.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
		}
	}
}
