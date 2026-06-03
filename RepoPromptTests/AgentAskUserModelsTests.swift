import Foundation
import XCTest
import MCP
@testable import RepoPrompt

final class AgentAskUserModelsTests: XCTestCase {
	func testSubmittedResponsePreservesQuestionOrderOptionOrderAndTrimsCustom() throws {
		let interaction = AgentAskUserInteraction(
			questions: [
				AgentAskUserQuestion(
					id: "scope",
					question: "Which scope?",
					options: [
						AgentAskUserOption(label: "UI"),
						AgentAskUserOption(label: "Backend")
					],
					allowsMultiple: true,
					allowsCustom: true
				),
				AgentAskUserQuestion(id: "notes", question: "Anything else?")
			]
		)

		let response = try interaction.buildSubmittedResponse(
			drafts: [
				"scope": AgentAskUserDraft(selectedOptionLabels: ["Backend", "UI"], customResponse: "  also tests  "),
				"notes": AgentAskUserDraft(customResponse: " keep it focused ")
			],
			elapsedSeconds: 42
		)

		XCTAssertEqual(response.answersByQuestionID["scope"]?.selectedOptions, ["UI", "Backend"])
		XCTAssertEqual(response.answersByQuestionID["scope"]?.customResponse, "also tests")
		XCTAssertEqual(response.answersByQuestionID["scope"]?.answers, ["UI", "Backend", "also tests"])
		XCTAssertEqual(response.answersByQuestionID["notes"]?.answers, ["keep it focused"])
		XCTAssertFalse(response.timedOut)
		XCTAssertFalse(response.skipped)
		XCTAssertEqual(response.elapsedSeconds, 42)
	}

	func testSubmittedResponseRequiresEveryQuestionAnsweredOrSkipped() throws {
		let interaction = AgentAskUserInteraction(
			questions: [
				AgentAskUserQuestion(id: "answered", question: "Answered?"),
				AgentAskUserQuestion(id: "missing", question: "Missing?")
			]
		)

		XCTAssertThrowsError(
			try interaction.buildSubmittedResponse(
				drafts: ["answered": AgentAskUserDraft(customResponse: "yes")],
				elapsedSeconds: 3
			)
		) { error in
			XCTAssertEqual(error as? AgentAskUserValidationError, .incompleteQuestion("missing"))
		}

		let response = try interaction.buildSubmittedResponse(
			drafts: [
				"answered": AgentAskUserDraft(customResponse: "yes"),
				"missing": AgentAskUserDraft(skipped: true)
			],
			elapsedSeconds: 4
		)
		XCTAssertEqual(response.answersByQuestionID["missing"]?.answers, [])
		XCTAssertEqual(response.answersByQuestionID["missing"]?.skipped, true)
	}

	func testTimedOutAndSkipAllResponsesUseExpectedSemantics() {
		let interaction = AgentAskUserInteraction(
			questions: [
				AgentAskUserQuestion(id: "partial", question: "Partial?"),
				AgentAskUserQuestion(id: "empty", question: "Empty?")
			]
		)

		let timedOut = interaction.buildTimedOutResponse(
			drafts: ["partial": AgentAskUserDraft(customResponse: "draft")],
			elapsedSeconds: 10
		)
		XCTAssertTrue(timedOut.timedOut)
		XCTAssertFalse(timedOut.skipped)
		XCTAssertEqual(timedOut.answersByQuestionID["partial"]?.answers, ["draft"])
		XCTAssertEqual(timedOut.answersByQuestionID["empty"]?.answers, [])
		XCTAssertEqual(timedOut.answersByQuestionID["empty"]?.skipped, false)

		let skipped = interaction.buildSkippedResponse(elapsedSeconds: 11)
		XCTAssertFalse(skipped.timedOut)
		XCTAssertTrue(skipped.skipped)
		XCTAssertEqual(skipped.answersByQuestionID["partial"]?.skipped, true)
		XCTAssertEqual(skipped.answersByQuestionID["empty"]?.skipped, true)
	}

