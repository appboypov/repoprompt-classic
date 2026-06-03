import XCTest
@testable import RepoPrompt

final class BenchmarkFeasibility_EdgeAndNoiseTests: XCTestCase {
	// MARK: - Helpers

	private func verifyFail(_ spec: BenchmarkTaskSpec,
							 baselineFiles: [String: String],
							 editedFiles: [BenchmarkEditedFile],
							 expectedReasonContains: String,
							 file: StaticString = #file, line: UInt = #line) {
		let baseline = BenchmarkMockFileSystemSnapshot(files: baselineFiles)
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(errors: [], edited: editedFiles, meta: nil)
		)
		let out = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(out.pass, "Expected failure but passed", file: file, line: line)
		XCTAssertTrue(out.reason.contains(expectedReasonContains),
					  "Expected reason to contain '\(expectedReasonContains)', got: \(out.reason)",
					  file: file, line: line)
	}

	// MARK: - insert_guard: tabFound and collateral change

	func testInsertGuard_TabFound_Fails() {
		let uid = "TAB1"
		let path = "src/ts/work/Work.ts"
		let snippet = """
if (n < 0) {
	return 0;
}
"""
		let baseline = """
export function clamp(n: number): number {
    // ANCHOR:start:\(uid)

    // ANCHOR:end:\(uid)
    return Math.abs(n);
}
"""
		let final = """
export function clamp(n: number): number {
    // ANCHOR:start:\(uid)
    if (n < 0) {
		return 0;
	}
    // ANCHOR:end:\(uid)
    return Math.abs(n);
}
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_guard_ts",
			type: .insertGuardTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "tab")
	}

	func testInsertGuard_CollateralInsideAnchors_Fails() {
		let uid = "COLL"
		let path = "src/swift/work/Work.swift"
		let snippet = """
if n < 0 {
	return 0
}
"""
		let baseline = """
public func clamp(_ n: Int) -> Int {
	// ANCHOR:start:\(uid)
	let normalized = abs(n)
	// ANCHOR:end:\(uid)
	return normalized
}
"""
		let final = """
public func clamp(_ n: Int) -> Int {
	// ANCHOR:start:\(uid)
	if n < 0 {
		return 0
	}
	let normalized = abs(n) + 1
	// ANCHOR:end:\(uid)
	return normalized
}
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_guard_swift",
			type: .insertGuardSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "collateral")
	}

	// MARK: - patch_block: mismatch allowed similarity (non-pass)

	func testPatchBlock_Ts_SimilarButNotExact_FailsWithSimilarityMetrics() {
		let uid = "PBAD"
		let path = "src/ts/work/Work.ts"
		let snippet = """
export function block2(n: number): number {
    const squared = n * n;
    return squared;
}
"""
		let baseline = """
/* BLOCK START:\(uid) */
export function block2(n: number): number {
    return n * 2;
}
/* BLOCK END:\(uid) */
"""
		let final = """
/* BLOCK START:\(uid) */
export function block2(n: number): number {
    const t = n * n;
    return t + 0;
}
/* BLOCK END:\(uid) */
"""
		let spec = BenchmarkTaskSpec(
			id: "patch_block_ts",
			type: .patchBlockTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)
		let baselineSnap = BenchmarkMockFileSystemSnapshot(files: [path: baseline])
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baselineSnap,
			result: BenchmarkTaskExecResult(errors: [], edited: [BenchmarkEditedFile(path: path, content: final)], meta: nil)
		)
		let out = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(out.pass)
		XCTAssertEqual(out.reason, "blockMismatch")
		XCTAssertNotNil(out.metrics["tokenSimilarity"])
	}

	// MARK: - swap_args outsideChanged fails

	func testSwapArgs_OutsideChanged_Fails() {
		let uid = "SOUT"
		let path = "src/go/work/Work.go"
		let baseline = """
package work

func use(a, b string) string { return a + b }

func Render() string {
	out := ""
	/* START_SWAP:\(uid) */
	out += use("a0", "b0")
	/* END_SWAP:\(uid) */
	out += use("outsideA", "outsideB")
	return out
}
"""
		let final = """
package work

func use(a, b string) string { return a + b }

func Render() string {
	out := ""
	/* START_SWAP:\(uid) */
	out += use("b0", "a0")
	/* END_SWAP:\(uid) */
	out += use("bOutside", "aOutside")
	return out
}
"""
		let spec = BenchmarkTaskSpec(
			id: "swap_args_in_region_go",
			type: .swapArgsInRegionGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "expectedSwaps": .integer(1)]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "outsideChanged")
	}

	// MARK: - index_only marker outside function fails

	func testIndexOnly_MarkerOutsideFunction_Fails() {
		let target = "appB"
		let path = "apps/\(target)/src/index.ts"
		let baseline = "export default function index() {\n\treturn \"\(target)\";\n}"
		let final = """
export default function index() {
	return "\(target)";
}
// DONE:\(target)
"""
		let spec = BenchmarkTaskSpec(
			id: "index_only_apps_ts",
			type: .indexOnlyAppsTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"target": .string(target),
				"otherPaths": .array([])
			]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "doneMarkerMissing")
	}

	// MARK: - move_function collateral change fails

	func testMoveFunction_CollateralChange_Fails() {
		let path = "src/swift/reorder/Order.swift"
		let baseline = """
public func alpha(_ n: Int) -> Int { return n * 1 }

public func bravo(_ n: Int) -> Int { return n * 2 }

// FOOTER: keep below here unchanged
"""
		let final = """
public func bravo(_ n: Int) -> Int { return n * 3 } // mutated!

public func alpha(_ n: Int) -> Int { return n * 1 }

// FOOTER: keep below here unchanged
"""
		let spec = BenchmarkTaskSpec(
			id: "move_function_swift",
			type: .moveFunctionSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["fromName": .string("alpha"), "afterName": .string("bravo")]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "collateralChange")
	}

	// MARK: - insert_function_bottom wrong placement fails

	func testInsertFunctionBottom_WrongPlacement_Fails() {
		let path = "src/ts/work/Work.ts"
		let footer = "// END-OF-FILE (append new functions immediately above this line)"
		let baseline = """
export function ping(x: string): string { return `ping:${x}`; }

export function pong(y: number): number { return y + 1; }

\(footer)
"""
		let snippet = "export const add = (a: number, b: number) => a + b;"
		let final = """
export function ping(x: string): string { return `ping:${x}`; }

export function pong(y: number): number { return y + 1; }

\(footer)

\(snippet)
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_function_bottom_ts",
			type: .insertFunctionBottomTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"snippet": .string(snippet),
				"footer": .string("// END-OF-FILE")
			]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "wrongPlacement")
	}

	// MARK: - remove_x near-miss changes penalize (should fail score threshold)

	func testRemoveX_NearMissChanged_Fails() {
		let path = "src/ts/Alpha.ts"
		let baseline = """
CALL_X(1);
call_x(1); // near miss
"""
		let final = """
// cleaned
"""
		let spec = BenchmarkTaskSpec(
			id: "remove_x_ts",
			type: .removeXTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(path), "target": .string("CALL_X(")]
		)
		let baselineSnap = BenchmarkMockFileSystemSnapshot(files: [path: baseline])
		let exec = BenchmarkTaskExecution(task: spec,
										 baseline: baselineSnap,
										 result: BenchmarkTaskExecResult(errors: [],
										 	edited: [BenchmarkEditedFile(path: path, content: final)],
										 	meta: nil))
		let out = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(out.pass)
		XCTAssertEqual(out.reason, "nearMissChanged")
		XCTAssertLessThan(out.score, 0.8)
	}

	// MARK: - DiffApplier policy checks

	func testRenameBarrelTwoLineSearch_ApplierAllowsTwoLines() async {
		let path = "src/ts/lib/index.ts"
		let baseline = """
export { OldX } from "./exporter";
export * as All from "./exporter";
"""
		var fs = BenchmarkMockFileSystem(files: [path: baseline])
		let baselineSnap = fs.snapshot()

		let change = Change(
			id: UUID(),
			type: .modify,
			summary: "rename barrel",
			isSelected: true,
			content: [
				"export { NewX } from \"./exporter\";",
				"export * as All from \"./exporter\";"
			],
			startSelector: nil,
			endSelector: nil,
			searchBlock: [
				"export { OldX } from \"./exporter\";",
				"export * as All from \"./exporter\";"
			]
		)
		let parsed = ParsedFile(fileName: path,
							 changes: [change],
							 fileContent: "",
							 canBeLoaded: true,
							 action: .modify,
							 lineEnding: "\n")
		let spec = BenchmarkTaskSpec(
			id: "rename_export_and_imports_ts_apply",
			type: .renameExportImportsTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"rename": .object(["from": .string("OldX"), "to": .string("NewX")]),
				"importPaths": .array([])
			]
		)

		let result = await BenchmarkDiffApplier.apply(parsedFiles: [parsed],
												 task: spec,
												 fileSystem: &fs,
												 baseline: baselineSnap)
		XCTAssertTrue(result.errors.isEmpty, "Unexpected errors: \(result.errors)")
		let newText = fs.content(for: path) ?? ""
		XCTAssertTrue(newText.contains("export { NewX }"),
					  "Expected updated barrel export, got:\n\(newText)")
	}

	func testApplier_LongSearchBlock_Pass() async {
		// Long search blocks should now be allowed (no upper limit)
		let path = "src/ts/sample.ts"
		let baseline = """
function f() {
	let x = 0;
	// region
	line1
	line2
	line3
	line4
	line5
	line6
	line7
}
"""
		var fs = BenchmarkMockFileSystem(files: [path: baseline])
		let baselineSnap = fs.snapshot()
		let longSearch = [
			"\t// region",
			"\tline1",
			"\tline2",
			"\tline3",
			"\tline4",
			"\tline5",
			"\tline6",
			"\tline7",
			"}"
		]
		let content = longSearch.map { $0.replacingOccurrences(of: "line", with: "LINE") }

		let change = Change(id: UUID(), type: .modify, summary: "long search ok", isSelected: true, content: content, startSelector: nil, endSelector: nil, searchBlock: longSearch)
		let parsed = ParsedFile(fileName: path, changes: [change], fileContent: "", canBeLoaded: true, action: .modify, lineEnding: "\n")
		let spec = BenchmarkTaskSpec(id: "swap_args_ts_long", type: .swapArgsInRegionTs, language: .ts, selectFiles: [path], maxEdits: 2, instructions: [], task: "", acceptance: [], params: [:])

		let result = await BenchmarkDiffApplier.apply(parsedFiles: [parsed], task: spec, fileSystem: &fs, baseline: baselineSnap)
		XCTAssertTrue(result.errors.isEmpty, "Long search blocks should now be allowed, errors: \(result.errors)")
		let newText = fs.content(for: path) ?? ""
		XCTAssertTrue(newText.contains("LINE1"), "Expected updated content")
	}

	func testApplierRejectsReusedSearchBlock() async {
		let path = "src/ts/sample2.ts"
		let baseline = """
let x = 1
let y = 2
let z = 3
let a = 4
let b = 5
"""
		var fs = BenchmarkMockFileSystem(files: [path: baseline])
		let baselineSnap = fs.snapshot()
		let search = ["let x = 1", "let y = 2", "let z = 3", "let a = 4", "let b = 5"]

		let ch1 = Change(id: UUID(), type: .modify, summary: "c1", isSelected: true, content: ["let x = 10", "let y = 2", "let z = 3", "let a = 4", "let b = 5"], startSelector: nil, endSelector: nil, searchBlock: search)
		let ch2 = Change(id: UUID(), type: .modify, summary: "c2", isSelected: true, content: ["let x = 100", "let y = 2", "let z = 3", "let a = 4", "let b = 5"], startSelector: nil, endSelector: nil, searchBlock: search)

		let parsed = ParsedFile(fileName: path, changes: [ch1, ch2], fileContent: "", canBeLoaded: true, action: .modify, lineEnding: "\n")
		let spec = BenchmarkTaskSpec(id: "swap_args_ts_reuse", type: .swapArgsInRegionTs, language: .ts, selectFiles: [path], maxEdits: 3, instructions: [], task: "", acceptance: [], params: [:])

		let result = await BenchmarkDiffApplier.apply(parsedFiles: [parsed], task: spec, fileSystem: &fs, baseline: baselineSnap)
		XCTAssertFalse(result.errors.isEmpty)
		XCTAssertTrue(result.errors.contains { $0.code == "EDIT_APPLY_FAILED" && ($0.detail ?? "").contains("reusedSearchBlock") })
	}

	// MARK: - Indentation Validation Tests

	func testInsertGuard_Swift_SpacesRejected() {
		// Swift should use tabs, not spaces for indentation
		let uid = "IND1"
		let path = "src/swift/work/Work.swift"
		let snippet = """
if n < 0 {
    return 0
}
"""
		let baseline = """
public func clamp(_ n: Int) -> Int {
	// ANCHOR:start:\(uid)
	let normalized = abs(n)
	// ANCHOR:end:\(uid)
	return normalized
}
"""
		let final = """
public func clamp(_ n: Int) -> Int {
	// ANCHOR:start:\(uid)
	if n < 0 {
	    return 0
	}
	let normalized = abs(n)
	// ANCHOR:end:\(uid)
	return normalized
}
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_guard_swift",
			type: .insertGuardSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "wrongIndentationStyle")
	}

	func testInsertGuard_Go_TabsRejected() {
		// Go should use spaces, not tabs
		let uid = "IND2"
		let path = "src/go/work/Work.go"
		let snippet = """
if n < 0 {
	return 0
}
"""
		let baseline = """
package work

func Clamp(n int) int {
    // ANCHOR:start:\(uid)
    normalized := n
    // ANCHOR:end:\(uid)
    return normalized
}
"""
		let final = """
package work

func Clamp(n int) int {
    // ANCHOR:start:\(uid)
    if n < 0 {
		return 0
	}
    normalized := n
    // ANCHOR:end:\(uid)
    return normalized
}
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_guard_go",
			type: .insertGuardGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "tabFound")
	}

	func testInsertGuard_Ts_TabsRejected() {
		// TypeScript should use spaces, not tabs
		let uid = "IND3"
		let path = "src/ts/work/Work.ts"
		let snippet = """
if (n < 0) {
	return 0;
}
"""
		let baseline = """
export function clamp(n: number): number {
    // ANCHOR:start:\(uid)
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid)
    return normalized;
}
"""
		let final = """
