import Foundation

struct SandboxFileEditHost: FileEditHost {
	let sandbox: DelegateEditSandbox

	func fileExists(path: String) async -> Bool {
		true
	}

	func readText(path: String) async throws -> String {
		await sandbox.currentContent()
	}

	func writeText(path: String, content: String, overwrite: Bool) async throws {
		await sandbox.setContent(content)
	}
}
