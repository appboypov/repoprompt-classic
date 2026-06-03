import Foundation

enum MCPServerIssue: Equatable, Sendable {
	case none
	case localNetworkPermissionDenied
	case bonjourRegistrationFailed(message: String)
	case listenerRestarting
	case portInUse
	case discoveryDegraded(message: String)
	case lastClientApprovalDenied(clientID: String)
	/// Client approval was auto-denied after timeout (UI didn't respond in time)
	case lastClientApprovalTimedOut(clientID: String)
	case lastClientDisconnectedUnexpectedly(clientID: String?)
	/// Identity/capability token recovery repeatedly failed; server forced filesystem fallback.
	case identityRecoveryDegraded(message: String)
}

struct MCPDiagnostics: Equatable, Sendable {
	var issue: MCPServerIssue
	var lastEventAt: Date?
	var listenerStateDescription: String
	
	init(
		issue: MCPServerIssue = .none,
		lastEventAt: Date? = nil,
		listenerStateDescription: String = "Idle"
	) {
		self.issue = issue
		self.lastEventAt = lastEventAt
		self.listenerStateDescription = listenerStateDescription
	}
}
