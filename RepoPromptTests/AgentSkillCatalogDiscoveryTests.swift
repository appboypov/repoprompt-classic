import XCTest
@testable import RepoPrompt

@MainActor
final class AgentSkillCatalogDiscoveryTests: XCTestCase {
	func testClaudeCatalogDiscoversWorkspaceClaudeAndGenericAgentRoots() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "claude-workspace-roots")
		let homeURL = try makeTemporaryDirectory(named: "claude-empty-home")
		try createFolderSkill(at: workspaceURL, name: "claude-review", relativeRoot: ".claude/skills")
		try createLegacySkill(at: workspaceURL, name: "claude-fix", relativeRoot: ".claude/commands")
		try createFolderSkill(at: workspaceURL, name: "agent-review", relativeRoot: ".agents/skills")
		try createLegacySkill(at: workspaceURL, name: "agent-fix", relativeRoot: ".agents/slash")

		let catalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		await catalog.refresh(workspacePaths: [workspaceURL.path], agentKind: .claudeCode)

		let claudeReview = try XCTUnwrap(catalog.resolve(name: "claude-review"))
		let claudeFix = try XCTUnwrap(catalog.resolve(name: "claude-fix"))
		let agentReview = try XCTUnwrap(catalog.resolve(name: "agent-review"))
		let agentFix = try XCTUnwrap(catalog.resolve(name: "agent-fix"))

		XCTAssertEqual(claudeReview.source, .workspaceClaudeSkills)
		XCTAssertEqual(claudeFix.source, .workspaceClaudeCommands)
		XCTAssertEqual(agentReview.source, .workspaceAgentsSkills)
		XCTAssertEqual(agentFix.source, .workspaceAgentsSlash)
		XCTAssertEqual(catalog.promptContext(for: agentReview).sourceLabel, ".agents/skills")
		XCTAssertEqual(catalog.promptContext(for: agentFix).sourceLabel, ".agents/slash")
	}

	func testClaudeCatalogDiscoversGlobalGenericAgentRoots() async throws {
		let homeURL = try makeTemporaryDirectory(named: "claude-global-agent-home")
		try createFolderSkill(at: homeURL, name: "global-agent", relativeRoot: ".agents/skills")
		try createLegacySkill(at: homeURL, name: "global-slash", relativeRoot: ".agents/slash")

		let catalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		await catalog.refresh(workspacePaths: [], agentKind: .claudeCode)

		let globalAgent = try XCTUnwrap(catalog.resolve(name: "global-agent"))
		let globalSlash = try XCTUnwrap(catalog.resolve(name: "global-slash"))
		XCTAssertEqual(globalAgent.source, .globalAgentsSkills)
		XCTAssertEqual(globalSlash.source, .globalAgentsSlash)
	}

	func testClaudeSpecificDuplicateWinsOverGenericAgentDuplicate() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "claude-duplicate-workspace")
		let homeURL = try makeTemporaryDirectory(named: "claude-duplicate-home")
		try createFolderSkill(
			at: workspaceURL,
			name: "review",
			body: "Claude-specific review body",
			relativeRoot: ".claude/skills"
		)
		try createFolderSkill(
			at: workspaceURL,
			name: "review",
			body: "Generic agent review body",
			relativeRoot: ".agents/skills"
		)

		let catalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		await catalog.refresh(workspacePaths: [workspaceURL.path], agentKind: .claudeCode)

		let resolved = try XCTUnwrap(catalog.resolve(name: "review"))
		XCTAssertEqual(resolved.source, .workspaceClaudeSkills)
		XCTAssertTrue(resolved.template.contains("Claude-specific review body"))
		XCTAssertFalse(resolved.template.contains("Generic agent review body"))
	}

	func testWorkspaceGenericDuplicateWinsOverGlobalClaudeDuplicate() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "claude-workspace-global-duplicate-workspace")
		let homeURL = try makeTemporaryDirectory(named: "claude-workspace-global-duplicate-home")
		try createFolderSkill(
			at: workspaceURL,
			name: "review",
			body: "Workspace generic review body",
			relativeRoot: ".agents/skills"
		)
		try createFolderSkill(
			at: homeURL,
			name: "review",
			body: "Global Claude review body",
			relativeRoot: ".claude/skills"
		)

		let catalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		await catalog.refresh(workspacePaths: [workspaceURL.path], agentKind: .claudeCode)

		let resolved = try XCTUnwrap(catalog.resolve(name: "review"))
		XCTAssertEqual(resolved.source, .workspaceAgentsSkills)
		XCTAssertTrue(resolved.template.contains("Workspace generic review body"))
		XCTAssertFalse(resolved.template.contains("Global Claude review body"))
	}

	func testSharedPhysicalRootCanBeScannedWithDistinctFormats() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "claude-shared-format-workspace")
		let homeURL = try makeTemporaryDirectory(named: "claude-shared-format-home")
		let sharedRootURL = workspaceURL.appendingPathComponent("shared-root", isDirectory: true)
		let folderSkillURL = sharedRootURL.appendingPathComponent("folder-skill", isDirectory: true)
		try FileManager.default.createDirectory(at: folderSkillURL, withIntermediateDirectories: true)
		try """
		---
		name: folder-skill
		description: Folder skill
		---

		Folder body
		""".write(
			to: folderSkillURL.appendingPathComponent("SKILL.md"),
			atomically: true,
			encoding: .utf8
		)
		try """
		---
		name: flat-command
		description: Flat command
		---

		Flat body
		""".write(
			to: sharedRootURL.appendingPathComponent("flat-command.md"),
			atomically: true,
			encoding: .utf8
		)

		let claudeRootURL = workspaceURL.appendingPathComponent(".claude", isDirectory: true)
		try FileManager.default.createDirectory(at: claudeRootURL, withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(
			at: claudeRootURL.appendingPathComponent("skills", isDirectory: true),
			withDestinationURL: sharedRootURL
		)
		try FileManager.default.createSymbolicLink(
			at: claudeRootURL.appendingPathComponent("commands", isDirectory: true),
			withDestinationURL: sharedRootURL
		)

		let catalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		await catalog.refresh(workspacePaths: [workspaceURL.path], agentKind: .claudeCode)

		let folderSkill = try XCTUnwrap(catalog.resolve(name: "folder-skill"))
		let flatCommand = try XCTUnwrap(catalog.resolve(name: "flat-command"))
		XCTAssertEqual(folderSkill.source, .workspaceClaudeSkills)
		XCTAssertEqual(flatCommand.source, .workspaceClaudeCommands)
	}

	func testSymlinkedSkillDirectoryDoesNotCreateDuplicateSuggestionForSamePhysicalSkill() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "claude-symlink-duplicate-workspace")
		let homeURL = try makeTemporaryDirectory(named: "claude-symlink-duplicate-home")
		let originalSkillDirectory = try createFolderSkill(
			at: workspaceURL,
			name: "original",
			body: "Original body",
			relativeRoot: ".agents/skills",
			includeNameFrontmatter: false
		)
		let aliasURL = workspaceURL
			.appendingPathComponent(".claude", isDirectory: true)
			.appendingPathComponent("skills", isDirectory: true)
			.appendingPathComponent("alias", isDirectory: true)
		try FileManager.default.createDirectory(at: aliasURL.deletingLastPathComponent(), withIntermediateDirectories: true)
		try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: originalSkillDirectory)

		let catalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		await catalog.refresh(workspacePaths: [workspaceURL.path], agentKind: .claudeCode)

		let suggestions = catalog.suggestions(prefix: "", limit: 10)
		XCTAssertEqual(suggestions.map(\.name), ["alias"])
		let resolved = try XCTUnwrap(catalog.resolve(name: "alias"))
		XCTAssertEqual(resolved.source, .workspaceClaudeSkills)
		XCTAssertNil(catalog.resolve(name: "original"))
	}

	func testSymlinkCycleUnderSkillDirectoryDoesNotDuplicateOrHang() async throws {
		let workspaceURL = try makeTemporaryDirectory(named: "claude-symlink-cycle-workspace")
		let homeURL = try makeTemporaryDirectory(named: "claude-symlink-cycle-home")
		let cycleDirectory = try createFolderSkill(
			at: workspaceURL,
			name: "cycle",
			body: "Cycle body",
			relativeRoot: ".agents/skills",
			includeNameFrontmatter: false
		)
		try FileManager.default.createSymbolicLink(
			at: cycleDirectory.appendingPathComponent("loop", isDirectory: true),
			withDestinationURL: cycleDirectory
		)

		let catalog = AgentSkillCatalog(homeDirectoryURL: homeURL)
		await catalog.refresh(workspacePaths: [workspaceURL.path], agentKind: .claudeCode)

		let suggestions = catalog.suggestions(prefix: "", limit: 10)
		XCTAssertEqual(suggestions.map(\.name), ["cycle"])
		XCTAssertNotNil(catalog.resolve(name: "cycle"))
	}

	private func makeTemporaryDirectory(named prefix: String) throws -> URL {
		let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
		addTeardownBlock {
			try? FileManager.default.removeItem(at: url)
		}
		return url
	}

	@discardableResult
	private func createFolderSkill(
		at rootURL: URL,
		name: String,
		body: String = "Test body",
		relativeRoot: String,
		includeNameFrontmatter: Bool = true
	) throws -> URL {
		let skillDirectoryURL = rootURL
			.appendingPathComponent(relativeRoot, isDirectory: true)
			.appendingPathComponent(name, isDirectory: true)
		try FileManager.default.createDirectory(at: skillDirectoryURL, withIntermediateDirectories: true)
		let frontmatter = includeNameFrontmatter
			? """
			---
			name: \(name)
			description: Test skill
			---

			"""
			: ""
		try "\(frontmatter)\(body)".write(
			to: skillDirectoryURL.appendingPathComponent("SKILL.md"),
			atomically: true,
			encoding: .utf8
		)
		return skillDirectoryURL
	}

	private func createLegacySkill(
		at rootURL: URL,
		name: String,
		body: String = "Test legacy body",
		relativeRoot: String
	) throws {
		let directoryURL = rootURL.appendingPathComponent(relativeRoot, isDirectory: true)
		try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
		let skillBody = """
		---
		name: \(name)
		description: Test legacy skill
		---

		\(body)
		"""
		try skillBody.write(
			to: directoryURL.appendingPathComponent("\(name).md"),
			atomically: true,
			encoding: .utf8
		)
	}
}
