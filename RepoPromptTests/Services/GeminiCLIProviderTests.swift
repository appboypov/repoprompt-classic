import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class GeminiCLIProviderTests: XCTestCase {
	func testPromptOnlyACPLaunchConfigurationUsesPromptOnlySettingsAndNoAllowedMCPServerNames() throws {
		let provider = GeminiACPAgentProvider(
			config: GeminiAgentConfig(
				modelString: "gemini-2.5-flash",
				toolContext: .promptOnly,
				includeRepoPromptMCPServer: false
			)
		)
		let request = ACPRunRequest(
			agentKind: .gemini,
			modelString: "gemini-2.5-flash",
			workspacePath: "/tmp/workspace",
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil
		)

		let launch = try provider.makeLaunchConfiguration(for: request)

		XCTAssertEqual(launch.providerID, .gemini)
		XCTAssertEqual(launch.arguments, ["--acp", "--model", "gemini-2.5-flash"])
		XCTAssertEqual(launch.workingDirectory, "/tmp/workspace")
		XCTAssertNil(launch.arguments.first(where: { $0 == "--allowed-mcp-server-names" }))

		let settingsPath = try XCTUnwrap(launch.environment[MCPIntegrationHelper.geminiSystemSettingsEnvKey])
		XCTAssertEqual(URL(fileURLWithPath: settingsPath).lastPathComponent, "gemini-prompt-only-acp-settings.json")
		let settingsData = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
		let settingsJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: settingsData) as? [String: Any])
		XCTAssertNil(settingsJSON["mcpServers"])
		XCTAssertNil(settingsJSON["tools"])
		let adminPolicyPaths = try XCTUnwrap(settingsJSON["adminPolicyPaths"] as? [String])
		XCTAssertEqual(adminPolicyPaths.count, 1)

		let policyURL = URL(fileURLWithPath: try XCTUnwrap(adminPolicyPaths.first))
		let policy = try String(contentsOf: policyURL, encoding: .utf8)
		XCTAssertTrue(policy.contains("toolName = ["))
		XCTAssertTrue(policy.contains("\"read_file\""))
		XCTAssertTrue(policy.contains("\"run_shell_command\""))
		XCTAssertTrue(policy.contains("decision = \"deny\""))
		XCTAssertFalse(policy.contains("mcpName ="))
	}

	func testPromptOnlyACPSessionConfigurationUsesFreshSessionWithoutMCPServers() throws {
		let provider = GeminiACPAgentProvider(
			config: GeminiAgentConfig(
				toolContext: .promptOnly,
				includeRepoPromptMCPServer: false
			)
		)
		let workspaceURL = FileManager.default.temporaryDirectory.appendingPathComponent("GeminiCLIProviderTests-session")
		let request = ACPRunRequest(
			agentKind: .gemini,
			modelString: nil,
			workspacePath: workspaceURL.path,
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil
		)

		let session = try provider.makeSessionConfiguration(for: request, mcpServer: .repoPrompt)

		XCTAssertEqual(session.mode, .new)
		XCTAssertEqual(session.workingDirectory, workspaceURL.standardizedFileURL.path)
		XCTAssertTrue(session.mcpServers.isEmpty)
	}

	func testGeminiCLIProviderACPFlowAppliesDefaultSessionModeBeforePrompt() async throws {
		let harness = try makeMockHarness(
			scenario: .success,
			environmentOverrides: ["ACP_TEST_CURRENT_MODE_ID": "yolo"]
		)
		let provider = makeProvider(using: harness)
		let stream = try await provider.streamMessage(
			AIMessage(systemPrompt: "System", userMessage: "Say hi"),
			model: .geminiCliFlash25,
			maxTokens: nil
		)

		let results = try await collectResults(from: stream)
		let methods = try harness.requestMethodSequence()
		let setModeEntry = try XCTUnwrap(harness.readLoggedEntries().first(where: { ($0["method"] as? String) == "session/set_mode" }))
		let setModeParams = try XCTUnwrap(setModeEntry["params"] as? [String: Any])

		let sessionNewIndex = try XCTUnwrap(methods.firstIndex(of: "session/new"))
		let setModeIndex = try XCTUnwrap(methods.firstIndex(of: "session/set_mode"))
		let promptIndex = try XCTUnwrap(methods.firstIndex(of: "session/prompt"))

		XCTAssertTrue(results.contains(where: { $0.type == "content" && $0.text == "OK from success scenario" }))
		XCTAssertTrue(results.contains(where: { $0.type == "message_stop" }))
		XCTAssertEqual(methods.first, "initialize")
		XCTAssertLessThan(sessionNewIndex, setModeIndex)
		XCTAssertLessThan(setModeIndex, promptIndex)
		XCTAssertEqual(setModeParams["modeId"] as? String, GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID)
	}

	func testGeminiCLIProviderACPFlowRejectsToolCallsInPromptOnlyMode() async throws {
		let harness = try makeMockHarness(
			scenario: .toolCall,
			environmentOverrides: ["ACP_TEST_CURRENT_MODE_ID": "yolo"]
		)
		let provider = makeProvider(using: harness)

		do {
			_ = try await provider.completeMessage(
				AIMessage(systemPrompt: "System", userMessage: "Read the repo"),
				model: .geminiCliFlash25,
				maxTokens: nil
			)
			XCTFail("Expected prompt-only tool use to throw")
		} catch let error as AIProviderError {
			guard case .invalidConfiguration(let detail) = error else {
				return XCTFail("Unexpected provider error: \(error)")
			}
			XCTAssertTrue(detail.contains("attempted to use tool 'read_file'"), detail)
		}
	}

	func testGeminiCLIProviderACPFlowRejectsApprovalRequestsInPromptOnlyMode() async throws {
		let harness = try makeMockHarness(
			scenario: .permission,
			environmentOverrides: ["ACP_TEST_CURRENT_MODE_ID": "yolo"]
		)
		let provider = makeProvider(using: harness)

		do {
			_ = try await provider.completeMessage(
				AIMessage(systemPrompt: "System", userMessage: "Need permission"),
				model: .geminiCliFlash25,
				maxTokens: nil
			)
			XCTFail("Expected prompt-only approval request to throw")
		} catch let error as AIProviderError {
			guard case .invalidConfiguration(let detail) = error else {
				return XCTFail("Unexpected provider error: \(error)")
			}
			XCTAssertTrue(detail.contains("requested tool approval while prompt-only mode is active"), detail)
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	private func makeProvider(using harness: MockHarness) -> GeminiCLIProvider {
		GeminiCLIProvider(
			workingDirectory: harness.tempDirectory.path,
			defaultRequestTimeout: 5,
			maxRetries: 0,
			controllerFactory: { runRequest, diagnosticSink, requestTimeouts in
				XCTAssertEqual(runRequest.workspacePath, harness.tempDirectory.path)
				XCTAssertEqual(runRequest.sessionModeID, GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID)
				return try ACPAgentSessionController(
					provider: ScriptBackedPromptOnlyGeminiACPProvider(
						scriptURL: harness.scriptURL,
						logURL: harness.logURL,
						scenario: harness.scenario.rawValue,
						sessionID: harness.sessionID,
						workingDirectory: harness.tempDirectory.path,
						environmentOverrides: harness.environmentOverrides
					),
					runRequest: runRequest,
					diagnosticSink: diagnosticSink,
					requestTimeouts: requestTimeouts
				)
			}
		)
	}

	private func collectResults(from stream: AsyncThrowingStream<AIStreamResult, Error>) async throws -> [AIStreamResult] {
		var results: [AIStreamResult] = []
		for try await result in stream {
			results.append(result)
		}
		return results
	}
}

private extension GeminiCLIProviderTests {
	enum MockScenario: String {
		case success = "success"
		case toolCall = "prompt"
		case permission = "permission"
	}

	struct MockHarness {
		let tempDirectory: URL
		let scriptURL: URL
		let logURL: URL
		let scenario: MockScenario
		let sessionID: String
		let environmentOverrides: [String: String]

		func readLoggedEntries() throws -> [[String: Any]] {
			guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
			let content = try String(contentsOf: logURL, encoding: .utf8)
			return try content
				.split(whereSeparator: \.isNewline)
				.compactMap { line -> [String: Any]? in
					guard !line.isEmpty else { return nil }
					return try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
				}
		}

		func requestMethodSequence() throws -> [String] {
			try readLoggedEntries().compactMap { $0["method"] as? String }
		}
	}

	func makeMockHarness(
		scenario: MockScenario,
		environmentOverrides: [String: String] = [:]
	) throws -> MockHarness {
		let tempDirectory = try makeTempDirectory()
		let scriptURL = tempDirectory.appendingPathComponent("mock-acp-server.sh")
		let logURL = tempDirectory.appendingPathComponent("gemini-cli-provider.jsonl")
		let sessionID = "gemini-cli-provider-\(UUID().uuidString)"
		try FileManager.default.copyItem(at: try mockACPServerFixtureURL(), to: scriptURL)
		try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: scriptURL.path)
		return MockHarness(
			tempDirectory: tempDirectory,
			scriptURL: scriptURL,
			logURL: logURL,
			scenario: scenario,
			sessionID: sessionID,
			environmentOverrides: environmentOverrides
		)
	}

	func makeTempDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("GeminiCLIProviderTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock {
			try? FileManager.default.removeItem(at: url)
		}
		return url
	}

	func mockACPServerFixtureURL() throws -> URL {
		let url = URL(fileURLWithPath: #filePath)
			.deletingLastPathComponent()
			.appendingPathComponent("Fixtures/mock-acp-server.sh")
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw XCTSkip("Missing mock ACP server fixture at \(url.path)")
		}
		return url
	}
}

