#if DEBUG
import XCTest
@testable import RepoPrompt

final class AgentChatStressLaunchConfigurationTests: XCTestCase {
	func testLegacyStressScenarioDoesNotEnableSessionPersistenceByDefault() {
		let configuration = AgentChatStressLaunchConfiguration(environment: [
			"RP_AGENT_STRESS_SCENARIO": "assistantMarkdownChurn"
		])

		XCTAssertEqual(configuration.scenario, .assistantMarkdownChurn)
		XCTAssertFalse(configuration.allowsAgentSessionPersistence)
	}

	func testPersistedReplayScenarioEnablesSessionPersistenceByDefault() {
		let configuration = AgentChatStressLaunchConfiguration(environment: [
			"RP_AGENT_STRESS_SCENARIO": "persistedCodexReplayChurn"
		])

		XCTAssertEqual(configuration.scenario, .persistedCodexReplayChurn)
		XCTAssertTrue(configuration.allowsAgentSessionPersistence)
	}

	func testPersistedReplayScenarioCanDisableSessionPersistenceExplicitly() {
		let configuration = AgentChatStressLaunchConfiguration(environment: [
			"RP_AGENT_STRESS_SCENARIO": "persistedCodexReplayChurn",
			"RP_AGENT_STRESS_ALLOW_SESSION_PERSISTENCE": "0"
		])

		XCTAssertEqual(configuration.scenario, .persistedCodexReplayChurn)
		XCTAssertFalse(configuration.allowsAgentSessionPersistence)
	}

	func testLegacyStressScenarioCanEnableSessionPersistenceExplicitly() {
		let configuration = AgentChatStressLaunchConfiguration(environment: [
			"RP_AGENT_STRESS_SCENARIO": "richToolChurn",
			"RP_AGENT_STRESS_ALLOW_SESSION_PERSISTENCE": "1"
		])

		XCTAssertEqual(configuration.scenario, .richToolChurn)
		XCTAssertTrue(configuration.allowsAgentSessionPersistence)
	}

	func testPersistedAgentSessionFixtureScenarioEnablesSessionPersistenceAndDefaultsFixtureName() {
		let configuration = AgentChatStressLaunchConfiguration(environment: [
			"RP_AGENT_STRESS_SCENARIO": "persistedAgentSessionFixture"
		])

		XCTAssertEqual(configuration.scenario, .persistedAgentSessionFixture)
		XCTAssertTrue(configuration.allowsAgentSessionPersistence)
		XCTAssertEqual(configuration.agentSessionFixtureName, "review-idle-scroll-coalescing-fix-97A6BA23.json")
	}

	func testPersistedAgentSessionFixtureScenarioAllowsFixtureOverride() {
		let configuration = AgentChatStressLaunchConfiguration(environment: [
			"RP_AGENT_STRESS_SCENARIO": "persistedAgentSessionFixture",
			"RP_AGENT_STRESS_AGENT_SESSION_FIXTURE": "custom-fixture.json"
		])

		XCTAssertEqual(configuration.scenario, .persistedAgentSessionFixture)
		XCTAssertEqual(configuration.agentSessionFixtureName, "custom-fixture.json")
	}

	func testLoadPersistedStressSessionFixtureDecodesSavedAgentSessionFixture() throws {
		let repoRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.path

		let session = try AgentModeViewModel.loadPersistedStressSessionFixture(
			named: "review-idle-scroll-coalescing-fix-97A6BA23.json",
			workspaceRootPaths: [repoRoot]
		)

		XCTAssertEqual(session.name, "Review: Idle scroll coalescing fix")
		XCTAssertEqual(session.agentKind, "claudeCode")
		XCTAssertEqual(session.agentModel, "opus")
		XCTAssertGreaterThan(session.items.count, 0)
		XCTAssertNotNil(session.transcript)
		XCTAssertNil(session.fileURL)
		XCTAssertNil(session.workspaceID)
		XCTAssertNil(session.composeTabID)
	}

	func testLoadPersistedStressSessionFixtureSearchesAllWorkspaceRoots() throws {
		let repoRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.path
		let missingRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
			.appendingPathComponent(UUID().uuidString, isDirectory: true)
			.path

		let fixtureURL = try XCTUnwrap(
			AgentModeViewModel.persistedStressSessionFixtureURL(
				named: "review-idle-scroll-coalescing-fix-97A6BA23.json",
				workspaceRootPaths: [missingRoot, repoRoot]
			)
		)

		XCTAssertTrue(FileManager.default.fileExists(atPath: fixtureURL.path))
		XCTAssertTrue(fixtureURL.path.contains("RepoPromptTests/Fixtures/AgentSessions/review-idle-scroll-coalescing-fix-97A6BA23.json"))
	}

	func testLoadPersistedStressSessionFixtureCreatesFreshSessionIdentity() throws {
		let repoRoot = URL(fileURLWithPath: #filePath, isDirectory: false)
			.deletingLastPathComponent()
			.deletingLastPathComponent()
			.path
		let fixtureURL = try XCTUnwrap(
			AgentModeViewModel.persistedStressSessionFixtureURL(
				named: "review-idle-scroll-coalescing-fix-97A6BA23.json",
				workspaceRootPaths: [repoRoot]
			)
		)
		let persistedData = try Data(contentsOf: fixtureURL)
		let persistedSession = try JSONDecoder().decode(AgentSession.self, from: persistedData)

		let stagedSession = try AgentModeViewModel.loadPersistedStressSessionFixture(
			named: "review-idle-scroll-coalescing-fix-97A6BA23.json",
			workspaceRootPaths: [repoRoot]
		)

		XCTAssertNotEqual(stagedSession.id, persistedSession.id)
	}
}
#endif
