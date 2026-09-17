import Foundation

/// Failures of workspace shell actions. `WindowRoutingService` maps them onto MCP error codes.
enum WorkspaceShellError: Error, Equatable, LocalizedError {
	case unknownWorkspace(UUID)
	case emptyName
	case duplicateName(String)
	case invalidOrder(String)
	case approvalDenied
	case cancelled
	case runtimeUnavailable(UUID)
	case captureFailed(String)
	case invalidOutputPath(String)

	var errorDescription: String? {
		switch self {
		case .unknownWorkspace(let id):
			return "No workspace with id \(id.uuidString)."
		case .emptyName:
			return "Workspace name must not be empty."
		case .duplicateName(let name):
			return "A workspace named \"\(name)\" already exists."
		case .invalidOrder(let reason):
			return "Invalid workspace order: \(reason)"
		case .approvalDenied:
			return "The request was denied by the user."
		case .cancelled:
			return "The request was cancelled."
		case .runtimeUnavailable(let id):
			return "Runtime not retained for workspace \(id.uuidString)."
		case .captureFailed(let reason):
			return "Capture failed: \(reason)"
		case .invalidOutputPath(let path):
			return "Invalid output path: \(path)"
		}
	}
}
