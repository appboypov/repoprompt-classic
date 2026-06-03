import Foundation
import XCTest
@_spi(TestSupport) @testable import RepoPrompt

final class ACPAgentSessionControllerTests: XCTestCase {
	private let discoveredModelsJSON = #"{"currentModelId":"gemini-2.5-pro-exp-0827","availableModels":[{"modelId":"gemini-2.5-pro-exp-0827","name":"Gemini 2.5 Pro Experimental","description":"Experimental Gemini Pro build"},{"modelId":"gemini-2.5-flash","name":"Gemini 2.5 Flash","description":"Fast Gemini model"}]}"#

	override func setUp() {
		super.setUp()
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
		AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
	}

	override func tearDown() {
		AgentACPModelRegistry.shared.test_reset(providerID: .gemini)
		AgentACPModelRegistry.shared.test_reset(providerID: .openCode)
		AgentACPModelRegistry.shared.test_reset(providerID: .cursor)
		super.tearDown()
	}

	func testRejectsMissingInjectedMCPCommandBeforeLaunchingACPProcess() throws {
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			mcpServerCommand: harnessMissingMCPCommandPath()
		)

		XCTAssertThrowsError(try harness.makeController()) { error in
			let message = error.localizedDescription
			XCTAssertTrue(message.contains("RepoPrompt"), message)
			XCTAssertTrue(message.contains("MCP command does not exist"), message)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: harness.logURL.path), "Controller should fail before spawning ACP transport.")
	}

	func testRejectsBareMissingInjectedMCPCommandBeforeLaunchingACPProcess() async throws {
		let missingBareCommand = "missing-rp-cli-\(UUID().uuidString)"
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			mcpServerCommand: missingBareCommand
		)
		let controller = try harness.makeController()

		do {
			_ = try await controller.bootstrap()
			XCTFail("Expected bare missing MCP command preflight to fail")
		} catch {
			let message = error.localizedDescription
			XCTAssertTrue(message.contains(missingBareCommand), message)
			XCTAssertTrue(message.contains("was not found"), message)
		}
		await controller.shutdown()
		XCTAssertFalse(FileManager.default.fileExists(atPath: harness.logURL.path), "Controller should fail before spawning ACP transport.")
	}

	func testRejectsNonExecutableInjectedMCPCommand() throws {
		let tempDirectory = try makeTempDirectory()
		let commandURL = tempDirectory.appendingPathComponent("not-executable-rp-cli")
		try "#!/bin/sh\necho should-not-run\n".write(to: commandURL, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int(0o644))], ofItemAtPath: commandURL.path)
		let server = RepoPromptMCPServerConfiguration(command: commandURL.path)

		XCTAssertThrowsError(try server.validateACPLaunchCommand(workingDirectory: tempDirectory.path)) { error in
			let message = error.localizedDescription
			XCTAssertTrue(message.contains("not executable"), message)
			XCTAssertTrue(message.contains(commandURL.path), message)
		}
	}

	func testInjectedMCPBareCommandCanResolveFromLaunchPathOverrideBeforeSpawningACPProcess() async throws {
		let commandDirectory = try makeTempDirectory()
		let commandName = "rp-mcp-from-launch-path-\(UUID().uuidString)"
		_ = try makeExecutableCommand(named: commandName, in: commandDirectory)
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			environmentOverrides: ["PATH": "\(commandDirectory.path):/usr/bin:/bin"],
			mcpServerCommand: commandName
		)
		let controller = try harness.makeController()

		do {
			let bootstrap = try await controller.bootstrap()
			XCTAssertEqual(bootstrap.sessionID, harness.sessionID)
			let entries = try harness.readLoggedEntries()
			XCTAssertEqual(requestMethodSequence(entries), ["initialize", "authenticate", "session/new"])
		} catch {
			await controller.shutdown()
			throw error
		}

		await controller.shutdown()
	}

	func testInjectedMCPBareCommandDoesNotResolveFromLaunchAdditionalPathHints() async throws {
		let commandDirectory = try makeTempDirectory()
		let commandName = "rp-mcp-from-provider-hint-\(UUID().uuidString)"
		_ = try makeExecutableCommand(named: commandName, in: commandDirectory)
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			mcpServerCommand: commandName,
			launchAdditionalPathHints: [commandDirectory.path]
		)
		let controller = try harness.makeController()

		do {
			_ = try await controller.bootstrap()
			XCTFail("Expected bare injected MCP command preflight to ignore ACP launch additional path hints")
		} catch {
			let message = error.localizedDescription
			XCTAssertTrue(message.contains(commandName), message)
			XCTAssertTrue(message.contains("was not found"), message)
		}

		await controller.shutdown()
		XCTAssertFalse(FileManager.default.fileExists(atPath: harness.logURL.path), "Controller should fail before spawning ACP transport.")
	}

	func testBootstrapFlowInitializeAuthenticateAndSessionNewReturnsSessionID() async throws {
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			environmentOverrides: ["ACP_TEST_MODELS_JSON": discoveredModelsJSON]
		)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			let bootstrap = try await controller.bootstrap()
			XCTAssertEqual(bootstrap.sessionID, harness.sessionID)
			XCTAssertTrue(bootstrap.loadSessionSupported)
			let discoveredModels = AgentACPModelRegistry.shared.test_snapshot(providerID: .gemini)
			XCTAssertEqual(discoveredModels?.currentModelRaw, "gemini-2.5-pro-exp-0827")
			XCTAssertEqual(discoveredModels?.options.map(\.rawValue), [
				"gemini-2.5-flash",
				"gemini-2.5-pro-exp-0827"
			])
			XCTAssertEqual(
				discoveredModels?.option(matching: "gemini-2.5-pro-exp-0827")?.displayName,
				"Gemini 2.5 Pro Experimental"
			)
			XCTAssertEqual(
				discoveredModels?.option(matching: "gemini-2.5-flash")?.description,
				"Fast Gemini model"
			)

			let entries = try harness.readLoggedEntries()
			XCTAssertEqual(requestMethodSequence(entries), ["initialize", "authenticate", "session/new"])

			let authenticate = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "authenticate" }))
			let authenticateParams = try XCTUnwrap(authenticate["params"] as? [String: Any])
			XCTAssertEqual(authenticateParams["methodId"] as? String, "use_gemini")

			let newSession = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/new" }))
			let newSessionParams = try XCTUnwrap(newSession["params"] as? [String: Any])
			let mcpServers = try XCTUnwrap(newSessionParams["mcpServers"] as? [[String: Any]])
			XCTAssertEqual(mcpServers.count, 1)
			XCTAssertEqual(mcpServers.first?["name"] as? String, "RepoPrompt")
			XCTAssertEqual(mcpServers.first?["command"] as? String, "/bin/echo")
			XCTAssertEqual(mcpServers.first?["args"] as? [String], ["serve"])
			let env = try XCTUnwrap(mcpServers.first?["env"] as? [[String: Any]])
			XCTAssertEqual(env.count, 1)
			XCTAssertEqual(env.first?["name"] as? String, "ENV_ONE")
			XCTAssertEqual(env.first?["value"] as? String, "VALUE_ONE")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testOpenCodeBootstrapParsesConfigOptionModels() async throws {
		let openCodeConfigOptionsJSON = #"[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"openai/gpt-5","options":[{"value":"anthropic/claude-sonnet-4","name":"Anthropic/Claude Sonnet 4","description":"Anthropic via OpenCode"},{"value":"openai/gpt-5","name":"OpenAI/GPT-5","description":"OpenAI via OpenCode"}]}]"#
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			environmentOverrides: ["ACP_TEST_CONFIG_OPTIONS_JSON": openCodeConfigOptionsJSON],
			providerID: .openCode
		)
		let controller = try harness.makeController(modelString: "Default")
		let recorder = EventRecorder(stream: await controller.events)

		do {
			let bootstrap = try await controller.bootstrap()
			XCTAssertEqual(bootstrap.sessionID, harness.sessionID)
			let discoveredModels = AgentACPModelRegistry.shared.test_snapshot(providerID: .openCode)
			XCTAssertEqual(discoveredModels?.currentModelRaw, "openai/gpt-5")
			XCTAssertEqual(discoveredModels?.options.map(\.rawValue), [
				"anthropic/claude-sonnet-4",
				"openai/gpt-5"
			])
			XCTAssertEqual(
				discoveredModels?.option(matching: "anthropic/claude-sonnet-4")?.displayName,
				"Anthropic/Claude Sonnet 4"
			)
			XCTAssertEqual(
				discoveredModels?.option(matching: "openai/gpt-5")?.description,
				"OpenAI via OpenCode"
			)

			let entries = try harness.readLoggedEntries()
			XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/new"])
			XCTAssertFalse(entries.contains { ($0["method"] as? String) == "authenticate" })
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCursorBootstrapUsesCursorLoginWhenEnvironmentTokenMissing() async throws {
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			environmentOverrides: ["ACP_TEST_AUTH_METHODS_KIND": "cursor"],
			providerID: .cursor
		)
		let controller = try harness.makeController(modelString: AgentModel.cursorAuto.rawValue)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			let bootstrap = try await controller.bootstrap()
			XCTAssertEqual(bootstrap.sessionID, harness.sessionID)
			let entries = try harness.readLoggedEntries()
			XCTAssertEqual(requestMethodSequence(entries), ["initialize", "authenticate", "session/new"])
			let authenticate = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "authenticate" }))
			let authenticateParams = try XCTUnwrap(authenticate["params"] as? [String: Any])
			XCTAssertEqual(authenticateParams["methodId"] as? String, "cursor_login")
			let sessionNew = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/new" }))
			let params = try XCTUnwrap(sessionNew["params"] as? [String: Any])
			assertRepoPromptMCPServer(in: params)
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCursorSkipsAuthenticateWithEnvironmentTokenAndUsesSessionLoadResume() async throws {
		let existingSessionID = "existing-cursor-session"
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			resumeSessionID: existingSessionID,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "cursor",
				"CURSOR_API_KEY": "test-token"
			],
			providerID: .cursor
		)
		let controller = try harness.makeController(modelString: AgentModel.cursorAuto.rawValue)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			let bootstrap = try await controller.bootstrap()
			XCTAssertEqual(bootstrap.sessionID, existingSessionID)
			XCTAssertFalse(bootstrap.didFallbackToNewSessionAfterLoadFailure)
			let entries = try harness.readLoggedEntries()
			XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/load"])
			XCTAssertFalse(entries.contains { ($0["method"] as? String) == "authenticate" })
			XCTAssertFalse(entries.contains { ($0["method"] as? String) == "session/new" })
			let sessionLoad = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/load" }))
			let params = try XCTUnwrap(sessionLoad["params"] as? [String: Any])
			XCTAssertEqual(params["sessionId"] as? String, existingSessionID)
			assertRepoPromptMCPServer(in: params)
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCursorSessionLoadMissingSessionFallsBackToNewSession() async throws {
		try await assertSessionLoadMissingSessionFallsBackToNewSession(
			providerID: .cursor,
			modelString: AgentModel.cursorAuto.rawValue,
			existingSessionID: "missing-cursor-session"
		)
	}

	func testGeminiSessionLoadMissingSessionDataMessageFallsBackToNewSession() async throws {
		try await assertSessionLoadMissingSessionFallsBackToNewSession(
			providerID: .gemini,
			modelString: "mock-model",
			existingSessionID: "missing-gemini-session"
		)
	}

	func testGeminiSessionLoadInvalidIdentifierFallsBackToNewSession() async throws {
		let existingSessionID = "missing-gemini-acp-session"
		try await assertSessionLoadMissingSessionFallsBackToNewSession(
			providerID: .gemini,
			modelString: "mock-model",
			existingSessionID: existingSessionID,
			loadError: "Internal error",
			loadErrorCode: "-32603",
			loadErrorDataMessage: "Invalid session identifier \(existingSessionID). Searched for sessions in ~/.gemini/tmp/studio/chats. Use --list-sessions, --resume {number}, --resume {uuid}, or --resume latest."
		)
	}

	func testGeminiSessionLoadNoPreviousSessionsFallsBackToNewSession() async throws {
		try await assertSessionLoadMissingSessionFallsBackToNewSession(
			providerID: .gemini,
			modelString: "mock-model",
			existingSessionID: "missing-gemini-previous-session",
			loadError: "Internal error",
			loadErrorCode: "-32603",
			loadErrorDataMessage: "No previous sessions found"
		)
	}

	func testOpenCodeSessionLoadMissingSessionDataMessageFallsBackToNewSession() async throws {
		try await assertSessionLoadMissingSessionFallsBackToNewSession(
			providerID: .openCode,
			modelString: "Default",
			existingSessionID: "missing-opencode-session"
		)
	}

	func testGeminiAndOpenCodeNonNotFoundSessionLoadFailuresDoNotFallback() async throws {
		for (providerID, modelString, existingSessionID) in [
			(ACPProviderID.gemini, "mock-model", "gemini-session-load-fails"),
			(ACPProviderID.openCode, "Default", "opencode-session-load-fails")
		] {
			let loadError = "Invalid params"
			let loadDetail = "Session \(existingSessionID) is locked"
			let harness = try makeMockHarness(
				scenario: .bootstrap,
				resumeSessionID: existingSessionID,
				environmentOverrides: [
					"ACP_TEST_AUTH_METHODS_KIND": "none",
					"ACP_TEST_LOAD_ERROR": loadError,
					"ACP_TEST_LOAD_ERROR_CODE": "-32602",
					"ACP_TEST_LOAD_ERROR_DATA_MESSAGE": loadDetail
				],
				providerID: providerID
			)
			let controller = try harness.makeController(modelString: modelString)
			let recorder = EventRecorder(stream: await controller.events)

			do {
				_ = try await controller.bootstrap()
				XCTFail("Expected \(providerID.rawValue) session/load to fail without fallback for non-not-found errors")
			} catch {
				let message = error.localizedDescription
				XCTAssertTrue(message.contains(loadError), message)
				XCTAssertTrue(message.contains(loadDetail), message)
			}

			await controller.shutdown()
			let entries = try harness.readLoggedEntries()
			XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/load"], "Unexpected request sequence for \(providerID.rawValue)")
			XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/new" }), "Non-not-found load error should not open a fresh \(providerID.rawValue) session")
			await recorder.cancel()
		}
	}

	func testGeminiSessionLoadInternalErrorWithoutInvalidIdentifierDoesNotFallback() async throws {
		let existingSessionID = "gemini-session-load-backend-fails"
		let loadError = "Internal error"
		let loadDetail = "Gemini backend unavailable for session \(existingSessionID)"
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			resumeSessionID: existingSessionID,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_LOAD_ERROR": loadError,
				"ACP_TEST_LOAD_ERROR_CODE": "-32603",
				"ACP_TEST_LOAD_ERROR_DATA_MESSAGE": loadDetail
			],
			providerID: .gemini
		)
		let controller = try harness.makeController(modelString: "mock-model")
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			XCTFail("Expected Gemini session/load to fail without fallback for arbitrary -32603 errors")
		} catch {
			let message = error.localizedDescription
			XCTAssertTrue(message.contains(loadError), message)
			XCTAssertTrue(message.contains(loadDetail), message)
		}

		await controller.shutdown()
		let entries = try harness.readLoggedEntries()
		XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/load"])
		XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/new" }))
		await recorder.cancel()
	}

	func testCursorBootstrapParsesConfigOptionModels() async throws {
		let cursorConfigOptionsJSON = #"[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"composer-2","options":[{"value":"composer-2","name":"Composer 2","description":"Cursor Composer 2"},{"value":"auto","name":"Auto"}]}]"#
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_CONFIG_OPTIONS_JSON": cursorConfigOptionsJSON
			],
			providerID: .cursor
		)
		let controller = try harness.makeController(modelString: AgentModel.cursorAuto.rawValue)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			let discoveredModels = AgentACPModelRegistry.shared.test_snapshot(providerID: .cursor)
			XCTAssertEqual(discoveredModels?.currentModelRaw, "composer-2")
			XCTAssertEqual(discoveredModels?.options.map(\.rawValue), ["auto", "composer-2"])
			XCTAssertEqual(discoveredModels?.option(matching: "composer-2")?.displayName, "Composer 2")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCursorSetAutoUsesExactDiscoveredConfigValue() async throws {
		let cursorConfigOptionsJSON = #"[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"default[]","options":[{"value":"default[]","name":"Auto"},{"value":"composer-2[fast=true]","name":"composer-2"}]}]"#
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_CONFIG_OPTIONS_JSON": cursorConfigOptionsJSON
			],
			providerID: .cursor
		)
		let controller = try harness.makeController(modelString: AgentModel.cursorAuto.rawValue)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.setSessionModel(AgentModel.cursorAuto.rawValue)

			let entries = try harness.readLoggedEntries()
			let setConfig = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/set_config_option" }))
			let params = try XCTUnwrap(setConfig["params"] as? [String: Any])
			XCTAssertEqual(params["sessionId"] as? String, harness.sessionID)
			XCTAssertEqual(params["configId"] as? String, "model")
			XCTAssertEqual(params["value"] as? String, "default[]")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCursorSetComposer2UsesExactDiscoveredConfigValue() async throws {
		let cursorConfigOptionsJSON = #"[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"default[]","options":[{"value":"default[]","name":"Auto"},{"value":"composer-2[fast=true]","name":"composer-2"},{"value":"composer-1.5[]","name":"composer-1.5"}]}]"#
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_CONFIG_OPTIONS_JSON": cursorConfigOptionsJSON
			],
			providerID: .cursor
		)
		let controller = try harness.makeController(modelString: AgentModel.cursorAuto.rawValue)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.setSessionModel(AgentModel.cursorComposer2.rawValue)

			let entries = try harness.readLoggedEntries()
			let setConfig = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/set_config_option" }))
			let params = try XCTUnwrap(setConfig["params"] as? [String: Any])
			XCTAssertEqual(params["sessionId"] as? String, harness.sessionID)
			XCTAssertEqual(params["configId"] as? String, "model")
			XCTAssertEqual(params["value"] as? String, "composer-2[fast=true]")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCursorHeadlessProviderStreamsPromptAndUsesAutoFallbackWithoutInvalidConfig() async throws {
		let harness = try makeMockHarness(
			scenario: .success,
			environmentOverrides: ["ACP_TEST_AUTH_METHODS_KIND": "none"],
			providerID: .cursor
		)
		let provider = makeCursorHeadlessProvider(
			harness: harness,
			modelString: AgentModel.cursorAuto.rawValue
		)
		let stream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "System", userMessage: "Hello", resumeSessionID: nil),
			runID: UUID()
		)
		let results = try await collectStreamResults(from: stream)

		XCTAssertTrue(results.contains(where: { $0.type == "content" && $0.text == "OK from success scenario" }))
		XCTAssertTrue(results.contains(where: { $0.type == "message_stop" && $0.providerSessionID == harness.sessionID }))

		let entries = try harness.readLoggedEntries()
		XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/new", "session/prompt", "session/cancel"])
		XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/set_config_option" }))
		let prompt = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/prompt" }))
		let promptParams = try XCTUnwrap(prompt["params"] as? [String: Any])
		let promptBlocks = try XCTUnwrap(promptParams["prompt"] as? [[String: Any]])
		XCTAssertEqual(promptBlocks.first?["text"] as? String, "System\n\nHello")
	}

	func testCursorHeadlessProviderSkipsUnknownModelWithoutBlockingPrompt() async throws {
		let harness = try makeMockHarness(
			scenario: .success,
			environmentOverrides: ["ACP_TEST_AUTH_METHODS_KIND": "none"],
			providerID: .cursor
		)
		let provider = makeCursorHeadlessProvider(
			harness: harness,
			modelString: "cursor/unknown-model"
		)
		let stream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "", userMessage: "Hello", resumeSessionID: nil),
			runID: UUID()
		)
		let results = try await collectStreamResults(from: stream)

		XCTAssertTrue(results.contains(where: { $0.type == "content" && $0.text == "OK from success scenario" }))
		let entries = try harness.readLoggedEntries()
		XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/new", "session/prompt", "session/cancel"])
		XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/set_config_option" }))
	}

	func testCursorHeadlessProviderClearsStaleResumeIDAfterLoadFallback() async throws {
		let missingSessionID = "missing-cursor-headless-session"
		let harness = try makeMockHarness(
			scenario: .prompt,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_LOAD_ERROR": "Invalid params",
				"ACP_TEST_LOAD_ERROR_CODE": "-32602",
				"ACP_TEST_LOAD_ERROR_DATA_MESSAGE": "Session \(missingSessionID) not found"
			],
			providerID: .cursor
		)
		let provider = makeCursorHeadlessProvider(harness: harness, modelString: nil)

		let stream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "System", userMessage: "Fresh fallback", resumeSessionID: missingSessionID),
			runID: UUID()
		)
		_ = try await collectStreamResults(from: stream)

		let entries = try harness.readLoggedEntries()
		XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/load", "session/new", "session/prompt", "session/cancel"])
		let prompt = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/prompt" }))
		let promptParams = try XCTUnwrap(prompt["params"] as? [String: Any])
		XCTAssertEqual(promptParams["sessionId"] as? String, harness.sessionID)
		let promptBlocks = try XCTUnwrap(promptParams["prompt"] as? [[String: Any]])
		XCTAssertEqual(promptBlocks.first?["text"] as? String, "System\n\nFresh fallback")
	}

	func testCursorHeadlessProviderAppliesRegistryKnownDynamicModel() async throws {
		let model = "cursor/custom-dynamic"
		AgentACPModelRegistry.shared.updateDiscoveredModels(
			ACPDiscoveredSessionModels(
				options: [
					AgentModelOption(
						rawValue: model,
						displayName: "Custom Dynamic",
						description: nil,
						isDefault: false
					)
				],
				currentModelRaw: nil
			),
			for: .cursor
		)
		let harness = try makeMockHarness(
			scenario: .success,
			environmentOverrides: ["ACP_TEST_AUTH_METHODS_KIND": "none"],
			providerID: .cursor
		)
		let provider = makeCursorHeadlessProvider(harness: harness, modelString: model)
		let stream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "", userMessage: "Hello", resumeSessionID: nil),
			runID: UUID()
		)
		_ = try await collectStreamResults(from: stream)

		let entries = try harness.readLoggedEntries()
		XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/new", "session/set_config_option", "session/prompt", "session/cancel"])
		let setConfig = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/set_config_option" }))
		let params = try XCTUnwrap(setConfig["params"] as? [String: Any])
		XCTAssertEqual(params["value"] as? String, model)
	}

	func testCursorHeadlessProviderDeclinesNativePermissionAndCancelsPrompt() async throws {
		let harness = try makeMockHarness(
			scenario: .cancel,
			environmentOverrides: ["ACP_TEST_AUTH_METHODS_KIND": "none"],
			providerID: .cursor
		)
		let provider = makeCursorHeadlessProvider(harness: harness, modelString: nil)
		let stream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "", userMessage: "Needs tool", resumeSessionID: nil),
			runID: UUID()
		)

		do {
			_ = try await collectStreamResults(from: stream)
			XCTFail("Expected Cursor native permission request to fail the headless stream")
		} catch {
			let message: String
			if case AIProviderError.invalidConfiguration(let detail) = error {
				message = detail
			} else {
				message = String(describing: error)
			}
			XCTAssertTrue(message.contains("Cursor requested tool approval during headless discovery"), message)
			XCTAssertTrue(message.contains("Run test command"), message)
		}

		let entries = try await waitForLoggedEntries(harness: harness) { entries in
			requestMethodSequence(entries).contains("session/cancel")
				&& entries.contains(where: { jsonRPCID($0) == 900 && $0["method"] == nil })
		}
		XCTAssertTrue(requestMethodSequence(entries).contains("session/cancel"))
		let permissionResponse = try XCTUnwrap(entries.first(where: { jsonRPCID($0) == 900 && $0["method"] == nil }))
		let resultDescription = String(describing: permissionResponse["result"])
		XCTAssertTrue(resultDescription.contains("selected"), resultDescription)
		XCTAssertTrue(resultDescription.contains("opt-reject-once"), resultDescription)
	}

	func testGeminiHeadlessProviderStreamsPromptWithDefaultModeAndMCPInjection() async throws {
		let harness = try makeMockHarness(
			scenario: .success,
			environmentOverrides: ["ACP_TEST_CURRENT_MODE_ID": "yolo"],
			providerID: .gemini
		)
		let provider = makeGeminiHeadlessProvider(
			harness: harness,
			modelString: "gemini-2.5-flash"
		)

		let stream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "System", userMessage: "Hello", resumeSessionID: nil),
			runID: UUID()
		)
		let results = try await collectStreamResults(from: stream)

		XCTAssertTrue(results.contains(where: { $0.type == "content" && $0.text == "OK from success scenario" }))
		XCTAssertTrue(results.contains(where: { $0.type == "message_stop" && $0.providerSessionID == harness.sessionID }))

		let entries = try harness.readLoggedEntries()
		let methods = requestMethodSequence(entries)
		XCTAssertTrue(methods.starts(with: ["initialize", "authenticate", "session/new"]), String(describing: methods))
		let setModeIndex = try XCTUnwrap(methods.firstIndex(of: "session/set_mode"))
		let promptIndex = try XCTUnwrap(methods.firstIndex(of: "session/prompt"))
		XCTAssertLessThan(setModeIndex, promptIndex)

		let setMode = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/set_mode" }))
		let setModeParams = try XCTUnwrap(setMode["params"] as? [String: Any])
		XCTAssertEqual(setModeParams["modeId"] as? String, GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID)

		let sessionNew = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/new" }))
		let sessionParams = try XCTUnwrap(sessionNew["params"] as? [String: Any])
		assertRepoPromptMCPServer(in: sessionParams)

		let prompt = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/prompt" }))
		let promptParams = try XCTUnwrap(prompt["params"] as? [String: Any])
		let promptBlocks = try XCTUnwrap(promptParams["prompt"] as? [[String: Any]])
		XCTAssertEqual(promptBlocks.first?["text"] as? String, "System\n\nHello")
	}

	func testGeminiHeadlessProviderDiscoversDurableLoadIDDifferentFromRuntimeUsingArrayContent() async throws {
		let durableID = "durable-gemini-\(UUID().uuidString)"
		let harness = try makeMockHarness(
			scenario: .success,
			environmentOverrides: [
				"ACP_TEST_GEMINI_DURABLE_SESSION_ID": durableID,
				"ACP_TEST_GEMINI_CHAT_CONTENT_FORMAT": "array",
				"ACP_TEST_GEMINI_CHAT_USER_TEXT": "RepoPrompt mock prompt"
			],
			providerID: .gemini
		)
		XCTAssertNotEqual(durableID, harness.sessionID)
		let provider = makeGeminiHeadlessProvider(harness: harness, modelString: "gemini-2.5-flash")

		let firstStream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "", userMessage: "RepoPrompt mock prompt", resumeSessionID: nil),
			runID: UUID()
		)
		let firstResults = try await collectStreamResults(from: firstStream)
		XCTAssertTrue(firstResults.contains(where: { $0.type == "message_stop" && $0.providerSessionID == durableID }))

		let secondStream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "", userMessage: "Follow up", resumeSessionID: durableID),
			runID: UUID()
		)
		_ = try await collectStreamResults(from: secondStream)

		let entries = try harness.readLoggedEntries()
		let load = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/load" }))
		let loadParams = try XCTUnwrap(load["params"] as? [String: Any])
		XCTAssertEqual(loadParams["sessionId"] as? String, durableID)
	}

	func testGeminiHeadlessProviderAutoApprovesPermissionWithProceedOption() async throws {
		let harness = try makeMockHarness(
			scenario: .permission,
			environmentOverrides: [
				"ACP_TEST_PERMISSION_TITLE": "read_file",
				"ACP_TEST_PERMISSION_KIND": "other",
				"ACP_TEST_PERMISSION_RAW_INPUT_JSON": #"{"path":"README.md"}"#,
				"ACP_TEST_PERMISSION_OPTIONS_JSON": #"[{"optionId":"proceed_once","kind":"allow_once"},{"optionId":"proceed_always_server","kind":"allow_always"},{"optionId":"reject_once","kind":"reject_once"}]"#
			],
			providerID: .gemini
		)
		let provider = makeGeminiHeadlessProvider(harness: harness, modelString: nil)

		let stream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "", userMessage: "Needs permission", resumeSessionID: nil),
			runID: UUID()
		)
		let results = try await collectStreamResults(from: stream)

		XCTAssertTrue(results.contains(where: { $0.type == "content" && $0.text == "OK from success scenario" }))
		XCTAssertTrue(results.contains(where: { $0.type == "message_stop" && $0.providerSessionID == harness.sessionID }))

		let entries = try harness.readLoggedEntries()
		let permissionResponse = try XCTUnwrap(entries.first(where: { jsonRPCID($0) == 900 && $0["result"] != nil }))
		let result = try XCTUnwrap(permissionResponse["result"] as? [String: Any])
		let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
		XCTAssertEqual(outcome["outcome"] as? String, "selected")
		XCTAssertEqual(outcome["optionId"] as? String, "proceed_always_server")
	}

	func testGeminiHeadlessProviderUsesSessionLoadForResume() async throws {
		let existingSessionID = "existing-gemini-headless-session"
		let harness = try makeMockHarness(
			scenario: .success,
			resumeSessionID: existingSessionID,
			providerID: .gemini
		)
		let provider = makeGeminiHeadlessProvider(
			harness: harness,
			modelString: "gemini-2.5-flash"
		)

		let stream = try await provider.streamAgentMessage(
			AgentMessage(systemPrompt: "System", userMessage: "Follow up", resumeSessionID: existingSessionID),
			runID: UUID()
		)
		_ = try await collectStreamResults(from: stream)

		let entries = try harness.readLoggedEntries()
		let methods = requestMethodSequence(entries)
		XCTAssertTrue(methods.contains("session/load"), String(describing: methods))
		XCTAssertFalse(methods.contains("session/new"), String(describing: methods))
		let loadIndex = try XCTUnwrap(methods.firstIndex(of: "session/load"))
		let promptIndex = try XCTUnwrap(methods.firstIndex(of: "session/prompt"))
		XCTAssertLessThan(loadIndex, promptIndex)

		let load = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/load" }))
		let loadParams = try XCTUnwrap(load["params"] as? [String: Any])
		XCTAssertEqual(loadParams["sessionId"] as? String, existingSessionID)

		let prompt = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/prompt" }))
		let promptParams = try XCTUnwrap(prompt["params"] as? [String: Any])
		let promptBlocks = try XCTUnwrap(promptParams["prompt"] as? [[String: Any]])
		XCTAssertEqual(promptBlocks.first?["text"] as? String, "Follow up")
	}

	func testDiscoverAgentServiceGeminiFactoryUsesACPHeadlessProvider() {
		let provider = DiscoverAgentService.shared.makeProvider(
			for: .gemini,
			modelString: "gemini-2.5-flash",
			workspacePath: "/tmp/gemini-acp-headless"
		)

		XCTAssertTrue(provider is GeminiACPHeadlessAgentProvider)
	}

	func testGeminiHeadlessProviderDisposeCancelsActivePrompt() async {
		var harnessForCancellationCheck: MockHarness?
		do {
			let harness = try makeMockHarness(
				scenario: .toolCallDelayedUpdateThenHang,
				providerID: .gemini
			)
			harnessForCancellationCheck = harness
			let provider = makeGeminiHeadlessProvider(harness: harness, modelString: nil)
			let stream = try await provider.streamAgentMessage(
				AgentMessage(systemPrompt: "", userMessage: "Hang until disposed", resumeSessionID: nil),
				runID: UUID()
			)
			let collectTask = Task<Void, Never> {
				do {
					_ = try await collectStreamResults(from: stream)
				} catch {
					// Expected when disposal races an active prompt; the stream may surface
					// cancellation or transport shutdown depending on timing.
				}
			}

			let promptStartedEntries = try await waitForLoggedEntries(harness: harness) { entries in
				requestMethodSequence(entries).contains("session/prompt")
			}
			XCTAssertTrue(requestMethodSequence(promptStartedEntries).contains("session/prompt"))

			await provider.dispose()
			await collectTask.value

			let entries = try await waitForLoggedEntries(harness: harness) { entries in
				requestMethodSequence(entries).contains("session/cancel")
			}
			XCTAssertTrue(requestMethodSequence(entries).contains("session/cancel"))
		} catch is CancellationError {
			let entries = (try? harnessForCancellationCheck?.readLoggedEntries()) ?? []
			XCTAssertTrue(
				requestMethodSequence(entries).contains("session/cancel"),
				"Expected dispose-triggered cancellation to log session/cancel before surfacing CancellationError. Entries: \(requestMethodSequence(entries))"
			)
		} catch {
			XCTFail("Unexpected cancellation test error: \(error)")
		}
	}

	func testGeminiFullAccessAutoApprovesNativePermissionWithoutApprovalEvent() async throws {
		let harness = try makeMockHarness(
			scenario: .permission,
			environmentOverrides: [
				"ACP_TEST_PERMISSION_TITLE": "read_file",
				"ACP_TEST_PERMISSION_KIND": "other",
				"ACP_TEST_PERMISSION_RAW_INPUT_JSON": #"{"path":"README.md"}"#,
				"ACP_TEST_PERMISSION_OPTIONS_JSON": #"[{"optionId":"proceed_once","kind":"allow_once"},{"optionId":"proceed_always_server","kind":"allow_always"},{"optionId":"reject_once","kind":"reject_once"}]"#
			],
			providerID: .gemini
		)
		let controller = try harness.makeController(
			modelString: "gemini-2.5-flash",
			autoApproveAllToolPermissions: true
		)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.prompt(AgentMessage(userMessage: "Trigger a Gemini permission request"))
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let events = await recorder.snapshot()
			XCTAssertTrue(approvals(from: events).isEmpty)

			let entries = try harness.readLoggedEntries()
			let permissionResponse = try XCTUnwrap(entries.first(where: { jsonRPCID($0) == 900 && $0["result"] != nil }))
			let result = try XCTUnwrap(permissionResponse["result"] as? [String: Any])
			let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
			XCTAssertEqual(outcome["outcome"] as? String, "selected")
			XCTAssertEqual(outcome["optionId"] as? String, "proceed_always_server")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCursorCLIProviderAppliesAskModeBeforePromptAndStreamsWithNoMCPConfig() async throws {
		let harness = try makeMockHarness(
			scenario: .success,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_CURRENT_MODE_ID": "agent",
				"ACP_TEST_AVAILABLE_MODES_JSON": #"[{"id":"agent"},{"id":"plan"},{"id":"ask"}]"#
			],
			providerID: .cursor
		)
		let capture = CursorCLIProviderCapture()
		let providerFactory = MockCursorHeadlessACPProviderFactory(harness: harness)
		let provider = CursorCLIProvider { config, workspacePath in
			capture.config = config
			capture.workspacePath = workspacePath
			return CursorACPHeadlessAgentProvider(
				config: config,
				workspacePath: workspacePath,
				providerFactory: { config in providerFactory.makeProvider(includeRepoPromptMCPServer: config.includeRepoPromptMCPServer) }
			)
		}

		let stream = try await provider.streamMessage(
			AIMessage(systemPrompt: "System", userMessage: "Say hi"),
			model: .cursorCustom(name: AgentModel.cursorAuto.rawValue),
			maxTokens: nil
		)
		let results = try await collectStreamResults(from: stream)

		XCTAssertTrue(results.contains(where: { $0.type == "content" && $0.text == "OK from success scenario" }))
		XCTAssertTrue(results.contains(where: { $0.type == "message_stop" && $0.providerSessionID == harness.sessionID }))
		let config = try XCTUnwrap(capture.config)
		XCTAssertEqual(config.modelString, AgentModel.cursorAuto.rawValue)
		XCTAssertFalse(config.includeRepoPromptMCPServer)
		XCTAssertTrue(config.cleanupProjectMCPConfig)
		XCTAssertEqual(config.sessionModeID, CursorAgentConfig.promptOnlySessionModeID)
		XCTAssertNil(capture.workspacePath)

		let entries = try harness.readLoggedEntries()
		XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/new", "session/set_mode", "session/prompt", "session/cancel"])
		XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/set_config_option" }))
		let setMode = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/set_mode" }))
		let setModeParams = try XCTUnwrap(setMode["params"] as? [String: Any])
		XCTAssertEqual(setModeParams["modeId"] as? String, CursorAgentConfig.promptOnlySessionModeID)
		let sessionNew = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/new" }))
		let sessionParams = try XCTUnwrap(sessionNew["params"] as? [String: Any])
		XCTAssertEqual((sessionParams["mcpServers"] as? [[String: Any]])?.count, 0)
		let prompt = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/prompt" }))
		let promptParams = try XCTUnwrap(prompt["params"] as? [String: Any])
		let promptBlocks = try XCTUnwrap(promptParams["prompt"] as? [[String: Any]])
		let promptText = try XCTUnwrap(promptBlocks.first?["text"] as? String)
		XCTAssertTrue(promptText.contains("System"), promptText)
		XCTAssertTrue(promptText.contains("User: Say hi"), promptText)
	}

	func testCursorCLIProviderFailsBeforePromptWhenAskModeUnavailable() async throws {
		let harness = try makeMockHarness(
			scenario: .success,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_CURRENT_MODE_ID": "agent",
				"ACP_TEST_AVAILABLE_MODES_JSON": #"[{"id":"agent"},{"id":"plan"}]"#
			],
			providerID: .cursor
		)
		let providerFactory = MockCursorHeadlessACPProviderFactory(harness: harness)
		let provider = CursorCLIProvider { config, workspacePath in
			CursorACPHeadlessAgentProvider(
				config: config,
				workspacePath: workspacePath,
				providerFactory: { config in providerFactory.makeProvider(includeRepoPromptMCPServer: config.includeRepoPromptMCPServer) }
			)
		}

		do {
			_ = try await provider.completeMessage(
				AIMessage(systemPrompt: "System", userMessage: "Say hi"),
				model: .cursorCustom(name: AgentModel.cursorAuto.rawValue),
				maxTokens: nil
			)
			XCTFail("Expected Cursor chat to fail when ask mode is not advertised")
		} catch {
			let message: String
			if case AIProviderError.invalidConfiguration(let detail) = error {
				message = detail
			} else {
				message = error.localizedDescription
			}
			XCTAssertTrue(message.contains("session mode 'ask'"), message)
			XCTAssertTrue(message.contains("Available modes: agent, plan"), message)
		}

		let entries = try harness.readLoggedEntries()
		XCTAssertTrue(requestMethodSequence(entries).starts(with: ["initialize", "session/new"]))
		XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/set_mode" }))
		XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/prompt" }))
	}

	func testOpenCodeSetSessionModelUsesConfigOptionAndRefreshesRegistry() async throws {
		let openCodeConfigOptionsJSON = #"[{"id":"model","name":"Model","category":"model","type":"select","currentValue":"openai/gpt-5","options":[{"value":"anthropic/claude-sonnet-4","name":"Anthropic/Claude Sonnet 4"},{"value":"openai/gpt-5","name":"OpenAI/GPT-5"}]}]"#
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			environmentOverrides: ["ACP_TEST_CONFIG_OPTIONS_JSON": openCodeConfigOptionsJSON],
			providerID: .openCode
		)
		let controller = try harness.makeController(modelString: "Default")
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.setSessionModel("anthropic/claude-sonnet-4")

			let discoveredModels = AgentACPModelRegistry.shared.test_snapshot(providerID: .openCode)
			XCTAssertEqual(discoveredModels?.currentModelRaw, "anthropic/claude-sonnet-4")
			XCTAssertEqual(discoveredModels?.options.map(\.rawValue), [
				"anthropic/claude-sonnet-4",
				"openai/gpt-5"
			])

			let entries = try harness.readLoggedEntries()
			let setConfig = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/set_config_option" }))
			let params = try XCTUnwrap(setConfig["params"] as? [String: Any])
			XCTAssertEqual(params["sessionId"] as? String, harness.sessionID)
			XCTAssertEqual(params["configId"] as? String, "model")
			XCTAssertEqual(params["value"] as? String, "anthropic/claude-sonnet-4")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testPromptFlowStreamsUpdatesAndReturnsStopReason() async throws {
		let harness = try makeMockHarness(scenario: .prompt)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.prompt(AgentMessage(systemPrompt: "System", userMessage: "Say hello"))
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let events = await recorder.snapshot()
			let streamResults = streamResults(from: events)
			XCTAssertTrue(streamResults.contains(where: { $0.type == "content" && $0.text == "hello from mock acp" }))
			XCTAssertTrue(streamResults.contains(where: { $0.type == "tool_call" && $0.toolName == "read_file" }))
			XCTAssertTrue(streamResults.contains(where: {
				$0.type == "tool_result"
					&& $0.toolResultJSON?.contains("running") == true
					&& $0.toolResultJSON?.contains("Reading README.md") == true
			}))
			XCTAssertTrue(streamResults.contains(where: { $0.type == "tool_result" && $0.toolName == "read_file" && $0.toolResultJSON?.contains("mock file contents") == true }))
			XCTAssertTrue(streamResults.contains(where: { $0.type == "message_stop" && $0.stopReason == "end_turn" && $0.providerSessionID == harness.sessionID }))
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testPromptFlowIncludesOpenCodeUsageOnMessageStop() async throws {
		let usageJSON = #"{"inputTokens":12,"outputTokens":7,"cachedReadTokens":3,"cachedWriteTokens":2,"totalTokens":24}"#
		let harness = try makeMockHarness(
			scenario: .prompt,
			environmentOverrides: ["ACP_TEST_PROMPT_USAGE_JSON": usageJSON],
			providerID: .openCode
		)
		let controller = try harness.makeController(modelString: "Default")
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.prompt(AgentMessage(userMessage: "Say hello"))
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let events = await recorder.snapshot()
			let messageStop = try XCTUnwrap(streamResults(from: events).first(where: { $0.type == "message_stop" }))
			XCTAssertEqual(messageStop.promptTokens, 12)
			XCTAssertEqual(messageStop.completionTokens, 7)
			XCTAssertEqual(messageStop.contextUsedTokens, 17)
			XCTAssertEqual(messageStop.providerSessionID, harness.sessionID)
			XCTAssertEqual(messageStop.stopReason, "end_turn")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testOpenCodeEmptyPromptCompletionEmitsDiagnosticError() async throws {
		let usageJSON = #"{"inputTokens":0,"outputTokens":0,"totalTokens":0}"#
		let harness = try makeMockHarness(
			scenario: .emptyOpenCodeCompletion,
			environmentOverrides: ["ACP_TEST_PROMPT_USAGE_JSON": usageJSON],
			providerID: .openCode
		)
		let controller = try harness.makeController(modelString: "Default")
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.prompt(AgentMessage(userMessage: "Say hello"))
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let streamResults = streamResults(from: await recorder.snapshot())
			XCTAssertFalse(streamResults.contains(where: { $0.type == "content" }))
			let diagnostic = try XCTUnwrap(streamResults.first(where: { $0.type == "error" })?.text)
			XCTAssertTrue(diagnostic.contains("emitted no assistant content or reasoning chunks"))
			XCTAssertTrue(diagnostic.contains("input=0, output=0, total=0"))
			XCTAssertTrue(diagnostic.contains("usage_update=1"))
			let messageStop = try XCTUnwrap(streamResults.first(where: { $0.type == "message_stop" }))
			XCTAssertEqual(messageStop.promptTokens, 0)
			XCTAssertEqual(messageStop.completionTokens, 0)
			XCTAssertEqual(messageStop.stopReason, "end_turn")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testPermissionRequestFlowEmitsApprovalAndRespondsToServer() async throws {
		let harness = try makeMockHarness(scenario: .permission)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()

			let promptTask = Task {
				try await controller.prompt(AgentMessage(userMessage: "Trigger a permission request"))
			}

			let sawApprovalRequest = await recorder.waitForApprovalRequest(timeout: 2.0)
			XCTAssertTrue(sawApprovalRequest)
			let firstApproval = await recorder.firstApprovalRequest()
			let approval = try XCTUnwrap(firstApproval)
			XCTAssertEqual(approval.method, "session/request_permission")
			XCTAssertEqual(approval.reason, "Run test command")
			XCTAssertEqual(approval.command, "{\n  \"command\" : \"echo hi\"\n}")

			await controller.respondToPermissionRequest(id: approval.requestID.displayValue, decision: .accept)
			try await promptTask.value
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let entries = try harness.readLoggedEntries()
			let permissionResponse = try XCTUnwrap(entries.first(where: { jsonRPCID($0) == 900 && $0["result"] != nil }))
			let result = try XCTUnwrap(permissionResponse["result"] as? [String: Any])
			let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
			XCTAssertEqual(outcome["outcome"] as? String, "selected")
			XCTAssertEqual(outcome["optionId"] as? String, "opt-allow-once")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testOpenCodeRepoPromptMCPPermissionAutoApprovesWithoutApprovalEvent() async throws {
		let harness = try makeMockHarness(
			scenario: .permission,
			environmentOverrides: [
				"ACP_TEST_PERMISSION_TITLE": "mcp__RepoPrompt__get_file_tree",
				"ACP_TEST_PERMISSION_RAW_INPUT_JSON": #"{"server":"RepoPrompt","toolName":"get_file_tree","args":{"type":"roots"}}"#,
				"ACP_TEST_PERMISSION_OPTIONS_JSON": #"[{"optionId":"once","kind":"allow_once"},{"optionId":"always","kind":"allow_always"},{"optionId":"reject","kind":"reject_once"}]"#
			],
			providerID: .openCode
		)
		let controller = try harness.makeController(modelString: "Default")
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.prompt(AgentMessage(userMessage: "Trigger a RepoPrompt MCP permission request"))
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let events = await recorder.snapshot()
			XCTAssertTrue(approvals(from: events).isEmpty)

			let entries = try harness.readLoggedEntries()
			let permissionResponse = try XCTUnwrap(entries.first(where: { jsonRPCID($0) == 900 && $0["result"] != nil }))
			let result = try XCTUnwrap(permissionResponse["result"] as? [String: Any])
			let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
			XCTAssertEqual(outcome["outcome"] as? String, "selected")
			XCTAssertEqual(outcome["optionId"] as? String, "always")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCursorRepoPromptGitPermissionAutoApprovesAllowAlwaysWithoutApprovalEvent() async throws {
		let harness = try makeMockHarness(
			scenario: .permission,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_PERMISSION_TITLE": "RepoPrompt-git: git",
				"ACP_TEST_PERMISSION_KIND": "other",
				"ACP_TEST_PERMISSION_RAW_INPUT_JSON": #"{"command":"git status"}"#,
				"ACP_TEST_PERMISSION_OPTIONS_JSON": #"[{"optionId":"allow_once","kind":"allow_once"},{"optionId":"allow_always","kind":"allow_always"},{"optionId":"reject_once","kind":"reject_once"}]"#
			],
			providerID: .cursor
		)
		let controller = try harness.makeController(modelString: AgentModel.cursorAuto.rawValue)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.prompt(AgentMessage(userMessage: "Trigger a Cursor RepoPrompt MCP permission request"))
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let events = await recorder.snapshot()
			XCTAssertTrue(approvals(from: events).isEmpty)

			let entries = try harness.readLoggedEntries()
			let permissionResponse = try XCTUnwrap(entries.first(where: { jsonRPCID($0) == 900 && $0["result"] != nil }))
			let result = try XCTUnwrap(permissionResponse["result"] as? [String: Any])
			let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
			XCTAssertEqual(outcome["outcome"] as? String, "selected")
			XCTAssertEqual(outcome["optionId"] as? String, "allow_always")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCursorNativeGitPermissionDoesNotAutoApproveWithoutRepoPromptIdentity() async throws {
		let harness = try makeMockHarness(
			scenario: .permission,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_PERMISSION_TITLE": "git",
				"ACP_TEST_PERMISSION_KIND": "other",
				"ACP_TEST_PERMISSION_RAW_INPUT_JSON": #"{"command":"git status"}"#,
				"ACP_TEST_PERMISSION_OPTIONS_JSON": #"[{"optionId":"allow_once","kind":"allow_once"},{"optionId":"allow_always","kind":"allow_always"},{"optionId":"reject_once","kind":"reject_once"}]"#
			],
			providerID: .cursor
		)
		let controller = try harness.makeController(modelString: AgentModel.cursorAuto.rawValue)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()

			let promptTask = Task {
				try await controller.prompt(AgentMessage(userMessage: "Trigger a native Cursor git permission request"))
			}

			let sawApprovalRequest = await recorder.waitForApprovalRequest(timeout: 2.0)
			XCTAssertTrue(sawApprovalRequest)
			let firstApproval = await recorder.firstApprovalRequest()
			let approval = try XCTUnwrap(firstApproval)
			XCTAssertEqual(approval.reason, "git")

			await controller.respondToPermissionRequest(id: approval.requestID.displayValue, decision: .accept)
			try await promptTask.value
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let entries = try harness.readLoggedEntries()
			let permissionResponse = try XCTUnwrap(entries.first(where: { jsonRPCID($0) == 900 && $0["result"] != nil }))
			let result = try XCTUnwrap(permissionResponse["result"] as? [String: Any])
			let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
			XCTAssertEqual(outcome["outcome"] as? String, "selected")
			XCTAssertEqual(outcome["optionId"] as? String, "allow_once")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCursorFullAccessAutoApprovesNativePermissionWithoutApprovalEvent() async throws {
		let harness = try makeMockHarness(
			scenario: .permission,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_PERMISSION_TITLE": "git",
				"ACP_TEST_PERMISSION_KIND": "other",
				"ACP_TEST_PERMISSION_RAW_INPUT_JSON": #"{"command":"git status"}"#,
				"ACP_TEST_PERMISSION_OPTIONS_JSON": #"[{"optionId":"allow_once","kind":"allow_once"},{"optionId":"allow_always","kind":"allow_always"},{"optionId":"reject_once","kind":"reject_once"}]"#
			],
			providerID: .cursor
		)
		let controller = try harness.makeController(
			modelString: AgentModel.cursorAuto.rawValue,
			autoApproveAllToolPermissions: true
		)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.prompt(AgentMessage(userMessage: "Trigger a native Cursor git permission request"))
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let events = await recorder.snapshot()
			XCTAssertTrue(approvals(from: events).isEmpty)

			let entries = try harness.readLoggedEntries()
			let permissionResponse = try XCTUnwrap(entries.first(where: { jsonRPCID($0) == 900 && $0["result"] != nil }))
			let result = try XCTUnwrap(permissionResponse["result"] as? [String: Any])
			let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
			XCTAssertEqual(outcome["outcome"] as? String, "selected")
			XCTAssertEqual(outcome["optionId"] as? String, "allow_always")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testOpenCodeNativePermissionDoesNotAutoApprove() async throws {
		let harness = try makeMockHarness(
			scenario: .permission,
			environmentOverrides: [
				"ACP_TEST_PERMISSION_TITLE": "bash",
				"ACP_TEST_PERMISSION_RAW_INPUT_JSON": #"{"command":"echo hi"}"#,
				"ACP_TEST_PERMISSION_OPTIONS_JSON": #"[{"optionId":"once","kind":"allow_once"},{"optionId":"always","kind":"allow_always"},{"optionId":"reject","kind":"reject_once"}]"#
			],
			providerID: .openCode
		)
		let controller = try harness.makeController(modelString: "Default")
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()

			let promptTask = Task {
				try await controller.prompt(AgentMessage(userMessage: "Trigger a native permission request"))
			}

			let sawApprovalRequest = await recorder.waitForApprovalRequest(timeout: 2.0)
			XCTAssertTrue(sawApprovalRequest)
			let firstApproval = await recorder.firstApprovalRequest()
			let approval = try XCTUnwrap(firstApproval)
			XCTAssertEqual(approval.reason, "bash")

			await controller.respondToPermissionRequest(id: approval.requestID.displayValue, decision: .accept)
			try await promptTask.value
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let entries = try harness.readLoggedEntries()
			let permissionResponse = try XCTUnwrap(entries.first(where: { jsonRPCID($0) == 900 && $0["result"] != nil }))
			let result = try XCTUnwrap(permissionResponse["result"] as? [String: Any])
			let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
			XCTAssertEqual(outcome["outcome"] as? String, "selected")
			XCTAssertEqual(outcome["optionId"] as? String, "once")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testCancelFlowSendsSessionCancelAndCancelsPendingPermissions() async throws {
		let harness = try makeMockHarness(scenario: .cancel)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()

			let promptTask = Task {
				try await controller.prompt(AgentMessage(userMessage: "Trigger cancel flow"))
			}

			let sawApprovalRequest = await recorder.waitForApprovalRequest(timeout: 2.0)
			XCTAssertTrue(sawApprovalRequest)
			await controller.cancelPrompt()
			try await promptTask.value
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .cancelled)
			XCTAssertTrue(reachedTerminal)

			let events = await recorder.snapshot()
			let approval = try XCTUnwrap(approvals(from: events).first)
			XCTAssertTrue(approvalCancelledIDs(from: events).contains(approval.requestID))

			let entries = try harness.readLoggedEntries()
			let cancelEntry = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/cancel" }))
			XCTAssertNil(cancelEntry["id"], "session/cancel must be sent as a notification")

			let permissionResponse = try XCTUnwrap(entries.first(where: { jsonRPCID($0) == 900 && $0["result"] != nil }))
			let result = try XCTUnwrap(permissionResponse["result"] as? [String: Any])
			let outcome = try XCTUnwrap(result["outcome"] as? [String: Any])
			XCTAssertEqual(outcome["outcome"] as? String, "cancelled")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testInterruptActivePromptForSteeringCancelsActivePromptAndAllowsSecondPromptOnSameStream() async throws {
		let harness = try makeMockHarness(
			scenario: .steeringCancelThenSuccess,
			environmentOverrides: ["ACP_TEST_AUTH_METHODS_KIND": "none"]
		)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()

			let firstPromptTask = Task {
				try await controller.prompt(AgentMessage(userMessage: "First prompt blocks on permission"))
			}

			let sawApprovalRequest = await recorder.waitForApprovalRequest(timeout: 2.0)
			XCTAssertTrue(sawApprovalRequest)

			try await controller.interruptActivePromptForSteering(timeoutSeconds: 2.0)
			try await firstPromptTask.value

			try await controller.prompt(AgentMessage(userMessage: "Second steering prompt"))
			let reachedCompletedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedCompletedTerminal)

			let events = await recorder.snapshot()
			let terminals = events.compactMap { event -> AgentSessionRunState? in
				guard case .terminal(let state, _) = event else { return nil }
				return state
			}
			XCTAssertEqual(terminals, [.cancelled, .completed])

			let entries = try harness.readLoggedEntries()
			XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/new", "session/prompt", "session/cancel", "session/prompt"])
			let cancelEntry = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/cancel" }))
			XCTAssertNil(cancelEntry["id"], "session/cancel must be sent as a notification")

			let promptEntries = entries.filter { ($0["method"] as? String) == "session/prompt" }
			XCTAssertEqual(promptEntries.count, 2)
			let secondPromptParams = try XCTUnwrap(promptEntries.last?["params"] as? [String: Any])
			let secondPromptBlocks = try XCTUnwrap(secondPromptParams["prompt"] as? [[String: Any]])
			XCTAssertEqual(secondPromptBlocks.first?["text"] as? String, "Second steering prompt")
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testOpenCodeSessionLoadReplayUpdatesAreSuppressedButPromptStillStreams() async throws {
		let existingSessionID = "existing-opencode-session-42"
		let harness = try makeMockHarness(
			scenario: .prompt,
			resumeSessionID: existingSessionID,
			environmentOverrides: ["ACP_TEST_LOAD_REPLAY_UPDATES": "true"],
			providerID: .openCode
		)
		let controller = try harness.makeController(modelString: "Default")
		let recorder = EventRecorder(stream: await controller.events)

		func containsOldReplay(_ result: AIStreamResult) -> Bool {
			let fields = [
				result.text,
				result.reasoning,
				result.toolName,
				result.toolArgs,
				result.toolOutput,
				result.toolResultJSON,
				result.toolArgsJSON
			].compactMap { $0 }
			return result.contextUsedTokens == 111
				|| result.modelContextWindow == 222
				|| result.cost == 0.33
				|| fields.contains(where: { $0.contains("old replay") || $0.contains("old-replay") })
		}

		do {
			let bootstrap = try await controller.bootstrap()
			XCTAssertEqual(bootstrap.sessionID, existingSessionID)
			let bootstrapStreamResults = streamResults(from: await recorder.snapshot())
			XCTAssertFalse(
				bootstrapStreamResults.contains(where: containsOldReplay),
				"session/load replay updates should be suppressed during bootstrap"
			)

			try await controller.prompt(AgentMessage(userMessage: "Say hello after load"))
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let events = await recorder.snapshot()
			let streamResults = streamResults(from: events)
			XCTAssertFalse(
				streamResults.contains(where: containsOldReplay),
				"old load replay text/tool/usage/plan events must not leak into the live stream"
			)
			XCTAssertTrue(streamResults.contains(where: { $0.type == "content" && $0.text == "hello from mock acp" }))
			XCTAssertTrue(streamResults.contains(where: { $0.type == "tool_call" && $0.toolName == "read_file" }))
			XCTAssertTrue(streamResults.contains(where: {
				$0.type == "tool_result"
					&& $0.toolResultJSON?.contains("running") == true
					&& $0.toolResultJSON?.contains("Reading README.md") == true
			}))
			XCTAssertTrue(streamResults.contains(where: { $0.type == "tool_result" && $0.toolName == "read_file" && $0.toolResultJSON?.contains("mock file contents") == true }))
			XCTAssertTrue(streamResults.contains(where: { $0.type == "message_stop" && $0.stopReason == "end_turn" && $0.providerSessionID == existingSessionID }))

			let entries = try harness.readLoggedEntries()
			XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/load", "session/prompt"])
			XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/new" }))

			let loadSession = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/load" }))
			let params = try XCTUnwrap(loadSession["params"] as? [String: Any])
			XCTAssertEqual(params["sessionId"] as? String, existingSessionID)
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testSessionLoadFlowUsesSessionLoadForExistingSessionID() async throws {
		let existingSessionID = "existing-session-42"
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			resumeSessionID: existingSessionID,
			environmentOverrides: ["ACP_TEST_MODELS_JSON": discoveredModelsJSON]
		)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			let bootstrap = try await controller.bootstrap()
			XCTAssertEqual(bootstrap.sessionID, existingSessionID)
			XCTAssertTrue(bootstrap.loadSessionSupported)
			let discoveredModels = AgentACPModelRegistry.shared.test_snapshot(providerID: .gemini)
			XCTAssertEqual(discoveredModels?.currentModelRaw, "gemini-2.5-pro-exp-0827")
			XCTAssertEqual(
				discoveredModels?.option(matching: "gemini-2.5-flash")?.displayName,
				"Gemini 2.5 Flash"
			)

			let entries = try harness.readLoggedEntries()
			XCTAssertEqual(requestMethodSequence(entries), ["initialize", "authenticate", "session/load"])
			XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/new" }))

			let loadSession = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/load" }))
			let params = try XCTUnwrap(loadSession["params"] as? [String: Any])
			XCTAssertEqual(params["sessionId"] as? String, existingSessionID)
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testSessionLoadUnsupportedFailsWithoutOpeningFreshSession() async throws {
		let existingSessionID = "existing-session-unsupported"
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			resumeSessionID: existingSessionID,
			environmentOverrides: ["ACP_TEST_LOAD_SESSION_SUPPORTED": "false"]
		)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			XCTFail("Expected bootstrap to fail when an existing ACP session cannot be loaded")
		} catch {
			let message = error.localizedDescription
			XCTAssertTrue(message.contains("does not support session/load"), message)
			XCTAssertTrue(message.contains(existingSessionID), message)
		}

		await controller.shutdown()
		let entries = try harness.readLoggedEntries()
		XCTAssertEqual(requestMethodSequence(entries), ["initialize", "authenticate"])
		XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/new" }))
		await recorder.cancel()
	}

	func testSessionLoadFailureFailsWithoutOpeningFreshSession() async throws {
		let existingSessionID = "existing-session-load-fails"
		let loadError = "mock load failure"
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			resumeSessionID: existingSessionID,
			environmentOverrides: ["ACP_TEST_LOAD_ERROR": loadError]
		)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			XCTFail("Expected bootstrap to fail when session/load fails")
		} catch {
			let message = error.localizedDescription
			XCTAssertTrue(message.contains(loadError), message)
		}

		await controller.shutdown()
		let entries = try harness.readLoggedEntries()
		XCTAssertEqual(requestMethodSequence(entries), ["initialize", "authenticate", "session/load"])
		XCTAssertFalse(entries.contains(where: { ($0["method"] as? String) == "session/new" }))

		let loadSession = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/load" }))
		let params = try XCTUnwrap(loadSession["params"] as? [String: Any])
		XCTAssertEqual(params["sessionId"] as? String, existingSessionID)
		await recorder.cancel()
	}

	func testGeminiJSONReasoningChunkIsEmittedBeforeDelayedContent() async throws {
		let harness = try makeMockHarness(scenario: .jsonReasoningBeforeDelayedContent)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			let promptTask = Task {
				try await controller.prompt(AgentMessage(userMessage: "Think first"))
			}

			let sawReasoning = await waitForReasoningEvent(
				recorder: recorder,
				timeout: 0.4,
				expectedReasoning: #"{"summary":"thinking"}"#
			)
			XCTAssertTrue(sawReasoning)

			try await promptTask.value
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testUnexpectedProcessExitEmitsErrorAndTerminalEvent() async throws {
		let harness = try makeMockHarness(scenario: .exitAfterBootstrap)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .failed)
			XCTAssertTrue(reachedTerminal)

			let events = await recorder.snapshot()
			let streamResults = streamResults(from: events)
			XCTAssertTrue(streamResults.contains(where: { $0.type == "error" && ($0.text?.contains("exited unexpectedly") ?? false) }))
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testSessionNewStructuredErrorPreservesDetailCodeAndMethodDiagnostic() async throws {
		let diagnostics = ACPDiagnosticRecorder()
		let harness = try makeMockHarness(
			scenario: .bootstrap,
			environmentOverrides: [
				"ACP_TEST_NEW_ERROR": "Internal error",
				"ACP_TEST_NEW_ERROR_CODE": "-32603",
				"ACP_TEST_NEW_ERROR_DATA_MESSAGE": "MCP server RepoPrompt failed to initialize: connection refused"
			]
		)
		let controller = try harness.makeController(diagnostics: diagnostics)

		do {
			_ = try await controller.bootstrap()
			XCTFail("Expected session/new structured ACP error")
		} catch {
			let message = error.localizedDescription
			XCTAssertTrue(message.contains("Internal error"), message)
			XCTAssertTrue(message.contains("MCP server RepoPrompt failed to initialize: connection refused"), message)
			XCTAssertTrue(message.contains("code -32603"), message)
		}

		let summary = await diagnostics.summary()
		XCTAssertTrue(summary.contains("ACP request session/new failed code=-32603"), summary)
		XCTAssertTrue(summary.contains("MCP server RepoPrompt failed to initialize"), summary)
		await controller.shutdown()
	}

	func testPromptStructuredErrorPreservesDetailCodeAndEmitsTerminalError() async throws {
		let diagnostics = ACPDiagnosticRecorder()
		let harness = try makeMockHarness(
			scenario: .prompt,
			environmentOverrides: [
				"ACP_TEST_PROMPT_ERROR": "Internal error",
				"ACP_TEST_PROMPT_ERROR_CODE": "-32603",
				"ACP_TEST_PROMPT_ERROR_DATA_MESSAGE": "MCP initialization failed before ACP prompt: RepoPrompt timed out"
			]
		)
		let controller = try harness.makeController(diagnostics: diagnostics)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			try await controller.prompt(AgentMessage(userMessage: "Hello"))
			XCTFail("Expected session/prompt structured ACP error")
		} catch {
			let message = error.localizedDescription
			XCTAssertTrue(message.contains("Internal error"), message)
			XCTAssertTrue(message.contains("MCP initialization failed before ACP prompt"), message)
			XCTAssertTrue(message.contains("code -32603"), message)
		}

		let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .failed)
		XCTAssertTrue(reachedTerminal)
		let terminalError = await recorder.snapshot().compactMap { event -> String? in
			guard case .terminal(.failed, let errorText) = event else { return nil }
			return errorText
		}.first
		XCTAssertTrue((terminalError ?? "").contains("MCP initialization failed before ACP prompt"), terminalError ?? "")
		let summary = await diagnostics.summary()
		XCTAssertTrue(summary.contains("ACP request session/prompt failed code=-32603"), summary)
		await controller.shutdown()
		await recorder.cancel()
	}

	func testBootstrapTimeoutIncludesLaunchAndSilenceDiagnostics() async throws {
		let harness = try makeMockHarness(scenario: .silent, providerID: .cursor)
		let controller = try harness.makeController(
			requestTimeouts: ACPAgentSessionController.RequestTimeouts(bootstrapSeconds: 0.1)
		)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
			XCTFail("Expected bootstrap timeout")
		} catch {
			let message = error.localizedDescription
			XCTAssertTrue(message.contains("ACP request initialize timed out"), message)
			XCTAssertTrue(message.contains("Launched:"), message)
			XCTAssertTrue(message.contains("stayed silent"), message)
		}

		await controller.shutdown()
		await recorder.cancel()
	}

	func testShutdownCleansUpProcessAndFinishesEventStream() async throws {
		let harness = try makeMockHarness(scenario: .bootstrap)
		let controller = try harness.makeController()
		let recorder = EventRecorder(stream: await controller.events)

		do {
			_ = try await controller.bootstrap()
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testLiveGeminiACPFlashRoundTrip_optIn() async throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["RUN_GEMINI_ACP_LIVE"] == "1",
			"Live Gemini ACP test is opt-in (set RUN_GEMINI_ACP_LIVE=1)"
		)

		let workspaceURL = try makeTempDirectory()
		let model = ProcessInfo.processInfo.environment["GEMINI_ACP_MODEL"] ?? "gemini-2.5-flash"
		let runRequest = ACPRunRequest(
			agentKind: .gemini,
			modelString: model,
			workspacePath: workspaceURL.path,
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil
		)
		let provider = LiveGeminiACPTestProvider(
			base: GeminiACPAgentProvider(
				config: GeminiAgentConfig(
					modelString: model,
					enableDebugLogging: ProcessInfo.processInfo.environment["GEMINI_ACP_DEBUG"] == "1"
				)
			)
		)

		switch await provider.support(for: runRequest) {
		case .supported:
			break
		case .unsupported(let reason):
			throw XCTSkip("Gemini ACP runtime unavailable: \(reason)")
		}

		let controller = try ACPAgentSessionController(provider: provider, runRequest: runRequest)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			let bootstrap = try await controller.bootstrap()
			XCTAssertFalse(bootstrap.sessionID.isEmpty)

			try await controller.prompt(
				AgentMessage(userMessage: "Reply with exactly LIVE_GEMINI_ACP_OK and nothing else.")
			)
			let reachedTerminal = await recorder.waitForTerminal(timeout: 30.0, expected: .completed)
			XCTAssertTrue(reachedTerminal)

			let events = await recorder.snapshot()
			let transcript = streamResults(from: events)
				.filter { $0.type == "content" }
				.compactMap(\.text)
				.joined()
			XCTAssertTrue(
				transcript.localizedCaseInsensitiveContains("LIVE_GEMINI_ACP_OK"),
				"Expected live Gemini ACP transcript to contain LIVE_GEMINI_ACP_OK, got: \(transcript)"
			)
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 5.0)
		XCTAssertTrue(didFinish)
		await recorder.cancel()
	}

	func testLiveGeminiACPBootstrapDiagnostics_optIn() async throws {
		try XCTSkipUnless(
			ProcessInfo.processInfo.environment["RUN_GEMINI_ACP_LIVE"] == "1",
			"Live Gemini ACP diagnostic test is opt-in (set RUN_GEMINI_ACP_LIVE=1)"
		)

		let workspaceURL = try makeTempDirectory()
		let model = ProcessInfo.processInfo.environment["GEMINI_ACP_MODEL"] ?? "gemini-2.5-flash"
		let initialConfig = GeminiAgentConfig(
			commandName: ProcessInfo.processInfo.environment["GEMINI_CLI_PATH"] ?? "gemini",
			modelString: model,
			enableDebugLogging: true
		)
		let initialProvider = GeminiACPAgentProvider(config: initialConfig)
		let runRequest = ACPRunRequest(
			agentKind: .gemini,
			modelString: model,
			workspacePath: workspaceURL.path,
			resumeSessionID: nil,
			attachments: [],
			taskLabelKind: nil
		)

		switch await initialProvider.support(for: runRequest) {
		case .supported:
			break
		case .unsupported(let reason):
			throw XCTSkip("Gemini ACP runtime unavailable: \(reason)")
		}

		let diagLogURL = FileManager.default.temporaryDirectory.appendingPathComponent("acp-diag-\(UUID().uuidString).log")
		func diagLog(_ msg: String) {
			let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
			print(line, terminator: "")
			if let data = line.data(using: .utf8) {
				if FileManager.default.fileExists(atPath: diagLogURL.path) {
					if let handle = try? FileHandle(forWritingTo: diagLogURL) {
						handle.seekToEndOfFile()
						handle.write(data)
						handle.closeFile()
					}
				} else {
					try? data.write(to: diagLogURL)
				}
			}
		}
		diagLog("Diagnostic log: \(diagLogURL.path)")

		let resolvedCLIPath = try await resolveRealCLIPath(
			commandName: initialConfig.commandName,
			additionalPathHints: initialConfig.additionalPathHints,
			enableDebugLogging: initialConfig.enableDebugLogging
		)
		diagLog("[ACP-DIAG] Resolved Gemini CLI path: \(resolvedCLIPath)")

		let provider = GeminiACPAgentProvider(
			config: GeminiAgentConfig(
				commandName: resolvedCLIPath,
				additionalPathHints: [],
				modelString: model,
				enableDebugLogging: true
			)
		)
		let launchConfiguration = try provider.makeLaunchConfiguration(for: runRequest)
		diagLog("[ACP-DIAG] launch arguments: \(launchConfiguration.arguments)")
		diagLog("[ACP-DIAG] launch workingDirectory: \(launchConfiguration.workingDirectory ?? "<nil>")")
		diagLog("[ACP-DIAG] launch environment keys: \(launchConfiguration.environment.keys.sorted())")
		let diagnostics = ACPDiagnosticRecorder()
		let controller = try ACPAgentSessionController(
			provider: provider,
			runRequest: runRequest,
			diagnosticSink: { event in
				Task {
					await diagnostics.record(event)
				}
			}
		)
		let recorder = EventRecorder(
			stream: await controller.events,
			onEvent: { event in
				diagLog("[ACP-EVENT] \(String(describing: event))")
			}
		)

		do {
			let bootstrapTask = Task { try await controller.bootstrap() }
			try await diagnostics.waitForPhaseCompletion("launch", timeout: 30.0)
			try await diagnostics.waitForPhaseCompletion("initialize", timeout: 30.0)
			try await diagnostics.waitForPhaseCompletion("authenticate", timeout: 30.0)
			try await diagnostics.waitForPhaseCompletion("session/new", timeout: 30.0)
			let bootstrap = try await bootstrapTask.value
			diagLog("[ACP-DIAG] bootstrap completed with sessionID=\(bootstrap.sessionID)")

			let promptTask = Task {
				try await controller.prompt(AgentMessage(userMessage: "Reply with OK"))
			}
			try await diagnostics.waitForPhaseCompletion("prompt", timeout: 30.0)
			try await promptTask.value

			let reachedTerminal = await recorder.waitForTerminal(timeout: 30.0, expected: .completed)
			let diagnosticSummary = await diagnostics.summary()
			XCTAssertTrue(reachedTerminal, diagnosticSummary)

			let events = await recorder.snapshot()
			let transcript = streamResults(from: events)
				.filter { $0.type == "content" }
				.compactMap(\.text)
				.joined()
			diagLog("[ACP-DIAG] final transcript=\(transcript)")
		} catch {
			diagLog("[ACP-DIAG] FAILURE: \(error)")
			diagLog(await diagnostics.summary())
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		diagLog(await diagnostics.summary())
		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 10.0)
		let finalDiagnosticSummary = await diagnostics.summary()
		XCTAssertTrue(didFinish, finalDiagnosticSummary)
		await recorder.cancel()
	}
}

