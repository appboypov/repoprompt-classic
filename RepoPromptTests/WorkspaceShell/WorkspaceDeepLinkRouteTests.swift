import XCTest
@testable import RepoPrompt

final class WorkspaceDeepLinkRouteTests: XCTestCase {
	func testParsesWorkspaceHostByIDAndName() throws {
		let id = UUID()

		XCTAssertEqual(
			AppDeepLinkRoute.parse(url: URL(string: "repoprompt://workspace?id=\(id.uuidString)")!),
			.route(.workspace(WorkspaceDeepLinkRoute(id: id, name: nil)))
		)
		XCTAssertEqual(
			AppDeepLinkRoute.parse(url: URL(string: "repoprompt://workspace?name=Float%20Note")!),
			.route(.workspace(WorkspaceDeepLinkRoute(id: nil, name: "Float Note")))
		)
	}

	func testMissingParametersIsInvalidScopedRoute() {
		XCTAssertEqual(AppDeepLinkRoute.parse(url: URL(string: "repoprompt://workspace")!), .invalidScopedRoute)
		XCTAssertEqual(AppDeepLinkRoute.parse(url: URL(string: "repoprompt://workspace?id=nope")!), .invalidScopedRoute)
		XCTAssertEqual(AppDeepLinkRoute.parse(url: URL(string: "repoprompt://workspace?name=%20")!), .invalidScopedRoute)
	}
}
