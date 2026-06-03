import Foundation

/// Headless/discovery adapter for Gemini's ACP runtime.
///
/// Gemini discovery/delegate-edit runs use ACP default mode and answer ACP
/// permission requests automatically instead of launching the legacy yolo
/// stream-json runner.
final class GeminiACPHeadlessAgentProvider: HeadlessAgentProvider {
	typealias ProviderFactory = @Sendable (_ config: GeminiAgentConfig) -> any ACPAgentProvider
	typealias ControllerFactory = ACPHeadlessAgentProviderBridge.ControllerFactory

	private let config: GeminiAgentConfig
	private let bridge: ACPHeadlessAgentProviderBridge

#if DEBUG
	var test_config: GeminiAgentConfig { config }
#endif

	init(
		config: GeminiAgentConfig,
		workspacePath: String? = nil,
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
			GeminiACPAgentProvider(config: config)
		}
		let defaultSessionModeID = GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID
		self.bridge = ACPHeadlessAgentProviderBridge(
			providerName: "Gemini",
			makeProvider: {
				resolvedProviderFactory(config)
			},
			makeRequest: { message, _ in
				ACPRunRequest(
					agentKind: .gemini,
					modelString: config.modelString,
					workspacePath: workspacePath,
					resumeSessionID: message.resumeSessionID,
					attachments: [],
					taskLabelKind: nil,
					sessionModeID: defaultSessionModeID,
					autoApproveAllToolPermissions: true
				)
			},
			makeController: controllerFactory,
			beforePrompt: { controller, _ in
				await controller.setAutoApproveAllToolPermissions(true)
				try await controller.setSessionMode(defaultSessionModeID)
			},
			approvalPolicy: .acceptForSession
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