private extension ACPAgentSessionControllerTests {
	enum MockACPScenario: String {
		case bootstrap = "bootstrap"
		case prompt = "prompt"
		case success = "success"
		case permission = "permission"
		case cancel = "cancel"
		case steeringCancelThenSuccess = "steering_cancel_then_success"
		case jsonReasoningBeforeDelayedContent = "json_reasoning_before_delayed_content"
		case toolCallDelayedUpdateThenComplete = "tool_call_delayed_update_then_complete"
		case toolCallDelayedUpdateThenHang = "tool_call_delayed_update_then_hang"
		case emptyOpenCodeCompletion = "empty_opencode_completion"
		case exitAfterBootstrap = "exit_after_bootstrap"
		case silent
	}

	struct MockHarness {
		let tempDirectory: URL
		let scriptURL: URL
		let logURL: URL
		let scenario: MockACPScenario
		let sessionID: String
		let resumeSessionID: String?
		let environmentOverrides: [String: String]
		let mcpServerCommand: String
		let providerID: ACPProviderID
		let launchAdditionalPathHints: [String]
		func makeController(
			requestTimeouts: ACPAgentSessionController.RequestTimeouts = .default,
			modelString: String = "mock-model",
			autoApproveAllToolPermissions: Bool = false,
			diagnostics: ACPDiagnosticRecorder? = nil
		) throws -> ACPAgentSessionController {
			let provider = MockACPAgentProvider(
				scriptURL: scriptURL,
				logURL: logURL,
				scenario: scenario.rawValue,
				sessionID: sessionID,
				workingDirectory: tempDirectory.path,
				environmentOverrides: environmentOverrides,
				mcpServerCommand: mcpServerCommand,
				providerID: providerID,
				launchAdditionalPathHints: launchAdditionalPathHints,
				includeRepoPromptMCPServer: true
			)
			let agentKind: DiscoverAgentKind
			switch providerID {
			case .openCode:
				agentKind = .openCode
			case .cursor:
				agentKind = .cursor
			case .gemini:
				agentKind = .gemini
			}
			let request = ACPRunRequest(
				agentKind: agentKind,
				modelString: modelString,
				workspacePath: tempDirectory.path,
				resumeSessionID: resumeSessionID,
				attachments: [],
				taskLabelKind: nil,
				autoApproveAllToolPermissions: autoApproveAllToolPermissions
			)
			return try ACPAgentSessionController(
				provider: provider,
				runRequest: request,
				diagnosticSink: diagnostics.map { recorder in
					{ event in
						Task { await recorder.record(event) }
					}
				},
				requestTimeouts: requestTimeouts
			)
		}

