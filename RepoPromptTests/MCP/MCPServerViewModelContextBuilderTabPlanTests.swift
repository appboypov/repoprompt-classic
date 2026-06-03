import Foundation
import XCTest
@testable import RepoPrompt

@MainActor
final class MCPServerViewModelContextBuilderTabPlanTests: XCTestCase {
	func testAgentModeRunAlwaysUsesAgentTabReusePlan() {
		let explicitTabID = UUID()
		let explicitPlan = MCPServerViewModel.planContextBuilderTab(
			purpose: .agentModeRun,
			explicitTabID: explicitTabID
		)
		let fallbackPlan = MCPServerViewModel.planContextBuilderTab(
			purpose: .agentModeRun,
			explicitTabID: nil
		)

		XCTAssertEqual(explicitPlan, .agentModeReuse)
		XCTAssertEqual(fallbackPlan, .agentModeReuse)
	}

	func testDiscoverRunWithoutExplicitTabCreatesFreshTabPlan() {
		let plan = MCPServerViewModel.planContextBuilderTab(
			purpose: .discoverRun,
			explicitTabID: nil
		)

		XCTAssertEqual(plan, .freshTab)
	}

	func testDiscoverRunWithExplicitTabReusesExplicitTabPlan() {
		let explicitTabID = UUID()
		let plan = MCPServerViewModel.planContextBuilderTab(
			purpose: .discoverRun,
			explicitTabID: explicitTabID
		)

		XCTAssertEqual(plan, .explicitTab(explicitTabID))
	}

	func testUnknownRunWithoutExplicitTabCreatesFreshTabPlan() {
		let plan = MCPServerViewModel.planContextBuilderTab(
			purpose: .unknown,
			explicitTabID: nil
		)

		XCTAssertEqual(plan, .freshTab)
	}

	func testDelegateEditRunWithExplicitTabUsesExplicitTabPlan() {
		let explicitTabID = UUID()
		let plan = MCPServerViewModel.planContextBuilderTab(
			purpose: .delegateEditRun,
			explicitTabID: explicitTabID
		)

		XCTAssertEqual(plan, .explicitTab(explicitTabID))
	}