export function clamp(n: number): number {
    // ANCHOR:start:\(uid)
    if (n < 0) {
		return 0;
	}
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid)
    return normalized;
}
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_guard_ts",
			type: .insertGuardTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "tabFound")
	}

	func testInsertGuard_MixedIndentation_Fails() {
		// Mixed tabs and spaces should fail
		let uid = "IND4"
		let path = "src/ts/work/Work.ts"
		let snippet = """
if (n < 0) {
    return 0;
	}
"""
		let baseline = """
export function clamp(n: number): number {
    // ANCHOR:start:\(uid)
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid)
    return normalized;
}
"""
		let final = """
export function clamp(n: number): number {
    // ANCHOR:start:\(uid)
    if (n < 0) {
        return 0;
	}
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid)
    return normalized;
}
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_guard_ts",
			type: .insertGuardTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "tabFound")
	}

	// MARK: - Scoring Threshold Tests (Fail)

	func testMoveFunction_JustBelowThreshold_Fails() {
		// Score should be below 0.8, causing failure
		let path = "src/swift/reorder/Order.swift"
		let baseline = """
public func alpha(_ n: Int) -> Int { return n * 1 }

public func bravo(_ n: Int) -> Int { return n * 2 }

// FOOTER: keep below here unchanged
"""
		let final = """
public func bravo(_ n: Int) -> Int { return n * 3 }

public func alpha(_ n: Int) -> Int { return n * 1 }

// FOOTER: keep below here unchanged
"""
		let spec = BenchmarkTaskSpec(
			id: "move_function_swift",
			type: .moveFunctionSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["fromName": .string("alpha"), "afterName": .string("bravo")]
		)
		let baseline_snap = BenchmarkMockFileSystemSnapshot(files: [path: baseline])
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline_snap,
			result: BenchmarkTaskExecResult(errors: [], edited: [BenchmarkEditedFile(path: path, content: final)], meta: nil)
		)
		let out = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(out.pass)
		XCTAssertLessThan(out.score, 0.8)
	}

	// MARK: - Anchor/Marker Edge Cases

	func testInsertGuard_MissingEndAnchor_Fails() {
		let uid = "ANCH1"
		let path = "src/ts/work/Work.ts"
		let snippet = """
if (n < 0) {
    return 0;
}
"""
		let baseline = """
export function clamp(n: number): number {
    // ANCHOR:start:\(uid)
    const normalized = Math.abs(n);
    return normalized;
}
"""
		let final = """
export function clamp(n: number): number {
    // ANCHOR:start:\(uid)
    if (n < 0) {
        return 0;
    }
    const normalized = Math.abs(n);
    return normalized;
}
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_guard_ts",
			type: .insertGuardTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "anchorsMissing")
	}

	func testIndexOnly_DoneMarkerAtStartOfFunction_Fails() {
		let target = "appB"
		let path = "apps/\(target)/src/index.ts"
		let baseline = "export default function index() {\n\treturn \"\(target)\";\n}"
		let final = """
// DONE:\(target)
export default function index() {
	return "\(target)";
}
"""
		let spec = BenchmarkTaskSpec(
			id: "index_only_apps_ts",
			type: .indexOnlyAppsTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"target": .string(target),
				"otherPaths": .array([])
			]
		)
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)],
				   expectedReasonContains: "doneMarkerMissing")
	}

	// MARK: - Search Block Edge Cases

	func testApplier_SearchBlockWithBlankLines_Pass() async {
		let path = "src/go/work/Work.go"
		let baseline = """
package work

func demo() {
	x := 1

	y := 2
	z := 3
	a := 4
	b := 5
}
"""
		var fs = BenchmarkMockFileSystem(files: [path: baseline])
		let baselineSnap = fs.snapshot()
		// Need at least 5 lines for swapArgs tasks
		let search = [
			"\tx := 1",
			"",
			"\ty := 2",
			"\tz := 3",
			"\ta := 4"
		]
		let content = [
			"\tx := 10",
			"",
			"\ty := 2",
			"\tz := 3",
			"\ta := 4"
		]
		let change = Change(id: UUID(), type: .modify, summary: "update", isSelected: true, content: content, startSelector: nil, endSelector: nil, searchBlock: search)
		let parsed = ParsedFile(fileName: path, changes: [change], fileContent: "", canBeLoaded: true, action: .modify, lineEnding: "\n")
		let spec = BenchmarkTaskSpec(id: "test_blank_lines", type: .swapArgsInRegionGo, language: .go, selectFiles: [path], maxEdits: 1, instructions: [], task: "", acceptance: [], params: [:])

		let result = await BenchmarkDiffApplier.apply(parsedFiles: [parsed], task: spec, fileSystem: &fs, baseline: baselineSnap)
		XCTAssertTrue(result.errors.isEmpty, "Unexpected errors: \(result.errors)")
		let newText = fs.content(for: path) ?? ""
		XCTAssertTrue(newText.contains("x := 10"), "Expected updated value")
	}

	func testApplier_SearchBlockRegexChars_Pass() async {
		let path = "src/ts/work/Work.ts"
		let baseline = """
export function demo() {
	const pattern = /.*+?[]()/;
	const x = 1;
	const y = 2;
	const z = 3;
	return pattern;
}
"""
		var fs = BenchmarkMockFileSystem(files: [path: baseline])
		let baselineSnap = fs.snapshot()
		// Need at least 5 lines for swapArgs tasks
		let search = [
			"\tconst pattern = /.*+?[]()/;",
			"\tconst x = 1;",
			"\tconst y = 2;",
			"\tconst z = 3;",
			"\treturn pattern;"
		]
		let content = [
			"\tconst pattern = /.*+?[]()/;",
			"\tconst x = 1;",
			"\tconst y = 2;",
			"\tconst z = 3;",
			"\treturn pattern.toString();"
		]
		let change = Change(id: UUID(), type: .modify, summary: "update return", isSelected: true, content: content, startSelector: nil, endSelector: nil, searchBlock: search)
		let parsed = ParsedFile(fileName: path, changes: [change], fileContent: "", canBeLoaded: true, action: .modify, lineEnding: "\n")
		let spec = BenchmarkTaskSpec(id: "test_regex_chars", type: .swapArgsInRegionTs, language: .ts, selectFiles: [path], maxEdits: 1, instructions: [], task: "", acceptance: [], params: [:])

		let result = await BenchmarkDiffApplier.apply(parsedFiles: [parsed], task: spec, fileSystem: &fs, baseline: baselineSnap)
		XCTAssertTrue(result.errors.isEmpty, "Unexpected errors: \(result.errors)")
		let newText = fs.content(for: path) ?? ""
		XCTAssertTrue(newText.contains("toString()"), "Expected updated return statement")
	}

	// MARK: - Multi-File Bundle Tests

	func testInsertGuard_Bundle_PartialFailure() {
		let uid1 = "B1"
		let uid2 = "B2"
		let uid3 = "B3"
		let path1 = "src/ts/file1.ts"
		let path2 = "src/ts/file2.ts"
		let path3 = "src/ts/file3.ts"

		let snippet1 = """
if (n < 0) {
    return 0;
}
"""
		let snippet2 = """
if (n < 0) {
    return 0;
}
"""
		let snippet3 = """
if (n < 0) {
    return 0;
}
"""

		// File 1: Pass
		let baseline1 = """
export function clamp1(n: number): number {
    // ANCHOR:start:\(uid1)
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid1)
    return normalized;
}
"""
		let final1 = """
export function clamp1(n: number): number {
    // ANCHOR:start:\(uid1)
    if (n < 0) {
        return 0;
    }
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid1)
    return normalized;
}
"""

		// File 2: Pass
		let baseline2 = """
export function clamp2(n: number): number {
    // ANCHOR:start:\(uid2)
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid2)
    return normalized;
}
"""
		let final2 = """
export function clamp2(n: number): number {
    // ANCHOR:start:\(uid2)
    if (n < 0) {
        return 0;
    }
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid2)
    return normalized;
}
"""

		// File 3: Fail (has tabs)
		let baseline3 = """
export function clamp3(n: number): number {
    // ANCHOR:start:\(uid3)
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid3)
    return normalized;
}
"""
		let final3 = """
export function clamp3(n: number): number {
    // ANCHOR:start:\(uid3)
    if (n < 0) {
		return 0;
	}
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid3)
    return normalized;
}
"""

		let spec = BenchmarkTaskSpec(
			id: "insert_guard_ts_bundle",
			type: .insertGuardTs,
			language: .ts,
			selectFiles: [path1, path2, path3],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"guards": .array([
					.object(["path": .string(path1), "uid": .string(uid1), "snippet": .string(snippet1)]),
					.object(["path": .string(path2), "uid": .string(uid2), "snippet": .string(snippet2)]),
					.object(["path": .string(path3), "uid": .string(uid3), "snippet": .string(snippet3)])
				])
			]
		)
		let baseline_snap = BenchmarkMockFileSystemSnapshot(files: [path1: baseline1, path2: baseline2, path3: baseline3])
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline_snap,
			result: BenchmarkTaskExecResult(errors: [], edited: [
				BenchmarkEditedFile(path: path1, content: final1),
				BenchmarkEditedFile(path: path2, content: final2),
				BenchmarkEditedFile(path: path3, content: final3)
			], meta: nil)
		)
		let out = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(out.pass)
		XCTAssertTrue(out.reason.contains("tabFound"), "Expected tabFound in reason, got: \(out.reason)")
	}

	func testRename_Bundle_AllPass_AggregateScore() {
		let exporter = "src/lib/exporter.ts"
		let importer1 = "src/apps/app1.ts"
		let importer2 = "src/apps/app2.ts"
		let oldName = "OldFunc"
		let newName = "NewFunc"

		let baselineExporter = "export function \(oldName)() { return 42; }"
		let baselineImporter1 = "import { \(oldName) } from '../lib/exporter';\nexport const x = \(oldName)();"
		let baselineImporter2 = "import { \(oldName) } from '../lib/exporter';\nexport const y = \(oldName)();"

		let finalExporter = "export function \(newName)() { return 42; }"
		let finalImporter1 = "import { \(newName) } from '../lib/exporter';\nexport const x = \(newName)();"
		let finalImporter2 = "import { \(newName) } from '../lib/exporter';\nexport const y = \(newName)();"

		let spec = BenchmarkTaskSpec(
			id: "rename_export_and_imports_ts",
			type: .renameExportImportsTs,
			language: .ts,
			selectFiles: [exporter, importer1, importer2],
			maxEdits: 6,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"rename": .object(["from": .string(oldName), "to": .string(newName)]),
				"importPaths": .array([.string(importer1), .string(importer2)])
			]
		)
		let baseline_snap = BenchmarkMockFileSystemSnapshot(files: [
			exporter: baselineExporter,
			importer1: baselineImporter1,
			importer2: baselineImporter2
		])
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline_snap,
			result: BenchmarkTaskExecResult(errors: [], edited: [
				BenchmarkEditedFile(path: exporter, content: finalExporter),
				BenchmarkEditedFile(path: importer1, content: finalImporter1),
				BenchmarkEditedFile(path: importer2, content: finalImporter2)
			], meta: nil)
		)
		let out = BenchmarkVerifier().verify(exec)
		XCTAssertTrue(out.pass, "Expected pass, got: \(out.reason)")
		XCTAssertEqual(out.score, 1.0, accuracy: 0.01)
	}

	// MARK: - Near-Miss Variations

	func testRemoveX_CaseSensitiveNearMiss_Pass() {
		// Remove "CALL_X" but keep "call_x" (different case) - should pass without penalty
		let path = "src/ts/Alpha.ts"
		let baseline = """
export function alpha(values: number[]): number {
    let total = 0;
    for (const value of values) {
        total += CALL_X(value);
    }
    const debug = call_x(value); // different case, should be preserved
    return total;
}
"""
		let final = """
export function alpha(values: number[]): number {
    let total = 0;
    for (const value of values) {
        total += value;
    }
    const debug = call_x(value); // different case, should be preserved
    return total;
}
"""
		let spec = BenchmarkTaskSpec(
			id: "remove_x_ts",
			type: .removeXTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(path), "target": .string("CALL_X(")]
		)
		let baseline_snap = BenchmarkMockFileSystemSnapshot(files: [path: baseline])
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline_snap,
			result: BenchmarkTaskExecResult(errors: [], edited: [BenchmarkEditedFile(path: path, content: final)], meta: nil)
		)
		let out = BenchmarkVerifier().verify(exec)
		XCTAssertTrue(out.pass, "Case-sensitive near miss should not be penalized")
		XCTAssertEqual(out.score, 1.0, accuracy: 0.01)
	}

	func testRemoveX_UnicodeNearMiss_Pass() {
		// Remove "CALL_X" but keep "CALL_Χ" (Greek Chi) - should pass
		let path = "src/swift/Alpha.swift"
		let baseline = """
public func alpha(_ values: [Int]) -> Int {
	var total = 0
	for v in values {
		total += CALL_X(v)
	}
	let other = CALL_Χ(v) // Greek Chi, not Latin X
	return total
}
"""
		let final = """
public func alpha(_ values: [Int]) -> Int {
	var total = 0
	for v in values {
		total += v
	}
	let other = CALL_Χ(v) // Greek Chi, not Latin X
	return total
}
"""
		let spec = BenchmarkTaskSpec(
			id: "remove_x_swift",
			type: .removeXSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(path), "target": .string("CALL_X(")]
		)
		let baseline_snap = BenchmarkMockFileSystemSnapshot(files: [path: baseline])
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline_snap,
			result: BenchmarkTaskExecResult(errors: [], edited: [BenchmarkEditedFile(path: path, content: final)], meta: nil)
		)
		let out = BenchmarkVerifier().verify(exec)
		XCTAssertTrue(out.pass, "Unicode near miss should not be penalized")
		XCTAssertEqual(out.score, 1.0, accuracy: 0.01)
	}

	// MARK: - Lenient vs Strict Policy Tests

	func testRemoveX_LenientPolicy_ReducedScore() {
		// With lenient=true, nearMiss reduces score but passes
		let path = "src/ts/Alpha.ts"
		let baseline = """
CALL_X(1);
call_x(1); // near miss
"""
		let final = """
// cleaned
"""
		let spec = BenchmarkTaskSpec(
			id: "remove_x_ts",
			type: .removeXTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(path), "target": .string("CALL_X(")]
		)
		let baselineSnap = BenchmarkMockFileSystemSnapshot(files: [path: baseline])
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baselineSnap,
			result: BenchmarkTaskExecResult(errors: [], edited: [BenchmarkEditedFile(path: path, content: final)], meta: nil)
		)
		let verifier = BenchmarkVerifier(policy: GradingPolicy(lenient: true))
		let out = verifier.verify(exec)
		XCTAssertFalse(out.pass, "Should fail due to near miss change")
		XCTAssertLessThan(out.score, 0.8)
		XCTAssertEqual(out.reason, "nearMissChanged")
	}

	func testRemoveX_StrictPolicy_ImmediateFail() {
		// With lenient=false, nearMiss fails immediately
		let path = "src/go/Alpha.go"
		let baseline = """
package alpha

func Alpha(values []int) int {
	total := 0
	for _, v := range values {
		total += CALL_X(v)
	}
	debug := call_x(v) // near miss
	return total
}
"""
		let final = """
package alpha

func Alpha(values []int) int {
	total := 0
	for _, v := range values {
		total += v
	}
	return total
}
"""
		let spec = BenchmarkTaskSpec(
			id: "remove_x_go",
			type: .removeXGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(path), "target": .string("CALL_X(")]
		)
		let baselineSnap = BenchmarkMockFileSystemSnapshot(files: [path: baseline])
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baselineSnap,
			result: BenchmarkTaskExecResult(errors: [], edited: [BenchmarkEditedFile(path: path, content: final)], meta: nil)
		)
		let verifier = BenchmarkVerifier(policy: GradingPolicy(lenient: false))
		let out = verifier.verify(exec)
		XCTAssertFalse(out.pass)
		XCTAssertEqual(out.reason, "nearMissChanged")
	}

	// MARK: - Unified Patch Failure Cases

	func testApplyUnifiedPatch_ContextMismatch_Fails() {
		let path = "src/ts/mismatch/Mismatch.ts"
		let baseline = """
export function compute(x: number): number {
\treturn x * 2
}
"""
		// Patch expects different context line
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,3 +1,3 @@")
		patch.append(" export function calculate(x: number): number {") // Wrong name
		patch.append("-\treturn x * 2")
		patch.append("+\treturn x * 3")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")

		// Patch should fail to apply due to context mismatch
		let result = SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline)
		XCTAssertNil(result, "Expected patch to fail due to context mismatch")

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_mismatch",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)

		// Since patch can't be applied, verifier should fail with invalidPatch
		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: baseline)],
				   expectedReasonContains: "invalidPatch")
	}

	func testApplyUnifiedPatch_WrongOutput_Fails() {
		let path = "src/go/wrong/Wrong.go"
		let baseline = """
package wrong

func compute(n int) int {
    return n * 2
}
"""
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -3,3 +3,3 @@")
		patch.append(" func compute(n int) int {")
		patch.append("-    return n * 2")
		patch.append("+    return n * 3")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")

		// Submit wrong output - not applying the patch correctly
		let wrongOutput = """
package wrong

func compute(n int) int {
    return n * 5
}
"""
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_go_wrong",
			type: .applyUnifiedPatchGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)

		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: wrongOutput)],
				   expectedReasonContains: "diffMismatch")
	}

	func testApplyUnifiedPatch_MalformedHeader_Fails() {
		let path = "src/swift/malformed/Malformed.swift"
		let baseline = """
public func test() -> Int {
\treturn 1
}
"""
		// Invalid hunk header format
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ INVALID HEADER @@")
		patch.append(" public func test() -> Int {")
		patch.append("-\treturn 1")
		patch.append("+\treturn 2")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")

		// Malformed patch should fail to parse
		let result = SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline)
		XCTAssertNil(result, "Expected malformed patch to fail parsing")

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_swift_malformed",
			type: .applyUnifiedPatchSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)

		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: baseline)],
				   expectedReasonContains: "invalidPatch")
	}

	func testApplyUnifiedPatch_LineNumberMismatch_Fails() {
		let path = "src/ts/linemismatch/LineMismatch.ts"
		let baseline = """
export function alpha(): number {
\treturn 1
}

export function bravo(): number {
\treturn 2
}
"""
		// Patch targets lines that don't exist at specified location
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -10,3 +10,3 @@") // Line 10 doesn't exist
		patch.append(" export function bravo(): number {")
		patch.append("-\treturn 2")
		patch.append("+\treturn 20")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")

		// Patch should fail to apply due to line number mismatch
		let result = SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline)
		XCTAssertNil(result, "Expected patch to fail due to line number mismatch")

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_linemismatch",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)

		verifyFail(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: baseline)],
				   expectedReasonContains: "invalidPatch")
	}
}
