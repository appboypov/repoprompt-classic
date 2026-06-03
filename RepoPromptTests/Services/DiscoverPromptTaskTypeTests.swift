import XCTest
@testable import RepoPrompt

final class DiscoverPromptReviewHotwordTests: XCTestCase {
	func testClarifyStructuredReviewPromptEnablesReviewModeGuidance() {
		let prompt = SystemPromptService.discoverPrompt(
			responseType: "clarify",
			instructions: "<task>Review changes</task><context>Review intent: code review. Git scope: compare main. Current branch: feature/x. Use git diff artifacts and inspect affected source files.</context>"
		)

		XCTAssertTrue(prompt.contains("## Review Mode"))
		XCTAssertTrue(prompt.contains("{\"tool\":\"git\",\"args\":{\"op\":\"diff\",\"artifacts\":true}}"))
	}

	func testClarifyStandaloneReviewTokenEnablesReviewModeGuidance() {
		let prompt = SystemPromptService.discoverPrompt(
			responseType: "clarify",
			instructions: "<task>Please review the recent authentication changes</task><context>Focus on error handling.</context>"
		)

		XCTAssertTrue(prompt.contains("## Review Mode"))
	}

	func testClarifyStandaloneGitTokenEnablesReviewModeGuidance() {
		let prompt = SystemPromptService.discoverPrompt(
			responseType: "clarify",
			instructions: "<task>Analyze git history around onboarding regressions</task><context>Focus on recent changes in setup flows.</context>"
		)

		XCTAssertTrue(prompt.contains("## Review Mode"))
	}

	func testClarifyWithoutReviewHotwordsDoesNotEnableReviewModeGuidance() {
		let prompt = SystemPromptService.discoverPrompt(
			responseType: "clarify",
			instructions: "<task>Plan authentication cleanup</task><context>Focus on service boundaries and settings migration.</context>"
		)

		XCTAssertFalse(prompt.contains("## Review Mode"))
	}

	func testLegacyReviewResponseTypeStillEnablesReviewModeGuidance() {
		let prompt = SystemPromptService.discoverPrompt(responseType: "review")

		XCTAssertTrue(prompt.contains("## Review Mode"))
	}
}
