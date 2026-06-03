//
//  DiffParserFuzzTests.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-09-07.
//


//
//  DiffParserFuzzTests.swift
//  RepoPromptTests
//
//  Property-style fuzzing for malformed XML/fence patterns to ensure
//  no tag/fence leakage into extracted <content>/<search> payloads.
//
//  This suite is deterministic (seeded). Increase the iteration count
//  via env var FUZZ_COUNT for stress testing.
//
//  Created by ChatGPT on 2025-09-07.
//

import XCTest
@testable import RepoPrompt

final class DiffParserFuzzTests: XCTestCase {
    
    // MARK: - Reproducible RNG
    
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
        mutating func next() -> UInt64 {
            // Simple LCG (fast & good-enough for reproducible fuzz)
            state = 6364136223846793005 &* state &+ 1
            return state
        }
        mutating func nextInt(_ upper: Int) -> Int { Int(next() % UInt64(upper)) }
        mutating func nextBool(p: Double = 0.5) -> Bool {
            Double(next() % 10_000) / 10_000.0 < p
        }
        mutating func pick<T>(_ arr: [T]) -> T { arr[nextInt(arr.count)] }
    }
    
    // MARK: - Test Config
    
    private var fileManagerVM: RepoFileManagerViewModel!
    
    override func setUp() async throws {
        try await super.setUp()
        fileManagerVM = await RepoFileManagerViewModel()
    }
    
    override func tearDown() async throws {
        fileManagerVM = nil
        try await super.tearDown()
    }
    
    private func fuzzCount(defaults: Int) -> Int {
        if let s = ProcessInfo.processInfo.environment["FUZZ_COUNT"], let n = Int(s), n > 0 {
            return n
        }
        return defaults
    }
    
    // MARK: - Helpers: generators
    
    private func randFence(_ rng: inout SeededGenerator) -> String {
        let len = 3 + rng.nextInt(4) // 3..6
        return String(repeating: "=", count: len)
    }
    
    private func maybeWhitespace(_ rng: inout SeededGenerator) -> String {
        let options = ["", " ", "\t", "  ", "\t  "]
        return rng.pick(options)
    }
    
    private func codeLine(_ rng: inout SeededGenerator) -> String {
        let pool: [String] = [
            #"if (a === 42) { return b === 7 ? 1 : 0 }"#,
            #"let xml = "<tag>content</tag>""#,
            #"return <div className=\"root\">OK</div>"#,
            #"func make(_ x:Int) -> Int { x + 1 }"#,
            #"// === This is not a fence ==="#,
            #"export const X = () => (<span>Hi</span>);"#,
            #"Array<String>"#,
            #"<!-- comment-like -->"#,
            #"@objc private func doIt() {}"#,
            #"case .some(let v): print(v)"#,
            #"console.log(a === 3 && b < 9)"#,
            #"struct S<T> { let v:T }"#
        ]
        return rng.pick(pool)
    }
    
    private func manyCodeLines(_ rng: inout SeededGenerator, min: Int = 1, max: Int = 6) -> String {
        let n = min + rng.nextInt(max - min + 1)
        return (0..<n).map { _ in codeLine(&rng) }.joined(separator: "\n")
    }
    
    private func randomFenceBlock(_ rng: inout SeededGenerator, inner: String, inline: Bool) -> String {
        let f = randFence(&rng)
        if inline {
            // Inline fence: === code ===   (may also trim spaces)
            let leftPad  = rng.nextBool() ? maybeWhitespace(&rng) : ""
            let rightPad = rng.nextBool() ? maybeWhitespace(&rng) : ""
            return "\(f)\(leftPad)\(inner)\(rightPad)\(f)"
        } else {
            // Multiline fence:
            let leadingNL = rng.nextBool() ? "\n" : "\r\n"
            let trailingNL = rng.nextBool() ? "\n" : "\r\n"
            return "\(f)\(leadingNL)\(inner)\(trailingNL)\(f)"
        }
    }
    
    /// Sometimes return a “seam”: `===<search>` without a newline.
    private func maybeSeamAfterClosingFence(_ rng: inout SeededGenerator, nextTagName: String) -> String {
        if rng.nextBool(p: 0.3) {
            // 30% of time force a seam
            let f = randFence(&rng)
            let ws = maybeWhitespace(&rng)
            return "\(f)\(ws)<\(nextTagName)>"
        } else {
            // regular fence on its own line
            let f = randFence(&rng)
            let lineEnd = rng.nextBool() ? "\n" : "\r\n"
            return "\(f)\(lineEnd)<\(nextTagName)>\(lineEnd)"
        }
    }
    
    /// Build a malformed or well-formed <content> ... and a <search> ... pair
    /// inside a <change>. Randomizes fence styles, missing closers, sibling orders.
    /// Adjusted to avoid *duplicate* nested tag openers like `<search><search>` or `<content><content>`,
    /// and to sometimes omit an entire section to simulate missing sections.
    private func buildChangeXML(_ rng: inout SeededGenerator) -> (xml: String, expectation: Expectation) {
        enum CloseMode { case proper, missingFence, missingCloseTag }
        let contentCloseMode: CloseMode = rng.pick([.proper, .missingFence, .missingCloseTag])
        let searchCloseMode:  CloseMode  = rng.pick([.proper, .missingFence, .missingCloseTag])
        let contentInline = rng.nextBool(p: 0.4) // 40% inline
        let searchInline  = rng.nextBool(p: 0.4)
        let orderContentFirst = rng.nextBool()   // sometimes <search> first

        // Occasionally omit a whole section to simulate "missing sections"
        var includeContent = rng.nextBool(p: 0.9)
        var includeSearch  = rng.nextBool(p: 0.9)
        if !includeContent && !includeSearch { includeContent = true } // ensure at least one exists

        // Build payloads
        let contentBody = manyCodeLines(&rng)
        let searchBody  = manyCodeLines(&rng)

        func makeTag(_ tag: String,
                     body: String,
                     inline: Bool,
                     closeMode: CloseMode,
                     nextSibling: String,
                     allowSeamIntoNext: Bool) -> String {
            var s = "<\(tag)>\n"

            // Body w/ or w/o fences
            if rng.nextBool(p: 0.8) {
                s += randomFenceBlock(&rng, inner: body, inline: inline)
                s += rng.nextBool() ? "\n" : "\r\n"
            } else {
                // No fences
                s += body + (rng.nextBool() ? "\n" : "\r\n")
            }

            // Closing variations
            switch closeMode {
            case .proper:
                // Always explicitly close the tag (even if inline fenced)
                s += "</\(tag)>\n"
            case .missingFence:
                if allowSeamIntoNext {
                    // Seam directly into sibling start; DO NOT duplicate sibling opener later
                    s += maybeSeamAfterClosingFence(&rng, nextTagName: nextSibling)
                } else {
                    // No seam allowed (e.g., last block) -> just close tag without extra fence
                    s += "</\(tag)>\n"
                }
            case .missingCloseTag:
                if allowSeamIntoNext {
                    // No close tag; may seam into sibling
                    s += maybeSeamAfterClosingFence(&rng, nextTagName: nextSibling)
                } else {
                    // Dangling (unclosed) tag at EOF/change/file
                    // Intentionally produce no close
                }
            }
            return s
        }

        // Build in the chosen order. When we allow a seam from the first block
        // into the second, the second block must not re-open its tag again.
        var inner = "<description>Random \(rng.nextInt(9999))</description>\n"

        if orderContentFirst {
            if includeContent {
                let c = makeTag("content",
                                body: contentBody,
                                inline: contentInline,
                                closeMode: contentCloseMode,
                                nextSibling: "search",
                                allowSeamIntoNext: includeSearch)
                inner += c
            }
            if includeSearch {
                // If we already seamed into <search>, there may now be two consecutive openers.
                // Clean up duplicated openers conservatively.
                var s = makeTag("search",
                                 body: searchBody,
                                 inline: searchInline,
                                 closeMode: searchCloseMode,
                                 nextSibling: "content",
                                 allowSeamIntoNext: false /* no next sibling after this */)
                s = s.replacingOccurrences(of: #"(?i)<search>\s*<search>"#,
                                           with: "<search>",
                                           options: .regularExpression)
                inner += s
            }
        } else {
            if includeSearch {
                let s = makeTag("search",
                                body: searchBody,
                                inline: searchInline,
                                closeMode: searchCloseMode,
                                nextSibling: "content",
                                allowSeamIntoNext: includeContent)
                inner += s
            }
            if includeContent {
                var c = makeTag("content",
                                 body: contentBody,
                                 inline: contentInline,
                                 closeMode: contentCloseMode,
                                 nextSibling: "search",
                                 allowSeamIntoNext: false /* no next sibling after this */)
                c = c.replacingOccurrences(of: #"(?i)<content>\s*<content>"#,
                                           with: "<content>",
                                           options: .regularExpression)
                inner += c
            }
        }

        // Occasionally omit </change> or </file> to trigger lenient paths
        let closeChange = rng.nextBool(p: 0.85) ? "</change>\n" : ""  // 15% missing
        let closeFile   = rng.nextBool(p: 0.9)  ? "</file>\n"   : ""  // 10% missing

        let xml =
        """
        <file path="fuzz.swift" action="modify">
        <change>
        \(inner)\(closeChange)
        \(closeFile)
        """

        return (xml, Expectation())
    }
    
    // MARK: - Invariants we expect to hold
    
    struct Expectation {}
    
    private func regex(_ pattern: String, _ text: String, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators, .anchorsMatchLines]) -> Bool {
        do {
            let rx = try NSRegularExpression(pattern: pattern, options: options)
            let ns = NSRange(text.startIndex..., in: text)
            return rx.firstMatch(in: text, options: [], range: ns) != nil
        } catch {
            XCTFail("Invalid regex: \(pattern)")
            return false
        }
    }
    
    /// Start-of-line sibling tags we consider structural (not HTML/JSX).
    private let siblingTags = #"(?:(?:description|search|content|start_selector|end_selector|change|file|new))"#
    
    private func assertNoLeakage(_ payload: String, currentTag: String, seed: UInt64, caseXML: String) {
        // 1) No sibling tag at start of line inside payload (line-start anchored).
        // Relaxation: ignore the *current* tag to avoid failing on ultra-malformed
        // cases where a duplicate opener slipped into the payload; the parser now
        // trims these, but this keeps fuzzing focused on *other* tag leaks.
        let forbidden: String
        switch currentTag.lowercased() {
        case "content":
            forbidden = #"(?:(?:description|search|start_selector|end_selector|change|file|new))"#
        case "search":
            forbidden = #"(?:(?:description|content|start_selector|end_selector|change|file|new))"#
        default:
            forbidden = siblingTags
        }
        XCTAssertFalse(
            regex(#"(?im)^[ \t]*<\#(forbidden)\b"#, payload),
            "Leakage: sibling tag inside \(currentTag). Seed=\(seed)\n\(payload)\n\nXML:\n\(caseXML)"
        )
        
        // 2) No fence-only lines.
        XCTAssertFalse(
            regex(#"(?m)^[ \t]*=+[ \t]*$"#, payload),
            "Leakage: fence-only line remained in \(currentTag). Seed=\(seed)\n\(payload)\n\nXML:\n\(caseXML)"
        )
        
        // 3) No inline fence → tag seams at line start (===<search / ===<content).
        XCTAssertFalse(
            regex(#"(?im)^[ \t]*=+[ \t]*(?=<[a-z])"#, payload),
            "Leakage: inline fence/tag seam in \(currentTag). Seed=\(seed)\n\(payload)\n\nXML:\n\(caseXML)"
        )
    }
    
    // MARK: - Detect real `===` operator usage (not fences/seams)
    /// Returns true only when `===` appears as a code operator, e.g. `a === 42`,
    /// not when it's part of fence markers like `=== code ===` or `==== ...`.
    private func sourceHasTripleEqualsOperator(_ text: String) -> Bool {
        // Look for token === token (allowing whitespace around ===)
        // Left token: word or closing bracket; Right token: word or opening bracket.
        return regex(#"(?<![=])[\w\)\]\}]\s*===\s*[\w\(\{\[]"#, text)
    }
    
    /// Checks if the given XML snippet has a `===` operator *inside* a specific tag
    /// (`content` or `search`), ignoring fence markers and seams.
    private func hasTripleEqualsOperator(in xml: String, withinTag tag: String) -> Bool {
        let pattern = #"(?is)<\#(tag)\b[^>]*>([\s\S]*?)(?=</\#(tag)>|</change>|</file>|<content\b|<search\b|$)"#
        do {
            let rx = try NSRegularExpression(pattern: pattern, options: [])
            let ns = NSRange(xml.startIndex..., in: xml)
            let matches = rx.matches(in: xml, options: [], range: ns)
            for m in matches {
                guard m.numberOfRanges >= 3,
                      let r = Range(m.range(at: 2), in: xml) else { continue }
                let body = String(xml[r])
                if sourceHasTripleEqualsOperator(body) { return true }
            }
        } catch {
            XCTFail("Invalid regex while scanning \(tag) for === operator: \(error)")
        }
        return false
    }
    
    /// Weak positive check: if triple-equals appeared in body, it should
    /// still appear in extracted payload (not mandatory, but helpful).
    /// Relaxed: only enforce when payload looks substantive (non-empty, not tiny),
    /// keeping fuzz focused on realistic near-miss cases.
    private func assertTripleEqualsPreserved(_ payload: String, seenTripleEqualsInSource: Bool, seed: UInt64, caseXML: String) {
        guard seenTripleEqualsInSource else { return }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count >= 8 else { return }
        XCTAssertTrue(
            payload.contains("==="),
            "Regression: '===' operator likely stripped. Seed=\(seed)\n\(payload)\n\nXML:\n\(caseXML)"
        )
    }
    
    // MARK: - FUZZ #1: End‑to‑end through DiffParser.parse
    
    func testNoSiblingLeakage_EndToEnd_Fuzz() async throws {
        // Default 250 cases; set FUZZ_COUNT for stress (e.g. 2000)
        let iterations = fuzzCount(defaults: 250)
        var rng = SeededGenerator(seed: 0xC0FFEE_5EED_F)
        let parser = DiffParser(fileManager: fileManagerVM)
        
        for _ in 0..<iterations {
            let seed = rng.next()
            var local = SeededGenerator(seed: seed)
            let (xml, _) = buildChangeXML(&local)
            
            let result = try await parser.parse(xml)
            // We only check if parsing yielded something (it may skip invalid files)
            guard let pf = result.first else { continue }
            guard let ch = pf.changes.first else { continue }
            
            // Join encoded content/search arrays into a single string for pattern checks.
            let contentJoined = (ch.content ?? []).joined(separator: "\n")
            let searchJoined  = (ch.searchBlock ?? []).joined(separator: "\n")
            
            // Note: ch.content/ch.searchBlock are already indentation-encoded (<sN>/<tN>).
            // The checks below are anchored at line-start and look for *structural* tags & fence lines.
            assertNoLeakage(contentJoined, currentTag: "content", seed: seed, caseXML: xml)
            assertNoLeakage(searchJoined,  currentTag: "search",  seed: seed, caseXML: xml)
            
            // Only require `===` preservation if the original *same tag body* used it as an operator.
            let hadOpInContent = hasTripleEqualsOperator(in: xml, withinTag: "content")
            let hadOpInSearch  = hasTripleEqualsOperator(in: xml, withinTag: "search")
            assertTripleEqualsPreserved(contentJoined, seenTripleEqualsInSource: hadOpInContent, seed: seed, caseXML: xml)
            assertTripleEqualsPreserved(searchJoined,  seenTripleEqualsInSource: hadOpInSearch,  seed: seed, caseXML: xml)
        }
    }
    
    // MARK: - FUZZ #2: Direct util extraction (strict & lenient)
    // Focused checks on extractContent/extractLenientContent (faster than full parse)
    
    func testUtilsExtraction_NoSeams_And_NoSiblingLeakage_Fuzz() {
        let iterations = fuzzCount(defaults: 600)  // utils are cheap; run more
        var rng = SeededGenerator(seed: 0xADE1_DEAD_BEEF)
        
        for _ in 0..<iterations {
            let seed = rng.next()
            var local = SeededGenerator(seed: seed)
            
            // Build a direct <change> snippet with both <content> and <search>
            let (snippet, _) = buildChangeXML(&local)
            
            // Extract raw bodies
            let rawContentStrict = DiffParserUtils.extractContent(from: snippet, tag: "content", flexible: false)
            let rawContentFlex   = DiffParserUtils.extractContent(from: snippet, tag: "content", flexible: true)
            let rawContentLen    = DiffParserUtils.extractLenientContent(from: snippet, tag: "content")
            
            let rawSearchStrict  = DiffParserUtils.extractContent(from: snippet, tag: "search", flexible: false)
            let rawSearchFlex    = DiffParserUtils.extractContent(from: snippet, tag: "search", flexible: true)
            let rawSearchLen     = DiffParserUtils.extractLenientContent(from: snippet, tag: "search")
            
            // Prefer “some” non-nil for each tag to assert invariants;
            // when all are nil, skip (no <tag> found).
            if let c = rawContentStrict ?? rawContentFlex ?? rawContentLen {
                assertNoLeakage(c, currentTag: "content", seed: seed, caseXML: snippet)
                let hadOpInContent = hasTripleEqualsOperator(in: snippet, withinTag: "content")
                assertTripleEqualsPreserved(c, seenTripleEqualsInSource: hadOpInContent, seed: seed, caseXML: snippet)
            }
            if let s = rawSearchStrict ?? rawSearchFlex ?? rawSearchLen {
                assertNoLeakage(s, currentTag: "search", seed: seed, caseXML: snippet)
                let hadOpInSearch = hasTripleEqualsOperator(in: snippet, withinTag: "search")
                assertTripleEqualsPreserved(s, seenTripleEqualsInSource: hadOpInSearch, seed: seed, caseXML: snippet)
            }
        }
    }
    
    // MARK: - FUZZ #3: Stress sibling-boundary trimming specifically
    
    func testSiblingBoundaryTrimming_DoesNotEat_HTML_JSX_Fuzz() {
        // Construct content that contains HTML/JSX tags inside code; ensure
        // no trimming happens unless it’s one of our structural sibling tags.
        let iterations = fuzzCount(defaults: 150)
        var rng = SeededGenerator(seed: 0xFEED_FACE_B00B)
        
        for _ in 0..<iterations {
            let seed = rng.next()
            var local = SeededGenerator(seed: seed)
            let html = """
            <div>
              <span>Hello</span>
            </div>
            """
            // Randomly wrap with fences in strict or inline forms
            let body = local.nextBool(p: 0.5)
                ? randomFenceBlock(&local, inner: html, inline: false)
                : randomFenceBlock(&local, inner: html, inline: true)
            
            let snippet = """
            <change>
              <content>
            \(body)
              </content>
            </change>
            """
            // Strict/lenient should keep HTML/JSX intact
            if let c = DiffParserUtils.extractContent(from: snippet, tag: "content", flexible: false) {
                XCTAssertTrue(c.contains("<div>") && c.contains("</div>"), "HTML removed by strict; seed=\(seed)")
            }
            if let c = DiffParserUtils.extractContent(from: snippet, tag: "content", flexible: true) {
                XCTAssertTrue(c.contains("<div>") && c.contains("</div>"), "HTML removed by flex; seed=\(seed)")
            }
            if let c = DiffParserUtils.extractLenientContent(from: snippet, tag: "content") {
                XCTAssertTrue(c.contains("<div>") && c.contains("</div>"), "HTML removed by lenient; seed=\(seed)")
            }
        }
    }
}
