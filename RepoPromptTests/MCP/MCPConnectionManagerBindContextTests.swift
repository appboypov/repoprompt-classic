import XCTest
import MCP
@testable import RepoPrompt

final class MCPConnectionManagerBindContextTests: XCTestCase {
	private func makeBindingResolver(
		matchesByContextID: [UUID: [MCPContextBindingMatch]],
		existingWindowID: Int? = nil,
		clientName: String? = nil,
		reusableWindowID: Int? = nil,
		liveRunWindowID: Int? = nil,
		preferredWindowID: Int? = nil
	) -> MCPBindingResolver {
		MCPBindingResolver(
			collectMatchesForContextID: { contextID in
				matchesByContextID[contextID] ?? []
			},
			collectMatchesForWorkingDirs: { _ in [] },
			existingWindowIDForConnection: { _ in existingWindowID },
			clientIdentifier: { _ in clientName },
			reusableWindowForClient: { _, _ in reusableWindowID },
			sessionKeyForConnection: { _ in nil },
			preferredLiveRunWindowID: { _, _ in liveRunWindowID },
			preferredWindowID: { _, _ in preferredWindowID }
		)
	}

	func testShouldAdvertiseCanonicalBindingParamsOnlyForBindContext() {
		XCTAssertTrue(ServerNetworkManager.shouldAdvertiseCanonicalBindingParams(for: "bind_context"))
		XCTAssertFalse(ServerNetworkManager.shouldAdvertiseCanonicalBindingParams(for: "manage_workspaces"))
		XCTAssertFalse(ServerNetworkManager.shouldAdvertiseCanonicalBindingParams(for: "read_file"))
	}

	func testShouldBypassLogicalContextPreResolutionOnlyForBindContext() {
		XCTAssertTrue(ServerNetworkManager.shouldBypassLogicalContextPreResolution(for: "bind_context"))
		XCTAssertFalse(ServerNetworkManager.shouldBypassLogicalContextPreResolution(for: "manage_workspaces"))
		XCTAssertFalse(ServerNetworkManager.shouldBypassLogicalContextPreResolution(for: "read_file"))
	}

	func testShouldSkipGenericTabBindingForBindContextAndManageWorkspaces() {
		XCTAssertTrue(ServerNetworkManager.shouldSkipGenericTabBinding(for: "bind_context"))
		XCTAssertTrue(ServerNetworkManager.shouldSkipGenericTabBinding(for: "manage_workspaces"))
		XCTAssertFalse(ServerNetworkManager.shouldSkipGenericTabBinding(for: "read_file"))
	}

	func testIsWindowSelectionExemptForBindContext() {
		XCTAssertTrue(ServerNetworkManager.isWindowSelectionExempt(toolName: "bind_context", args: [:]))
	}

	func testIsWindowSelectionExemptForManageWorkspacesListAndOpenInNewWindow() {
		XCTAssertTrue(ServerNetworkManager.isWindowSelectionExempt(
			toolName: "manage_workspaces",
			args: ["action": .string("list")]
		))
		XCTAssertTrue(ServerNetworkManager.isWindowSelectionExempt(
			toolName: "manage_workspaces",
			args: [
				"action": .string("switch"),
				"open_in_new_window": .bool(true)
			]
		))
		XCTAssertFalse(ServerNetworkManager.isWindowSelectionExempt(
			toolName: "manage_workspaces",
			args: ["action": .string("create_tab")]
		))
	}

	func testAugmentSchemaRetainsBindingParamsOnlyForBindContext() {
		let schema: Value = .object([
			"type": .string("object"),
			"properties": .object([
				"context_id": .object(["type": .string("string")]),
				"working_dirs": .object(["type": .string("string")]),
				"other": .object(["type": .string("string")])
			]),
			"required": .array([.string("context_id"), .string("other")])
		])

		let bindSchema = ServerNetworkManager.augmentSchemaWithCanonicalBindingParams(
			schema,
			toolName: "bind_context",
			purpose: .unknown
		)
		let otherSchema = ServerNetworkManager.augmentSchemaWithCanonicalBindingParams(
			schema,
			toolName: "manage_workspaces",
			purpose: .unknown
		)

		let bindProps = bindSchema.objectValue?["properties"]?.objectValue
		let otherProps = otherSchema.objectValue?["properties"]?.objectValue
		XCTAssertNotNil(bindProps?["context_id"])
		XCTAssertNotNil(bindProps?["working_dirs"])
		XCTAssertNil(otherProps?["context_id"])
		XCTAssertNil(otherProps?["working_dirs"])

		let bindRequired = bindSchema.objectValue?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
		let otherRequired = otherSchema.objectValue?["required"]?.arrayValue?.compactMap { $0.stringValue } ?? []
		XCTAssertTrue(bindRequired.contains("context_id"))
		XCTAssertFalse(otherRequired.contains("context_id"))
	}

