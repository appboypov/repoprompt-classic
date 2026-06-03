import XCTest
@testable import RepoPrompt

final class AgentWorkflowSectionsTests: XCTestCase {
	func testBuiltInSectionsRespectHiddenIDsAndPreserveWorkflowOrder() {
		let sections = AgentWorkflow.builtInSections(hiddenBuiltInIDs: [
			AgentWorkflow.oracleExport.rawValue,
			AgentWorkflow.review.rawValue
		])

		XCTAssertEqual(
			sections.visibleBuiltIns.compactMap(\.builtInWorkflow),
			[.orchestrate, .deepPlan, .optimize, .build, .refactor, .investigate]
		)
		XCTAssertEqual(
			sections.hiddenBuiltIns.compactMap(\.builtInWorkflow),
			[.review, .oracleExport]
		)
	}

	func testDefaultHiddenBuiltInsHidePlanAndBuildAndLeaveOrchestrateFirst() {
		let sections = AgentWorkflow.builtInSections(hiddenBuiltInIDs: AgentWorkflowStore.defaultHiddenBuiltInIDs)

		XCTAssertEqual(
			sections.visibleBuiltIns.compactMap(\.builtInWorkflow),
			[.orchestrate, .deepPlan, .optimize, .review, .refactor, .investigate, .oracleExport]
		)
		XCTAssertEqual(
			sections.hiddenBuiltIns.compactMap(\.builtInWorkflow),
			[.build]
		)
	}

	func testBuiltInSectionsIgnoreUnknownHiddenIDs() {
		let sections = AgentWorkflow.builtInSections(hiddenBuiltInIDs: ["not-a-workflow"])

		XCTAssertEqual(
			sections.visibleBuiltIns.compactMap(\.builtInWorkflow),
			AgentWorkflow.displayOrder
		)
		XCTAssertTrue(sections.hiddenBuiltIns.isEmpty)
	}

	@MainActor
	func testResolveWorkflowReferenceMatchesStableIDAndDisplayNameCaseInsensitively() {
		let workflow = AgentWorkflow.review.definition
		let store = AgentWorkflowStore.shared

		XCTAssertEqual(store.resolveWorkflowReference(workflow.id)?.id, workflow.id)
		XCTAssertEqual(store.resolveWorkflowReference(workflow.displayName.uppercased())?.id, workflow.id)
		XCTAssertNil(store.resolveWorkflowReference("definitely-not-a-workflow"))
	}

	func testOrchestrateWorkflowHasExpectedMetadata() {
		let workflow = AgentWorkflow.orchestrate
		let definition = workflow.definition

		XCTAssertEqual(definition.displayName, "Orchestrate")
		XCTAssertEqual(definition.id, "builtin-orchestrate")
		XCTAssertTrue(definition.isBuiltIn)
		XCTAssertNotNil(workflow.template)
		XCTAssertFalse(workflow.template.isEmpty)
		XCTAssertTrue(workflow.template.contains("$ARGUMENTS"))
		XCTAssertEqual(workflow.defaultTaskLabelKind, .pair)
	}