	func testDraftReconstructionClassifiesOptionsAndRejectsInvalidSingleSelect() throws {
		let interaction = AgentAskUserInteraction(
			questions: [
				AgentAskUserQuestion(
					id: "choice",
					question: "Pick one",
					options: [AgentAskUserOption(label: "A"), AgentAskUserOption(label: "B")],
					allowsMultiple: false,
					allowsCustom: true
				),
				AgentAskUserQuestion(
					id: "multi",
					question: "Pick many",
					options: [AgentAskUserOption(label: "First"), AgentAskUserOption(label: "Second")],
					allowsMultiple: true,
					allowsCustom: true
				)
			]
		)

		let drafts = try interaction.drafts(fromFlatAnswers: ["multi": ["Second", "custom", "First"]])
		XCTAssertEqual(drafts["multi"]?.selectedOptionLabels, ["First", "Second"])
		XCTAssertEqual(drafts["multi"]?.customResponse, "custom")

		XCTAssertThrowsError(try interaction.drafts(fromFlatAnswers: ["choice": ["A", "custom"]])) { error in
			XCTAssertEqual(error as? AgentAskUserValidationError, .invalidSingleSelectAnswer(questionID: "choice"))
		}
	}

	func testDraftReconstructionRejectsUnknownQuestionIDs() throws {
		let interaction = AgentAskUserInteraction(
			questions: [
				AgentAskUserQuestion(id: "scope", question: "Scope?"),
				AgentAskUserQuestion(id: "notes", question: "Notes?")
			]
		)

		XCTAssertThrowsError(try interaction.drafts(fromFlatAnswers: ["scoop": ["UI"]])) { error in
			XCTAssertEqual(error as? AgentAskUserValidationError, .unknownQuestionID(id: "scoop", validIDs: ["scope", "notes"]))
			XCTAssertTrue(error.localizedDescription.contains("Known IDs: scope, notes"))
		}
	}

	func testDraftReconstructionRejectsMultipleCustomAnswers() throws {
		let interaction = AgentAskUserInteraction(
			questions: [
				AgentAskUserQuestion(id: "multi", question: "Pick many", allowsMultiple: true, allowsCustom: true)
			]
		)

		XCTAssertThrowsError(try interaction.drafts(fromFlatAnswers: ["multi": ["first custom", "second custom"]])) { error in
			XCTAssertEqual(error as? AgentAskUserValidationError, .invalidCustomAnswer(questionID: "multi"))
		}
	}

	func testPendingStateEqualityIncludesDraftAndIndexChanges() {
		let interaction = AgentAskUserInteraction(
			id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
			questions: [
				AgentAskUserQuestion(id: "one", question: "One?"),
				AgentAskUserQuestion(id: "two", question: "Two?")
			]
		)
		let initial = AgentAskUserPendingState(interaction: interaction)
		var edited = initial
		edited.draftsByQuestionID["one"]?.customResponse = "draft"
		var advanced = initial
		advanced.currentQuestionIndex = 1

		XCTAssertNotEqual(initial, edited)
		XCTAssertNotEqual(initial, advanced)
	}

	func testInteractionFieldSerializesAdditiveMetadataForUserInput() {
		let field = AgentRunMCPSnapshot.Interaction.Field(
			id: "q1",
			header: "Header",
			prompt: "Prompt",
			context: "Context",
			isSecret: false,
			allowsOther: true,
			allowsMultiple: true,
			allowsCustom: true,
			options: [AgentRunMCPSnapshot.Interaction.Option(label: "A", description: "First")]
		)

		let object = field.asObject()
		XCTAssertEqual(object["context"]?.stringValue, "Context")
		XCTAssertEqual(object["allows_multiple"]?.boolValue, true)
		XCTAssertEqual(object["allows_custom"]?.boolValue, true)
		XCTAssertEqual(object["allows_other"]?.boolValue, true)
	}

	func testInteractionFieldCanOmitLegacyAllowsOtherForAskUserQuestions() {
		let field = AgentRunMCPSnapshot.Interaction.Field(
			id: "q1",
			header: "Header",
			prompt: "Prompt",
			context: "Context",
			isSecret: false,
			allowsOther: true,
			allowsMultiple: true,
			allowsCustom: true,
			emitAllowsOther: false,
			options: [AgentRunMCPSnapshot.Interaction.Option(label: "A", description: "First")]
		)

		let object = field.asObject()
		XCTAssertEqual(object["allows_multiple"]?.boolValue, true)
		XCTAssertEqual(object["allows_custom"]?.boolValue, true)
		XCTAssertNil(object["allows_other"])
	}
}