		func readLoggedEntries() throws -> [[String: Any]] {
			guard FileManager.default.fileExists(atPath: logURL.path) else { return [] }
			let content = try String(contentsOf: logURL, encoding: .utf8)
			return try content
				.split(whereSeparator: \.isNewline)
				.compactMap { line -> [String: Any]? in
					guard !line.isEmpty else { return nil }
					let data = Data(line.utf8)
					return try JSONSerialization.jsonObject(with: data) as? [String: Any]
				}
		}
	}

	func assertSessionLoadMissingSessionFallsBackToNewSession(
		providerID: ACPProviderID,
		modelString: String,
		existingSessionID: String,
		loadError: String = "Invalid params",
		loadErrorCode: String = "-32602",
		loadErrorDataMessage: String? = nil,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws {
		let loadDetail = loadErrorDataMessage ?? "Session \(existingSessionID) not found"
		let harness = try makeMockHarness(
			scenario: .prompt,
			resumeSessionID: existingSessionID,
			environmentOverrides: [
				"ACP_TEST_AUTH_METHODS_KIND": "none",
				"ACP_TEST_LOAD_ERROR": loadError,
				"ACP_TEST_LOAD_ERROR_CODE": loadErrorCode,
				"ACP_TEST_LOAD_ERROR_DATA_MESSAGE": loadDetail
			],
			providerID: providerID
		)
		let controller = try harness.makeController(modelString: modelString)
		let recorder = EventRecorder(stream: await controller.events)

		do {
			let bootstrap = try await controller.bootstrap()
			XCTAssertEqual(bootstrap.sessionID, harness.sessionID, file: file, line: line)
			XCTAssertTrue(bootstrap.didFallbackToNewSessionAfterLoadFailure, file: file, line: line)

			try await controller.prompt(AgentMessage(systemPrompt: "System", userMessage: "Continue from here"))
			let reachedTerminal = await recorder.waitForTerminal(timeout: 2.0, expected: .completed)
			XCTAssertTrue(reachedTerminal, file: file, line: line)
			let events = await recorder.snapshot()
			XCTAssertTrue(streamResults(from: events).contains(where: {
				$0.type == "message_stop" && $0.providerSessionID == harness.sessionID
			}), file: file, line: line)

			let entries = try harness.readLoggedEntries()
			XCTAssertEqual(requestMethodSequence(entries), ["initialize", "session/load", "session/new", "session/prompt"], file: file, line: line)
			let loadSession = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/load" }), file: file, line: line)
			let loadParams = try XCTUnwrap(loadSession["params"] as? [String: Any], file: file, line: line)
			XCTAssertEqual(loadParams["sessionId"] as? String, existingSessionID, file: file, line: line)
			let prompt = try XCTUnwrap(entries.first(where: { ($0["method"] as? String) == "session/prompt" }), file: file, line: line)
			let promptParams = try XCTUnwrap(prompt["params"] as? [String: Any], file: file, line: line)
			XCTAssertEqual(promptParams["sessionId"] as? String, harness.sessionID, file: file, line: line)
			let promptBlocks = try XCTUnwrap(promptParams["prompt"] as? [[String: Any]], file: file, line: line)
			let promptText = try XCTUnwrap(promptBlocks.first?["text"] as? String, file: file, line: line)
			XCTAssertEqual(promptText, "System\n\nContinue from here", "Fresh fallback prompt should clear only the stale resume ID before provider prompt construction", file: file, line: line)
		} catch {
			await controller.shutdown()
			await recorder.cancel()
			throw error
		}

		await controller.shutdown()
		let didFinish = await recorder.waitForFinish(timeout: 2.0)
		XCTAssertTrue(didFinish, file: file, line: line)
		await recorder.cancel()
	}

	func collectStreamResults(from stream: AsyncThrowingStream<AIStreamResult, Error>) async throws -> [AIStreamResult] {
		var results: [AIStreamResult] = []
		for try await result in stream {
			results.append(result)
		}
		return results
	}

	func waitForLoggedEntries(
		harness: MockHarness,
		timeout: TimeInterval = 2.0,
		predicate: ([[String: Any]]) -> Bool
	) async throws -> [[String: Any]] {
		let deadline = Date().addingTimeInterval(timeout)
		var latest = try harness.readLoggedEntries()
		while Date() < deadline {
			if predicate(latest) {
				return latest
			}
			try await Task.sleep(nanoseconds: 20_000_000)
			latest = try harness.readLoggedEntries()
		}
		return latest
	}

	func makeCursorHeadlessProvider(
		harness: MockHarness,
		modelString: String?
	) -> CursorACPHeadlessAgentProvider {
		let providerFactory = MockCursorHeadlessACPProviderFactory(harness: harness)
		return CursorACPHeadlessAgentProvider(
			config: CursorAgentConfig(
				enableDebugLogging: false,
				modelString: modelString,
				includeRepoPromptMCPServer: true,
				cleanupProjectMCPConfig: true
			),
			workspacePath: harness.tempDirectory.path,
			providerFactory: { config in providerFactory.makeProvider(includeRepoPromptMCPServer: config.includeRepoPromptMCPServer) }
		)
	}

	func makeGeminiHeadlessProvider(
		harness: MockHarness,
		modelString: String?
	) -> GeminiACPHeadlessAgentProvider {
		let providerFactory = MockGeminiHeadlessACPProviderFactory(harness: harness)
		return GeminiACPHeadlessAgentProvider(
			config: GeminiAgentConfig(
				modelString: modelString,
				enableDebugLogging: false,
				toolContext: .agentRun,
				includeRepoPromptMCPServer: true
			),
			workspacePath: harness.tempDirectory.path,
			providerFactory: { config in providerFactory.makeProvider(includeRepoPromptMCPServer: config.includeRepoPromptMCPServer) },
			controllerFactory: { provider, request, diagnosticSink in
				XCTAssertEqual(request.agentKind, .gemini)
				XCTAssertEqual(request.workspacePath, harness.tempDirectory.path)
				XCTAssertEqual(request.sessionModeID, GeminiAgentToolPreferences.PermissionLevel.default.sessionModeID)
				XCTAssertTrue(request.autoApproveAllToolPermissions)
				return try ACPAgentSessionController(
					provider: provider,
					runRequest: request,
					diagnosticSink: diagnosticSink
				)
			}
		)
	}

	func makeMockHarness(
		scenario: MockACPScenario,
		resumeSessionID: String? = nil,
		environmentOverrides: [String: String] = [:],
		mcpServerCommand: String = "/bin/echo",
		providerID: ACPProviderID = .gemini,
		launchAdditionalPathHints: [String] = []
	) throws -> MockHarness {
		let tempDirectory = try makeTempDirectory()
		let scriptURL = tempDirectory.appendingPathComponent("mock-acp-server.sh")
		let logURL = tempDirectory.appendingPathComponent("client-requests.jsonl")
		let sessionID = "mock-session-\(UUID().uuidString)"
		var effectiveEnvironmentOverrides = environmentOverrides
		if providerID == .gemini {
			let geminiRoot = tempDirectory.appendingPathComponent("gemini-home", isDirectory: true)
			try FileManager.default.createDirectory(at: geminiRoot, withIntermediateDirectories: true)
			GeminiACPResumeIDResolver.test_setGlobalGeminiDirectoryURL(geminiRoot)
			effectiveEnvironmentOverrides["ACP_TEST_GEMINI_CHAT_TMP_DIR"] = geminiRoot.appendingPathComponent("tmp", isDirectory: true).path
			effectiveEnvironmentOverrides["ACP_TEST_GEMINI_WORKSPACE_PATH"] = tempDirectory.path
			effectiveEnvironmentOverrides["ACP_TEST_GEMINI_WRITE_CHAT_ON_PROMPT"] = effectiveEnvironmentOverrides["ACP_TEST_GEMINI_WRITE_CHAT_ON_PROMPT"] ?? "true"
			addTeardownBlock {
				GeminiACPResumeIDResolver.test_setGlobalGeminiDirectoryURL(nil)
			}
		}
		try FileManager.default.copyItem(at: try mockACPServerFixtureURL(), to: scriptURL)
		try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: scriptURL.path)
		return MockHarness(
			tempDirectory: tempDirectory,
			scriptURL: scriptURL,
			logURL: logURL,
			scenario: scenario,
			sessionID: sessionID,
			resumeSessionID: resumeSessionID,
			environmentOverrides: effectiveEnvironmentOverrides,
			mcpServerCommand: mcpServerCommand,
			providerID: providerID,
			launchAdditionalPathHints: launchAdditionalPathHints
		)
	}

