import XCTest
@testable import RepoPrompt

final class WorkspaceApprovalManagerTests: XCTestCase {
	@MainActor
	func testCancelPendingForWindowIDDeniesMatchingRequestsAndPreservesOthers() async {
		resetManager()
		defer { resetManager() }
		let manager = WorkspaceApprovalManager.shared
		let first = makeRequest(clientID: "test-close-current", windowID: 101)
		let second = makeRequest(clientID: "test-close-other", windowID: 202)
		let third = makeRequest(clientID: "test-close-queued", windowID: 101)

		let firstTask = Task { @MainActor in
			await manager.requestApproval(for: first)
		}
		await waitForPendingRequest(id: first.id)

		let secondTask = Task { @MainActor in
			await manager.requestApproval(for: second)
		}
		await Task.yield()

		let thirdTask = Task { @MainActor in
			await manager.requestApproval(for: third)
		}
		await Task.yield()
		await Task.yield()

		manager.cancelPending(forWindowID: 101)
		XCTAssertEqual(manager.pendingRequest?.id, second.id)

		let firstResult = await firstTask.value
		let thirdResult = await thirdTask.value
		assertDenied(firstResult)
		assertDenied(thirdResult)

		manager.resolveApproval(allow: true)
		let secondResult = await secondTask.value
		assertApproved(secondResult)
	}

	@MainActor
	func testAlwaysAllowMatchesEquivalentClaudeClientVariants() async {
		resetManager()
		defer { resetManager() }
		let manager = WorkspaceApprovalManager.shared

		manager.addAutoApproval(clientID: "claude-code", operation: .deleteWorkspace)

		let result = await manager.requestApproval(
			for: makeRequest(clientID: "Claude Code 1.2.3", windowID: 12)
		)

		assertApproved(result)
	}

	@MainActor
	func testAddingEquivalentClientVariantReusesExistingPolicyBucket() {
		resetManager()
		defer { resetManager() }
		let manager = WorkspaceApprovalManager.shared

		manager.addAutoApproval(clientID: "Claude Code", operation: .addFolder)
		manager.addAutoApproval(clientID: "claude-code", operation: .removeFolder)

		XCTAssertEqual(manager.trustedClients.count, 1)
		let policy = try? XCTUnwrap(manager.trustedClients.first)
		XCTAssertTrue(policy?.allowedOperations.contains(.addFolder) == true)
		XCTAssertTrue(policy?.allowedOperations.contains(.removeFolder) == true)
	}

	@MainActor
	private func resetManager() {
		let manager = WorkspaceApprovalManager.shared
		manager.cancelAllPending()
		manager.setAutoApproveAll(false)
		for operation in WorkspaceApprovalOperation.allCases {
			manager.setAutoApproveOperation(operation, enabled: false)
		}
		for client in manager.trustedClients {
			manager.removeAllAutoApprovals(for: client.clientID)
		}
	}

	private func makeRequest(clientID: String, windowID: Int?) -> WorkspaceApprovalRequest {
		WorkspaceApprovalRequest(
			clientID: clientID,
			operation: .deleteWorkspace,
			workspaceName: "RepoPrompt",
			workspaceID: UUID(),
			windowID: windowID
		)
	}

	@MainActor
	private func waitForPendingRequest(id: UUID, timeoutIterations: Int = 40) async {
		for _ in 0..<timeoutIterations {
			if WorkspaceApprovalManager.shared.pendingRequest?.id == id {
				return
			}
			await Task.yield()
		}
		XCTFail("Timed out waiting for pending request \(id)")
	}

	private func assertDenied(_ result: WorkspaceApprovalResult, file: StaticString = #filePath, line: UInt = #line) {
		guard case .denied = result else {
			return XCTFail("Expected denied result, got \(String(describing: result))", file: file, line: line)
		}
	}

	private func assertApproved(_ result: WorkspaceApprovalResult, file: StaticString = #filePath, line: UInt = #line) {
		guard case .approved = result else {
			return XCTFail("Expected approved result, got \(String(describing: result))", file: file, line: line)
		}
	}
}
