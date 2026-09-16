import Foundation

enum RuntimeDisposalReason: Equatable, Sendable {
	case removal
	case duplicateCleanup
}

/// What the rest of the app may ask of the workspace shell.
/// `WindowStatesManager.shell` holds the live instance; nil means the legacy per-window path.
@MainActor
protocol WorkspaceShellCoordinating: AnyObject {
	var isStarted: Bool { get }
	var isMCPToolsEnabled: Bool { get set }
	func select(_ id: UUID) async throws
	func add(name: String, folderPath: String?, makeVisible: Bool) async throws -> UUID
	func runtime(for id: UUID) -> WindowState?
	func disposeRuntime(for id: UUID, reason: RuntimeDisposalReason) async
	func flushAllWorkspaceState()
	func makeCloseImpactSnapshot() -> WindowCloseImpactSnapshot
}