	func makeExecutableCommand(named commandName: String, in directory: URL) throws -> URL {
		let commandURL = directory.appendingPathComponent(commandName)
		try "#!/bin/sh\necho should-not-run\n".write(to: commandURL, atomically: true, encoding: .utf8)
		try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int(0o755))], ofItemAtPath: commandURL.path)
		return commandURL
	}

	func harnessMissingMCPCommandPath() throws -> String {
		try makeTempDirectory()
			.appendingPathComponent("missing-rp-cli")
			.path
	}

	func makeTempDirectory() throws -> URL {
		let url = FileManager.default.temporaryDirectory
			.appendingPathComponent("ACPAgentSessionControllerTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock {
			try? FileManager.default.removeItem(at: url)
		}
		return url
	}

	func requestMethodSequence(_ entries: [[String: Any]]) -> [String] {
		entries.compactMap { $0["method"] as? String }
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

	func jsonRPCID(_ object: [String: Any]) -> Int? {
		if let value = object["id"] as? Int {
			return value
		}
		if let value = object["id"] as? NSNumber {
			return value.intValue
		}
		return nil
	}

	func streamResults(from events: [NormalizedAgentRuntimeEvent]) -> [AIStreamResult] {
		events.compactMap {
			guard case .stream(let result) = $0 else { return nil }
			return result
		}
	}

	func assertRepoPromptMCPServer(
		in params: [String: Any],
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		guard let mcpServers = params["mcpServers"] as? [[String: Any]] else {
			return XCTFail("Expected mcpServers array", file: file, line: line)
		}
		XCTAssertEqual(mcpServers.count, 1, file: file, line: line)
		let server = mcpServers.first
		XCTAssertEqual(server?["name"] as? String, "RepoPrompt", file: file, line: line)
		XCTAssertEqual(server?["command"] as? String, "/bin/echo", file: file, line: line)
		XCTAssertEqual(server?["args"] as? [String], ["serve"], file: file, line: line)
		let env = server?["env"] as? [[String: Any]]
		XCTAssertEqual(env?.count, 1, file: file, line: line)
		XCTAssertEqual(env?.first?["name"] as? String, "ENV_ONE", file: file, line: line)
		XCTAssertEqual(env?.first?["value"] as? String, "VALUE_ONE", file: file, line: line)
	}

	func approvals(from events: [NormalizedAgentRuntimeEvent]) -> [AgentApprovalRequest] {
		events.compactMap {
			guard case .approvalRequested(let request) = $0 else { return nil }
			return request
		}
	}

	func approvalCancelledIDs(from events: [NormalizedAgentRuntimeEvent]) -> [AgentApprovalRequestID] {
		events.compactMap {
			guard case .approvalCancelled(let requestID) = $0 else { return nil }
			return requestID
		}
	}

	func waitForReasoningEvent(
		recorder: EventRecorder,
		timeout: TimeInterval,
		expectedReasoning: String
	) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			let events = await recorder.snapshot()
			if streamResults(from: events).contains(where: {
				$0.type == "reasoning" && $0.reasoning == expectedReasoning
			}) {
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		let events = await recorder.snapshot()
		return streamResults(from: events).contains(where: {
			$0.type == "reasoning" && $0.reasoning == expectedReasoning
		})
	}

	func resolveRealCLIPath(
		commandName: String,
		additionalPathHints: [String],
		enableDebugLogging: Bool
	) async throws -> String {
		let environment = await ProcessEnvironmentBuilder.build(
			ProcessEnvironmentRequest(
				purpose: .acpAgent(providerID: ACPProviderID.gemini.rawValue),
				enableDebugLogging: enableDebugLogging
			)
		).environment
		return CommandPathResolver.resolve(
			commandName,
			environment: environment,
			additionalPaths: additionalPathHints,
			preferredBasenames: [commandName]
		)
	}
}

