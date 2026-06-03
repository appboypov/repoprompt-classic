import XCTest
@testable import RepoPrompt

final class AppSettingsCardPresentationTests: XCTestCase {
	func testListSubtitleIncludesGroupAndCount() {
		let args = #"{"op":"list","group":"ui"}"#
		let result = #"{"op":"list","status":"ok","count":2,"settings":[{"key":"ui.appearance_mode","group":"ui","type":"string","value":"Dark"},{"key":"ui.show_tooltips","group":"ui","type":"boolean","value":true}]}"#

		let presentation = AppSettingsCardPresentationBuilder.build(argsJSON: args, resultJSON: result, toolIsError: false)

		XCTAssertEqual(presentation.subtitle, "list • ui • 2 settings")
		XCTAssertEqual(presentation.detailText, "ui.appearance_mode, ui.show_tooltips")
		XCTAssertEqual(presentation.status, .success)
	}

	func testGetSingleValueSubtitleUsesTwentyFourCharacterPreview() {
		let args = #"{"op":"get","key":"models.custom_planning_prompt"}"#
		let result = #"{"op":"get","status":"ok","count":1,"values":{"models.custom_planning_prompt":{"value_preview":"abcdefghijklmnopqrstuvwxyz","value_length":80}}}"#

		let presentation = AppSettingsCardPresentationBuilder.build(argsJSON: args, resultJSON: result, toolIsError: false)

		XCTAssertTrue(presentation.subtitle?.hasPrefix("get • models.custom_planning_prompt = \"abcdefghijklmnopqrstuvw…\"") == true)
		XCTAssertTrue(presentation.subtitle?.contains("(…+57 chars)") == true)
		XCTAssertNil(presentation.detailText)
	}

	func testSetChangedDetailIncludesArrowAndSideEffectSuffix() {
		let args = #"{"op":"set","key":"ui.appearance_mode","value":"Dark"}"#
		let result = #"{"op":"set","status":"ok","key":"ui.appearance_mode","old_value":"System","new_value":"Dark","changed":true,"applied":true,"side_effect":"requires_app_relaunch"}"#

		let presentation = AppSettingsCardPresentationBuilder.build(argsJSON: args, resultJSON: result, toolIsError: false)

		XCTAssertEqual(presentation.subtitle, "set • ui.appearance_mode • changed")
		XCTAssertEqual(presentation.detailText, "\"System\" → \"Dark\" • takes effect after relaunching RepoPrompt")
	}

	func testSetUnchangedSubtitleHasNoArrow() {
		let args = #"{"op":"set","key":"ui.show_tooltips","value":true}"#
		let result = #"{"op":"set","status":"ok","key":"ui.show_tooltips","old_value":true,"new_value":true,"changed":false,"applied":false,"side_effect":"noop"}"#

		let presentation = AppSettingsCardPresentationBuilder.build(argsJSON: args, resultJSON: result, toolIsError: false)

		XCTAssertEqual(presentation.subtitle, "set • ui.show_tooltips • unchanged")
		XCTAssertFalse((presentation.detailText ?? "").contains("→"))
		XCTAssertEqual(presentation.detailText, "new value: true")
	}

	func testSetChangedButUnappliedUsesWarningPresentation() {
		let args = #"{"op":"set","key":"models.custom_planning_prompt","value":"new"}"#
		let result = #"{"op":"set","status":"ok","key":"models.custom_planning_prompt","old_value":"old","new_value":"new","changed":true,"applied":false}"#

		let presentation = AppSettingsCardPresentationBuilder.build(argsJSON: args, resultJSON: result, toolIsError: false)

		XCTAssertEqual(presentation.subtitle, "set • models.custom_planning_prompt • changed • not applied")
		XCTAssertEqual(presentation.detailText, "\"old\" → \"new\" • change not applied")
		XCTAssertEqual(presentation.status, .warning)
	}

	func testErrorSubtitlePrefixesAttemptedOperationForMinimalEnvelope() {
		let args = #"{"op":"set","key":"ui.appearance_mode"}"#
		let result = #"{"error":"Invalid value."}"#

		let presentation = AppSettingsCardPresentationBuilder.build(argsJSON: args, resultJSON: result, toolIsError: true)

		XCTAssertEqual(presentation.subtitle, "set • ui.appearance_mode")
		XCTAssertEqual(presentation.detailText, "Invalid value.")
		XCTAssertEqual(presentation.status, .failure)
	}
}
