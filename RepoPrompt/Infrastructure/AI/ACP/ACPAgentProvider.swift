import Foundation

enum ACPProviderID: String, Sendable, Hashable {
	case antigravity
	case openCode
	case cursor

	/// Antigravity starts the session's MCP servers when the first prompt arrives,
	/// not at session/new, so its RepoPrompt MCP connection follows the prompt.
	var connectsMCPServersOnPrompt: Bool {
		self == .antigravity
	}
}

enum ACPSupportResult: Sendable, Equatable {
	case supported
	case unsupported(reason: String)

	var reason: String? {
		switch self {
		case .supported:
			return nil
		case .unsupported(let reason):
			return reason
		}
	}
}

struct ACPDiscoveredSessionModels: Sendable, Equatable {
	let options: [AgentModelOption]
	let currentModelRaw: String?

	var preferredModelRaw: String? {
		option(matching: currentModelRaw)?.rawValue
			?? Self.normalizedRawModel(currentModelRaw)
			?? options.first(where: \.isProviderDefault)?.rawValue
			?? options.first?.rawValue
	}

	func option(matching raw: String?) -> AgentModelOption? {
		guard let normalized = Self.normalizedRawModel(raw) else { return nil }
		return options.first {
			Self.normalizedRawModel($0.rawValue) == normalized
		}
	}

	func contains(rawModel: String?) -> Bool {
		option(matching: rawModel) != nil
	}

	private static func normalizedRawModel(_ raw: String?) -> String? {
		guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
			!trimmed.isEmpty else {
			return nil
		}
		return trimmed.lowercased()
	}
}

/// ACP session identity reported by the ACP controller to the runner. The
/// session ID is the one a later `session/load` resumes.
struct ACPProviderSessionIdentity: Sendable, Equatable {
	let providerID: ACPProviderID
	let sessionID: String?

	init(providerID: ACPProviderID, sessionID: String? = nil) {
		self.providerID = providerID
		let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines)
		self.sessionID = trimmed?.isEmpty == false ? trimmed : nil
	}
}

struct ACPRunRequest: Sendable {
	let agentKind: DiscoverAgentKind
	let modelString: String?
	let workspacePath: String?
	let resumeSessionID: String?
	let isProviderSessionContinuation: Bool
	let attachments: [AgentImageAttachment]
	let taskLabelKind: AgentModelCatalog.TaskLabelKind?
	let sessionModeID: String?
	let autoApproveAllToolPermissions: Bool

	init(
		agentKind: DiscoverAgentKind,
		modelString: String?,
		workspacePath: String?,
		resumeSessionID: String?,
		isProviderSessionContinuation: Bool = false,
		attachments: [AgentImageAttachment],
		taskLabelKind: AgentModelCatalog.TaskLabelKind?,
		sessionModeID: String? = nil,
		autoApproveAllToolPermissions: Bool = false
	) {
		self.agentKind = agentKind
		self.modelString = modelString
		self.workspacePath = workspacePath
		self.resumeSessionID = resumeSessionID
		self.isProviderSessionContinuation = isProviderSessionContinuation
		self.attachments = attachments
		self.taskLabelKind = taskLabelKind
		self.sessionModeID = sessionModeID
		self.autoApproveAllToolPermissions = autoApproveAllToolPermissions
	}
}

struct ACPAuthenticationContext: Sendable, Equatable {
	let authMethodIDs: [String]
	let environment: [String: String]
}

struct ACPLaunchCleanupArtifact: Sendable, Equatable {
	let providerID: ACPProviderID
	let id: UUID
	let kind: String
}

struct ACPLaunchConfiguration: Sendable, Equatable {
	let providerID: ACPProviderID
	let command: String
	let arguments: [String]
	let environment: [String: String]
	let workingDirectory: String?
	let additionalPathHints: [String]
	let enableDebugLogging: Bool
	let cleanupArtifact: ACPLaunchCleanupArtifact?
	/// Inherited variables the agent process must not see.
	let removedEnvironmentKeys: Set<String>
	/// Prefixes of inherited variables the agent process must not see.
	let removedEnvironmentKeyPrefixes: [String]

	init(
		providerID: ACPProviderID,
		command: String,
		arguments: [String],
		environment: [String: String],
		workingDirectory: String?,
		additionalPathHints: [String],
		enableDebugLogging: Bool,
		cleanupArtifact: ACPLaunchCleanupArtifact? = nil,
		removedEnvironmentKeys: Set<String> = [],
		removedEnvironmentKeyPrefixes: [String] = []
	) {
		self.providerID = providerID
		self.command = command
		self.arguments = arguments
		self.environment = environment
		self.workingDirectory = workingDirectory
		self.additionalPathHints = additionalPathHints
		self.enableDebugLogging = enableDebugLogging
		self.cleanupArtifact = cleanupArtifact
		self.removedEnvironmentKeys = removedEnvironmentKeys
		self.removedEnvironmentKeyPrefixes = removedEnvironmentKeyPrefixes
	}
}

struct ACPSessionConfiguration: Sendable, Equatable {
	enum Mode: Sendable, Equatable {
		case new
		case load(existingSessionID: String)
	}

	let mode: Mode
	let workingDirectory: String
	let mcpServers: [RepoPromptMCPServerConfiguration]
}

enum NormalizedAgentRuntimeEvent: Sendable {
	case stream(AIStreamResult)
	case approvalRequested(AgentApprovalRequest)
	case approvalCancelled(AgentInteractionRequestID)
	case userInputRequested(AgentRequestUserInputRequest)
	case terminal(state: AgentSessionRunState, errorText: String?)
}

protocol ACPAgentProvider: Sendable {
	var providerID: ACPProviderID { get }

	func support(for request: ACPRunRequest) async -> ACPSupportResult
	func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration
	func makeSessionConfiguration(
		for request: ACPRunRequest,
		mcpServer: RepoPromptMCPServerConfiguration
	) throws -> ACPSessionConfiguration
	func buildPromptBlocks(
		for message: AgentMessage,
		request: ACPRunRequest
	) throws -> [[String: Any]]
	func normalizeSessionUpdate(
		_ payload: [String: Any],
		sessionID: String
	) -> [NormalizedAgentRuntimeEvent]
	func preferredAuthMethodID(context: ACPAuthenticationContext) -> String?
	/// The account's plan name, when the provider reports it in the
	/// `session/new` or `session/load` result.
	func accountPlanName(fromSessionResponse response: [String: Any]) -> String?
	func cleanupLaunchArtifacts(for configuration: ACPLaunchConfiguration) async
	func normalizeError(_ error: Error) -> Error
}

extension ACPAgentProvider {
	func preferredAuthMethodID(context _: ACPAuthenticationContext) -> String? {
		nil
	}

	func accountPlanName(fromSessionResponse _: [String: Any]) -> String? {
		nil
	}

	func cleanupLaunchArtifacts(for _: ACPLaunchConfiguration) async {}
}
