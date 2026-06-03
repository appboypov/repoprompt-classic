import XCTest
@testable import RepoPrompt

final class CodeMapPCRE2RegexTests: XCTestCase {
	private static func asciiLineText(in subject: String, range: Range<Int>) -> String {
		let bytes = Array(subject.utf8)
		return String(decoding: bytes[range], as: UTF8.self)
	}

	func testCapturesAfterMultibyteCharacters() {
		let pattern = CodeMapPCRE2Pattern(#"😀\s+(\p{L}+)"#)

		let match = pattern.firstMatch(in: "prefix 😀 café suffix")

		XCTAssertEqual(match?.capture(1), "café")
	}

	func testReplacingAroundMultibyteCharacters() {
		let pattern = CodeMapPCRE2Pattern(#"TYPE"#)

		let replaced = pattern.replacingMatches(in: "π TYPE café TYPE 🚀", with: "T")

		XCTAssertEqual(replaced, "π T café T 🚀")
	}

	func testNoMatchReplacementPreservesOriginalString() {
		let pattern = CodeMapPCRE2Pattern(#"MISSING"#)
		let original = "π café 🚀"

		XCTAssertEqual(pattern.replacingMatches(in: original, with: "T"), original)
	}

	func testWholeMatchUsesEntireSubjectByteRange() {
		let pattern = CodeMapPCRE2Pattern(#"[A-Z]+"#)

		XCTAssertTrue(pattern.wholeMatch(in: "ABC"))
		XCTAssertFalse(pattern.wholeMatch(in: "ABC\n"))
		XCTAssertFalse(pattern.wholeMatch(in: "xABC"))
	}

	func testUnicodeAndCaseInsensitiveOptionsAreEnabled() {
		let unicodePattern = CodeMapPCRE2Pattern(#"^(\p{L}+)$"#)
		let keywordPattern = CodeMapPCRE2Pattern(#"some"#, caseInsensitive: true)

		XCTAssertEqual(unicodePattern.firstCapture(in: "Éclair"), "Éclair")
		XCTAssertTrue(keywordPattern.wholeMatch(in: "SOME"))
	}

	func testOptionalCapturesRemainNilAfterUTF8OffsetConversion() {
		let pattern = CodeMapPCRE2Pattern(#"😀\s+(foo)?(bar)"#)

		let match = pattern.firstMatch(in: "prefix 😀 bar suffix")

		XCTAssertNil(match?.capture(1))
		XCTAssertEqual(match?.capture(2), "bar")
	}

	func testCapturesCanEndInsideSwiftGraphemeCluster() {
		let pattern = CodeMapPCRE2Pattern(#"^(\p{L}+)"#)

		let match = pattern.firstMatch(in: "Cafe\u{301}")

		XCTAssertEqual(match?.capture(1), "Cafe")
	}

	func testPCRE2JITEnvironmentDisablesDefaultJITMode() throws {
		try withEnvironmentVariable("REPOPROMPT_PCRE2_JIT", value: "disabled") {
			XCTAssertEqual(RepoPromptRegexRuntime.pcre2JITMode, .disabled)

			let request = RepoPromptPCRE2CompileRequest(
				pattern: "literal",
				caseInsensitive: false,
				multilineAnchors: false
			)
			let regex = try RepoPromptPCRE2Adapter.compile(request)

			XCTAssertEqual(request.jitMode, .disabled)
			XCTAssertEqual(regex.jitStatus, .disabled)
		}
	}

	func testPCRE2JITEnvironmentAcceptsRequiredAndDefaultsToAuto() throws {
		try withEnvironmentVariable("REPOPROMPT_PCRE2_JIT", value: "required") {
			XCTAssertEqual(RepoPromptRegexRuntime.pcre2JITMode, .required)
		}

		try withEnvironmentVariable("REPOPROMPT_PCRE2_JIT", value: "unexpected") {
			XCTAssertEqual(RepoPromptRegexRuntime.pcre2JITMode, .auto)
		}
	}

	func testPCRE2EnumerateMatchesPreservesUTF8ByteRanges() throws {
		let regex = try PCRE2Regex("a", jit: .disabled)
		let subject = "π a 😀a café"
		var ranges: [Range<Int>] = []

		try regex.enumerateMatches(in: subject) { match in
			ranges.append(match.byteRange)
			return true
		}

		XCTAssertEqual(ranges, [3..<4, 9..<10, 12..<13])
	}

	func testPCRE2EnumerateMatchesReusesSubjectSafelyAcrossMultipleMatches() throws {
		let regex = try PCRE2Regex("item", jit: .disabled)
		let subject = Array(repeating: "item", count: 64).joined(separator: " ")
		var ranges: [Range<Int>] = []

		try regex.enumerateMatches(in: subject) { match in
			ranges.append(match.byteRange)
			return true
		}

		XCTAssertEqual(ranges.count, 64)
		XCTAssertEqual(ranges.first, 0..<4)
		XCTAssertEqual(ranges.last, 315..<319)
	}

	func testPCRE2SubstringFirstMatchReturnsRangesRelativeToSubstring() throws {
		let regex = try PCRE2Regex("needle", jit: .disabled)
		let base = "prefix 😀 needle suffix"
		let substring = base[base.firstIndex(of: "😀")!...]

		let match = try regex.firstMatch(in: substring)

		XCTAssertEqual(match?.byteRange, 5..<11)
	}

	func testPCRE2ZeroLengthEnumerationAdvancesAcrossUnicodeScalars() throws {
		let regex = try PCRE2Regex("", jit: .disabled)
		var ranges: [Range<Int>] = []

		try regex.enumerateMatches(in: "aé😀") { match in
			ranges.append(match.byteRange)
			return true
		}

		XCTAssertEqual(ranges, [0..<0, 1..<1, 3..<3, 7..<7])
	}

	func testPCRE2MatchSessionContainsMatchAcrossMultipleSubjects() throws {
		let regex = try PCRE2Regex(#"\b(?:TODO|FIXME)-\d+\b"#, jit: .disabled)

		try regex.withMatchSession { session in
			XCTAssertTrue(try session.containsMatch(in: "// TODO-123: fix"))
			XCTAssertTrue(try session.containsMatch(in: "// FIXME-9: fix"))
			XCTAssertFalse(try session.containsMatch(in: "// NOTE-123: ignore"))

			let base = "prefix 😀 TODO-456 suffix"
			let substring = base[base.firstIndex(of: "😀")!...]
			XCTAssertTrue(try session.containsMatch(in: substring))
		}
	}

	func testPCRE2MatchSessionFirstMatchCopiesRangesAcrossReuse() throws {
		let regex = try PCRE2Regex(#"(needle)(\d+)"#, jit: .disabled)

		try regex.withMatchSession { session in
			let first = try XCTUnwrap(session.firstMatch(in: "prefix needle123 suffix"))
			let second = try XCTUnwrap(session.firstMatch(in: "π needle45"))

			XCTAssertEqual(first.byteRange, 7..<16)
			XCTAssertEqual(first.captureByteRanges, [7..<16, 7..<13, 13..<16])
			XCTAssertEqual(second.byteRange, 3..<11)
			XCTAssertEqual(second.captureByteRanges, [3..<11, 3..<9, 9..<11])
		}
	}

	func testPCRE2MatchSessionMatchLimitExceededMapsToPCRE2Error() throws {
		let regex = try PCRE2Regex(#"^(a|aa)+$"#, jit: .disabled)
		let subject = String(repeating: "a", count: 80) + "b"

		XCTAssertThrowsError(
			try regex.withMatchSession(matchLimits: PCRE2MatchLimits(matchLimit: 1, depthLimit: 10, heapLimitKiB: 1024)) { session in
				try session.containsMatch(in: subject)
			}
		) { error in
			guard case let PCRE2Error.matchLimitExceeded(kind, _, _) = error else {
				return XCTFail("Expected PCRE2Error.matchLimitExceeded, got \(error)")
			}
			XCTAssertEqual(kind, .match)
		}
	}

	func testPCRE2DirectJITMatchSessionMatchesWhenAvailable() throws {
		let jitMode: PCRE2JITMode = PCRE2BuildConfiguration.isJITSupported ? .required : .auto
		let regex = try PCRE2Regex(#"\bTODO-\d+\b"#, jit: jitMode)

		try regex.withMatchSession { session in
			XCTAssertTrue(try session.containsMatch(in: "// TODO-123: fix"))
			XCTAssertFalse(try session.containsMatch(in: "// NOTE-123: ignore"))
		}
	}

	func testPCRE2MatchSessionMatchLimitExceededWithDefaultJITMode() throws {
		let regex = try PCRE2Regex(#"^(a|aa)+$"#)
		let subject = String(repeating: "a", count: 80) + "b"

		XCTAssertThrowsError(
			try regex.withMatchSession(matchLimits: PCRE2MatchLimits(matchLimit: 1, depthLimit: 10, heapLimitKiB: 1024)) { session in
				try session.containsMatch(in: subject)
			}
		) { error in
			guard case let PCRE2Error.matchLimitExceeded(kind, _, _) = error else {
				return XCTFail("Expected PCRE2Error.matchLimitExceeded, got \(error)")
			}
			XCTAssertEqual(kind, .match)
		}
	}

	func testPCRE2ASCIIMarkerLinePatternFindsTodoStyleMatches() throws {
		let pattern = try XCTUnwrap(PCRE2ASCIIMarkerLinePattern(marker: "TODO", digitCount: 3, requiredPrefix: "Search", caseInsensitive: false))
		let result = pattern.scanMatchingLines(
			in: "note\nTODO-123: SearchThing\nother TODO-x TODO-456: SearchLater\nTODO-789:\nSearchAcross\n",
			collectMatches: true
		)

		XCTAssertEqual(result?.matchingLineNumbers, [1, 2, 3])
		XCTAssertEqual(result?.lineMatchCount, 3)
		XCTAssertNil(pattern.scanMatchingLines(in: "café\nTODO-123: SearchThing", collectMatches: true))
		XCTAssertNil(pattern.scanMatchingLines(in: "TODO-123: SearchThing\ncafé\nTODO-456: SearchLater", collectMatches: true))
	}

	func testPCRE2ASCIIMarkerLinePatternCollectsDenseAndBoundedMatches() throws {
		let pattern = try XCTUnwrap(PCRE2ASCIIMarkerLinePattern(marker: "TODO", digitCount: 3, requiredPrefix: "Search", caseInsensitive: false))
		let subject = (0 ..< 80).map { index in
			let number = String(index % 1000)
			let padded = String(repeating: "0", count: 3 - number.count) + number
			return "TODO-\(padded): SearchThing"
		}.joined(separator: "\n")

		let all = pattern.scanMatchingLines(in: subject, collectMatches: true)
		XCTAssertEqual(all?.matchingLineNumbers, Array(0 ..< 80))
		XCTAssertEqual(all?.lineMatchCount, 80)

		let bounded = pattern.scanMatchingLines(in: subject, collectMatches: true, maxCollectedMatches: 5)
		XCTAssertEqual(bounded?.matchingLineNumbers, Array(0 ..< 5))
		XCTAssertEqual(bounded?.lineMatchCount, 80)
	}

	func testPCRE2ASCIIMarkerLineRangePatternFindsTodoStyleMatches() throws {
		let pattern = try XCTUnwrap(PCRE2ASCIIMarkerLinePattern(marker: "TODO", digitCount: 3, requiredPrefix: "Search", caseInsensitive: false))
		let subject = "note\nTODO-123: SearchThing\nother TODO-x TODO-456: SearchLater\nTODO-789:\nSearchAcross\n"

		let result = pattern.scanMatchingLineRanges(in: subject, maxCollectedMatches: 10)

		XCTAssertEqual(result?.hits.map(\.lineNumber), [1, 2, 3])
		XCTAssertEqual(result?.lineMatchCount, 3)
		XCTAssertEqual(result?.hits.map { Self.asciiLineText(in: subject, range: $0.byteRange) }, [
			"TODO-123: SearchThing",
			"other TODO-x TODO-456: SearchLater",
			"TODO-789:"
		])
	}

	func testPCRE2ASCIIMarkerLineRangePatternDeduplicatesAndBoundsMatches() throws {
		let pattern = try XCTUnwrap(PCRE2ASCIIMarkerLinePattern(marker: "TODO", digitCount: 3, requiredPrefix: "Search", caseInsensitive: false))
		let subject = "TODO-123: SearchOne and TODO-456: SearchTwo\nTODO-789: SearchThree\n"

		let result = pattern.scanMatchingLineRanges(in: subject, maxCollectedMatches: 1)

		XCTAssertEqual(result?.hits.map(\.lineNumber), [0])
		XCTAssertEqual(result?.lineMatchCount, 2)
		XCTAssertEqual(result?.hits.first.map { Self.asciiLineText(in: subject, range: $0.byteRange) }, "TODO-123: SearchOne and TODO-456: SearchTwo")
	}

	func testPCRE2ASCIIMarkerLineRangePatternCaseInsensitiveCRLFAndNonASCII() throws {
		let pattern = try XCTUnwrap(PCRE2ASCIIMarkerLinePattern(marker: "TODO", digitCount: 3, requiredPrefix: "Search", caseInsensitive: true))
		let subject = "zero\r\ntodo-123: searchThing\rnext TODO-456: SEARCHAgain"

		let result = pattern.scanMatchingLineRanges(in: subject, maxCollectedMatches: 10)

		XCTAssertEqual(result?.hits.map(\.lineNumber), [1, 2])
		XCTAssertEqual(result?.hits.map { Self.asciiLineText(in: subject, range: $0.byteRange) }, ["todo-123: searchThing", "next TODO-456: SEARCHAgain"])
		XCTAssertNil(pattern.scanMatchingLineRanges(in: "TODO-123: searchThing\ncafé", maxCollectedMatches: 10))
	}

	func testPCRE2ASCIIMarkerLineRangePatternCRLFCrossesWordBoundary() throws {
		let pattern = try XCTUnwrap(PCRE2ASCIIMarkerLinePattern(marker: "TODO", digitCount: 3, requiredPrefix: "Search", caseInsensitive: false))
		let wordSize = MemoryLayout<UInt>.size

		for paddingLength in [wordSize - 1, (wordSize * 2) - 1, (wordSize * 3) - 1] {
			let subject = String(repeating: "a", count: paddingLength) + "\r\nTODO-123: SearchThing"
			let lineResult = pattern.scanMatchingLines(in: subject, collectMatches: true)
			let rangeResult = pattern.scanMatchingLineRanges(in: subject, maxCollectedMatches: 10)

			XCTAssertEqual(lineResult?.matchingLineNumbers, [1], "paddingLength=\(paddingLength)")
			XCTAssertEqual(lineResult?.lineMatchCount, 1, "paddingLength=\(paddingLength)")
			XCTAssertEqual(rangeResult?.hits.map(\.lineNumber), [1], "paddingLength=\(paddingLength)")
			XCTAssertEqual(rangeResult?.hits.map { Self.asciiLineText(in: subject, range: $0.byteRange) }, ["TODO-123: SearchThing"], "paddingLength=\(paddingLength)")
		}
	}

	func testPCRE2LineScannerCRLFAndCRLineNumbers() throws {
		let regex = try PCRE2Regex("match", jit: .disabled)
		let subject = "zero\r\none\nmatch\rthree"

		let result = try regex.withMatchSession { session in
			try session.scanMatchingLines(in: subject, options: PCRE2LineScanOptions())
		}

		XCTAssertEqual(result.matchingLineNumbers, [2])
		XCTAssertEqual(result.lineMatchCount, 1)
	}

	func testPCRE2LineScannerMultibytePrefixAndAnchoredNoCrossLine() throws {
		let needle = try PCRE2Regex(#"needle\s+here"#, jit: .disabled)
		let needleResult = try needle.withMatchSession { session in
			try session.scanMatchingLines(in: "emoji 😀 prefix\nneedle here\n", options: PCRE2LineScanOptions())
		}
		XCTAssertEqual(needleResult.matchingLineNumbers, [1])

		let anchored = try PCRE2Regex(#"^foo\s+bar$"#, jit: .disabled)
		let anchoredResult = try anchored.withMatchSession { session in
			try session.scanMatchingLines(in: "foo\nbar\n", options: PCRE2LineScanOptions())
		}
		XCTAssertTrue(anchoredResult.matchingLineNumbers.isEmpty)
		XCTAssertEqual(anchoredResult.lineMatchCount, 0)
	}

	func testPCRE2LineScannerLongLineSkipAndCountOnly() throws {
		let regex = try PCRE2Regex("needle", jit: .disabled)
		let result = try regex.withMatchSession { session in
			try session.scanMatchingLines(
				in: "short needle\nvery long needle\nneedle again",
				options: PCRE2LineScanOptions(maxLineUTF8Length: 12, collectMatches: false)
			)
		}
		XCTAssertTrue(result.matchingLineNumbers.isEmpty)
		XCTAssertEqual(result.lineMatchCount, 2)
	}

	func testPCRE2ASCIIWholeWordLiteralScannerEligibilityAndFallbackSignal() throws {
		let literal = try XCTUnwrap(PCRE2ASCIIWholeWordLiteral(needle: "SearchResult", caseInsensitive: false))
		let result = literal.scanMatchingLines(
			in: "SearchResult\nSearchResultEnvelope\nmy SearchResult here\n",
			collectMatches: true
		)
		XCTAssertEqual(result?.matchingLineNumbers, [0, 2])
		XCTAssertNil(literal.scanMatchingLines(in: "café SearchResult", collectMatches: true))
		XCTAssertNil(PCRE2ASCIIWholeWordLiteral(needle: "café", caseInsensitive: true))
	}

	func testPCRE2PathSuffixPatternMatching() {
		let suffix = PCRE2PathSuffixPattern(suffixes: [".js", ".swift"])
		XCTAssertTrue(suffix.matches("Sources/App.swift", caseInsensitive: false))
		XCTAssertTrue(suffix.matches("Sources/App.JS", caseInsensitive: true))
		XCTAssertFalse(suffix.matches("Sources/App.JS", caseInsensitive: false))

		let generated = PCRE2PathSuffixPattern(
			suffixes: [".swift"],
			basenamePrefix: "GeneratedSearchFile_0",
			singleDigitRange: UInt8(ascii: "0")...UInt8(ascii: "7")
		)
		XCTAssertTrue(generated.matches("Smoke/Search/GeneratedSearchFile_07.swift", caseInsensitive: false))
		XCTAssertTrue(generated.matches("Smoke/Search/XGeneratedSearchFile_07.swift", caseInsensitive: false))
		XCTAssertFalse(generated.matches("Smoke/Search/Other_07.swift", caseInsensitive: false))
		XCTAssertFalse(generated.matches("Smoke/Search/GeneratedSearchFile_09.swift", caseInsensitive: false))
	}

	func testPCRE2ConcurrentMatchingOnSharedRegex() async throws {
		let regex = try PCRE2Regex(#"[A-Z]+\d+"#, jit: .disabled)

		try await withThrowingTaskGroup(of: Range<Int>?.self) { group in
			for index in 0..<32 {
				group.addTask {
					let subject = "prefix VALUE\(index) suffix"
					return try regex.firstMatch(in: subject)?.byteRange
				}
			}

			var count = 0
			while let range = try await group.next() {
				XCTAssertNotNil(range)
				XCTAssertEqual(range?.lowerBound, 7)
				count += 1
			}
			XCTAssertEqual(count, 32)
		}
	}

	func testPCRE2MatchLimitExceededMapsToPCRE2Error() throws {
		let regex = try PCRE2Regex(#"^(a|aa)+$"#, jit: .disabled)
		let subject = String(repeating: "a", count: 80) + "b"

		XCTAssertThrowsError(
			try regex.firstMatch(in: subject, matchLimits: PCRE2MatchLimits(matchLimit: 1, depthLimit: 10, heapLimitKiB: 1024))
		) { error in
			guard case let PCRE2Error.matchLimitExceeded(kind, _, _) = error else {
				return XCTFail("Expected PCRE2Error.matchLimitExceeded, got \(error)")
			}
			XCTAssertEqual(kind, .match)
		}
	}

	func testPCRE2MatchLimitEnvironmentDisablesPolicy() throws {
		try withEnvironmentVariable("REPOPROMPT_PCRE2_MATCH_LIMITS", value: "disabled") {
			XCTAssertFalse(RepoPromptRegexRuntime.pcre2SearchMatchLimitsEnabled)
			XCTAssertNil(RepoPromptPCRE2MatchPolicy.fileSearchLine)
		}

		try withEnvironmentVariable("REPOPROMPT_PCRE2_MATCH_LIMITS", value: nil) {
			XCTAssertTrue(RepoPromptRegexRuntime.pcre2SearchMatchLimitsEnabled)
			XCTAssertNotNil(RepoPromptPCRE2MatchPolicy.fileSearchLine)
		}
	}

	private func withEnvironmentVariable(_ name: String, value: String?, _ body: () throws -> Void) rethrows {
		let oldValue = getenv(name).map { String(cString: $0) }
		if let value {
			setenv(name, value, 1)
		} else {
			unsetenv(name)
		}
		defer {
			if let oldValue {
				setenv(name, oldValue, 1)
			} else {
				unsetenv(name)
			}
		}
		try body()
	}
}
