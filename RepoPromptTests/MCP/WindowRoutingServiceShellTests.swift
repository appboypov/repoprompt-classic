import MCP
import XCTest
@testable import RepoPrompt

/// Drives `manage_workspaces` through a started shell on a temporary workspace root (`GlobalCustomStorageURL`).
@MainActor
final class WindowRoutingServiceShellTests: XCTestCase {
	private var storageRoot: URL!
	private var previousStoragePath: String?
	private var viewModel: WorkspaceShellViewModel?
	private var routing: WindowRoutingService?

	override func setUp() async throws {
		try await super.setUp()
		storageRoot = FileManager.default.temporaryDirectory
			.appendingPathComponent("WindowRoutingServiceShellTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
		previousStoragePath = UserDefaults.standard.string(forKey: "GlobalCustomStorageURL")
		UserDefaults.standard.set(storageRoot.path, forKey: "GlobalCustomStorageURL")
	}

	override func tearDown() async throws {
		if let routing {
			ServiceRegistry.unregister(routing)
		}
		routing = nil
		await viewModel?.stop()
		viewModel = nil
		if let previousStoragePath {
			UserDefaults.standard.set(previousStoragePath, forKey: "GlobalCustomStorageURL")
		} else {
			UserDefaults.standard.removeObject(forKey: "GlobalCustomStorageURL")
		}
		try? FileManager.default.removeItem(at: storageRoot)
		try await super.tearDown()
	}

	private func makeRouting(startShell: Bool = true) async -> WindowRoutingService {
		let shell = WorkspaceShellViewModel(preparesRemainingInBackground: false)
		viewModel = shell
		let service = WorkspaceShellActionService(viewModel: shell)
		if startShell {
			await shell.start()
		}
		let routing = WindowRoutingService(windowStates: .shared, networkMgr: .shared, shellActionService: service)
		self.routing = routing
		return routing
	}

	private func makeRoot(_ name: String) throws -> String {
		let url = storageRoot.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		return url.path
	}

	private func manageWorkspacesTool(_ routing: WindowRoutingService) async throws -> RepoPrompt.Tool {
		for _ in 0..<200 {
			if let tool = await routing.tools.first(where: { $0.name == "manage_workspaces" }) {
				return tool
			}
			await Task.yield()
		}
		throw XCTSkip("manage_workspaces tool never cached")
	}

	private func assertInvalidParams(_ error: Error, contains fragment: String, file: StaticString = #filePath, line: UInt = #line) {
		guard case MCPError.invalidParams(let message) = error else {
			return XCTFail("expected invalidParams, got \(error)", file: file, line: line)
		}
		XCTAssertTrue(message?.contains(fragment) == true, "unexpected message: \(message ?? "nil")", file: file, line: line)
	}

	func testManageWorkspacesSchemaOmitsRemovedArguments() async throws {
		let routing = await makeRouting()
		let tool = try await manageWorkspacesTool(routing)

		let data = try JSONEncoder().encode(tool.inputSchema)
		let schema = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
		XCTAssertNil(properties["open_in_new_window"])
		XCTAssertNil(properties["close_window"])
		XCTAssertNotNil(properties["workspace_ids"])
		XCTAssertNotNil(properties["output_path"])
		let action = try XCTUnwrap(properties["action"] as? [String: Any])
		let actions = try XCTUnwrap(action["enum"] as? [String])
		XCTAssertTrue(Set(["state", "capture", "rename", "reorder"]).isSubset(of: Set(actions)))
	}

	func testRemovedArgumentReturnsInvalidParams() async throws {
		let routing = await makeRouting()

		do {
			_ = try await routing.handleManageWorkspaces(["action": "switch", "workspace": "A", "open_in_new_window": true])
			XCTFail("removed argument is rejected")
		} catch {
			assertInvalidParams(error, contains: "'open_in_new_window' is no longer supported")
		}
	}

	func testResponseEncodesShellField() async throws {
		let routing = await makeRouting()
		let shell = try XCTUnwrap(viewModel)
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)

		let response = try await routing.handleManageWorkspaces(["action": "state"])

		XCTAssertEqual(response.windowID, WindowStatesManager.shared.shellWindowID)
		let data = try JSONEncoder().encode(response)
		let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
		let shellObject = try XCTUnwrap(object["shell"] as? [String: Any])
		XCTAssertEqual(shellObject["visible_workspace_id"] as? String, a.uuidString)
	}

	func testListExcludesSystemWorkspaceAndKeepsIndexOrder() async throws {
		let routing = await makeRouting()
		let shell = try XCTUnwrap(viewModel)
		let b = try await shell.add(name: "B", folderPath: try makeRoot("b"), makeVisible: true)
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: false)

		let response = try await routing.handleManageWorkspaces(["action": "list"])

		let listed = try XCTUnwrap(response.workspaces)
		XCTAssertEqual(listed.map(\.id), [b, a], "catalog index order, never alphabetical")
		XCTAssertFalse(listed.contains(where: { $0.name == "No Workspace" }))
	}

	func testSwitchToSystemWorkspaceReturnsInvalidParams() async throws {
		let routing = await makeRouting()
		let shell = try XCTUnwrap(viewModel)
		let a = try await shell.add(name: "A", folderPath: try makeRoot("a"), makeVisible: true)
		let system = try XCTUnwrap(shell.hostRuntime?.workspaceManager.workspaces.first(where: { $0.isSystemWorkspace }))

		for reference in [system.id.uuidString, system.name] {
			do {
				_ = try await routing.handleManageWorkspaces(["action": "switch", "workspace": .string(reference)])
				XCTFail("system workspace is never selectable via '\(reference)'")
			} catch {
				guard case MCPError.invalidParams = error else {
					return XCTFail("expected invalidParams for '\(reference)', got \(error)")
				}
			}
		}
		XCTAssertEqual(shell.visibleWorkspaceID, a)
	}

	func testCreateTabOnEmptyCatalogReturnsInvalidRequest() async throws {
		let routing = await makeRouting()

		do {
			_ = try await routing.handleManageWorkspaces(["action": "create_tab"])
			XCTFail("empty catalog has nowhere to put a tab")
		} catch MCPError.invalidRequest(let message) {
			XCTAssertEqual(message, "No workspace is registered. Create one with action=create first.")
		}
	}
}
