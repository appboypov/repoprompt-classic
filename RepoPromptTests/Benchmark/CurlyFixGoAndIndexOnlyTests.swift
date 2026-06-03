import XCTest
@testable import RepoPrompt

final class CurlyFixGoAndIndexOnlyTests: XCTestCase {
	// MARK: - Helpers
	
	private func makeCurlySpecAndBaseline() -> (spec: BenchmarkTaskSpec, baseline: BenchmarkMockFileSystemSnapshot, path: String) {
		let path = "src/go/main.go"
		// Baseline mirrors the generator: missing closing braces.
		let baselineText = """
package main

import "fmt"

func main() {
	sum := 0
	for i := 0; i < 5; i++ {
		sum += i
	fmt.Println(sum)
"""
		var fs = BenchmarkMockFileSystem()
		fs.setFile(path, content: baselineText)
		let baseline = fs.snapshot()
		
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
		return (spec, baseline, path)
	}

	private func makeCurlySpecAndBaselineTs() -> (spec: BenchmarkTaskSpec, baseline: BenchmarkMockFileSystemSnapshot, path: String) {
		let path = "src/ts/main.ts"
		let baselineLines = [
			"export function main() {",
			"\tlet sum = 0",
			"\tfor (let i = 0; i < 5; i++) {",
			"\t\tsum += i",
			"\tconsole.log(sum)"
		]
		let baselineText = baselineLines.joined(separator: "\n")
		var fs = BenchmarkMockFileSystem()
		fs.setFile(path, content: baselineText)
		let baseline = fs.snapshot()
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
		return (spec, baseline, path)
	}

	private func makeCurlySpecAndBaselineSwift() -> (spec: BenchmarkTaskSpec, baseline: BenchmarkMockFileSystemSnapshot, path: String) {
		let path = "src/swift/main.swift"
		let baselineLines = [
			"import Foundation",
			"",
			"func main() {",
			"\tvar sum = 0",
			"\tfor i in 0..<5 {",
			"\t\tsum += i",
			"\tprint(sum)"
		]
		let baselineText = baselineLines.joined(separator: "\n")
		var fs = BenchmarkMockFileSystem()
		fs.setFile(path, content: baselineText)
		let baseline = fs.snapshot()
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
		return (spec, baseline, path)
	}

	private func makeIndexOnlySpecAndBaseline(targetApp: String = "appB") -> (spec: BenchmarkTaskSpec, baseline: BenchmarkMockFileSystemSnapshot, targetPath: String, otherPaths: [String]) {
		let apps = ["appA", "appB", "appC"]
		let packages = ["pkg1", "pkg2"]
		
		var fs = BenchmarkMockFileSystem()
		for app in apps {
			let path = "apps/\(app)/src/index.ts"
			let content = "export default function index() {\n\treturn \"\(app)\";\n}"
			fs.setFile(path, content: content)
		}
		for pkg in packages {
			let path = "packages/\(pkg)/src/index.ts"
			let content = "export const value = \"\(pkg)\";"
			fs.setFile(path, content: content)
		}
		let baseline = fs.snapshot()
		
		let targetPath = "apps/\(targetApp)/src/index.ts"
		var selectFiles = [targetPath]
		let others = apps.filter { $0 != targetApp }.map { "apps/\($0)/src/index.ts" } + packages.map { "packages/\($0)/src/index.ts" }
		selectFiles.append(contentsOf: others)
		let params: [String: BenchmarkJSONValue] = [
			"target": .string(targetApp),
			"otherPaths": .array(others.map { .string($0) })
		]
		let spec = BenchmarkTaskSpec(
			id: "index_only_apps_ts",
			type: .indexOnlyAppsTs,
			language: .ts,
			selectFiles: selectFiles,
			maxEdits: 2,
			instructions: [],
			task: "",
			acceptance: [],
			params: params
		)
		return (spec, baseline, targetPath, others)
	}
	
	// MARK: - curly_fix_go
	
