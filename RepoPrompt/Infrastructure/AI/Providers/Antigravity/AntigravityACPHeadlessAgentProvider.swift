import Foundation

/// Headless adapter for the Antigravity ACP server.
///
/// Discovery and delegate-edit runs use ACP default mode and answer ACP
/// permission requests automatically. Prompt-only runs (chat, Oracle) decline
/// every tool request instead.
final class AntigravityACPHeadlessAgentProvider: HeadlessAgentProvider {
	typealias ProviderFactory = @Sendable (_ config: AntigravityAgentConfig) -> any ACPAgentProvider
	typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

	private let config: AntigravityAgentConfig
	private let bridge: ACPHeadlessAgentProviderBridge

#if DEBUG
	var test_config: AntigravityAgentConfig { config }
#endif

	init(
		config: AntigravityAgentConfig,
		workspacePath: String? = nil,
		promptOnly: Bool = false,
		providerFactory: ProviderFactory? = nil,
		controllerFactory: @escaping ControllerFactory = { provider, request, diagnosticSink in
			try ACPAgentSessionController(
				provider: provider,
				runRequest: request,
				diagnosticSink: diagnosticSink
			)
		}
	) {
		self.config = config
		let resolvedProviderFactory = providerFactory ?? { config in
			AntigravityACPAgentProvider(config: config)
		}
		let defaultSessionModeID = AntigravityAgentToolPreferences.PermissionLevel.default.sessionModeID
		self.bridge = ACPHeadlessAgentProviderBridge(
			providerName: "Antigravity",
			makeProvider: {
				resolvedProviderFactory(config)
			},
			makeRequest: { message, _ in
				ACPRunRequest(
					agentKind: .antigravity,
					modelString: config.modelString,
					workspacePath: workspacePath,
					resumeSessionID: message.resumeSessionID,
					attachments: [],
					taskLabelKind: nil,
					sessionModeID: defaultSessionModeID,
					autoApproveAllToolPermissions: !promptOnly
				)
			},
			makeController: controllerFactory,
			beforePrompt: { controller, _ in
				await controller.setAutoApproveAllToolPermissions(!promptOnly)
				try await controller.setSessionMode(defaultSessionModeID)
				if let model = config.modelString {
					try await controller.setSessionModel(model)
				}
			},
			approvalPolicy: promptOnly ? .declineUnsupported : .acceptForSession
		)
	}

	func streamAgentMessage(
		_ message: AgentMessage,
		runID: UUID? = nil
	) async throws -> AsyncThrowingStream<AIStreamResult, Error> {
		try await bridge.streamAgentMessage(message, runID: runID)
	}

	func dispose() async {
		await bridge.dispose()
	}
}