	@MainActor
	func testAgentRunStartDefaultsToPairWhenModelIDIsOmitted() {
		XCTAssertEqual(AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: nil), .pair)
	}

	@MainActor
	func testAgentRunStartDefaultsToPairWhenWorkflowIsProvidedAndModelIDIsOmitted() {
		XCTAssertEqual(
			AgentRunMCPToolService.defaultTaskLabelForStart(
				resolvedTabID: nil,
				workflow: AgentWorkflow.oracleExport.definition
			),
			.pair
		)
	}

	@MainActor
	func testAgentRunStartKeepsExplicitTargetTabSelectionWhenModelIDIsOmitted() {
		XCTAssertNil(AgentRunMCPToolService.defaultTaskLabelForStart(resolvedTabID: UUID()))
	}

	func testBuiltInWorkflowCleanupGuidanceDefaultsEnabled() {
		let wrapped = AgentWorkflow.orchestrate.definition.wrapUserText("Do the thing")

		XCTAssertTrue(wrapped.contains("Do the thing"))
		XCTAssertTrue(wrapped.contains("### Housekeeping"))
		XCTAssertTrue(wrapped.contains("cleanup_sessions"))
		XCTAssertTrue(wrapped.contains("Dismiss a completed session"))
	}

	func testBuiltInWorkflowCleanupGuidanceCanBeDisabled() {
		let wrapped = AgentWorkflow.orchestrate.definition.wrapUserText(
			"Do the thing",
			includeBuiltInSessionCleanupGuidance: false
		)

		XCTAssertTrue(wrapped.contains("Do the thing"))
		XCTAssertFalse(wrapped.contains("cleanup_sessions"))
		XCTAssertFalse(wrapped.contains("Dismiss a completed session"))
		XCTAssertFalse(wrapped.contains("### Housekeeping"))
	}

	func testInvestigationAndRefactorCleanupGuidanceCanBeDisabled() {
		let investigate = AgentWorkflow.investigate.definition.wrapUserText(
			"Trace a bug",
			includeBuiltInSessionCleanupGuidance: false
		)
		let refactor = AgentWorkflow.refactor.definition.wrapUserText(
			"Clean up duplication",
			includeBuiltInSessionCleanupGuidance: false
		)

		XCTAssertFalse(investigate.contains("cleanup_sessions"))
		XCTAssertFalse(investigate.contains("#### Housekeeping"))
		XCTAssertFalse(refactor.contains("cleanup_sessions"))
		XCTAssertFalse(refactor.contains("### Housekeeping"))
	}

	func testCustomWorkflowIgnoresBuiltInCleanupGuidanceFlag() {
		let custom = AgentWorkflowDefinition(
			customID: UUID(),
			displayName: "Custom Cleanup Workflow",
			template: "Custom header\ncleanup_sessions sentinel\nTask: $ARGUMENTS"
		)

		let wrapped = custom.wrapUserText(
			"Do custom work",
			includeBuiltInSessionCleanupGuidance: false
		)

		XCTAssertTrue(wrapped.contains("cleanup_sessions sentinel"))
		XCTAssertTrue(wrapped.contains("Do custom work"))
	}

	@MainActor
	func testResolveWorkflowReferenceSkipsHiddenBuiltIns() {
		let workflow = AgentWorkflow.review
		let store = AgentWorkflowStore.shared
		let previousHiddenIDs = store.hiddenBuiltInIDs
		defer { store.hiddenBuiltInIDs = previousHiddenIDs }

		store.hiddenBuiltInIDs = [workflow.rawValue]

		XCTAssertNil(store.resolveWorkflowReference(workflow.definition.id))
		XCTAssertNil(store.resolveWorkflowReference(workflow.definition.displayName))
	}

	@MainActor
	func testSetBuiltInVisibilityHidingRemovesFeaturedAndShowingDoesNotRefeature() {
		let workflow = AgentWorkflow.review
		let store = AgentWorkflowStore.shared
		let previousHiddenIDs = store.hiddenBuiltInIDs
		let previousFeaturedIDs = store.featuredWorkflowIDs
		defer {
			store.hiddenBuiltInIDs = previousHiddenIDs
			for id in store.featuredWorkflowIDs {
				store.removeFeaturedWorkflow(withID: id)
			}
			for id in previousFeaturedIDs {
				if let workflow = store.featureableWorkflows.first(where: { $0.id == id }) {
					store.toggleFeatured(workflow)
				}
			}
		}

		store.setBuiltInVisibility(workflow, isVisible: true)
		for id in store.featuredWorkflowIDs {
			store.removeFeaturedWorkflow(withID: id)
		}
		store.toggleFeatured(workflow.definition)
		XCTAssertTrue(store.isFeatured(workflow.definition))

		store.setBuiltInVisibility(workflow, isVisible: false)
		XCTAssertTrue(store.isBuiltInHidden(workflow))
		XCTAssertFalse(store.isFeatured(workflow.definition))

		store.setBuiltInVisibility(workflow, isVisible: false)
		XCTAssertTrue(store.isBuiltInHidden(workflow))
		XCTAssertFalse(store.isFeatured(workflow.definition))

		store.setBuiltInVisibility(workflow, isVisible: true)
		XCTAssertFalse(store.isBuiltInHidden(workflow))
		XCTAssertFalse(store.isFeatured(workflow.definition))
	}
}