	func testGeneratedOracleExportPathAnchorsUnderPrimaryRootWhenSecondaryHasPromptExports() throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }

		let primaryRoot = tempRoot.appendingPathComponent("xcodetester", isDirectory: true)
		let secondaryRoot = tempRoot.appendingPathComponent("RepoPrompt", isDirectory: true)
		try FileManager.default.createDirectory(at: primaryRoot, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(
			at: secondaryRoot.appendingPathComponent("prompt-exports", isDirectory: true),
			withIntermediateDirectories: true
		)

		let tabID = UUID()
		let workspace = WorkspaceModel(
			name: "Multi-root",
			repoPaths: [primaryRoot.path, secondaryRoot.path]
		)

		let destination = try MCPServerViewModel.makeOracleExportDestination(
			workspace: workspace,
			windowID: 42,
			tabID: tabID
		)
		let resolvedPath = try MCPServerViewModel.resolveGeneratedOracleExportPath(
			relativePath: "prompt-exports/oracle-plan.md",
			destination: destination
		)

		XCTAssertEqual(destination.workspaceID, workspace.id)
		XCTAssertEqual(destination.windowID, 42)
		XCTAssertEqual(destination.tabID, tabID)
		XCTAssertTrue(resolvedPath.hasPrefix("/"))
		XCTAssertEqual(resolvedPath, primaryRoot.appendingPathComponent("prompt-exports/oracle-plan.md").path)
		XCTAssertFalse(resolvedPath.hasPrefix(secondaryRoot.path))
	}

	func testGeneratedOracleExportDestinationFailsWhenPrimaryRootMissing() throws {
		let workspace = WorkspaceModel(name: "No roots", repoPaths: [])

		XCTAssertThrowsError(
			try MCPServerViewModel.makeOracleExportDestination(
				workspace: workspace,
				windowID: 1,
				tabID: nil
			)
		) { error in
			XCTAssertTrue(String(describing: error).contains("workspace.repoPaths.first"))
		}
	}

	func testGeneratedOracleExportDestinationFailsWhenPrimaryRootUnavailable() throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let missingRoot = tempRoot.appendingPathComponent("missing-primary", isDirectory: true)
		let workspace = WorkspaceModel(name: "Missing root", repoPaths: [missingRoot.path])

		XCTAssertThrowsError(
			try MCPServerViewModel.makeOracleExportDestination(
				workspace: workspace,
				windowID: 1,
				tabID: nil
			)
		) { error in
			XCTAssertTrue(String(describing: error).contains("primary root is unavailable"))
		}
	}

	func testGeneratedOracleExportWriteReturnsImmediatelyReadablePath() async throws {
		let (fileManagerVM, rootURL, workspace) = try await makeLoadedWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let destination = try MCPServerViewModel.makeOracleExportDestination(
			workspace: workspace,
			windowID: 1,
			tabID: UUID()
		)
		let exportURL = rootURL.appendingPathComponent("prompt-exports/oracle-plan-readable.md")

		let resolvedPath = try await MCPServerViewModel.writeGeneratedOracleExportFileForReadFileHandoff(
			fileManager: fileManagerVM,
			path: exportURL.path,
			content: "# Oracle Plan\n\nReadable through MCP.",
			destination: destination,
			sourceTool: "context_builder"
		)

		XCTAssertEqual(resolvedPath, (exportURL.path as NSString).standardizingPath)
		guard case .workspace(let readableFile)? = await fileManagerVM.resolveReadableFileForUserInput(
			resolvedPath,
			rootScopeOverride: .visibleWorkspace
		) else {
			return XCTFail("Expected generated export to be immediately readable through MCP read_file resolution")
		}
		XCTAssertEqual(readableFile.standardizedFullPath, resolvedPath)
		let content = try await fileManagerVM.readWorkspaceFileContentStrictly(readableFile)
		XCTAssertTrue(content.contains("Readable through MCP."))
	}

	func testGeneratedOracleExportFailsWhenPrimaryRootExistsButIsNotLoaded() async throws {
		let tempRoot = makeTempDirectory()
		defer { try? FileManager.default.removeItem(at: tempRoot) }
		let primaryRoot = tempRoot.appendingPathComponent("Primary", isDirectory: true)
		let loadedRoot = tempRoot.appendingPathComponent("Loaded", isDirectory: true)
		try FileManager.default.createDirectory(at: primaryRoot, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: loadedRoot, withIntermediateDirectories: true)

		let loadedWorkspace = WorkspaceModel(name: "Loaded", repoPaths: [loadedRoot.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: loadedRoot, for: loadedWorkspace, freshStart: true)

		let exportWorkspace = WorkspaceModel(name: "Primary", repoPaths: [primaryRoot.path])
		let destination = try MCPServerViewModel.makeOracleExportDestination(
			workspace: exportWorkspace,
			windowID: 1,
			tabID: nil
		)
		let exportURL = primaryRoot.appendingPathComponent("prompt-exports/oracle-plan-unloaded.md")

		do {
			_ = try await MCPServerViewModel.writeGeneratedOracleExportFileForReadFileHandoff(
				fileManager: fileManagerVM,
				path: exportURL.path,
				content: "# Oracle Plan",
				destination: destination,
				sourceTool: "context_builder"
			)
			XCTFail("Expected generated export to fail when the captured primary root is not loaded")
		} catch {
			let message = String(describing: error)
			XCTAssertTrue(message.contains("not currently loaded/visible"), message)
			XCTAssertTrue(message.contains("read_file"), message)
		}
		XCTAssertFalse(FileManager.default.fileExists(atPath: exportURL.path))
	}

	func testGeneratedOracleExportFailsWhenTargetIsIgnoredAndUnreadable() async throws {
		let (fileManagerVM, rootURL, workspace) = try await makeLoadedWorkspaceRoot(gitignore: "prompt-exports/\n")
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let destination = try MCPServerViewModel.makeOracleExportDestination(
			workspace: workspace,
			windowID: 1,
			tabID: nil
		)
		let exportURL = rootURL.appendingPathComponent("prompt-exports/oracle-plan-ignored.md")

		do {
			_ = try await MCPServerViewModel.writeGeneratedOracleExportFileForReadFileHandoff(
				fileManager: fileManagerVM,
				path: exportURL.path,
				content: "# Oracle Plan\n\nIgnored by policy.",
				destination: destination,
				sourceTool: "context_builder"
			)
			XCTFail("Expected generated export to fail when the target is ignored")
		} catch {
			let message = String(describing: error)
			XCTAssertTrue(message.contains("ignored"), message)
			XCTAssertTrue(message.contains("Not returning oracle_export_path"), message)
		}

		XCTAssertTrue(FileManager.default.fileExists(atPath: exportURL.path))
		let readable = await fileManagerVM.resolveReadableFileForUserInput(exportURL.path, rootScopeOverride: .visibleWorkspace)
		XCTAssertNil(readable)
	}

	func testGeneratedOracleExportExactPathRemainsReadableAndInstructionSaysVerbatim() async throws {
		let (fileManagerVM, rootURL, workspace) = try await makeLoadedWorkspaceRoot()
		defer { try? FileManager.default.removeItem(at: rootURL) }
		let destination = try MCPServerViewModel.makeOracleExportDestination(
			workspace: workspace,
			windowID: 1,
			tabID: nil
		)
		let exportURL = rootURL.appendingPathComponent("prompt-exports/oracle Exact Path.md")
		let exactPath = (exportURL.path as NSString).standardizingPath

		let resolvedPath = try await MCPServerViewModel.writeGeneratedOracleExportFileForReadFileHandoff(
			fileManager: fileManagerVM,
			path: exactPath,
			content: "# Oracle Review\n\nExact path body.",
			destination: destination,
			sourceTool: "ask_oracle"
		)
		try await MCPServerViewModel.validateGeneratedOracleExportReadableForReadFileHandoff(
			fileManager: fileManagerVM,
			path: resolvedPath,
			destination: destination,
			sourceTool: "ask_oracle"
		)

		guard case .workspace(let readableFile)? = await fileManagerVM.resolveReadableFileForUserInput(
			resolvedPath,
			rootScopeOverride: .visibleWorkspace
		) else {
			return XCTFail("Expected exact returned absolute path to remain readable")
		}
		XCTAssertEqual(readableFile.standardizedFullPath, exactPath)

		let instruction = AgentOracleExport.instruction(path: resolvedPath)
		XCTAssertTrue(instruction.contains(resolvedPath))
		XCTAssertTrue(instruction.contains("exact path verbatim"), instruction)
		XCTAssertTrue(instruction.contains("do not shorten"), instruction)
	}

	private func makeLoadedWorkspaceRoot(gitignore: String? = nil) async throws -> (RepoFileManagerViewModel, URL, WorkspaceModel) {
		let rootURL = makeTempDirectory()
		if let gitignore {
			try gitignore.write(to: rootURL.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
		}
		let workspace = WorkspaceModel(name: "Test", repoPaths: [rootURL.path])
		let fileManagerVM = RepoFileManagerViewModel()
		try await fileManagerVM.loadFolder(at: rootURL, for: workspace, freshStart: true)
		return (fileManagerVM, rootURL, workspace)
	}

	private func makeTempDirectory() -> URL {
		let dir = FileManager.default.temporaryDirectory
			.appendingPathComponent("RepoPrompt-ContextBuilderExportTests-\(UUID().uuidString)", isDirectory: true)
		try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
		return dir
	}
}
