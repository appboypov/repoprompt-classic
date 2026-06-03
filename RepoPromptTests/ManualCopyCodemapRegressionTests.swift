import XCTest
@testable import RepoPrompt

final class ManualCopyCodemapRegressionTests: XCTestCase {
	func testGlobalDisableForcesManualResolutionToNoneWithoutChangingInputs() {
		let resolved = PromptViewModel.resolveCopyCodeMapUsage(
			isManualPreset: true,
			customCodeMapUsage: .complete,
			presetCodeMapUsage: nil,
			uiCodeMapUsage: .selected,
			globallyDisabled: true
		)

		XCTAssertEqual(resolved, .none)
	}

	func testGlobalDisableForcesNonManualResolutionToNone() {
		let resolved = PromptViewModel.resolveCopyCodeMapUsage(
			isManualPreset: false,
			customCodeMapUsage: nil,
			presetCodeMapUsage: .complete,
			uiCodeMapUsage: .selected,
			globallyDisabled: true
		)

		XCTAssertEqual(resolved, .none)
	}

	func testManualResolutionPrefersVisibleCodeMapUsageOverStaleCustomizationOverride() {
		let resolved = PromptViewModel.resolveCopyCodeMapUsage(
			isManualPreset: true,
			customCodeMapUsage: .complete,
			presetCodeMapUsage: nil,
			uiCodeMapUsage: .none
		)

		XCTAssertEqual(resolved, .none)
	}

	func testNonManualResolutionUsesPresetValueForStandardRecovery() {
		let resolved = PromptViewModel.resolveCopyCodeMapUsage(
			isManualPreset: false,
			customCodeMapUsage: .complete,
			presetCodeMapUsage: .auto,
			uiCodeMapUsage: .none
		)

		XCTAssertEqual(resolved, .auto)
	}

	func testRemovingCodeMapUsageOverridePreservesOtherManualCustomizations() {
		let customizations = CopyCustomizations(
			fileTreeMode: .selected,
			codeMapUsage: .complete,
			includeFiles: false,
			includeMCPMetadata: true
		)

		let sanitized = customizations.removingCodeMapUsageOverride()

		XCTAssertNil(sanitized.codeMapUsage)
		XCTAssertEqual(sanitized.fileTreeMode, .selected)
		XCTAssertEqual(sanitized.includeFiles, false)
		XCTAssertEqual(sanitized.includeMCPMetadata, true)
	}

	func testRemovingCodeMapUsageOverrideCanCollapseToEmptyPersistenceValue() {
		let customizations = CopyCustomizations(codeMapUsage: .auto)

		let sanitized = customizations.removingCodeMapUsageOverride()

		XCTAssertFalse(sanitized.hasCustomizations)
	}
}