private final class CursorCLIProviderCapture: @unchecked Sendable {
	var config: CursorAgentConfig?
	var workspacePath: String? = "not-called"
}

private final class MockCursorHeadlessACPProviderFactory: @unchecked Sendable {
	private let scriptURL: URL
	private let logURL: URL
	private let scenario: String
	private let sessionID: String
	private let workingDirectory: String
	private let environmentOverrides: [String: String]
	private let mcpServerCommand: String
	private let launchAdditionalPathHints: [String]

	init(harness: ACPAgentSessionControllerTests.MockHarness) {
		self.scriptURL = harness.scriptURL
		self.logURL = harness.logURL
		self.scenario = harness.scenario.rawValue
		self.sessionID = harness.sessionID
		self.workingDirectory = harness.tempDirectory.path
		self.environmentOverrides = harness.environmentOverrides
		self.mcpServerCommand = harness.mcpServerCommand
		self.launchAdditionalPathHints = harness.launchAdditionalPathHints
	}

	func makeProvider(includeRepoPromptMCPServer: Bool = true) -> MockACPAgentProvider {
		MockACPAgentProvider(
			scriptURL: scriptURL,
			logURL: logURL,
			scenario: scenario,
			sessionID: sessionID,
			workingDirectory: workingDirectory,
			environmentOverrides: environmentOverrides,
			mcpServerCommand: mcpServerCommand,
			providerID: .cursor,
			launchAdditionalPathHints: launchAdditionalPathHints,
			includeRepoPromptMCPServer: includeRepoPromptMCPServer
		)
	}
}

