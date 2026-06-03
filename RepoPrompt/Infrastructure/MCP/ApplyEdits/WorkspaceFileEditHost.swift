import Foundation

struct WorkspaceFileEditHost: FileEditHost {
	let fileManager: RepoFileManagerViewModel
	let resolveFile: (String) async throws -> FileViewModel
	let fileExistsResolver: (String) async -> Bool

	func fileExists(path: String) async -> Bool {
		await fileExistsResolver(path)
	}

	func readText(path: String) async throws -> String {
		let fileVM = try await resolveFile(path)
		return try await fileManager.readWorkspaceFileContentStrictly(fileVM)
	}

	func writeText(path: String, content: String, overwrite: Bool) async throws {
		if overwrite {
			let fileVM = try await resolveFile(path)
			try await fileManager.editFileFromTool(atPath: fileVM.standardizedFullPath, newContent: content)
		} else {
			try await fileManager.writeFileFromTool(
				userPath: path,
				content: content,
				ifExists: "error",
				selectAfterCreate: true,
				pathResolutionPolicy: .canonicalAliasFirst
			)
		}
	}
}
