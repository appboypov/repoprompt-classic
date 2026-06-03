import XCTest
@testable import RepoPrompt

final class ContextBuilderBudgetResolverTests: XCTestCase {
	func testResolveBudgetUsesDiscoveryBudgetWhenResponseTypeIsOmitted() {
		let budget = ContextBuilderBudgetResolver.resolveBudget(
			wantsResponse: false,
			discoveryTokenBudget: 55_000,
			planTokenBudget: 125_000
		)

		XCTAssertEqual(budget, 55_000)
	}

	func testResolveBudgetUsesDiscoveryBudgetForClarify() {
		let budget = ContextBuilderBudgetResolver.resolveBudget(
			wantsResponse: false,
			discoveryTokenBudget: 65_000,
			planTokenBudget: 130_000
		)

		XCTAssertEqual(budget, 65_000)
	}

	func testResolveBudgetUsesPlanBudgetForPlanQuestionAndReview() {
		XCTAssertEqual(
			ContextBuilderBudgetResolver.resolveBudget(
				wantsResponse: true,
				discoveryTokenBudget: 60_000,
				planTokenBudget: 140_000
			),
			140_000
		)
		XCTAssertEqual(
			ContextBuilderBudgetResolver.resolveBudget(
				wantsResponse: true,
				discoveryTokenBudget: 60_000,
				planTokenBudget: 140_000
			),
			140_000
		)
		XCTAssertEqual(
			ContextBuilderBudgetResolver.resolveBudget(
				wantsResponse: true,
				discoveryTokenBudget: 60_000,
				planTokenBudget: 140_000
			),
			140_000
		)
	}

	func testResolveBudgetFallsBackToDefaultsWhenWorkspaceSettingsMissing() {
		XCTAssertEqual(
			ContextBuilderBudgetResolver.resolveBudget(
				wantsResponse: false,
				discoveryTokenBudget: nil,
				planTokenBudget: nil
			),
			ContextBuilderDefaults.discoveryTokenBudget
		)
		XCTAssertEqual(
			ContextBuilderBudgetResolver.resolveBudget(
				wantsResponse: true,
				discoveryTokenBudget: nil,
				planTokenBudget: nil
			),
			ContextBuilderDefaults.planTokenBudget
		)
	}
}