private final class MockGeminiHeadlessACPProviderFactory: @unchecked Sendable {
	private let scriptURL: URL
	private let logURL: URL
	private let scenario: String
	private let sessionID: String
	private let workingDirectory: String
	private let environmentOverrides: [String: String]
	private let mcpServerCommand: String
	private let launchAdditionalPathHints: [String]

	init(harness: ACPAgentSessionControllerTests.MockHarness) {
		self.scriptURL = harness.scriptURL
		self.logURL = harness.logURL
		self.scenario = harness.scenario.rawValue
		self.sessionID = harness.sessionID
		self.workingDirectory = harness.tempDirectory.path
		self.environmentOverrides = harness.environmentOverrides
		self.mcpServerCommand = harness.mcpServerCommand
		self.launchAdditionalPathHints = harness.launchAdditionalPathHints
	}

	func makeProvider(includeRepoPromptMCPServer: Bool = true) -> MockACPAgentProvider {
		MockACPAgentProvider(
			scriptURL: scriptURL,
			logURL: logURL,
			scenario: scenario,
			sessionID: sessionID,
			workingDirectory: workingDirectory,
			environmentOverrides: environmentOverrides,
			mcpServerCommand: mcpServerCommand,
			providerID: .gemini,
			launchAdditionalPathHints: launchAdditionalPathHints,
			includeRepoPromptMCPServer: includeRepoPromptMCPServer
		)
	}
}