	func testMultiWindowSelectionGuidanceMentionsBindContextForExternalClients() {
		let guidance = ServerNetworkManager.multiWindowSelectionGuidance()
		XCTAssertTrue(guidance.contains("bind_context"))
		XCTAssertTrue(guidance.contains("context_id"))
		XCTAssertFalse(guidance.contains("select_window"))
		XCTAssertFalse(guidance.contains("list_windows"))
	}

	func testAgentModeRoutingGuidanceDoesNotRecommendHiddenRecovery() {
		let guidance = ServerNetworkManager.multiWindowSelectionGuidance(
			purpose: .agentModeRun,
			restrictedTools: AgentModeMCPToolPolicy.restrictedTools
		)
		XCTAssertTrue(guidance.contains("Automatic Agent Mode routing failed"))
		XCTAssertFalse(guidance.contains("bind_context"))
		XCTAssertFalse(guidance.contains("_windowID"))
	}

	func testRestrictedRoutingGuidanceDoesNotRecommendHiddenRecovery() {
		let guidance = ServerNetworkManager.invalidWindowSelectionGuidance(
			windowID: 99,
			purpose: .unknown,
			restrictedTools: ["bind_context"]
		)
		XCTAssertTrue(guidance.contains("restricted MCP connection"))
		XCTAssertFalse(guidance.contains("bind_context"))
		XCTAssertFalse(guidance.contains("_windowID"))
	}

	func testLogicalContextResolverCollapsesDuplicateWorkspaceRecordsWithSameRootSet() async throws {
		let contextID = UUID()
		let firstWorkspaceID = UUID()
		let duplicateWorkspaceID = UUID()
		let resolver = makeBindingResolver(matchesByContextID: [
			contextID: [
				MCPContextBindingMatch(
					windowID: 5,
					tabID: contextID,
					workspaceID: duplicateWorkspaceID,
					workspaceName: "RepoPrompt Copy",
					repoPaths: ["/tmp/repo", "/tmp/other"]
				),
				MCPContextBindingMatch(
					windowID: 2,
					tabID: contextID,
					workspaceID: firstWorkspaceID,
					workspaceName: "RepoPrompt",
					repoPaths: ["/tmp/other", "/tmp/repo"]
				)
			]
		])

		let resolution = try await resolver.resolveLogicalContextBinding(
			connectionID: UUID(),
			explicitContextID: contextID,
			legacyTabID: nil,
			workingDirs: [],
			requestedWindowID: 5
		)

		XCTAssertEqual(resolution?.windowID, 5)
		XCTAssertEqual(resolution?.logicalContext.tabID, contextID)
		XCTAssertEqual(resolution?.logicalContext.windowIDs, [2, 5])
		XCTAssertEqual(resolution?.logicalContext.workspaceID, firstWorkspaceID)
	}

	func testLogicalContextResolverKeepsDifferentRootSetsAmbiguous() async throws {
		let contextID = UUID()
		let resolver = makeBindingResolver(matchesByContextID: [
			contextID: [
				MCPContextBindingMatch(
					windowID: 1,
					tabID: contextID,
					workspaceID: UUID(),
					workspaceName: "Repo A",
					repoPaths: ["/tmp/repo-a"]
				),
				MCPContextBindingMatch(
					windowID: 2,
					tabID: contextID,
					workspaceID: UUID(),
					workspaceName: "Repo B",
					repoPaths: ["/tmp/repo-b"]
				)
			]
		])

		do {
			_ = try await resolver.resolveLogicalContextBinding(
				connectionID: UUID(),
				explicitContextID: contextID,
				legacyTabID: nil,
				workingDirs: [],
				requestedWindowID: nil
			)
			XCTFail("Expected different root sets to remain ambiguous")
		} catch {
			XCTAssertTrue(error.localizedDescription.contains("Ambiguous binding"))
			XCTAssertTrue(error.localizedDescription.contains("roots=[/tmp/repo-a]"))
			XCTAssertTrue(error.localizedDescription.contains("roots=[/tmp/repo-b]"))
		}
	}

	func testLogicalContextResolverDoesNotCollapseEmptyRootWorkspaces() async throws {
		let contextID = UUID()
		let resolver = makeBindingResolver(matchesByContextID: [
			contextID: [
				MCPContextBindingMatch(
					windowID: 1,
					tabID: contextID,
					workspaceID: UUID(),
					workspaceName: "Empty One",
					repoPaths: []
				),
				MCPContextBindingMatch(
					windowID: 2,
					tabID: contextID,
					workspaceID: UUID(),
					workspaceName: "Empty Two",
					repoPaths: []
				)
			]
		])

		do {
			_ = try await resolver.resolveLogicalContextBinding(
				connectionID: UUID(),
				explicitContextID: contextID,
				legacyTabID: nil,
				workingDirs: [],
				requestedWindowID: nil
			)
			XCTFail("Expected empty root workspaces to remain distinct")
		} catch {
			XCTAssertTrue(error.localizedDescription.contains("Ambiguous binding"))
		}
	}
}
