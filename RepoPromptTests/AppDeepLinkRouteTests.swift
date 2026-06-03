import XCTest
@testable import RepoPrompt

final class AppDeepLinkRouteTests: XCTestCase {
	func testNotificationUserInfoParsesAgentSessionRoute() {
		let workspaceID = UUID()
		let tabID = UUID()
		let sessionID = UUID()
		let userInfo: [AnyHashable: Any] = [
			AppDeepLinkRouteUserInfoKey.routeKind: AppDeepLinkRouteUserInfoValue.agentSessionKind,
			AppDeepLinkRouteUserInfoKey.routeVersion: 1,
			AppDeepLinkRouteUserInfoKey.windowID: 42,
			AppDeepLinkRouteUserInfoKey.workspaceID: workspaceID.uuidString,
			AppDeepLinkRouteUserInfoKey.tabID: tabID.uuidString,
			AppDeepLinkRouteUserInfoKey.sessionID: sessionID.uuidString
		]

		let route = AgentSessionDeepLinkRoute.parse(notificationUserInfo: userInfo)

		XCTAssertEqual(route, AgentSessionDeepLinkRoute(windowID: 42, workspaceID: workspaceID, tabID: tabID, sessionID: sessionID))
	}

	func testNotificationUserInfoRejectsMissingOrInvalidRequiredUUIDs() {
		let tabID = UUID()
		let missingWorkspace: [AnyHashable: Any] = [
			AppDeepLinkRouteUserInfoKey.routeKind: AppDeepLinkRouteUserInfoValue.agentSessionKind,
			AppDeepLinkRouteUserInfoKey.routeVersion: 1,
			AppDeepLinkRouteUserInfoKey.tabID: tabID.uuidString
		]
		XCTAssertNil(AgentSessionDeepLinkRoute.parse(notificationUserInfo: missingWorkspace))

		let invalidTab: [AnyHashable: Any] = [
			AppDeepLinkRouteUserInfoKey.routeKind: AppDeepLinkRouteUserInfoValue.agentSessionKind,
			AppDeepLinkRouteUserInfoKey.routeVersion: 1,
			AppDeepLinkRouteUserInfoKey.workspaceID: UUID().uuidString,
			AppDeepLinkRouteUserInfoKey.tabID: "not-a-uuid"
		]
		XCTAssertNil(AgentSessionDeepLinkRoute.parse(notificationUserInfo: invalidTab))
	}

	func testNotificationUserInfoRejectsUnsupportedVersionAndInvalidOptionalSessionID() {
		let workspaceID = UUID()
		let tabID = UUID()
		let unsupportedVersion: [AnyHashable: Any] = [
			AppDeepLinkRouteUserInfoKey.routeKind: AppDeepLinkRouteUserInfoValue.agentSessionKind,
			AppDeepLinkRouteUserInfoKey.routeVersion: 99,
			AppDeepLinkRouteUserInfoKey.workspaceID: workspaceID.uuidString,
			AppDeepLinkRouteUserInfoKey.tabID: tabID.uuidString
		]
		XCTAssertNil(AgentSessionDeepLinkRoute.parse(notificationUserInfo: unsupportedVersion))

		let invalidSessionID: [AnyHashable: Any] = [
			AppDeepLinkRouteUserInfoKey.routeKind: AppDeepLinkRouteUserInfoValue.agentSessionKind,
			AppDeepLinkRouteUserInfoKey.routeVersion: 1,
			AppDeepLinkRouteUserInfoKey.workspaceID: workspaceID.uuidString,
			AppDeepLinkRouteUserInfoKey.tabID: tabID.uuidString,
			AppDeepLinkRouteUserInfoKey.sessionID: "not-a-uuid"
		]
		XCTAssertNil(AgentSessionDeepLinkRoute.parse(notificationUserInfo: invalidSessionID))
	}

