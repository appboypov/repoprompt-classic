import XCTest
@testable import RepoPrompt

final class ComposeTabStateDecodingTests: XCTestCase {
	func testDecodesLegacyPayloadWithDefaults() throws {
		let json = """
		{
			"id": "6F9619FF-8B86-D011-B42D-00CF4FC964FF",
			"name": "Legacy",
			"lastModified": "2024-01-01T12:34:56Z",
			"selection": {
				"selectedPaths": ["Sources/App.swift"],
				"autoCodemapPaths": [],
				"slices": {},
				"codemapAutoEnabled": true
			},
			"expandedFolders": [],
			"promptText": "Legacy prompt",
			"selectedMetaPromptIDs": []
		}
		"""

		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let data = try XCTUnwrap(json.data(using: .utf8))

		let tab = try decoder.decode(ComposeTabState.self, from: data)

		XCTAssertEqual(tab.name, "Legacy")
		XCTAssertEqual(tab.promptText, "Legacy prompt")
		XCTAssertEqual(tab.selection.selectedPaths, ["Sources/App.swift"])
		XCTAssertEqual(tab.discover.instructions, "")
		XCTAssertNil(tab.discover.tokenBudget)
		XCTAssertFalse(tab.migrationRequiresSave)
	}

	func testDecodesNewFields() throws {
		let json = """
		{
			"id": "6F9619FF-8B86-D011-B42D-00CF4FC964FE",
			"name": "Modern",
			"lastModified": "2024-01-01T12:34:56Z",
			"selection": {
				"selectedPaths": [],
				"autoCodemapPaths": [],
				"slices": {},
				"codemapAutoEnabled": false
			},
			"expandedFolders": [],
			"promptText": "",
			"selectedMetaPromptIDs": [],
			"discover": {
				"instructions": "inspect sources",
				"tokenBudget": 12345,
				"agentRaw": "custom-agent",
				"modelRaw": "model-x"
			},
			"contextBuilder": {
				"recommendedHighPaths": ["README.md"],
				"recommendedMediumPaths": [],
				"recommendedLowPaths": [],
				"recommendationsTitle": "Focus",
				"includeFileTree": false,
				"includeCodeMap": true,
				"maxTokensPerQuery": 32,
				"disableSizeLimits": false,
				"enableFinalRefinement": true,
				"includeHighPriority": true,
				"includeMediumPriority": false,
				"includeLowPriority": false,
				"useOverridePrompt": true,
				"overridePromptText": "Custom override",
				"useOnlySelectedFiles": true,
				"parallelPartitions": 7
			}
		}
		"""

		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		let data = try XCTUnwrap(json.data(using: .utf8))

		let tab = try decoder.decode(ComposeTabState.self, from: data)

		// Standalone tab decode keeps legacy override as a transient workspace-migration
		// candidate; WorkspaceModel applies it after root discovery migration.
		XCTAssertEqual(tab.promptText, "")
		XCTAssertEqual(tab.discover.instructions, "inspect sources")
		XCTAssertEqual(tab.discover.tokenBudget, 12_345)
		XCTAssertEqual(tab.discover.agentRaw, "custom-agent")
		XCTAssertEqual(tab.discover.modelRaw, "model-x")
		XCTAssertTrue(tab.migrationRequiresSave)

		let encoded = try JSONEncoder().encode(tab)
		let encodedJSON = String(data: encoded, encoding: .utf8) ?? ""
		XCTAssertFalse(encodedJSON.contains("contextBuilder"))
		XCTAssertFalse(encodedJSON.contains("contextOverrides"))
	}
}