	func testCurlyFixGo_Pass_WhenBracesBalancedAndPrintlnOutsideLoop() {
		let (spec, baseline, path) = makeCurlySpecAndBaseline()
		
		// Correct fix: close the for, then println outside, then close func.
		let finalText = """
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
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: path, content: finalText)]
			)
		)
		let output = BenchmarkVerifier().verify(exec)
		XCTAssertTrue(output.pass, "Expected pass, got: \(output.reason)")
	}
	
	func testCurlyFixGo_Fail_WhenPrintlnInsideLoop() {
		let (spec, baseline, path) = makeCurlySpecAndBaseline()
		
		// Wrong: println left inside the for-loop (but braces balanced overall).
		let finalText = """
package main

import "fmt"

func main() {
	sum := 0
	for i := 0; i < 5; i++ {
		sum += i
		fmt.Println(sum)
	}
}
"""
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: path, content: finalText)]
			)
		)
		let output = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(output.pass, "Expected failure")
		XCTAssertEqual(output.reason, "printCallInsideLoop")
	}
	
	func testCurlyFixGo_Fail_WhenOnlyOneBraceAddedStillUnbalanced() {
		let (spec, baseline, path) = makeCurlySpecAndBaseline()
		
		// Only close the for-loop; function remains unclosed -> unbalanced.
		let finalText = """
package main

import "fmt"

func main() {
	sum := 0
	for i := 0; i < 5; i++ {
		sum += i
	}
	fmt.Println(sum)
"""
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: path, content: finalText)]
			)
		)
		let output = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(output.pass, "Expected failure due to unbalanced braces")
		XCTAssertEqual(output.reason, "braceUnbalanced")
	}
	
	// MARK: - curly_fix_ts
	
	func testCurlyFixTs_Pass_WhenConsoleLogOutsideLoop() {
		let (spec, baseline, path) = makeCurlySpecAndBaselineTs()
		let finalLines = [
			"export function main() {",
			"\tlet sum = 0",
			"\tfor (let i = 0; i < 5; i++) {",
			"\t\tsum += i",
			"\t}",
			"\tconsole.log(sum)",
			"}",
			""
		]
		let finalText = finalLines.joined(separator: "\n")
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: path, content: finalText)]
			)
		)
		let output = BenchmarkVerifier().verify(exec)
		XCTAssertTrue(output.pass, "Expected pass, got: \(output.reason)")
	}
	
	func testCurlyFixTs_Fail_WhenConsoleLogInsideLoop() {
		let (spec, baseline, path) = makeCurlySpecAndBaselineTs()
		let finalLines = [
			"export function main() {",
			"\tlet sum = 0",
			"\tfor (let i = 0; i < 5; i++) {",
			"\t\tsum += i",
			"\t\tconsole.log(sum)",
			"\t}",
			"}",
			""
		]
		let finalText = finalLines.joined(separator: "\n")
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: path, content: finalText)]
			)
		)
		let output = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(output.pass, "Expected failure")
		XCTAssertEqual(output.reason, "printCallInsideLoop")
	}
	
	// MARK: - curly_fix_swift
	
	func testCurlyFixSwift_Pass_WhenPrintOutsideLoop() {
		let (spec, baseline, path) = makeCurlySpecAndBaselineSwift()
		let finalLines = [
			"import Foundation",
			"",
			"func main() {",
			"\tvar sum = 0",
			"\tfor i in 0..<5 {",
			"\t\tsum += i",
			"\t}",
			"\tprint(sum)",
			"}",
			""
		]
		let finalText = finalLines.joined(separator: "\n")
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: path, content: finalText)]
			)
		)
		let output = BenchmarkVerifier().verify(exec)
		XCTAssertTrue(output.pass, "Expected pass, got: \(output.reason)")
	}
	
	func testCurlyFixSwift_Fail_WhenPrintInsideLoop() {
		let (spec, baseline, path) = makeCurlySpecAndBaselineSwift()
		let finalLines = [
			"import Foundation",
			"",
			"func main() {",
			"\tvar sum = 0",
			"\tfor i in 0..<5 {",
			"\t\tsum += i",
			"\t\tprint(sum)",
			"\t}",
			"}",
			""
		]
		let finalText = finalLines.joined(separator: "\n")
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: path, content: finalText)]
			)
		)
		let output = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(output.pass, "Expected failure")
		XCTAssertEqual(output.reason, "printCallInsideLoop")
	}
	
	// MARK: - index_only_apps_ts
	
	func testIndexOnlyAppsTs_Pass_WhenReturnUnchangedAndDoneMarkerPresent() {
		let (spec, baseline, targetPath, _) = makeIndexOnlySpecAndBaseline()
		
		let finalTarget = """
export default function index() {
	return "appB";
	// DONE:appB
}
"""
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: targetPath, content: finalTarget)]
			)
		)
		let output = BenchmarkVerifier().verify(exec)
		XCTAssertTrue(output.pass, "Expected pass, got: \(output.reason)")
	}
	
	func testIndexOnlyAppsTs_Fails_WhenReturnChanged() {
		let (spec, baseline, targetPath, _) = makeIndexOnlySpecAndBaseline()
		
		let finalTarget = """
export default function index() {
	return "appB completed";
}
"""
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: targetPath, content: finalTarget)]
			)
		)
		let output = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(output.pass, "Expected failure")
		XCTAssertEqual(output.reason, "returnChanged")
	}
	
	func testIndexOnlyAppsTs_Fails_WhenDoneMarkerMissing() {
		let (spec, baseline, targetPath, _) = makeIndexOnlySpecAndBaseline()
		
		let finalTarget = """
export default function index() {
	return "appB";
}
"""
		let exec = BenchmarkTaskExecution(
			task: spec,
			baseline: baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: targetPath, content: finalTarget)]
			)
		)
		let output = BenchmarkVerifier().verify(exec)
		XCTAssertFalse(output.pass, "Expected failure")
		XCTAssertEqual(output.reason, "doneMarkerMissing")
	}
}