	func testNotificationUserInfoTreatsInvalidOptionalWindowIDAsAbsent() {
		let workspaceID = UUID()
		let tabID = UUID()
		let userInfo: [AnyHashable: Any] = [
			AppDeepLinkRouteUserInfoKey.routeKind: AppDeepLinkRouteUserInfoValue.agentSessionKind,
			AppDeepLinkRouteUserInfoKey.routeVersion: 1,
			AppDeepLinkRouteUserInfoKey.windowID: "not-an-int",
			AppDeepLinkRouteUserInfoKey.workspaceID: workspaceID.uuidString,
			AppDeepLinkRouteUserInfoKey.tabID: tabID.uuidString
		]

		let route = AgentSessionDeepLinkRoute.parse(notificationUserInfo: userInfo)

		XCTAssertEqual(route, AgentSessionDeepLinkRoute(workspaceID: workspaceID, tabID: tabID))
	}

	func testURLParserAcceptsCanonicalAgentSessionRoute() throws {
		let workspaceID = UUID()
		let tabID = UUID()
		let sessionID = UUID()
		let url = try XCTUnwrap(URL(string: "repoprompt://agent/session?workspace_id=\(workspaceID.uuidString)&tab_id=\(tabID.uuidString)&session_id=\(sessionID.uuidString)&window_id=7"))

		let parseResult = AppDeepLinkRoute.parse(url: url)

		XCTAssertEqual(parseResult, .route(.agentSession(AgentSessionDeepLinkRoute(windowID: 7, workspaceID: workspaceID, tabID: tabID, sessionID: sessionID))))
	}

	func testAgentSessionURLBuilderRoundTripsThroughParser() {
		let route = AgentSessionDeepLinkRoute(windowID: 3, workspaceID: UUID(), tabID: UUID(), sessionID: UUID())

		XCTAssertEqual(AppDeepLinkRoute.parse(url: route.url), .route(.agentSession(route)))
	}

	func testURLParserPreservesPromptAndOpenURLsAsLegacyRoutes() throws {
		let promptURL = try XCTUnwrap(URL(string: "repoprompt://prompt?title=Hello&content=World"))
		let openURL = try XCTUnwrap(URL(string: "repoprompt://open/~/Documents/Project?workspace=Demo"))

		XCTAssertEqual(AppDeepLinkRoute.parse(url: promptURL), .route(.legacyURL(promptURL)))
		XCTAssertEqual(AppDeepLinkRoute.parse(url: openURL), .route(.legacyURL(openURL)))
	}

	func testInvalidAgentSessionURLDoesNotBecomeLegacyRoute() throws {
		let missingWorkspace = try XCTUnwrap(URL(string: "repoprompt://agent/session?tab_id=\(UUID().uuidString)"))
		let malformedSession = try XCTUnwrap(URL(string: "repoprompt://agent/session?workspace_id=\(UUID().uuidString)&tab_id=\(UUID().uuidString)&session_id=not-a-uuid"))
		let unsupportedAgentPath = try XCTUnwrap(URL(string: "repoprompt://agent/other?workspace_id=\(UUID().uuidString)&tab_id=\(UUID().uuidString)"))

		XCTAssertEqual(AppDeepLinkRoute.parse(url: missingWorkspace), .invalidScopedRoute)
		XCTAssertEqual(AppDeepLinkRoute.parse(url: malformedSession), .invalidScopedRoute)
		XCTAssertEqual(AppDeepLinkRoute.parse(url: unsupportedAgentPath), .invalidScopedRoute)
	}

	func testLegacyWindowPreferenceMatchesPreviousPromptAndOpenRouting() throws {
		let promptURL = try XCTUnwrap(URL(string: "repoprompt://prompt?title=Hello"))
		let openURL = try XCTUnwrap(URL(string: "repoprompt://open/~/Documents/Project"))
		let otherLegacyURL = try XCTUnwrap(URL(string: "repoprompt://workspace/switch?name=RepoPrompt"))

		XCTAssertEqual(AppDeepLinkRouter.legacyWindowPreference(for: promptURL), .earliest)
		XCTAssertEqual(AppDeepLinkRouter.legacyWindowPreference(for: openURL), .latest)
		XCTAssertEqual(AppDeepLinkRouter.legacyWindowPreference(for: otherLegacyURL), .latest)
	}
}
