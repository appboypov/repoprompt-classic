import XCTest
@testable import RepoPrompt

@MainActor
final class NotificationServiceDeepLinkTests: XCTestCase {
	func testAgentTurnCompleteContentIncludesAgentSessionRouteUserInfo() {
		let route = AgentSessionDeepLinkRoute(
			windowID: 17,
			workspaceID: UUID(),
			tabID: UUID(),
			sessionID: UUID()
		)

		let content = NotificationService.agentTurnCompleteContent(
			sessionName: "Routed Session",
			previewText: "Done",
			route: route
		)

		XCTAssertEqual(content.title, "Routed Session")
		XCTAssertEqual(content.body, "Done")
		XCTAssertEqual(AgentSessionDeepLinkRoute.parse(notificationUserInfo: content.userInfo), route)
	}

	func testAgentWaitingForUserContentIncludesAgentSessionRouteUserInfo() {
		let route = AgentSessionDeepLinkRoute(
			windowID: 23,
			workspaceID: UUID(),
			tabID: UUID(),
			sessionID: UUID()
		)

		let content = NotificationService.agentWaitingForUserContent(
			sessionName: "Needs Input",
			promptText: "Please confirm",
			route: route
		)

		XCTAssertEqual(content.title, "Needs Input")
		XCTAssertEqual(content.body, "Please confirm")
		XCTAssertEqual(AgentSessionDeepLinkRoute.parse(notificationUserInfo: content.userInfo), route)
	}

	func testAgentNotificationContentWithoutRouteKeepsFallbackClickBehavior() {
		let turnContent = NotificationService.agentTurnCompleteContent(
			sessionName: nil,
			previewText: nil,
			route: nil
		)
		let waitingContent = NotificationService.agentWaitingForUserContent(
			sessionName: nil,
			promptText: nil,
			route: nil
		)

		XCTAssertNil(AgentSessionDeepLinkRoute.parse(notificationUserInfo: turnContent.userInfo))
		XCTAssertNil(AgentSessionDeepLinkRoute.parse(notificationUserInfo: waitingContent.userInfo))
		XCTAssertEqual(turnContent.title, "Agent Session")
		XCTAssertEqual(turnContent.body, "Your agent message is ready")
		XCTAssertEqual(waitingContent.title, "Agent Session")
		XCTAssertEqual(waitingContent.body, "Your agent needs input")
	}
}
