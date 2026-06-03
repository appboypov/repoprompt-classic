import XCTest
@testable import RepoPrompt

final class BenchmarkFeasibility_AllPassTests: XCTestCase {
	// MARK: - Helpers

	private func verifyPass(_ spec: BenchmarkTaskSpec,
							 baselineFiles: [String: String],
							 editedFiles: [BenchmarkEditedFile],
							 file: StaticString = #file, line: UInt = #line) {
		let baseline = BenchmarkMockFileSystemSnapshot(files: baselineFiles)
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(errors: [], edited: editedFiles, meta: nil)
		)
		let out = BenchmarkVerifier().verify(exec)
		XCTAssertTrue(out.pass, "Expected pass but got: \(out.reason)", file: file, line: line)
		XCTAssertGreaterThanOrEqual(out.score, 0.8, file: file, line: line)
	}

	private func verifyFail(_ spec: BenchmarkTaskSpec,
							baselineFiles: [String: String],
							editedFiles: [BenchmarkEditedFile],
							file: StaticString = #file, line: UInt = #line) -> BenchmarkVerifyOutput {
		let baseline = BenchmarkMockFileSystemSnapshot(files: baselineFiles)
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(errors: [], edited: editedFiles, meta: nil)
		)
		let out = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(out.pass, "Expected failure but passed", file: file, line: line)
		return out
	}

	// MARK: - remove_x_* (TS/Go/Swift)

	func testRemoveX_Ts_Pass() {
		let path = "src/ts/Alpha.ts"
		let baseline = """
export function alpha(values: number[]): number {
    let total = 0;
    for (const value of values) {
        total += CALL_X(value);
    }
    return total;
}
"""
		let final = """
export function alpha(values: number[]): number {
    let total = 0;
    for (const value of values) {
        total += value;
    }
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
		verifyPass(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testRemoveX_Go_Pass() {
		let path = "src/go/Alpha.go"
		let baseline = """
package alpha

func Alpha(values []int) int {
	total := 0
	for _, v := range values {
		total += CALL_X(v)
	}
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
		verifyPass(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testRemoveX_Swift_Pass() {
		let path = "src/swift/Alpha.swift"
		let baseline = """
public func alpha(_ values: [Int]) -> Int {
	var total = 0
	for v in values {
		total += CALL_X(v)
	}
	return total
}
"""
		let final = """
public func alpha(_ values: [Int]) -> Int {
	var total = 0
	for v in values {
		total += v
	}
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
		verifyPass(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	// MARK: - curly_fix_* (TS/Go/Swift)

	func testCurlyFix_Ts_Pass() {
		let path = "src/ts/main.ts"
		let baseline = """
export function main() {
	let sum = 0
	for (let i = 0; i < 5; i++) {
		sum += i
	console.log(sum)
"""
		let final = """
export function main() {
	let sum = 0
	for (let i = 0; i < 5; i++) {
		sum += i
	}
	console.log(sum)
}
"""
		let spec = BenchmarkTaskSpec(
			id: "curly_fix_ts",
			type: .curlyFixTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(path)]
		)
		verifyPass(spec, baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testCurlyFix_Go_Pass() {
		let path = "src/go/main.go"
		let baseline = """
package main

import "fmt"

func main() {
	sum := 0
	for i := 0; i < 5; i++ {
		sum += i
	fmt.Println(sum)
"""
		let final = """
package main

import "fmt"

func main() {
	sum := 0
	for i := 0; i < 5; i++ {
		sum += i
	}
	fmt.Println(sum)
}
"""
		let spec = BenchmarkTaskSpec(
			id: "curly_fix_go",
			type: .curlyFixGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(path)]
		)
		verifyPass(spec, baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testCurlyFix_Swift_Pass() {
		let path = "src/swift/main.swift"
		let baseline = """
import Foundation

func main() {
	var sum = 0
	for i in 0..<5 {
		sum += i
	print(sum)
"""
		let final = """
import Foundation

func main() {
	var sum = 0
	for i in 0..<5 {
		sum += i
	}
	print(sum)
}
"""
		let spec = BenchmarkTaskSpec(
			id: "curly_fix_swift",
			type: .curlyFixSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(path)]
		)
		verifyPass(spec, baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	// MARK: - insert_guard_* (TS/Go/Swift)

	func testInsertGuard_Ts_Pass() {
		let uid = "ABCD"
		let path = "src/ts/work/Work.ts"
		let snippet = """
if (n < 0) {
    return 0;
}
"""
		let baseline = """
export function clamp(n: number): number {
    const limit = 100;
    // ANCHOR:start:\(uid)
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid)
    return Math.min(normalized, limit);
}
"""
		let final = """
export function clamp(n: number): number {
    const limit = 100;
    // ANCHOR:start:\(uid)
    if (n < 0) {
        return 0;
    }
    const normalized = Math.abs(n);
    // ANCHOR:end:\(uid)
    return Math.min(normalized, limit);
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
		verifyPass(spec, baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testInsertGuard_Go_Pass() {
		let uid = "EFGH"
		let path = "src/go/work/Work.go"
		let snippet = """
if n < 0 {
    return 0
}
"""
		let baseline = """
package work

func Clamp(n int) int {
    limit := 100
    // ANCHOR:start:\(uid)
    normalized := n
    // ANCHOR:end:\(uid)
    if normalized > limit { return limit }
    if normalized < 0 { return -normalized }
    return normalized
}
"""
		let final = """
package work

func Clamp(n int) int {
    limit := 100
    // ANCHOR:start:\(uid)
    if n < 0 {
        return 0
    }
    normalized := n
    // ANCHOR:end:\(uid)
    if normalized > limit { return limit }
    if normalized < 0 { return -normalized }
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
		verifyPass(spec, baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testInsertGuard_Swift_Pass() {
		let uid = "IJKL"
		let path = "src/swift/work/Work.swift"
		let snippet = """
if n < 0 {
	return 0
}
"""
		let baseline = """
public func clamp(_ n: Int) -> Int {
	let limit = 100
	// ANCHOR:start:\(uid)
	let normalized = abs(n)
	// ANCHOR:end:\(uid)
	return min(normalized, limit)
}
"""
		let final = """
public func clamp(_ n: Int) -> Int {
	let limit = 100
	// ANCHOR:start:\(uid)
	if n < 0 {
		return 0
	}
	let normalized = abs(n)
	// ANCHOR:end:\(uid)
	return min(normalized, limit)
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
		verifyPass(spec, baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	// MARK: - insert_guard indentation validation tests

	func testInsertGuard_Go_UsesSpacesNotTabs() {
		// Verify Go language configuration expects spaces
		XCTAssertFalse(BenchmarkLanguage.go.usesTabIndentation, "Go should use spaces, not tabs")
		XCTAssertEqual(BenchmarkLanguage.go.indentString, "    ", "Go indent should be 4 spaces")
	}

	func testInsertGuard_Swift_UsesTabsNotSpaces() {
		// Verify Swift language configuration expects tabs
		XCTAssertTrue(BenchmarkLanguage.swift.usesTabIndentation, "Swift should use tabs")
		XCTAssertEqual(BenchmarkLanguage.swift.indentString, "\t", "Swift indent should be tab")
	}

	func testInsertGuard_Go_RejectsTabsInBaseline() {
		// Verify that Go with tabs in baseline is rejected
		let uid = "TAB1"
		let path = "src/go/work/Work.go"
		let snippet = """
if n < 0 {
    return 0
}
"""
		// Baseline incorrectly uses TABS (this is the bug we fixed)
		let baseline = """
package work

func Clamp(n int) int {
\tlimit := 100
\t// ANCHOR:start:\(uid)
\tnormalized := n
\t// ANCHOR:end:\(uid)
\treturn normalized
}
"""
		// Final has tabs too (copying from baseline)
		let final = """
package work

func Clamp(n int) int {
\tlimit := 100
\t// ANCHOR:start:\(uid)
\tif n < 0 {
\t\treturn 0
\t}
\tnormalized := n
\t// ANCHOR:end:\(uid)
\treturn normalized
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

		let result = verifyFail(spec, baselineFiles: [path: baseline],
								editedFiles: [BenchmarkEditedFile(path: path, content: final)])
		XCTAssertEqual(result.reason, "tabFound", "Go should reject tabs in inserted code")
	}

	func testInsertGuard_Swift_RejectsSpacesInSnippet() {
		// Verify that Swift with spaces in snippet/final is rejected
		let uid = "SPC1"
		let path = "src/swift/work/Work.swift"
		// Snippet incorrectly uses SPACES (this is the bug we fixed)
		let snippet = """
if n < 0 {
    return 0
}
"""
		// Baseline correctly uses tabs
		let baseline = """
public func clamp(_ n: Int) -> Int {
\tlet limit = 100
\t// ANCHOR:start:\(uid)
\tlet normalized = abs(n)
\t// ANCHOR:end:\(uid)
\treturn min(normalized, limit)
}
"""
		// Final has spaces inserted (using snippet's indentation)
		let final = """
public func clamp(_ n: Int) -> Int {
\tlet limit = 100
\t// ANCHOR:start:\(uid)
    if n < 0 {
        return 0
    }
\tlet normalized = abs(n)
\t// ANCHOR:end:\(uid)
\treturn min(normalized, limit)
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

		let result = verifyFail(spec, baselineFiles: [path: baseline],
								editedFiles: [BenchmarkEditedFile(path: path, content: final)])
		XCTAssertEqual(result.reason, "wrongIndentationStyle", "Swift should reject space indentation in inserted code")
	}

	// MARK: - patch_block indentation validation tests

	func testPatchBlock_Ts_RejectsTabsInFinal() {
		// Verify that TypeScript patch_block rejects tabs in final output
		let uid = "TAB2"
		let path = "src/ts/work/Work.ts"
		// Snippet correctly uses spaces
		let snippet = """
export function block2(n: number): number {
    const squared = n * n;
    return squared;
}
"""
		// Baseline uses spaces (correct)
		let baseline = """
/* BLOCK START:\(uid) */
export function block2(n: number): number {
    return n * 2;
}
/* BLOCK END:\(uid) */
"""
		// Final incorrectly has tabs (model error)
		let final = """
/* BLOCK START:\(uid) */
export function block2(n: number): number {
\tconst squared = n * n;
\treturn squared;
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

		let result = verifyFail(spec, baselineFiles: [path: baseline],
								editedFiles: [BenchmarkEditedFile(path: path, content: final)])
		XCTAssertEqual(result.reason, "tabFound", "TypeScript patch_block should reject tabs in final output")
	}

	func testPatchBlock_Go_RejectsTabsInFinal() {
		// Verify that Go patch_block rejects tabs in final output
		let uid = "TAB3"
		let path = "src/go/work/Work.go"
		// Snippet correctly uses spaces
		let snippet = """
func block2(n int) int {
    squared := n * n
    return squared
}
"""
		// Baseline uses spaces (correct)
		let baseline = """
/* BLOCK START:\(uid) */
func block2(n int) int {
    return n * 2
}
/* BLOCK END:\(uid) */
"""
		// Final incorrectly has tabs (model error)
		let final = """
/* BLOCK START:\(uid) */
func block2(n int) int {
\tsquared := n * n
\treturn squared
}
/* BLOCK END:\(uid) */
"""
		let spec = BenchmarkTaskSpec(
			id: "patch_block_go",
			type: .patchBlockGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)

		let result = verifyFail(spec, baselineFiles: [path: baseline],
								editedFiles: [BenchmarkEditedFile(path: path, content: final)])
		XCTAssertEqual(result.reason, "tabFound", "Go patch_block should reject tabs in final output")
	}

	// MARK: - apply_unified_patch indentation validation tests

	func testApplyUnifiedPatch_Ts_RejectsTabsInFinal() {
		// Verify that TypeScript unified patch rejects tabs in final output
		let path = "src/ts/patchables/Patch_TEST.ts"
		// Baseline correctly uses spaces
		let baseline = """
export function a(n: number) {
    return n + 1
}
"""
		// Patch correctly uses spaces
		let patch = """
--- a/\(path)
+++ b/\(path)
@@ -1,3 +1,3 @@
 export function a(n: number) {
-    return n + 1
+    return n + 2
 }
"""
		// Final incorrectly has tabs (model error)
		let final = """
export function a(n: number) {
\treturn n + 2
}
"""
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 6,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patch)]
		)

		let result = verifyFail(spec, baselineFiles: [path: baseline],
								editedFiles: [BenchmarkEditedFile(path: path, content: final)])
		XCTAssertEqual(result.reason, "tabFound", "TypeScript unified patch should reject tabs in final output")
	}

	func testApplyUnifiedPatch_Go_RejectsTabsInFinal() {
		// Verify that Go unified patch rejects tabs in final output
		let path = "src/go/patchables/Patch_TEST.go"
		// Baseline correctly uses spaces
		let baseline = """
package patchables

func a(n int) int {
    return n + 1
}
"""
		// Patch correctly uses spaces
		let patch = """
--- a/\(path)
+++ b/\(path)
@@ -3,3 +3,3 @@
 func a(n int) int {
-    return n + 1
+    return n + 2
 }
"""
		// Final incorrectly has tabs (model error)
		let final = """
package patchables

func a(n int) int {
\treturn n + 2
}
"""
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_go",
			type: .applyUnifiedPatchGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 7,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patch)]
		)

		let result = verifyFail(spec, baselineFiles: [path: baseline],
								editedFiles: [BenchmarkEditedFile(path: path, content: final)])
		XCTAssertEqual(result.reason, "tabFound", "Go unified patch should reject tabs in final output")
	}

	// MARK: - patch_block_* (TS/Go/Swift)

	func testPatchBlock_Ts_Pass() {
		let uid = "BL01"
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
    const squared = n * n;
    return squared;
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
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testPatchBlock_Go_Pass() {
		let uid = "BL02"
		let path = "src/go/work/Work.go"
		let snippet = """
func block2(n int) int {
    squared := n * n
    return squared
}
"""
		let baseline = """
/* BLOCK START:\(uid) */
func block2(n int) int {
    return n * 2
}
/* BLOCK END:\(uid) */
"""
		let final = """
/* BLOCK START:\(uid) */
func block2(n int) int {
    squared := n * n
    return squared
}
/* BLOCK END:\(uid) */
"""
		let spec = BenchmarkTaskSpec(
			id: "patch_block_go",
			type: .patchBlockGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testPatchBlock_Swift_Pass() {
		let uid = "BL03"
		let path = "src/swift/work/Work.swift"
		let snippet = """
public func block2(_ n: Int) -> Int {
	let squared = n * n
	return squared
}
"""
		let baseline = """
/* BLOCK START:\(uid) */
public func block2(_ n: Int) -> Int {
	return n * 2
}
/* BLOCK END:\(uid) */
"""
		let final = """
/* BLOCK START:\(uid) */
public func block2(_ n: Int) -> Int {
	let squared = n * n
	return squared
}
/* BLOCK END:\(uid) */
"""
		let spec = BenchmarkTaskSpec(
			id: "patch_block_swift",
			type: .patchBlockSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "snippet": .string(snippet)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	// MARK: - swap_args_in_region_* (TS/Go/Swift)

	func testSwapArgs_Ts_Pass() {
		let uid = "S001"
		let path = "src/ts/work/Work.ts"
		let baseline = """
export function render(list: string[]): string {
	let output = '';
	/* START_SWAP:\(uid) */
	output += use('a0', 'b0');
	output += use('a1', 'b1');
	output += use('a2', 'b2');
	output += use('a3', 'b3');
	/* END_SWAP:\(uid) */
	// decoy region
	/* START_SWAP:DECOY */
	output += use('a0', 'b0');
	/* END_SWAP:DECOY */
	output += use('outsideA', 'outsideB');
	return output;
}
"""
		let final = """
export function render(list: string[]): string {
	let output = '';
	/* START_SWAP:\(uid) */
	output += use('b0', 'a0');
	output += use('b1', 'a1');
	output += use('b2', 'a2');
	output += use('b3', 'a3');
	/* END_SWAP:\(uid) */
	// decoy region
	/* START_SWAP:DECOY */
	output += use('a0', 'b0');
	/* END_SWAP:DECOY */
	output += use('outsideA', 'outsideB');
	return output;
}
"""
		let spec = BenchmarkTaskSpec(
			id: "swap_args_in_region_ts",
			type: .swapArgsInRegionTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 4,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "expectedSwaps": .integer(4)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testSwapArgs_Go_Pass() {
		let uid = "S002"
		let path = "src/go/work/Work.go"
		let baseline = """
package work

func use(a, b string) string { return a + b }

func Render(list []string) string {
	out := ""
	/* START_SWAP:\(uid) */
	out += use("a0", "b0")
	out += use("a1", "b1")
	out += use("a2", "b2")
	out += use("a3", "b3")
	/* END_SWAP:\(uid) */
	out += use("outsideA", "outsideB")
	return out
}
"""
		let final = """
package work

func use(a, b string) string { return a + b }

func Render(list []string) string {
	out := ""
	/* START_SWAP:\(uid) */
	out += use("b0", "a0")
	out += use("b1", "a1")
	out += use("b2", "a2")
	out += use("b3", "a3")
	/* END_SWAP:\(uid) */
	out += use("outsideA", "outsideB")
	return out
}
"""
		let spec = BenchmarkTaskSpec(
			id: "swap_args_in_region_go",
			type: .swapArgsInRegionGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 4,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "expectedSwaps": .integer(4)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testSwapArgs_Swift_Pass() {
		let uid = "S003"
		let path = "src/swift/work/Work.swift"
		let baseline = """
func use(_ a: String, _ b: String) -> String { a + b }

func render(_ list: [String]) -> String {
	var output = ""
	/* START_SWAP:\(uid) */
	output += use("a0", "b0")
	output += use("a1", "b1")
	output += use("a2", "b2")
	output += use("a3", "b3")
	/* END_SWAP:\(uid) */
	return output
}
"""
		let final = """
func use(_ a: String, _ b: String) -> String { a + b }

func render(_ list: [String]) -> String {
	var output = ""
	/* START_SWAP:\(uid) */
	output += use("b0", "a0")
	output += use("b1", "a1")
	output += use("b2", "a2")
	output += use("b3", "a3")
	/* END_SWAP:\(uid) */
	return output
}
"""
		let spec = BenchmarkTaskSpec(
			id: "swap_args_in_region_swift",
			type: .swapArgsInRegionSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 4,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(uid), "expectedSwaps": .integer(4)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	// MARK: - index_only_apps_* (TS/Go/Swift)

	func testIndexOnly_Ts_Pass() {
		let target = "appB"
		let targetPath = "apps/\(target)/src/index.ts"
		let others = ["apps/appA/src/index.ts", "apps/appC/src/index.ts", "packages/pkg1/src/index.ts", "packages/pkg2/src/index.ts"]
		var files: [String: String] = [
			targetPath: "export default function index() {\n\treturn \"\(target)\";\n}"
		]
		for p in others {
			if p.contains("/apps/") {
				let app = p.split(separator: "/")[1]
				files[p] = "export default function index() {\n\treturn \"\(app)\";\n}"
			} else {
				let pkg = p.split(separator: "/")[1]
				files[p] = "export const value = \"\(pkg)\";"
			}
		}
		let updated = """
export default function index() {
	return "\(target)";
	// DONE:\(target)
}
"""
		let spec = BenchmarkTaskSpec(
			id: "index_only_apps_ts",
			type: .indexOnlyAppsTs,
			language: .ts,
			selectFiles: [targetPath] + others,
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"target": .string(target),
				"otherPaths": .array(others.map { .string($0) })
			]
		)
		verifyPass(spec, baselineFiles: files, editedFiles: [BenchmarkEditedFile(path: targetPath, content: updated)])
	}

	func testIndexOnly_Go_Pass() {
		let target = "appB"
		let targetPath = "apps/\(target)/main.go"
		let others = ["apps/appA/main.go", "apps/appC/main.go", "packages/pkg1/main.go", "packages/pkg2/main.go"]
		var files: [String: String] = [
			targetPath: "package main\n\nfunc index() string {\n\treturn \"\(target)\"\n}\n"
		]
		for p in others {
			if p.contains("/apps/") {
				let app = p.split(separator: "/")[1]
				files[p] = "package main\n\nfunc index() string {\n\treturn \"\(app)\"\n}\n"
			} else {
				let pkg = p.split(separator: "/")[1]
				files[p] = "package \(pkg)\n\nfunc value() string { return \"\(pkg)\" }\n"
			}
		}
		let updated = """
package main

func index() string {
	return "\(target)"
	// DONE:\(target)
}
"""
		let spec = BenchmarkTaskSpec(
			id: "index_only_apps_go",
			type: .indexOnlyAppsGo,
			language: .go,
			selectFiles: [targetPath] + others,
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"target": .string(target),
				"otherPaths": .array(others.map { .string($0) })
			]
		)
		verifyPass(spec, baselineFiles: files, editedFiles: [BenchmarkEditedFile(path: targetPath, content: updated)])
	}

	func testIndexOnly_Swift_Pass() {
		let target = "appB"
		let targetPath = "Apps/\(target)/index.swift"
		let others = ["Apps/appA/index.swift", "Apps/appC/index.swift", "Packages/Pkg1/index.swift", "Packages/Pkg2/index.swift"]
		var files: [String: String] = [
			targetPath: "public func index() -> String {\n\treturn \"\(target)\"\n}\n"
		]
		for p in others {
			if p.contains("/Apps/") {
				let app = p.split(separator: "/")[1]
				files[p] = "public func index() -> String {\n\treturn \"\(app)\"\n}\n"
			} else {
				let pkg = p.split(separator: "/")[1]
				files[p] = "public func value() -> String { \"\(pkg)\" }\n"
			}
		}
		let updated = """
public func index() -> String {
	return "\(target)"
	// DONE:\(target)
}
"""
		let spec = BenchmarkTaskSpec(
			id: "index_only_apps_swift",
			type: .indexOnlyAppsSwift,
			language: .swift,
			selectFiles: [targetPath] + others,
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"target": .string(target),
				"otherPaths": .array(others.map { .string($0) })
			]
		)
		verifyPass(spec, baselineFiles: files, editedFiles: [BenchmarkEditedFile(path: targetPath, content: updated)])
	}

	// MARK: - rename_export_and_imports_* (TS/Go/Swift)

	func testRename_TS_Pass() {
		let exporterPath = "src/ts/lib/exporter.ts"
		let barrelPath = "src/ts/lib/index.ts"
		let importers = [
			"apps/appA/src/useX_1.ts",
			"apps/appB/src/useX_2.ts"
		]
		let oldName = "OldX"
		let newName = "NewX"
		var files: [String: String] = [
			exporterPath: "export function \(oldName)(): string { return \"value\" }\nexport const usage = \(oldName)()\n",
			barrelPath: "export { \(oldName) } from \"./exporter\";\nexport * as All from \"./exporter\";\n"
		]
		files[importers[0]] = "import { \(oldName) } from '../../lib/exporter';\n\nexport function consume() { return \(oldName)(); }\n"
		files[importers[1]] = "import * as E from '../../lib';\n\nexport function consume() { return E.\(oldName)(); }\n"

		let edited: [BenchmarkEditedFile] = [
			BenchmarkEditedFile(path: exporterPath,
							   content: "export function \(newName)(): string { return \"value\" }\nexport const usage = \(newName)()\n"),
			BenchmarkEditedFile(path: barrelPath,
							   content: "export { \(newName) } from \"./exporter\";\nexport * as All from \"./exporter\";\n"),
			BenchmarkEditedFile(path: importers[0],
							   content: "import { \(newName) } from '../../lib/exporter';\n\nexport function consume() { return \(newName)(); }\n"),
			BenchmarkEditedFile(path: importers[1],
							   content: "import * as E from '../../lib';\n\nexport function consume() { return E.\(newName)(); }\n")
		]
		let spec = BenchmarkTaskSpec(
			id: "rename_export_and_imports_ts",
			type: .renameExportImportsTs,
			language: .ts,
			selectFiles: [exporterPath, barrelPath] + importers,
			maxEdits: 8,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"rename": .object(["from": .string(oldName), "to": .string(newName)]),
				"importPaths": .array(importers.map { .string($0) }),
				"reexportPaths": .array([.string(barrelPath)]),
				"nearMissTokens": .array([])
			]
		)
		verifyPass(spec, baselineFiles: files, editedFiles: edited)
	}

	func testRename_Go_Pass() {
		let exporterPath = "src/go/lib/exporter.go"
		let importers = [
			"apps/appA/useX_1.go",
			"apps/appB/useX_2.go"
		]
		let oldName = "OldX"
		let newName = "NewX"
		var files: [String: String] = [
			exporterPath: "package lib\n\nfunc \(oldName)() string { return \"value\" }\nvar Usage = \(oldName)()\n"
		]
		files[importers[0]] = "package main\n\nimport \"lib/exporter\"\n\nfunc consume() string { return exporter.\(oldName)() }\n"
		files[importers[1]] = "package main\n\nimport \"lib/exporter\"\n\nfunc consume() string { return exporter.\(oldName)() }\n"

		let edited: [BenchmarkEditedFile] = [
			BenchmarkEditedFile(path: exporterPath,
							   content: "package lib\n\nfunc \(newName)() string { return \"value\" }\nvar Usage = \(newName)()\n"),
			BenchmarkEditedFile(path: importers[0],
							   content: "package main\n\nimport \"lib/exporter\"\n\nfunc consume() string { return exporter.\(newName)() }\n"),
			BenchmarkEditedFile(path: importers[1],
							   content: "package main\n\nimport \"lib/exporter\"\n\nfunc consume() string { return exporter.\(newName)() }\n")
		]
		let spec = BenchmarkTaskSpec(
			id: "rename_export_and_imports_go",
			type: .renameExportImportsGo,
			language: .go,
			selectFiles: [exporterPath] + importers,
			maxEdits: 8,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"rename": .object(["from": .string(oldName), "to": .string(newName)]),
				"importPaths": .array(importers.map { .string($0) })
			]
		)
		verifyPass(spec, baselineFiles: files, editedFiles: edited)
	}

	func testRename_Swift_Pass() {
		let exporterPath = "Sources/Lib/Exporter.swift"
		let importers = [
			"Apps/appA/UseX_1.swift",
			"Apps/appB/UseX_2.swift"
		]
		let oldName = "OldX"
		let newName = "NewX"
		var files: [String: String] = [
			exporterPath: "public func \(oldName)() -> String { \"value\" }\n\npublic let usage = \(oldName)()\n"
		]
		files[importers[0]] = "import Lib\n\npublic func consume() -> String { return \(oldName)() }\n"
		files[importers[1]] = "import Lib\n\npublic func consume() -> String { return \(oldName)() }\n"

		let edited: [BenchmarkEditedFile] = [
			BenchmarkEditedFile(path: exporterPath,
							   content: "public func \(newName)() -> String { \"value\" }\n\npublic let usage = \(newName)()\n"),
			BenchmarkEditedFile(path: importers[0],
							   content: "import Lib\n\npublic func consume() -> String { return \(newName)() }\n"),
			BenchmarkEditedFile(path: importers[1],
							   content: "import Lib\n\npublic func consume() -> String { return \(newName)() }\n")
		]
		let spec = BenchmarkTaskSpec(
			id: "rename_export_and_imports_swift",
			type: .renameExportImportsSwift,
			language: .swift,
			selectFiles: [exporterPath] + importers,
			maxEdits: 8,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"rename": .object(["from": .string(oldName), "to": .string(newName)]),
				"importPaths": .array(importers.map { .string($0) })
			]
		)
		verifyPass(spec, baselineFiles: files, editedFiles: edited)
	}

	// MARK: - move_function_* (TS/Go/Swift)

	func testMoveFunction_Ts_Pass() {
		let path = "src/ts/reorder/Order.ts"
		let baseline = """
export function alpha(n: number): number { return n * 1; }

export function bravo(n: number): number { return n * 2; }

export function charlie(n: number): number { return n * 3; }

// FOOTER: keep below here unchanged
"""
		let final = """
export function bravo(n: number): number { return n * 2; }

export function charlie(n: number): number { return n * 3; }

export function alpha(n: number): number { return n * 1; }

// FOOTER: keep below here unchanged
"""
		let spec = BenchmarkTaskSpec(
			id: "move_function_ts",
			type: .moveFunctionTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["fromName": .string("alpha"), "afterName": .string("charlie")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Go_Pass() {
		let path = "src/go/reorder/Order.go"
		let baseline = """
package reorder

func alpha(n int) int { return n * 1 }

func bravo(n int) int { return n * 2 }

func charlie(n int) int { return n * 3 }

// FOOTER: keep below here unchanged
"""
		let final = """
package reorder

func bravo(n int) int { return n * 2 }

func charlie(n int) int { return n * 3 }

func alpha(n int) int { return n * 1 }

// FOOTER: keep below here unchanged
"""
		let spec = BenchmarkTaskSpec(
			id: "move_function_go",
			type: .moveFunctionGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["fromName": .string("alpha"), "afterName": .string("charlie")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Swift_Pass() {
		let path = "src/swift/reorder/Order.swift"
		let baseline = """
public func alpha(_ n: Int) -> Int { return n * 1 }

public func bravo(_ n: Int) -> Int { return n * 2 }

public func charlie(_ n: Int) -> Int { return n * 3 }

// FOOTER: keep below here unchanged
"""
		let final = """
public func bravo(_ n: Int) -> Int { return n * 2 }

public func charlie(_ n: Int) -> Int { return n * 3 }

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
			params: ["fromName": .string("alpha"), "afterName": .string("charlie")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	// MARK: - insert_function_bottom_* (TS/Go/Swift)

	func testInsertFunctionBottom_Ts_Pass() {
		let path = "src/ts/work/Work.ts"
		let footer = "// END-OF-FILE (append new functions immediately above this line)"
		let baseline = """
export function ping(x: string): string { return `ping:${x}`; }

export function pong(y: number): number { return y + 1; }

\(footer)
"""
		let snippet = """
export const curryAdd = (a: number) => (b: number) => a + b;

export function compose<A,B,C>(f: (b: B) => C, g: (a: A) => B) {
	return (a: A) => f(g(a));
}
"""
		let final = """
export function ping(x: string): string { return `ping:${x}`; }

export function pong(y: number): number { return y + 1; }

\(snippet)

\(footer)
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
				"inserts": .array([
					.object([
						"path": .string(path),
						"snippet": .string(snippet),
						"footer": .string("// END-OF-FILE")
					])
				])
			]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testInsertFunctionBottom_Go_Pass() {
		let path = "src/go/work/Work.go"
		let footer = "// END-OF-FILE (append new functions immediately above this line)"
		let baseline = """
package work

func ping(x string) string { return "ping:" + x }

func pong(y int) int { return y + 1 }

\(footer)
"""
		let snippet = """
func curryAdd(a int) func(int) int { return func(b int) int { return a + b } }

func compose[A any, B any, C any](f func(B) C, g func(A) B) func(A) C {
	return func(a A) C { return f(g(a)) }
}
"""
		let final = """
package work

func ping(x string) string { return "ping:" + x }

func pong(y int) int { return y + 1 }

\(snippet)

\(footer)
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_function_bottom_go",
			type: .insertFunctionBottomGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"inserts": .array([
					.object([
						"path": .string(path),
						"snippet": .string(snippet),
						"footer": .string("// END-OF-FILE")
					])
				])
			]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testInsertFunctionBottom_Swift_Pass() {
		let path = "src/swift/work/Work.swift"
		let footer = "// END-OF-FILE (append new functions immediately above this line)"
		let baseline = """
public func ping(_ x: String) -> String { "ping:\\(x)" }

public func pong(_ y: Int) -> Int { y + 1 }

\(footer)
"""
		let snippet = """
public func curryAdd(_ a: Int) -> (Int) -> Int { { b in a + b } }

public func compose<A,B,C>(_ f: @escaping (B) -> C, _ g: @escaping (A) -> B) -> (A) -> C {
	{ a in f(g(a)) }
}
"""
		let final = """
public func ping(_ x: String) -> String { "ping:\\(x)" }

public func pong(_ y: Int) -> Int { y + 1 }

\(snippet)

\(footer)
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_function_bottom_swift",
			type: .insertFunctionBottomSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"inserts": .array([
					.object([
						"path": .string(path),
						"snippet": .string(snippet),
						"footer": .string("// END-OF-FILE")
					])
				])
			]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	// MARK: - apply_unified_patch_* (TS/Go/Swift)

	func testApplyUnifiedPatch_Ts_Pass() throws {
		let path = "src/ts/patchables/Patch_ZZZZ.ts"
		var base: [String] = []
		base.append("export function a(n: number) {")
		base.append("    return n + 1")
		base.append("}")
		base.append("")
		base.append("export function b(s: string) {")
		base.append("    return s.toUpperCase()")
		base.append("}")
		base.append("")
		let baseline = base.joined(separator: "\n")
		let inc = 3
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,3 +1,3 @@")
		patch.append(" export function a(n: number) {")
		patch.append("-    return n + 1")
		patch.append("+    return n + \(inc)")
		patch.append(" }")
		patch.append("@@ -5,3 +5,2 @@")
		patch.append(" export function b(s: string) {")
		patch.append("-    return s.toUpperCase()")
		patch.append("+    return s.toLowerCase()")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 8,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_Go_Pass() throws {
		let path = "src/go/patchables/Patch_GO.go"
		var base: [String] = []
		base.append("package patchables")
		base.append("")
		base.append("func a(n int) int {")
		base.append("    return n + 1")
		base.append("}")
		base.append("")
		base.append("func b(s string) string {")
		base.append("    return s + s")
		base.append("}")
		base.append("")
		let baseline = base.joined(separator: "\n")
		let inc = 2
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -3,3 +3,3 @@")
		patch.append(" func a(n int) int {")
		patch.append("-    return n + 1")
		patch.append("+    return n + \(inc)")
		patch.append(" }")
		patch.append("@@ -7,3 +7,3 @@")
		patch.append(" func b(s string) string {")
		patch.append("-    return s + s")
		patch.append("+    return s")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_go",
			type: .applyUnifiedPatchGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 7,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_Swift_Pass() throws {
		let path = "src/swift/patchables/Patch_SW.swift"
		var base: [String] = []
		base.append("public func a(_ n: Int) -> Int {")
		base.append("\treturn n + 1")
		base.append("}")
		base.append("")
		base.append("public func b(_ s: String) -> String {")
		base.append("\treturn s.uppercased()")
		base.append("}")
		let baseline = base.joined(separator: "\n")
		let inc = 3
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,3 +1,3 @@")
		patch.append(" public func a(_ n: Int) -> Int {")
		patch.append("-\treturn n + 1")
		patch.append("+\treturn n + \(inc)")
		patch.append(" }")
		patch.append("@@ -5,3 +5,2 @@")
		patch.append(" public func b(_ s: String) -> String {")
		patch.append("-\treturn s.uppercased()")
		patch.append("+\treturn s.lowercased()")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_swift",
			type: .applyUnifiedPatchSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 6,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec,
				   baselineFiles: [path: baseline],
				   editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	// MARK: - Unified Patch Edge Cases

	func testApplyUnifiedPatch_SingleHunk_Ts_Pass() throws {
		let path = "src/ts/single/Single.ts"
		let baseline = """
export function compute(x: number): number {
    return x * 2
}
"""
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,3 +1,3 @@")
		patch.append(" export function compute(x: number): number {")
		patch.append("-    return x * 2")
		patch.append("+    return x * 3")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_single",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_AddOnly_Go_Pass() throws {
		let path = "src/go/add/Add.go"
		let baseline = """
package add

func original() int {
    return 1
}
"""
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -3,2 +3,4 @@")
		patch.append(" func original() int {")
		patch.append("+    // New comment")
		patch.append("+    fmt.Println(\"debug\")")
		patch.append("     return 1")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_go_add",
			type: .applyUnifiedPatchGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_DeleteOnly_Swift_Pass() throws {
		let path = "src/swift/delete/Delete.swift"
		let baseline = """
public func process(_ n: Int) -> Int {
\t// TODO: Remove this line
\tlet temp = n + 1
\treturn temp
}
"""
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,4 +1,3 @@")
		patch.append(" public func process(_ n: Int) -> Int {")
		patch.append("-\t// TODO: Remove this line")
		patch.append(" \tlet temp = n + 1")
		patch.append(" \treturn temp")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_swift_delete",
			type: .applyUnifiedPatchSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_PatchAtEOF_Ts_Pass() throws {
		let path = "src/ts/eof/EOF.ts"
		let baseline = """
export function first(): string {
    return "first"
}

export function last(): string {
    return "last"
}
"""
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -5,3 +5,3 @@")
		patch.append(" export function last(): string {")
		patch.append("-    return \"last\"")
		patch.append("+    return \"modified\"")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_eof",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_NoTrailingNewline_Go_Pass() throws {
		let path = "src/go/trail/Trail.go"
		let baseline = "package trail\n\nfunc process(n int) int {\n    return n * 2\n}"
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -3,3 +3,3 @@")
		patch.append(" func process(n int) int {")
		patch.append("-    return n * 2")
		patch.append("+    return n * 3")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_go_notrail",
			type: .applyUnifiedPatchGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_WhitespaceOnly_Swift_Pass() throws {
		let path = "src/swift/space/Space.swift"
		let baseline = """
public func format() -> String {
\treturn "value"
}
"""
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,3 +1,4 @@")
		patch.append(" public func format() -> String {")
		patch.append("+")
		patch.append(" \treturn \"value\"")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_swift_space",
			type: .applyUnifiedPatchSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_MultipleHunksAcrossFile_Ts_Pass() throws {
		let path = "src/ts/multi/Multi.ts"
		let baseline = """
export function alpha(): number {
    return 1
}

export function bravo(): number {
    return 2
}

export function charlie(): number {
    return 3
}

export function delta(): number {
    return 4
}
"""
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,3 +1,3 @@")
		patch.append(" export function alpha(): number {")
		patch.append("-    return 1")
		patch.append("+    return 10")
		patch.append(" }")
		patch.append("@@ -9,3 +9,3 @@")
		patch.append(" export function charlie(): number {")
		patch.append("-    return 3")
		patch.append("+    return 30")
		patch.append(" }")
		patch.append("@@ -13,3 +13,3 @@")
		patch.append(" export function delta(): number {")
		patch.append("-    return 4")
		patch.append("+    return 40")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_multi",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 10,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	// MARK: - Unified Patch Difficulty Scaling Tests
	//
	// These tests verify that all difficulty levels are passable with correct code
	// for all three languages (TypeScript, Go, Swift)

	// MARK: TypeScript Difficulty Tests

	func testApplyUnifiedPatch_Ts_Simple_Pass() throws {
		let path = "src/ts/patchables/Patch_SIMPLE.ts"
		var base: [String] = []
		base.append("export function a(n: number) {")
		base.append("    return n + 1")
		base.append("}")
		base.append("")
		base.append("export function b(s: string) {")
		base.append("    return s.toUpperCase()")
		base.append("}")
		base.append("")
		base.append("export const value = 42")
		let baseline = base.joined(separator: "\n")

		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,3 +1,3 @@")
		patch.append(" export function a(n: number) {")
		patch.append("-    return n + 1")
		patch.append("+    return n + 3")
		patch.append(" }")
		patch.append("@@ -5,3 +5,3 @@")
		patch.append(" export function b(s: string) {")
		patch.append("-    return s.toUpperCase()")
		patch.append("+    return s.toLowerCase()")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_simple",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 4,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_Ts_Medium_Pass() async throws {
		let path = "src/ts/patchables/Patch_MEDIUM.ts"

		// Baseline file
		var baseline: [String] = []
		baseline.append("export function a(n: number) {")
		baseline.append("    return n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("export function b(s: string) {")
		baseline.append("    return s.toUpperCase()")
		baseline.append("}")
		baseline.append("")
		baseline.append("export function c(xs: number[]): number {")
		baseline.append("    return xs.reduce((a, b) => a + b, 0)")
		baseline.append("}")
		baseline.append("")
		baseline.append("export const value = 42")

		// Expected file after changes (BOF addition + modify a + remove b)
		var expected: [String] = []
		expected.append("// NOTE: patched by benchmark")
		expected.append("")
		expected.append("export function a(n: number) {")
		expected.append("    return n + 3")
		expected.append("}")
		expected.append("")
		expected.append("export function c(xs: number[]): number {")
		expected.append("    return xs.reduce((a, b) => a + b, 0)")
		expected.append("}")
		expected.append("")
		expected.append("export const value = 42")

		// Generate proper unified diff
		let patchStr = try await UnifiedDiffGenerator.build(
			oldLines: baseline,
			newLines: expected,
			filePath: path
		)

		// Verify patch applies correctly
		let applied = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline.joined(separator: "\n")))
		XCTAssertEqual(applied, expected.joined(separator: "\n"))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_medium",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 7,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline.joined(separator: "\n")], editedFiles: [BenchmarkEditedFile(path: path, content: expected.joined(separator: "\n"))])
	}

	func testApplyUnifiedPatch_Ts_Hard_Pass() async throws {
		let path = "src/ts/patchables/Patch_HARD.ts"

		// Baseline file
		var baseline: [String] = []
		baseline.append("export function a(n: number) {")
		baseline.append("    return n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("export function b(s: string) {")
		baseline.append("    return s.toUpperCase()")
		baseline.append("}")
		baseline.append("")
		baseline.append("export function c(xs: number[]): number {")
		baseline.append("    return xs.reduce((a, b) => a + b, 0)")
		baseline.append("}")
		baseline.append("")
		baseline.append("export const value = 42")

		// Expected file (same as Medium but includes noise hunk test)
		var expected: [String] = []
		expected.append("// NOTE: patched by benchmark")
		expected.append("")
		expected.append("export function a(n: number) {")
		expected.append("    return n + 3")
		expected.append("}")
		expected.append("")
		expected.append("export function c(xs: number[]): number {")
		expected.append("    return xs.reduce((a, b) => a + b, 0)")
		expected.append("}")
		expected.append("")
		expected.append("export const value = 42")

		// Generate base diff (BOF + modify a + remove b)
		let patchStr = try await UnifiedDiffGenerator.build(
			oldLines: baseline,
			newLines: expected,
			filePath: path
		)

		// Append noise hunk (no-op change to test discrimination)
		let noise = buildTsNoiseHunk(baseline: baseline, filePath: path)
		let patchWithNoise = patchStr + (patchStr.hasSuffix("\n") ? "" : "\n") + noise + "\n"

		// Verify patch with noise hunk applies correctly
		let applied = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchWithNoise, to: baseline.joined(separator: "\n")))
		XCTAssertEqual(applied, expected.joined(separator: "\n"))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_hard",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 12,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchWithNoise)]
		)
		verifyPass(spec, baselineFiles: [path: baseline.joined(separator: "\n")], editedFiles: [BenchmarkEditedFile(path: path, content: expected.joined(separator: "\n"))])
	}

	// MARK: Go Difficulty Tests

	func testApplyUnifiedPatch_Go_Simple_Pass() throws {
		let path = "src/go/patchables/Patch_SIMPLE.go"
		var base: [String] = []
		base.append("package patchables")
		base.append("")
		base.append("func a(n int) int {")
		base.append("    return n + 1")
		base.append("}")
		base.append("")
		base.append("func b(s string) string {")
		base.append("    return s + s")
		base.append("}")
		base.append("")
		base.append("const value = 42")
		let baseline = base.joined(separator: "\n")

		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -3,3 +3,3 @@")
		patch.append(" func a(n int) int {")
		patch.append("-    return n + 1")
		patch.append("+    return n + 3")
		patch.append(" }")
		patch.append("@@ -7,3 +7,3 @@")
		patch.append(" func b(s string) string {")
		patch.append("-    return s + s")
		patch.append("+    return s")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_go_simple",
			type: .applyUnifiedPatchGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 4,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_Go_Medium_Pass() async throws {
		let path = "src/go/patchables/Patch_MEDIUM.go"

		// Baseline file
		var baseline: [String] = []
		baseline.append("package patchables")
		baseline.append("")
		baseline.append("func a(n int) int {")
		baseline.append("    return n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("func b(s string) string {")
		baseline.append("    return s + s")
		baseline.append("}")
		baseline.append("")
		baseline.append("func c(xs []int) int {")
		baseline.append("    return sum(xs)")
		baseline.append("}")
		baseline.append("")
		baseline.append("const value = 42")

		// Expected file after changes (BOF addition + modify a + remove b)
		var expected: [String] = []
		expected.append("// NOTE: patched by benchmark")
		expected.append("")
		expected.append("package patchables")
		expected.append("")
		expected.append("func a(n int) int {")
		expected.append("    return n + 3")
		expected.append("}")
		expected.append("")
		expected.append("func c(xs []int) int {")
		expected.append("    return sum(xs)")
		expected.append("}")
		expected.append("")
		expected.append("const value = 42")

		// Generate proper unified diff
		let patchStr = try await UnifiedDiffGenerator.build(
			oldLines: baseline,
			newLines: expected,
			filePath: path
		)

		// Verify patch applies correctly
		let applied = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline.joined(separator: "\n")))
		XCTAssertEqual(applied, expected.joined(separator: "\n"))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_go_medium",
			type: .applyUnifiedPatchGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 7,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline.joined(separator: "\n")], editedFiles: [BenchmarkEditedFile(path: path, content: expected.joined(separator: "\n"))])
	}

	func testApplyUnifiedPatch_Go_Hard_Pass() async throws {
		let path = "src/go/patchables/Patch_HARD.go"

		// Baseline file
		var baseline: [String] = []
		baseline.append("package patchables")
		baseline.append("")
		baseline.append("func a(n int) int {")
		baseline.append("    return n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("func b(s string) string {")
		baseline.append("    return s + s")
		baseline.append("}")
		baseline.append("")
		baseline.append("func c(xs []int) int {")
		baseline.append("    return sum(xs)")
		baseline.append("}")
		baseline.append("")
		baseline.append("const value = 42")

		// Expected file (same as Medium but includes noise hunk test)
		var expected: [String] = []
		expected.append("// NOTE: patched by benchmark")
		expected.append("")
		expected.append("package patchables")
		expected.append("")
		expected.append("func a(n int) int {")
		expected.append("    return n + 3")
		expected.append("}")
		expected.append("")
		expected.append("func c(xs []int) int {")
		expected.append("    return sum(xs)")
		expected.append("}")
		expected.append("")
		expected.append("const value = 42")

		// Generate base diff (BOF + modify a + remove b)
		let patchStr = try await UnifiedDiffGenerator.build(
			oldLines: baseline,
			newLines: expected,
			filePath: path
		)

		// Append noise hunk (no-op change to test discrimination)
		let noise = buildGoNoiseHunk(baseline: baseline, filePath: path)
		let patchWithNoise = patchStr + (patchStr.hasSuffix("\n") ? "" : "\n") + noise + "\n"

		// Verify patch with noise hunk applies correctly
		let applied = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchWithNoise, to: baseline.joined(separator: "\n")))
		XCTAssertEqual(applied, expected.joined(separator: "\n"))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_go_hard",
			type: .applyUnifiedPatchGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 12,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchWithNoise)]
		)
		verifyPass(spec, baselineFiles: [path: baseline.joined(separator: "\n")], editedFiles: [BenchmarkEditedFile(path: path, content: expected.joined(separator: "\n"))])
	}

	// MARK: Swift Difficulty Tests

	func testApplyUnifiedPatch_Swift_Simple_Pass() throws {
		let path = "src/swift/patchables/Patch_SIMPLE.swift"
		var base: [String] = []
		base.append("public func a(_ n: Int) -> Int {")
		base.append("\treturn n + 1")
		base.append("}")
		base.append("")
		base.append("public func b(_ s: String) -> String {")
		base.append("\treturn s.uppercased()")
		base.append("}")
		base.append("")
		base.append("public let value = 42")
		let baseline = base.joined(separator: "\n")

		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,3 +1,3 @@")
		patch.append(" public func a(_ n: Int) -> Int {")
		patch.append("-\treturn n + 1")
		patch.append("+\treturn n + 3")
		patch.append(" }")
		patch.append("@@ -5,3 +5,3 @@")
		patch.append(" public func b(_ s: String) -> String {")
		patch.append("-\treturn s.uppercased()")
		patch.append("+\treturn s.lowercased()")
		patch.append(" }")
		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_swift_simple",
			type: .applyUnifiedPatchSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 4,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_Swift_Medium_Pass() async throws {
		let path = "src/swift/patchables/Patch_MEDIUM.swift"

		// Baseline file
		var baseline: [String] = []
		baseline.append("public func a(_ n: Int) -> Int {")
		baseline.append("\treturn n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("public func b(_ s: String) -> String {")
		baseline.append("\treturn s.uppercased()")
		baseline.append("}")
		baseline.append("")
		baseline.append("public func c(_ xs: [Int]) -> Int {")
		baseline.append("\treturn xs.reduce(0, +)")
		baseline.append("}")
		baseline.append("")
		baseline.append("public let value = 42")

		// Expected file after changes (BOF addition + modify a + remove b)
		var expected: [String] = []
		expected.append("// NOTE: patched by benchmark")
		expected.append("")
		expected.append("public func a(_ n: Int) -> Int {")
		expected.append("\treturn n + 3")
		expected.append("}")
		expected.append("")
		expected.append("public func c(_ xs: [Int]) -> Int {")
		expected.append("\treturn xs.reduce(0, +)")
		expected.append("}")
		expected.append("")
		expected.append("public let value = 42")

		// Generate proper unified diff
		let patchStr = try await UnifiedDiffGenerator.build(
			oldLines: baseline,
			newLines: expected,
			filePath: path
		)

		// Verify patch applies correctly
		let applied = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline.joined(separator: "\n")))
		XCTAssertEqual(applied, expected.joined(separator: "\n"))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_swift_medium",
			type: .applyUnifiedPatchSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 7,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline.joined(separator: "\n")], editedFiles: [BenchmarkEditedFile(path: path, content: expected.joined(separator: "\n"))])
	}

	func testApplyUnifiedPatch_Swift_Hard_Pass() async throws {
		let path = "src/swift/patchables/Patch_HARD.swift"

		// Baseline file
		var baseline: [String] = []
		baseline.append("public func a(_ n: Int) -> Int {")
		baseline.append("\treturn n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("public func b(_ s: String) -> String {")
		baseline.append("\treturn s.uppercased()")
		baseline.append("}")
		baseline.append("")
		baseline.append("public func c(_ xs: [Int]) -> Int {")
		baseline.append("\treturn xs.reduce(0, +)")
		baseline.append("}")
		baseline.append("")
		baseline.append("public let value = 42")

		// Expected file (same as Medium but includes noise hunk test)
		var expected: [String] = []
		expected.append("// NOTE: patched by benchmark")
		expected.append("")
		expected.append("public func a(_ n: Int) -> Int {")
		expected.append("\treturn n + 3")
		expected.append("}")
		expected.append("")
		expected.append("public func c(_ xs: [Int]) -> Int {")
		expected.append("\treturn xs.reduce(0, +)")
		expected.append("}")
		expected.append("")
		expected.append("public let value = 42")

		// Generate base diff (BOF + modify a + remove b)
		let patchStr = try await UnifiedDiffGenerator.build(
			oldLines: baseline,
			newLines: expected,
			filePath: path
		)

		// Append noise hunk (no-op change to test discrimination)
		let noise = buildSwiftNoiseHunk(baseline: baseline, filePath: path)
		let patchWithNoise = patchStr + (patchStr.hasSuffix("\n") ? "" : "\n") + noise + "\n"

		// Verify patch with noise hunk applies correctly
		let applied = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchWithNoise, to: baseline.joined(separator: "\n")))
		XCTAssertEqual(applied, expected.joined(separator: "\n"))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_swift_hard",
			type: .applyUnifiedPatchSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 12,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchWithNoise)]
		)
		verifyPass(spec, baselineFiles: [path: baseline.joined(separator: "\n")], editedFiles: [BenchmarkEditedFile(path: path, content: expected.joined(separator: "\n"))])
	}

	// MARK: - Unified Patch VeryHard Tests

	func testApplyUnifiedPatch_Ts_VeryHard_Pass() async throws {
		let path = "src/ts/patchables/Patch_VERYHARD.ts"

		// Build multi-section baseline (Section 1: a/b/c + value, Section 2: d/e/f + value2, Section 3: g/h + value3)
		var baseline: [String] = []
		// Section 1
		baseline.append("export function a(n: number) {")
		baseline.append("    return n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("export function b(s: string) {")
		baseline.append("    return s.toUpperCase()")
		baseline.append("}")
		baseline.append("")
		baseline.append("export function c(xs: number[]): number {")
		baseline.append("    return xs.reduce((a, b) => a + b, 0)")
		baseline.append("}")
		baseline.append("")
		baseline.append("export const value = 42")
		// Section 2
		baseline.append("")
		baseline.append("export function d(n: number) {")
		baseline.append("    return n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("export function e(s: string) {")
		baseline.append("    return s.toLowerCase()")
		baseline.append("}")
		baseline.append("")
		baseline.append("export function f(xs: number[]): number {")
		baseline.append("    return xs.length")
		baseline.append("}")
		baseline.append("")
		baseline.append("export const value2 = 7")
		// Section 3
		baseline.append("")
		baseline.append("export function g(n: number) {")
		baseline.append("    return n * 2")
		baseline.append("}")
		baseline.append("")
		baseline.append("export function h(s: string) {")
		baseline.append("    return s")
		baseline.append("}")
		baseline.append("")
		baseline.append("export const value3 = 100")

		// Build expected VeryHard result
		var expected: [String] = []
		expected.append("// NOTE: patched by benchmark")
		expected.append("")
		expected.append("export function a(n: number) {")
		expected.append("    return n + 3")
		expected.append("}")
		expected.append("")
		expected.append("export function c(xs: number[]): number {")
		expected.append("    return xs.reduce((a, b) => a + b, 0)")
		expected.append("}")
		expected.append("")
		expected.append("export const value = 42")
		expected.append("")
		expected.append("export function d(n: number) {")
		expected.append("    return n + 3")
		expected.append("}")
		expected.append("")
		expected.append("export function f(xs: number[]): number {")
		expected.append("    return xs.length")
		expected.append("}")
		expected.append("")
		expected.append("export const value2 = 7")
		expected.append("")
		expected.append("export function g(n: number) {")
		expected.append("    return n * 3")
		expected.append("}")
		expected.append("")
		expected.append("export const value3 = 100")

		// Generate unified diff and append noise hunks for value and value2
		let patchStr = try await UnifiedDiffGenerator.build(
			oldLines: baseline,
			newLines: expected,
			filePath: path
		)
		let noise1 = buildTsNoiseHunk(baseline: baseline, filePath: path)
		let noise2 = buildTsNoiseHunkValue2(baseline: baseline, filePath: path)
		let patchWithNoise = patchStr + (patchStr.hasSuffix("\n") ? "" : "\n") + noise1 + "\n" + noise2 + "\n"

		// Verify patch applies correctly
		let applied = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(
			patch: patchWithNoise,
			to: baseline.joined(separator: "\n")
		))
		XCTAssertEqual(applied, expected.joined(separator: "\n"))

		// Verify via benchmark spec
		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_veryhard",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 28,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchWithNoise)]
		)
		verifyPass(spec,
					baselineFiles: [path: baseline.joined(separator: "\n")],
					editedFiles: [BenchmarkEditedFile(path: path, content: expected.joined(separator: "\n"))])
	}

	func testApplyUnifiedPatch_Go_VeryHard_Pass() async throws {
		let path = "src/go/patchables/Patch_VERYHARD.go"

		// Build multi-section baseline
		var baseline: [String] = []
		baseline.append("package patchables")
		baseline.append("")
		baseline.append("func a(n int) int {")
		baseline.append("    return n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("func b(s string) string {")
		baseline.append("    return s + s")
		baseline.append("}")
		baseline.append("")
		baseline.append("func c(xs []int) int {")
		baseline.append("    return sum(xs)")
		baseline.append("}")
		baseline.append("")
		baseline.append("const value = 42")
		// Section 2
		baseline.append("")
		baseline.append("func d(n int) int {")
		baseline.append("    return n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("func e(s string) string {")
		baseline.append("    return s")
		baseline.append("}")
		baseline.append("")
		baseline.append("func f(xs []int) int {")
		baseline.append("    return len(xs)")
		baseline.append("}")
		baseline.append("")
		baseline.append("const value2 = 7")
		// Section 3
		baseline.append("")
		baseline.append("func g(n int) int {")
		baseline.append("    return n * 2")
		baseline.append("}")
		baseline.append("")
		baseline.append("func h(s string) string {")
		baseline.append("    return s")
		baseline.append("}")
		baseline.append("")
		baseline.append("const value3 = 100")

		// Expected result
		var expected: [String] = []
		expected.append("// NOTE: patched by benchmark")
		expected.append("")
		expected.append("package patchables")
		expected.append("")
		expected.append("func a(n int) int {")
		expected.append("    return n + 3")
		expected.append("}")
		expected.append("")
		expected.append("func c(xs []int) int {")
		expected.append("    return sum(xs)")
		expected.append("}")
		expected.append("")
		expected.append("const value = 42")
		expected.append("")
		expected.append("func d(n int) int {")
		expected.append("    return n + 3")
		expected.append("}")
		expected.append("")
		expected.append("func f(xs []int) int {")
		expected.append("    return len(xs)")
		expected.append("}")
		expected.append("")
		expected.append("const value2 = 7")
		expected.append("")
		expected.append("func g(n int) int {")
		expected.append("    return n * 3")
		expected.append("}")
		expected.append("")
		expected.append("const value3 = 100")

		// Diff and noise hunks
		let patchStr = try await UnifiedDiffGenerator.build(
			oldLines: baseline,
			newLines: expected,
			filePath: path
		)
		let noise1 = buildGoNoiseHunk(baseline: baseline, filePath: path)
		let noise2 = buildGoNoiseHunkValue2(baseline: baseline, filePath: path)
		let patchWithNoise = patchStr + (patchStr.hasSuffix("\n") ? "" : "\n") + noise1 + "\n" + noise2 + "\n"

		let applied = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(
			patch: patchWithNoise,
			to: baseline.joined(separator: "\n")
		))
		XCTAssertEqual(applied, expected.joined(separator: "\n"))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_go_veryhard",
			type: .applyUnifiedPatchGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 28,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchWithNoise)]
		)
		verifyPass(spec,
					baselineFiles: [path: baseline.joined(separator: "\n")],
					editedFiles: [BenchmarkEditedFile(path: path, content: expected.joined(separator: "\n"))])
	}

	func testApplyUnifiedPatch_Swift_VeryHard_Pass() async throws {
		let path = "src/swift/patchables/Patch_VERYHARD.swift"

		// Baseline (Swift uses tabs for indentation on return lines)
		var baseline: [String] = []
		baseline.append("public func a(_ n: Int) -> Int {")
		baseline.append("\treturn n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("public func b(_ s: String) -> String {")
		baseline.append("\treturn s.uppercased()")
		baseline.append("}")
		baseline.append("")
		baseline.append("public func c(_ xs: [Int]) -> Int {")
		baseline.append("\treturn xs.reduce(0, +)")
		baseline.append("}")
		baseline.append("")
		baseline.append("public let value = 42")
		// Section 2
		baseline.append("")
		baseline.append("public func d(_ n: Int) -> Int {")
		baseline.append("\treturn n + 1")
		baseline.append("}")
		baseline.append("")
		baseline.append("public func e(_ s: String) -> String {")
		baseline.append("\treturn s")
		baseline.append("}")
		baseline.append("")
		baseline.append("public func f(_ xs: [Int]) -> Int {")
		baseline.append("\treturn xs.count")
		baseline.append("}")
		baseline.append("")
		baseline.append("public let value2 = 7")
		// Section 3
		baseline.append("")
		baseline.append("public func g(_ n: Int) -> Int {")
		baseline.append("\treturn n * 2")
		baseline.append("}")
		baseline.append("")
		baseline.append("public func h(_ s: String) -> String {")
		baseline.append("\treturn s")
		baseline.append("}")
		baseline.append("")
		baseline.append("public let value3 = 100")

		// Expected
		var expected: [String] = []
		expected.append("// NOTE: patched by benchmark")
		expected.append("")
		expected.append("public func a(_ n: Int) -> Int {")
		expected.append("\treturn n + 3")
		expected.append("}")
		expected.append("")
		expected.append("public func c(_ xs: [Int]) -> Int {")
		expected.append("\treturn xs.reduce(0, +)")
		expected.append("}")
		expected.append("")
		expected.append("public let value = 42")
		expected.append("")
		expected.append("public func d(_ n: Int) -> Int {")
		expected.append("\treturn n + 3")
		expected.append("}")
		expected.append("")
		expected.append("public func f(_ xs: [Int]) -> Int {")
		expected.append("\treturn xs.count")
		expected.append("}")
		expected.append("")
		expected.append("public let value2 = 7")
		expected.append("")
		expected.append("public func g(_ n: Int) -> Int {")
		expected.append("\treturn n * 3")
		expected.append("}")
		expected.append("")
		expected.append("public let value3 = 100")

		let patchStr = try await UnifiedDiffGenerator.build(
			oldLines: baseline,
			newLines: expected,
			filePath: path
		)
		let noise1 = buildSwiftNoiseHunk(baseline: baseline, filePath: path)
		let noise2 = buildSwiftNoiseHunkValue2(baseline: baseline, filePath: path)
		let patchWithNoise = patchStr + (patchStr.hasSuffix("\n") ? "" : "\n") + noise1 + "\n" + noise2 + "\n"

		let applied = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(
			patch: patchWithNoise,
			to: baseline.joined(separator: "\n")
		))
		XCTAssertEqual(applied, expected.joined(separator: "\n"))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_swift_veryhard",
			type: .applyUnifiedPatchSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 28,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchWithNoise)]
		)
		verifyPass(spec,
					baselineFiles: [path: baseline.joined(separator: "\n")],
					editedFiles: [BenchmarkEditedFile(path: path, content: expected.joined(separator: "\n"))])
	}

	// MARK: - Complex Patch Scenarios (EOF/BOF additions, function removal)
	//
	// NOTE: These tests cover EOF additions which are NOT included in the actual benchmark
	// generators (they were removed to avoid common model failures). However, we keep these
	// tests to document the correct implementation patterns for reference.

	func testApplyUnifiedPatch_Go_WithEOFAddition_Pass() throws {
		// Tests EOF addition pattern: @@ -N,0 +N,M @@ (no existing context)
		// This pattern was removed from the benchmark but is kept here for documentation
		let path = "src/go/patchables/Patch_EOFTEST.go"
		var base: [String] = []
		base.append("package patchables")
		base.append("")
		base.append("func a(n int) int {")
		base.append("    return n + 1")
		base.append("}")
		base.append("")
		base.append("func b(s string) string {")
		base.append("    return s + s")
		base.append("}")
		base.append("")
		let baseline = base.joined(separator: "\n")

		// This patch matches the exact pattern from generateUnifiedPatchGoTask
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -3,3 +3,3 @@")
		patch.append(" func a(n int) int {")
		patch.append("-    return n + 1")
		patch.append("+    return n + 4")
		patch.append(" }")
		patch.append("@@ -7,3 +7,3 @@")
		patch.append(" func b(s string) string {")
		patch.append("-    return s + s")
		patch.append("+    return s")
		patch.append(" }")
		patch.append("@@ -11,0 +11,2 @@")  // EOF addition with no context
		patch.append("+const value = 42")
		patch.append("+")

		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))

		// The expected result should match what SimpleUnifiedPatchApplier produces
		// Note: EOF additions may include trailing newlines based on patch format

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_go_eof",
			type: .applyUnifiedPatchGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 7,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_Ts_WithBOFAddition_Pass() throws {
		// Tests BOF (beginning of file) addition: @@ -1,0 +1,N @@
		let path = "src/ts/patchables/Patch_BOFTEST.ts"
		var base: [String] = []
		base.append("export function a(n: number) {")
		base.append("    return n + 1")
		base.append("}")
		base.append("")
		base.append("export function b(s: string) {")
		base.append("    return s.toUpperCase()")
		base.append("}")
		base.append("")
		base.append("export const value = 42")
		let baseline = base.joined(separator: "\n")

		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,0 +1,2 @@")  // BOF addition with no context
		patch.append("+// NOTE: patched by benchmark")
		patch.append("+")
		patch.append("@@ -1,3 +3,3 @@")
		patch.append(" export function a(n: number) {")
		patch.append("-    return n + 1")
		patch.append("+    return n + 2")
		patch.append(" }")

		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_bof",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 8,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_Ts_WithFunctionRemoval_Pass() throws {
		// Tests complete function removal from middle of file
		let path = "src/ts/patchables/Patch_RMTEST.ts"
		var base: [String] = []
		base.append("export function a(n: number) {")
		base.append("    return n + 1")
		base.append("}")
		base.append("")
		base.append("export function b(s: string) {")
		base.append("    return s.toUpperCase()")
		base.append("}")
		base.append("")
		base.append("export function c(xs: number[]): number {")
		base.append("    return xs.reduce((a, b) => a + b, 0)")
		base.append("}")
		base.append("")
		base.append("export const value = 42")
		let baseline = base.joined(separator: "\n")

		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -4,6 +4,2 @@")  // Remove function b (6 lines -> 2 lines)
		patch.append(" ")
		patch.append("-export function b(s: string) {")
		patch.append("-    return s.toUpperCase()")
		patch.append("-}")
		patch.append("-")
		patch.append(" export function c(xs: number[]): number {")

		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_removal",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 6,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	func testApplyUnifiedPatch_Ts_ComplexMultiHunk_Pass() throws {
		// Tests a complex multi-hunk pattern combining: BOF addition, modify, function removal, and EOF addition
		// NOTE: The actual benchmark no longer includes EOF additions, but this test documents the full pattern
		let path = "src/ts/patchables/Patch_COMPLEX.ts"
		var base: [String] = []
		base.append("export function a(n: number) {")
		base.append("    return n + 1")
		base.append("}")
		base.append("")
		base.append("export function b(s: string) {")
		base.append("    return s.toUpperCase()")
		base.append("}")
		base.append("")
		base.append("export function c(xs: number[]): number {")
		base.append("    return xs.reduce((a, b) => a + b, 0)")
		base.append("}")
		base.append("")
		base.append("export const value = 42")
		let baseline = base.joined(separator: "\n")

		// This matches the exact pattern from the generator
		var patch: [String] = []
		patch.append("--- a/\(path)")
		patch.append("+++ b/\(path)")
		patch.append("@@ -1,0 +1,2 @@")  // BOF header addition
		patch.append("+// NOTE: patched by benchmark")
		patch.append("+")
		patch.append("@@ -1,3 +3,3 @@")  // Modify function a
		patch.append(" export function a(n: number) {")
		patch.append("-    return n + 1")
		patch.append("+    return n + 3")
		patch.append(" }")
		patch.append("@@ -4,6 +6,2 @@")  // Remove function b
		patch.append(" ")
		patch.append("-export function b(s: string) {")
		patch.append("-    return s.toUpperCase()")
		patch.append("-}")
		patch.append("-")
		patch.append(" export function c(xs: number[]): number {")
		patch.append("@@ -14,0 +12,2 @@")  // EOF addition
		patch.append("+export const add = (x: number) => (y: number) => x + y;")
		patch.append("+")

		let patchStr = patch.joined(separator: "\n")
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patchStr, to: baseline))

		let spec = BenchmarkTaskSpec(
			id: "apply_unified_patch_ts_complex",
			type: .applyUnifiedPatchTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 12,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["patch": .string(patchStr)]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: expected)])
	}

	// MARK: - Function Modifier Edge Cases

	func testMoveFunction_Swift_PrivateModifier_Pass() {
		let path = "src/swift/reorder/Order.swift"
		let baseline = """
private func alpha(_ n: Int) -> Int { return n * 1 }

private func bravo(_ n: Int) -> Int { return n * 2 }

private func charlie(_ n: Int) -> Int { return n * 3 }

// FOOTER: keep below here unchanged
"""
		let final = """
private func bravo(_ n: Int) -> Int { return n * 2 }

private func charlie(_ n: Int) -> Int { return n * 3 }

private func alpha(_ n: Int) -> Int { return n * 1 }

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
			params: ["fromName": .string("alpha"), "afterName": .string("charlie")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Swift_InternalModifier_Pass() {
		let path = "src/swift/reorder/Order.swift"
		let baseline = """
internal func alpha(_ n: Int) -> Int { return n * 1 }

internal func bravo(_ n: Int) -> Int { return n * 2 }

internal func charlie(_ n: Int) -> Int { return n * 3 }

// FOOTER: keep below here unchanged
"""
		let final = """
internal func bravo(_ n: Int) -> Int { return n * 2 }

internal func charlie(_ n: Int) -> Int { return n * 3 }

internal func alpha(_ n: Int) -> Int { return n * 1 }

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
			params: ["fromName": .string("alpha"), "afterName": .string("charlie")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Swift_StaticModifier_Pass() {
		let path = "src/swift/reorder/Order.swift"
		let baseline = """
public static func alpha(_ n: Int) -> Int { return n * 1 }

public static func bravo(_ n: Int) -> Int { return n * 2 }

public static func charlie(_ n: Int) -> Int { return n * 3 }

// FOOTER: keep below here unchanged
"""
		let final = """
public static func bravo(_ n: Int) -> Int { return n * 2 }

public static func charlie(_ n: Int) -> Int { return n * 3 }

public static func alpha(_ n: Int) -> Int { return n * 1 }

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
			params: ["fromName": .string("alpha"), "afterName": .string("charlie")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Swift_MultipleModifiers_Pass() {
		let path = "src/swift/reorder/Order.swift"
		let baseline = """
@objc private func alpha(_ n: Int) -> Int { return n * 1 }

@objc private func bravo(_ n: Int) -> Int { return n * 2 }

@objc private func charlie(_ n: Int) -> Int { return n * 3 }

// FOOTER: keep below here unchanged
"""
		let final = """
@objc private func bravo(_ n: Int) -> Int { return n * 2 }

@objc private func charlie(_ n: Int) -> Int { return n * 3 }

@objc private func alpha(_ n: Int) -> Int { return n * 1 }

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
			params: ["fromName": .string("alpha"), "afterName": .string("charlie")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Ts_AsyncFunction_Pass() {
		let path = "src/ts/reorder/Order.ts"
		let baseline = """
export async function alpha(n: number): Promise<number> { return n * 1; }

export async function bravo(n: number): Promise<number> { return n * 2; }

export async function charlie(n: number): Promise<number> { return n * 3; }

// FOOTER: keep below here unchanged
"""
		let final = """
export async function bravo(n: number): Promise<number> { return n * 2; }

export async function charlie(n: number): Promise<number> { return n * 3; }

export async function alpha(n: number): Promise<number> { return n * 1; }

// FOOTER: keep below here unchanged
"""
		let spec = BenchmarkTaskSpec(
			id: "move_function_ts",
			type: .moveFunctionTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["fromName": .string("alpha"), "afterName": .string("charlie")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Ts_ExportAsyncFunction_Pass() {
		let path = "src/ts/reorder/Order.ts"
		let baseline = """
export async function alpha(n: number): Promise<number> {
	return n * 1;
}

export async function bravo(n: number): Promise<number> {
	return n * 2;
}

export async function charlie(n: number): Promise<number> {
	return n * 3;
}

// FOOTER: keep below here unchanged
"""
		let final = """
export async function bravo(n: number): Promise<number> {
	return n * 2;
}

export async function charlie(n: number): Promise<number> {
	return n * 3;
}

export async function alpha(n: number): Promise<number> {
	return n * 1;
}

// FOOTER: keep below here unchanged
"""
		let spec = BenchmarkTaskSpec(
			id: "move_function_ts",
			type: .moveFunctionTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["fromName": .string("alpha"), "afterName": .string("charlie")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	// MARK: - Scoring Threshold Tests (Pass)

	func testMoveFunction_ExactlyAtThreshold_Pass() {
		let path = "src/ts/reorder/Order.ts"
		let baseline = """
export function alpha(n: number): number { return n * 1; }

export function bravo(n: number): number { return n * 2; }

// FOOTER: keep below here unchanged
"""
		let final = """
export function bravo(n: number): number { return n * 2; }

export function alpha(n: number): number { return n * 1; }

// FOOTER: keep below here unchanged
"""
		let spec = BenchmarkTaskSpec(
			id: "move_function_ts",
			type: .moveFunctionTs,
			language: .ts,
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
		XCTAssertTrue(out.pass)
		XCTAssertEqual(out.score, 1.0, accuracy: 0.01)
	}

	// MARK: - Whitespace Boundary Conditions

	func testMoveFunction_NoTrailingNewline_Pass() {
		let path = "src/ts/reorder/Order.ts"
		let baseline = "export function alpha(n: number): number { return n * 1; }\n\nexport function bravo(n: number): number { return n * 2; }\n\n// FOOTER"
		let final = "export function bravo(n: number): number { return n * 2; }\n\nexport function alpha(n: number): number { return n * 1; }\n\n// FOOTER"
		let spec = BenchmarkTaskSpec(
			id: "move_function_ts",
			type: .moveFunctionTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["fromName": .string("alpha"), "afterName": .string("bravo")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_MultipleBlankLines_Pass() {
		let path = "src/go/reorder/Order.go"
		let baseline = """
package reorder

func alpha(n int) int { return n * 1 }



func bravo(n int) int { return n * 2 }



func charlie(n int) int { return n * 3 }

// FOOTER
"""
		let final = """
package reorder

func bravo(n int) int { return n * 2 }



func charlie(n int) int { return n * 3 }



func alpha(n int) int { return n * 1 }

// FOOTER
"""
		let spec = BenchmarkTaskSpec(
			id: "move_function_go",
			type: .moveFunctionGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["fromName": .string("alpha"), "afterName": .string("charlie")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testInsertFunctionBottom_EmptyLinesBefore_Pass() {
		let path = "src/swift/work/Work.swift"
		let footer = "// END-OF-FILE"
		let baseline = """
public func ping(_ x: String) -> String { "ping:\\(x)" }

public func pong(_ y: Int) -> Int { y + 1 }

\(footer)
"""
		let snippet = """


public func add(_ a: Int, _ b: Int) -> Int { a + b }

"""
		let final = """
public func ping(_ x: String) -> String { "ping:\\(x)" }

public func pong(_ y: Int) -> Int { y + 1 }

\(snippet)
\(footer)
"""
		let spec = BenchmarkTaskSpec(
			id: "insert_function_bottom_swift",
			type: .insertFunctionBottomSwift,
			language: .swift,
			selectFiles: [path],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: [
				"inserts": .array([
					.object([
						"path": .string(path),
						"snippet": .string(snippet),
						"footer": .string(footer)
					])
				])
			]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	// MARK: - Language Consistency Tests

	func testRemoveX_AllLanguages_SameLogic() {
		// Test that remove_x logic works consistently across TS, Go, Swift
		let tsPath = "src/ts/Alpha.ts"
		let goPath = "src/go/Alpha.go"
		let swiftPath = "src/swift/Alpha.swift"

		let tsBaseline = """
export function alpha(values: number[]): number {
    let total = 0;
    for (const value of values) {
        total += CALL_X(value);
    }
    return total;
}
"""
		let tsFinal = """
export function alpha(values: number[]): number {
    let total = 0;
    for (const value of values) {
        total += value;
    }
    return total;
}
"""

		let goBaseline = """
package alpha

func Alpha(values []int) int {
	total := 0
	for _, v := range values {
		total += CALL_X(v)
	}
	return total
}
"""
		let goFinal = """
package alpha

func Alpha(values []int) int {
	total := 0
	for _, v := range values {
		total += v
	}
	return total
}
"""

		let swiftBaseline = """
public func alpha(_ values: [Int]) -> Int {
	var total = 0
	for v in values {
		total += CALL_X(v)
	}
	return total
}
"""
		let swiftFinal = """
public func alpha(_ values: [Int]) -> Int {
	var total = 0
	for v in values {
		total += v
	}
	return total
}
"""

		// Test TypeScript
		let tsSpec = BenchmarkTaskSpec(
			id: "remove_x_ts",
			type: .removeXTs,
			language: .ts,
			selectFiles: [tsPath],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(tsPath), "target": .string("CALL_X(")]
		)
		verifyPass(tsSpec, baselineFiles: [tsPath: tsBaseline], editedFiles: [BenchmarkEditedFile(path: tsPath, content: tsFinal)])

		// Test Go
		let goSpec = BenchmarkTaskSpec(
			id: "remove_x_go",
			type: .removeXGo,
			language: .go,
			selectFiles: [goPath],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(goPath), "target": .string("CALL_X(")]
		)
		verifyPass(goSpec, baselineFiles: [goPath: goBaseline], editedFiles: [BenchmarkEditedFile(path: goPath, content: goFinal)])

		// Test Swift
		let swiftSpec = BenchmarkTaskSpec(
			id: "remove_x_swift",
			type: .removeXSwift,
			language: .swift,
			selectFiles: [swiftPath],
			maxEdits: 3,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(swiftPath), "target": .string("CALL_X(")]
		)
		verifyPass(swiftSpec, baselineFiles: [swiftPath: swiftBaseline], editedFiles: [BenchmarkEditedFile(path: swiftPath, content: swiftFinal)])
	}

	func testCurlyFix_AllLanguages_SameLogic() {
		// Test that curly_fix logic works consistently across TS, Go, Swift
		let tsPath = "src/ts/main.ts"
		let goPath = "src/go/main.go"
		let swiftPath = "src/swift/main.swift"

		let tsBaseline = """
export function main() {
	let sum = 0
	for (let i = 0; i < 5; i++) {
		sum += i
	console.log(sum)
"""
		let tsFinal = """
export function main() {
	let sum = 0
	for (let i = 0; i < 5; i++) {
		sum += i
	}
	console.log(sum)
}
"""

		let goBaseline = """
package main

import "fmt"

func main() {
	sum := 0
	for i := 0; i < 5; i++ {
		sum += i
	fmt.Println(sum)
"""
		let goFinal = """
package main

import "fmt"

func main() {
	sum := 0
	for i := 0; i < 5; i++ {
		sum += i
	}
	fmt.Println(sum)
}
"""

		let swiftBaseline = """
import Foundation

func main() {
	var sum = 0
	for i in 0..<5 {
		sum += i
	print(sum)
"""
		let swiftFinal = """
import Foundation

func main() {
	var sum = 0
	for i in 0..<5 {
		sum += i
	}
	print(sum)
}
"""

		// Test TypeScript
		let tsSpec = BenchmarkTaskSpec(
			id: "curly_fix_ts",
			type: .curlyFixTs,
			language: .ts,
			selectFiles: [tsPath],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(tsPath)]
		)
		verifyPass(tsSpec, baselineFiles: [tsPath: tsBaseline], editedFiles: [BenchmarkEditedFile(path: tsPath, content: tsFinal)])

		// Test Go
		let goSpec = BenchmarkTaskSpec(
			id: "curly_fix_go",
			type: .curlyFixGo,
			language: .go,
			selectFiles: [goPath],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(goPath)]
		)
		verifyPass(goSpec, baselineFiles: [goPath: goBaseline], editedFiles: [BenchmarkEditedFile(path: goPath, content: goFinal)])

		// Test Swift
		let swiftSpec = BenchmarkTaskSpec(
			id: "curly_fix_swift",
			type: .curlyFixSwift,
			language: .swift,
			selectFiles: [swiftPath],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["file": .string(swiftPath)]
		)
		verifyPass(swiftSpec, baselineFiles: [swiftPath: swiftBaseline], editedFiles: [BenchmarkEditedFile(path: swiftPath, content: swiftFinal)])
	}

	func testInsertGuard_AllLanguages_SameLogic() {
		// Test that insert_guard logic works consistently across TS, Go, Swift
		let tsPath = "src/ts/work/Work.ts"
		let goPath = "src/go/work/Work.go"
		let swiftPath = "src/swift/work/Work.swift"

		let tsUid = "LANG1"
		let goUid = "LANG2"
		let swiftUid = "LANG3"

		let tsSnippet = """
if (n < 0) {
    return 0;
}
"""
		let goSnippet = """
if n < 0 {
    return 0
}
"""
		let swiftSnippet = """
if n < 0 {
	return 0
}
"""

		let tsBaseline = """
export function clamp(n: number): number {
    const limit = 100;
    // ANCHOR:start:\(tsUid)
    const normalized = Math.abs(n);
    // ANCHOR:end:\(tsUid)
    return Math.min(normalized, limit);
}
"""
		let tsFinal = """
export function clamp(n: number): number {
    const limit = 100;
    // ANCHOR:start:\(tsUid)
    if (n < 0) {
        return 0;
    }
    const normalized = Math.abs(n);
    // ANCHOR:end:\(tsUid)
    return Math.min(normalized, limit);
}
"""

		let goBaseline = """
package work

func Clamp(n int) int {
    limit := 100
    // ANCHOR:start:\(goUid)
    normalized := n
    // ANCHOR:end:\(goUid)
    if normalized > limit { return limit }
    return normalized
}
"""
		let goFinal = """
package work

func Clamp(n int) int {
    limit := 100
    // ANCHOR:start:\(goUid)
    if n < 0 {
        return 0
    }
    normalized := n
    // ANCHOR:end:\(goUid)
    if normalized > limit { return limit }
    return normalized
}
"""

		let swiftBaseline = """
public func clamp(_ n: Int) -> Int {
	let limit = 100
	// ANCHOR:start:\(swiftUid)
	let normalized = abs(n)
	// ANCHOR:end:\(swiftUid)
	return min(normalized, limit)
}
"""
		let swiftFinal = """
public func clamp(_ n: Int) -> Int {
	let limit = 100
	// ANCHOR:start:\(swiftUid)
	if n < 0 {
		return 0
	}
	let normalized = abs(n)
	// ANCHOR:end:\(swiftUid)
	return min(normalized, limit)
}
"""

		// Test TypeScript
		let tsSpec = BenchmarkTaskSpec(
			id: "insert_guard_ts",
			type: .insertGuardTs,
			language: .ts,
			selectFiles: [tsPath],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(tsUid), "snippet": .string(tsSnippet)]
		)
		verifyPass(tsSpec, baselineFiles: [tsPath: tsBaseline], editedFiles: [BenchmarkEditedFile(path: tsPath, content: tsFinal)])

		// Test Go
		let goSpec = BenchmarkTaskSpec(
			id: "insert_guard_go",
			type: .insertGuardGo,
			language: .go,
			selectFiles: [goPath],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(goUid), "snippet": .string(goSnippet)]
		)
		verifyPass(goSpec, baselineFiles: [goPath: goBaseline], editedFiles: [BenchmarkEditedFile(path: goPath, content: goFinal)])

		// Test Swift
		let swiftSpec = BenchmarkTaskSpec(
			id: "insert_guard_swift",
			type: .insertGuardSwift,
			language: .swift,
			selectFiles: [swiftPath],
			maxEdits: 1,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["uid": .string(swiftUid), "snippet": .string(swiftSnippet)]
		)
		verifyPass(swiftSpec, baselineFiles: [swiftPath: swiftBaseline], editedFiles: [BenchmarkEditedFile(path: swiftPath, content: swiftFinal)])
	}

	// MARK: - Function Detection Robustness Tests

	func testMoveFunction_Swift_GenericFunction_Pass() {
		// Test detection of generic functions with type parameters
		let path = "src/swift/reorder/Order.swift"
		let baseline = """
public func alpha<T>(_ n: T) -> T where T: Numeric { return n * 1 }

public func bravo<T>(_ n: T) -> T where T: Numeric { return n * 2 }

// FOOTER
"""
		let final = """
public func bravo<T>(_ n: T) -> T where T: Numeric { return n * 2 }

public func alpha<T>(_ n: T) -> T where T: Numeric { return n * 1 }

// FOOTER
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
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Swift_MultipleDecorators_Pass() {
		// Test detection with multiple attributes/decorators
		let path = "src/swift/reorder/Order.swift"
		let baseline = """
@objc @available(iOS 13.0, *) public func alpha(_ n: Int) -> Int { return n * 1 }

@objc @available(iOS 13.0, *) public func bravo(_ n: Int) -> Int { return n * 2 }

// FOOTER
"""
		let final = """
@objc @available(iOS 13.0, *) public func bravo(_ n: Int) -> Int { return n * 2 }

@objc @available(iOS 13.0, *) public func alpha(_ n: Int) -> Int { return n * 1 }

// FOOTER
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
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Ts_GenericFunction_Pass() {
		// Test TypeScript generic functions
		let path = "src/ts/reorder/Order.ts"
		let baseline = """
export function alpha<T>(n: T): T { return n; }

export function bravo<T>(n: T): T { return n; }

// FOOTER
"""
		let final = """
export function bravo<T>(n: T): T { return n; }

export function alpha<T>(n: T): T { return n; }

// FOOTER
"""
		let spec = BenchmarkTaskSpec(
			id: "move_function_ts",
			type: .moveFunctionTs,
			language: .ts,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["fromName": .string("alpha"), "afterName": .string("bravo")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Go_ReceiverMethod_Pass() {
		// Test Go method with receiver type
		let path = "src/go/reorder/Order.go"
		let baseline = """
package reorder

type Calculator struct{}

func (c *Calculator) alpha(n int) int { return n * 1 }

func (c *Calculator) bravo(n int) int { return n * 2 }

// FOOTER
"""
		let final = """
package reorder

type Calculator struct{}

func (c *Calculator) bravo(n int) int { return n * 2 }

func (c *Calculator) alpha(n int) int { return n * 1 }

// FOOTER
"""
		let spec = BenchmarkTaskSpec(
			id: "move_function_go",
			type: .moveFunctionGo,
			language: .go,
			selectFiles: [path],
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: ["fromName": .string("alpha"), "afterName": .string("bravo")]
		)
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	func testMoveFunction_Swift_FinalOverride_Pass() {
		// Test Swift with final override modifiers
		let path = "src/swift/reorder/Order.swift"
		let baseline = """
final override public func alpha(_ n: Int) -> Int { return n * 1 }

final override public func bravo(_ n: Int) -> Int { return n * 2 }

// FOOTER
"""
		let final = """
final override public func bravo(_ n: Int) -> Int { return n * 2 }

final override public func alpha(_ n: Int) -> Int { return n * 1 }

// FOOTER
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
		verifyPass(spec, baselineFiles: [path: baseline], editedFiles: [BenchmarkEditedFile(path: path, content: final)])
	}

	// MARK: - Indentation Validation

	func testGeneratedTasks_IndentationMatchesLanguageConvention() {
		// Generate tasks for each language and verify indentation conventions:
		// - TypeScript: uses spaces
		// - Go: uses spaces
		// - Swift: uses tabs
		let seed: UInt32 = 42
		let gen = BenchmarkTaskGenerator()

		let languages: [BenchmarkLanguage] = [.ts, .go, .swift]

		for language in languages {
			// Generate a full seed for this language
			let config = BenchConfig(
				languages: [language],
				noise: 0.0,
				enabledTypes: BenchmarkCaseType.allCases
			)
			let generated = gen.generateSeed(seed, config: config, language: language)

			// Check indentation in all baseline files
			for (path, content) in generated.baseline.dictionary() {
				// Skip if file doesn't match the current language
				guard path.hasSuffix(".\(language.rawValue)") else { continue }

				// Split content into lines and detect indentation type
				let (lines, _) = String.splitContentPreservingLineEndings(content)

				// Skip files with no lines or all empty lines
				let nonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
				guard !nonEmptyLines.isEmpty else { continue }

				let (indentType, _) = String.detectIndentationTypeFromLines(lines)

				switch language {
				case .ts, .go:
					// TypeScript and Go should use spaces, not tabs
					if indentType == "t" {
						XCTFail("\(language.rawValue) file '\(path)' uses tabs. Should use 4 spaces instead.")
					}
				case .swift:
					// Swift should use tabs
					if indentType == "s" {
						XCTFail("Swift file '\(path)' uses spaces. Should use tabs instead.")
					}
				}
			}
		}
	}

	// MARK: - Noise Hunk Helpers

	/// Builds a noise hunk for TypeScript Hard tests (no-op change with context)
	private func buildTsNoiseHunk(baseline: [String], filePath: String) -> String {
		let target = "export const value = 42"
		let valueIdx = baseline.firstIndex(of: target)!
		precondition(valueIdx > 0, "value line must have a context line above")
		let ctxIdx = valueIdx - 1
		let ctxOldStart = ctxIdx + 1
		// +2 for BOF, -4 for function b removal (unchanged relative offsets)
		let ctxNewStart = ctxOldStart + 2 - 4

		// If target is the last line in baseline, avoid trailing context by switching to 1/1 hunk
		let hasTrailing = (valueIdx + 1) < baseline.count
		if hasTrailing {
			var lines: [String] = []
			lines.append("@@ -\(ctxOldStart),2 +\(ctxNewStart),2 @@")
			lines.append(" \(baseline[ctxIdx])")
			lines.append("-\(target)")
			lines.append("+\(target)")
			return lines.joined(separator: "\n")
		} else {
			// Drop the leading context and target only: adjust start by +1 from the ctx-based computation
			let oldStart = valueIdx + 1
			let newStart = ctxNewStart + 1
			return [
				"@@ -\(oldStart),1 +\(newStart),1 @@",
				"-\(target)",
				"+\(target)"
			].joined(separator: "\n")
		}
	}

	/// Builds a noise hunk for Go Hard tests (no-op change without context)
	private func buildGoNoiseHunk(baseline: [String], filePath: String) -> String {
		let target = "const value = 42"
		let valueIdx = baseline.firstIndex(of: target)!
		let oldStart = valueIdx + 1
		let newStart = oldStart + 2 - 4  // +2 for BOF, -4 for function b removal
		return [
			"@@ -\(oldStart),1 +\(newStart),1 @@",
			"-\(target)",
			"+\(target)"
		].joined(separator: "\n")
	}

	/// Builds a noise hunk for Swift Hard tests (no-op change without context)
	private func buildSwiftNoiseHunk(baseline: [String], filePath: String) -> String {
		let target = "public let value = 42"
		let valueIdx = baseline.firstIndex(of: target)!
		let oldStart = valueIdx + 1
		let newStart = oldStart + 2 - 4  // +2 for BOF, -4 for function b removal
		return [
			"@@ -\(oldStart),1 +\(newStart),1 @@",
			"-\(target)",
			"+\(target)"
		].joined(separator: "\n")
	}

	private func buildTsNoiseHunkValue2(baseline: [String], filePath: String) -> String {
		let target = "export const value2 = 7"
		guard let valueIdx = baseline.firstIndex(of: target), valueIdx > 0 else { return "" }
		let ctxIdx = valueIdx - 1
		let ctxOldStart = ctxIdx + 1
		// +2 BOF, -4 remove b, -4 remove e (unchanged offsets)
		let ctxNewStart = ctxOldStart + 2 - 8

		let hasTrailing = (valueIdx + 1) < baseline.count
		if hasTrailing {
			var lines: [String] = []
			lines.append("@@ -\(ctxOldStart),2 +\(ctxNewStart),2 @@")
			lines.append(" \(baseline[ctxIdx])")
			lines.append("-\(target)")
			lines.append("+\(target)")
			return lines.joined(separator: "\n")
		} else {
			let oldStart = valueIdx + 1
			let newStart = ctxNewStart + 1
			return [
				"@@ -\(oldStart),1 +\(newStart),1 @@",
				"-\(target)",
				"+\(target)"
			].joined(separator: "\n")
		}
	}

	private func buildGoNoiseHunkValue2(baseline: [String], filePath: String) -> String {
		let target = "const value2 = 7"
		guard let valueIdx = baseline.firstIndex(of: target), valueIdx > 0 else { return "" }
		let ctxIdx = valueIdx - 1
		let ctxOldStart = ctxIdx + 1
		// +2 BOF, -4 remove b, -4 remove e (unchanged offsets)
		let ctxNewStart = ctxOldStart + 2 - 8

		let hasTrailing = (valueIdx + 1) < baseline.count
		if hasTrailing {
			var lines: [String] = []
			lines.append("@@ -\(ctxOldStart),2 +\(ctxNewStart),2 @@")
			lines.append(" \(baseline[ctxIdx])")
			lines.append("-\(target)")
			lines.append("+\(target)")
			return lines.joined(separator: "\n")
		} else {
			let oldStart = valueIdx + 1
			let newStart = ctxNewStart + 1
			return [
				"@@ -\(oldStart),1 +\(newStart),1 @@",
				"-\(target)",
				"+\(target)"
			].joined(separator: "\n")
		}
	}

	private func buildSwiftNoiseHunkValue2(baseline: [String], filePath: String) -> String {
		let target = "public let value2 = 7"
		guard let valueIdx = baseline.firstIndex(of: target), valueIdx > 0 else { return "" }
		let ctxIdx = valueIdx - 1
		let ctxOldStart = ctxIdx + 1
		// +2 BOF, -4 remove b, -4 remove e (unchanged offsets)
		let ctxNewStart = ctxOldStart + 2 - 8

		let hasTrailing = (valueIdx + 1) < baseline.count
		if hasTrailing {
			var lines: [String] = []
			lines.append("@@ -\(ctxOldStart),2 +\(ctxNewStart),2 @@")
			lines.append(" \(baseline[ctxIdx])")
			lines.append("-\(target)")
			lines.append("+\(target)")
			return lines.joined(separator: "\n")
		} else {
			let oldStart = valueIdx + 1
			let newStart = ctxNewStart + 1
			return [
				"@@ -\(oldStart),1 +\(newStart),1 @@",
				"-\(target)",
				"+\(target)"
			].joined(separator: "\n")
		}
	}

	// MARK: - Unified Patch Generator Validity Tests

	func testUnifiedPatchGenerator_Swift_ValidPatches() throws {
		// Test that generated unified patch tasks produce valid patches
		// We test multiple seeds and verify all generated patches are valid
		let seeds: [UInt32] = [12345, 54321, 99999, 3618045077, 1, 42, 1337, 9876, 111111]
		let gen = BenchmarkTaskGenerator()

		for seed in seeds {
			let config = BenchConfig(languages: [.swift], enabledTypes: [.applyUnifiedPatchSwift])
			let generated = gen.generateSeed(seed, config: config, language: .swift)

			// Find all unified patch tasks (any difficulty)
			let tasks = generated.tasks.filter { $0.type == .applyUnifiedPatchSwift }

			XCTAssertFalse(tasks.isEmpty, "No unified patch tasks generated for seed \(seed)")

			for task in tasks {
				guard let patch = task.params["patch"]?.stringValue else {
					XCTFail("No patch in params for seed \(seed), difficulty \(task.difficulty)")
					continue
				}

				// For veryHard tasks with target discovery, use targetPath; otherwise use first selectFile
				let path: String
				if let targetPath = task.params["targetPath"]?.stringValue {
					path = targetPath
				} else if let firstFile = task.selectFiles.first {
					path = firstFile
				} else {
					XCTFail("No target path or selectFiles for seed \(seed), difficulty \(task.difficulty)")
					continue
				}

				guard let baseline = generated.baseline.dictionary()[path] else {
					XCTFail("No baseline file for path \(path), seed \(seed), difficulty \(task.difficulty)")
					continue
				}

				// Verify the patch can be applied
				let result = SimpleUnifiedPatchApplier.apply(patch: patch, to: baseline)
				XCTAssertNotNil(result, "Generated patch should be valid for seed \(seed), difficulty \(task.difficulty)")
			}
		}
	}
}
