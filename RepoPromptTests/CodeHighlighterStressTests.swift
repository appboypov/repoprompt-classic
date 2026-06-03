import XCTest
@testable import RepoPrompt
import AppKit

final class CodeHighlighterStressTests: XCTestCase {

	func testHtmlDenseSourceSkipsHighlightingQuickly() {
		let source = PathologicalInputFactory.makeHtmlDenseSnippet(repetitions: 500)
		let attributed = Self.makeMutableString(source)
		let start = CFAbsoluteTimeGetCurrent()
		CodeHighlighter.applyHighlighting(to: attributed, code: source)
		let duration = CFAbsoluteTimeGetCurrent() - start
		XCTAssertLessThan(duration, 0.5, "Highlighting should bail out quickly for HTML-dense payloads")
		let colour = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
		XCTAssertTrue(colour?.isEqual(NSColor.white) ?? false, "Guarded HTML-dense input should remain uncoloured")
	}

	func testChunkedHighlightingColoursKeywordAcrossBoundaries() {
		let sample = PathologicalInputFactory.makeChunkBoundarySource()
		let attributed = Self.makeMutableString(sample.source)
		CodeHighlighter.applyHighlighting(to: attributed, code: sample.source)
		let colour = attributed.attribute(.foregroundColor, at: sample.keywordLocation, effectiveRange: nil) as? NSColor
		XCTAssertNotNil(colour)
		XCTAssertFalse(colour?.isEqual(NSColor.white) ?? true, "Chunked processing should still colour keywords that straddle windows")
	}

	func testLargePlaintextInputProcessesWithoutCrash() {
		let source = PathologicalInputFactory.makeLargePlainSnippet()
		let attributed = Self.makeMutableString(source)
		CodeHighlighter.applyHighlighting(to: attributed, code: source)
		XCTAssertEqual(attributed.length, source.utf16.count, "Highlighting should preserve string length even for large inputs")
	}

	private static func makeMutableString(_ source: String) -> NSMutableAttributedString {
		return NSMutableAttributedString(
			string: source,
			attributes: [
				.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
				.foregroundColor: NSColor.white
			]
		)
	}
}

private enum PathologicalInputFactory {

	static func makeHtmlDenseSnippet(repetitions: Int) -> String {
		let snippet = "<div class=\"wrap\"><span data-index=\"123\">value</span><img src=\"/path\" /></div>"
		return String(repeating: snippet, count: repetitions)
	}

	static func makeChunkBoundarySource() -> (source: String, keywordLocation: Int) {
		let filler = String(repeating: "let placeholder = 42\n", count: 200)
		let keywordLine = "func acrossChunks() { return placeholder }\n"
		let source = filler + keywordLine + filler
		let nsSource = source as NSString
		let keywordRange = nsSource.range(of: "func acrossChunks()")
		XCTAssertNotEqual(keywordRange.location, NSNotFound)
		return (source, keywordRange.location)
	}

	static func makeLargePlainSnippet() -> String {
		let line = "var token = \"abc123\" // comment\n"
		var source = String()
		while source.utf16.count < 11_500 {
			source.append(line)
		}
		return source
	}
}