private struct MockACPAgentProvider: ACPAgentProvider {
	let scriptURL: URL
	let logURL: URL
	let scenario: String
	let sessionID: String
	let workingDirectory: String
	let environmentOverrides: [String: String]
	let mcpServerCommand: String
	let providerID: ACPProviderID
	let launchAdditionalPathHints: [String]
	let includeRepoPromptMCPServer: Bool

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
			additionalPathHints: launchAdditionalPathHints,
			enableDebugLogging: false
		)
	}

	func makeSessionConfiguration(
		for request: ACPRunRequest,
		mcpServer _: RepoPromptMCPServerConfiguration
	) throws -> ACPSessionConfiguration {
		let mode: ACPSessionConfiguration.Mode
		if let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !resume.isEmpty {
			mode = .load(existingSessionID: resume)
		} else {
			mode = .new
		}
		let mcpServers: [RepoPromptMCPServerConfiguration]
		if includeRepoPromptMCPServer, providerID != .openCode {
			mcpServers = [
				RepoPromptMCPServerConfiguration(
					name: "RepoPrompt",
					command: mcpServerCommand,
					args: ["serve"],
					env: [.init(name: "ENV_ONE", value: "VALUE_ONE")]
				)
			]
		} else {
			mcpServers = []
		}
		return ACPSessionConfiguration(
			mode: mode,
			workingDirectory: workingDirectory,
			mcpServers: mcpServers
		)
	}

	func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
		let isFollowUp = request.resumeSessionID?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.isEmpty == false
		let systemPrompt = message.systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
		let userMessage = message.userMessage.trimmingCharacters(in: .whitespacesAndNewlines)
		let text: String
		if isFollowUp || systemPrompt.isEmpty {
			text = userMessage.isEmpty ? message.userMessage : userMessage
		} else if userMessage.isEmpty {
			text = systemPrompt
		} else {
			text = "\(systemPrompt)\n\n\(userMessage)"
		}
		return [["type": "text", "text": text]]
	}

	func normalizeSessionUpdate(
		_ payload: [String: Any],
		sessionID _: String
	) -> [NormalizedAgentRuntimeEvent] {
		guard let updateType = payload["sessionUpdate"] as? String else { return [] }
		switch updateType {
		case "agent_message_chunk":
			guard let content = payload["content"] as? [String: Any], let text = content["text"] as? String else {
				return []
			}
			return [.stream(AIStreamResult(type: "content", text: text))]
		case "agent_thought_chunk":
			guard let content = payload["content"] as? [String: Any], let text = content["text"] as? String else {
				return []
			}
			return [.stream(AIStreamResult(type: "reasoning", text: nil, reasoning: text))]
		case "usage_update":
			return [
				.stream(
					AIStreamResult(
						type: "usage",
						text: nil,
						cost: payload["cost"].flatMap { value -> Double? in
							if let cost = value as? [String: Any] {
								return cost["amount"] as? Double
							}
							return value as? Double
						},
						modelContextWindow: payload["size"] as? Int,
						contextUsedTokens: payload["used"] as? Int
					)
				)
			]
		case "session_info_update":
			guard let title = payload["title"] as? String else { return [] }
			return [.stream(AIStreamResult(type: "status", text: title))]
		case "plan":
			let entries = payload["entries"] as? [[String: Any]]
			let text = entries?.compactMap { $0["content"] as? String }.joined(separator: "\n")
			guard let text, !text.isEmpty else { return [] }
			return [.stream(AIStreamResult(type: "plan", text: text))]
		case "user_message_chunk", "available_commands_update":
			return []
		case "tool_call":
			return [
				.stream(
					AIStreamResult(
						type: "tool_call",
						text: nil,
						toolName: payload["title"] as? String,
						toolArgs: prettyJSONString(payload["rawInput"]),
						toolArgsJSON: prettyJSONString(payload["rawInput"])
					)
				)
			]
		case "tool_call_update":
			return ACPDefaultSessionUpdateNormalizer.normalize(payload, providerID: providerID)
		default:
			return []
		}
	}

	func preferredAuthMethodID(context: ACPAuthenticationContext) -> String? {
		switch providerID {
		case .gemini:
			for preferredID in ["use_gemini_api", "use_gemini"] {
				if let match = context.authMethodIDs.first(where: { $0.lowercased() == preferredID }) {
					return match
				}
			}
			return context.authMethodIDs.first
		case .openCode:
			return nil
		case .cursor:
			let hasToken = ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"].contains { key in
				context.environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
			}
			guard !hasToken else { return nil }
			return context.authMethodIDs.first { $0.caseInsensitiveCompare("cursor_login") == .orderedSame }
		}
	}

	func normalizeError(_ error: Error) -> Error {
		guard providerID == .cursor else { return error }
		if error is AIProviderError {
			return error
		}
		let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
		let lower = description.lowercased()
		if lower.contains("session mode") || lower.contains("session/set_mode") {
			return AIProviderError.invalidConfiguration(detail: description)
		}
		return error
	}

	private func prettyJSONString(_ value: Any?) -> String? {
		guard let value else { return nil }
		guard JSONSerialization.isValidJSONObject(value),
			let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]),
			let string = String(data: data, encoding: .utf8)
		else {
			return value as? String
		}
		return string
	}
}

