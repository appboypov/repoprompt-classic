//
//  IndentationEncodingTests.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-06-17.
//


//
//  IndentationEncodingTests.swift
//  RepoPromptTests
//
//  Created by ChatGPT on 2025-06-17.
//

import XCTest
@testable import RepoPrompt        // ← replace with the correct module name if different

final class IndentationEncodingTests: XCTestCase {

    // ──────────────────────────────────────────────────────────────
    // MARK: – encodeIndentationAsTabs(_:)
    // ──────────────────────────────────────────────────────────────

    func testEncodeIndentationAsTabs_AllSpaces() {
        XCTAssertEqual(
            String.encodeIndentationAsTabs("    foo"),   // 4 spaces
            "<t1>foo"
        )
    }

    func testEncodeIndentationAsTabs_AllTabs() {
        XCTAssertEqual(
            String.encodeIndentationAsTabs("\t\tbar"),    // 2 tabs
            "<t2>bar"
        )
    }

    func testEncodeIndentationAsTabs_MixedTabPlusSpaces() {
        // 1 tab (4) + 2 spaces  ⇒  6 effective spaces  ⇒  ⌈6/4⌉ = 2 tabs
        XCTAssertEqual(
            String.encodeIndentationAsTabs("\t  baz"),
            "<t2>baz"
        )
    }

	func testEncodeIndentationAsTabs_BlankLineWithMixedIndent() {
		// 1 tab (4) + 1 space = 5  → ceil(5/4) = 2 tabs
		XCTAssertEqual(
			String.encodeIndentationAsTabs("\t "),
			"<t2>"
		)
	}

    // ──────────────────────────────────────────────────────────────
    // MARK: – encodeIndentationAsSpaces(_:)
    // ──────────────────────────────────────────────────────────────

    func testEncodeIndentationAsSpaces_AllSpaces() {
        XCTAssertEqual(
            String.encodeIndentationAsSpaces("    qux"),  // 4 spaces
            "<s4>qux"
        )
    }

    func testEncodeIndentationAsSpaces_AllTabs() {
        XCTAssertEqual(
            String.encodeIndentationAsSpaces("\tquux"),   // 1 tab
            "<s4>quux"
        )
    }

    func testEncodeIndentationAsSpaces_MixedTabPlusSpaces() {
        // 1 tab (4) + 3 spaces  ⇒  7 spaces
        XCTAssertEqual(
            String.encodeIndentationAsSpaces("\t   corge"),
            "<s7>corge"
        )
    }

    func testEncodeIndentationAsSpaces_BlankLineWithMixedIndent() {
        XCTAssertEqual(
            String.encodeIndentationAsSpaces("\t\t "),    // 2 tabs + 1 space = 9
            "<s9>"
        )
    }

    // ──────────────────────────────────────────────────────────────
    // MARK: – Round-trip sanity
    // ──────────────────────────────────────────────────────────────

	func testRoundTrip_MixedIndent() {
		let original = "\t  grault"           // 1 tab + 2 spaces = 6 spaces total
		let encoded  = String.encodeIndentationAsSpaces(original)
		let decoded  = String.decodeIndentation(encoded)
		
		// Validate that the text part survived …
		XCTAssertEqual(decoded.trimmingCharacters(in: .whitespaces), "grault")
		
		// … and that the effective indentation width is still 6 spaces.
		let leadingSpaces = decoded.prefix { $0 == " " }.count
		XCTAssertEqual(leadingSpaces, 6)
	}
}