private struct ScriptBackedPromptOnlyGeminiACPProvider: ACPAgentProvider {
	private let base = GeminiACPAgentProvider(
		config: GeminiAgentConfig(
			toolContext: .promptOnly,
			includeRepoPromptMCPServer: false
		)
	)
	let scriptURL: URL
	let logURL: URL
	let scenario: String
	let sessionID: String
	let workingDirectory: String
	let environmentOverrides: [String: String]

	var providerID: ACPProviderID { .gemini }

	func support(for _: ACPRunRequest) async -> ACPSupportResult {
		.supported
	}

	func makeLaunchConfiguration(for _: ACPRunRequest) throws -> ACPLaunchConfiguration {
		var environment: [String: String] = [
			"ACP_TEST_LOG": logURL.path,
			"ACP_TEST_SCENARIO": scenario,
			"ACP_TEST_SESSION_ID": sessionID
		]
		for (key, value) in environmentOverrides {
			environment[key] = value
		}
		return ACPLaunchConfiguration(
			providerID: providerID,
			command: "/bin/sh",
			arguments: [scriptURL.path],
			environment: environment,
			workingDirectory: workingDirectory,
			additionalPathHints: [],
			enableDebugLogging: false
		)
	}

	func makeSessionConfiguration(
		for request: ACPRunRequest,
		mcpServer: RepoPromptMCPServerConfiguration
	) throws -> ACPSessionConfiguration {
		try base.makeSessionConfiguration(for: request, mcpServer: mcpServer)
	}

	func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
		try base.buildPromptBlocks(for: message, request: request)
	}

	func normalizeSessionUpdate(_ payload: [String: Any], sessionID: String) -> [NormalizedAgentRuntimeEvent] {
		base.normalizeSessionUpdate(payload, sessionID: sessionID)
	}

	func normalizeError(_ error: Error) -> Error {
		base.normalizeError(error)
	}
}