private struct LiveGeminiACPTestProvider: ACPAgentProvider {
	let base: GeminiACPAgentProvider

	var providerID: ACPProviderID { base.providerID }

	func support(for request: ACPRunRequest) async -> ACPSupportResult {
		await base.support(for: request)
	}

	func makeLaunchConfiguration(for request: ACPRunRequest) throws -> ACPLaunchConfiguration {
		try base.makeLaunchConfiguration(for: request)
	}

	func makeSessionConfiguration(
		for request: ACPRunRequest,
		mcpServer _: RepoPromptMCPServerConfiguration
	) throws -> ACPSessionConfiguration {
		let workingDirectory = request.workspacePath?
			.trimmingCharacters(in: .whitespacesAndNewlines)
			.nonEmpty
			?? FileManager.default.temporaryDirectory.path
		let mode: ACPSessionConfiguration.Mode
		if let resume = request.resumeSessionID?.trimmingCharacters(in: .whitespacesAndNewlines), !resume.isEmpty {
			mode = .load(existingSessionID: resume)
		} else {
			mode = .new
		}
		return ACPSessionConfiguration(mode: mode, workingDirectory: workingDirectory, mcpServers: [])
	}

	func buildPromptBlocks(for message: AgentMessage, request: ACPRunRequest) throws -> [[String: Any]] {
		try base.buildPromptBlocks(for: message, request: request)
	}

	func normalizeSessionUpdate(
		_ payload: [String: Any],
		sessionID: String
	) -> [NormalizedAgentRuntimeEvent] {
		base.normalizeSessionUpdate(payload, sessionID: sessionID)
	}

	func normalizeError(_ error: Error) -> Error {
		base.normalizeError(error)
	}
}

private actor EventRecorder {
	private var events: [NormalizedAgentRuntimeEvent] = []
	private var finished = false
	private var task: Task<Void, Never>?
	private let onEvent: (@Sendable (NormalizedAgentRuntimeEvent) -> Void)?

	init(
		stream: AsyncStream<NormalizedAgentRuntimeEvent>,
		onEvent: (@Sendable (NormalizedAgentRuntimeEvent) -> Void)? = nil
	) {
		self.onEvent = onEvent
		task = Task {
			for await event in stream {
				await record(event)
			}
			await markFinished()
		}
	}

	func snapshot() -> [NormalizedAgentRuntimeEvent] {
		events
	}

	func firstApprovalRequest() -> AgentApprovalRequest? {
		for event in events {
			if case .approvalRequested(let request) = event {
				return request
			}
		}
		return nil
	}

	func waitForApprovalRequest(timeout: TimeInterval) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if events.contains(where: { event in
				if case .approvalRequested = event {
					return true
				}
				return false
			}) {
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return events.contains(where: { event in
			if case .approvalRequested = event {
				return true
			}
			return false
		})
	}

	func waitForTerminal(timeout: TimeInterval, expected: AgentSessionRunState) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if events.contains(where: { event in
				if case .terminal(let state, _) = event {
					return state == expected
				}
				return false
			}) {
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return events.contains(where: { event in
			if case .terminal(let state, _) = event {
				return state == expected
			}
			return false
		})
	}

	func waitForFinish(timeout: TimeInterval) async -> Bool {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if finished {
				return true
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		return finished
	}

	func cancel() async {
		task?.cancel()
		_ = await task?.value
		task = nil
	}

	private func record(_ event: NormalizedAgentRuntimeEvent) {
		events.append(event)
		onEvent?(event)
	}

	private func markFinished() {
		finished = true
	}

}

private actor ACPDiagnosticRecorder {
	struct Entry: Sendable {
		let offset: TimeInterval
		let event: ACPAgentSessionController.DiagnosticEvent
	}

	private let startTime = Date()
	private var entries: [Entry] = []

	func record(_ event: ACPAgentSessionController.DiagnosticEvent) {
		let offset = Date().timeIntervalSince(startTime)
		let entry = Entry(offset: offset, event: event)
		entries.append(entry)
		print(String(format: "[ACP-DIAG +%.3fs] %@", offset, describe(event)))
	}

	func waitForPhaseCompletion(_ phase: String, timeout: TimeInterval) async throws {
		let deadline = Date().addingTimeInterval(timeout)
		while Date() < deadline {
			if entries.contains(where: {
				if case .phaseCompleted(let completedPhase) = $0.event {
					return completedPhase == phase
				}
				return false
			}) {
				return
			}
			try? await Task.sleep(nanoseconds: 20_000_000)
		}
		throw NSError(
			domain: "ACPAgentSessionControllerTests",
			code: 1,
			userInfo: [
				NSLocalizedDescriptionKey: "Timed out waiting for phase '\(phase)' to complete.\n\(summaryText())"
			]
		)
	}

	func summary() -> String {
		summaryText()
	}

	private func summaryText() -> String {
		let rendered = entries.map { entry in
			String(format: "[ACP-DIAG +%.3fs] %@", entry.offset, describe(entry.event))
		}
		if rendered.isEmpty {
			return "[ACP-DIAG] no events recorded"
		}
		return rendered.joined(separator: "\n")
	}

	private func describe(_ event: ACPAgentSessionController.DiagnosticEvent) -> String {
		switch event {
		case .phaseStarted(let phase):
			return "phase-start \(phase)"
		case .phaseCompleted(let phase):
			return "phase-complete \(phase)"
		case .outboundJSON(let line):
			return "outbound \(line)"
		case .inboundJSON(let line):
			return "inbound \(line)"
		case .stderrLine(let line):
			return "stderr \(line)"
		case .info(let message):
			return "info \(message)"
		case .invalidJSON(let line):
			return "invalid-json \(line)"
		case .unmatchedResponse(let id, let line):
			return "unmatched-response id=\(id) line=\(line)"
		}
	}
}

private extension String {
	var nonEmpty: String? {
		isEmpty ? nil : self
	}
}
