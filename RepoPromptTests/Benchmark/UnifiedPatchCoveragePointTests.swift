import XCTest
@testable import RepoPrompt

final class UnifiedPatchCoveragePointTests: XCTestCase {

	// MARK: - Helper Methods

	/// Build a simple TypeScript file with 3 functions for testing partial patch application
	private func buildTSBaseline() -> String {
		return """
		export function calculateSum(a: number, b: number): number {
		    return a + b;
		}

		export function formatString(s: string): string {
		    return s.toUpperCase();
		}

		export const magicNumber = 42;
		"""
	}

	/// Build a unified patch that modifies all three sections
	private func buildFullPatch() -> String {
		return """
		@@ -1,3 +1,3 @@
		 export function calculateSum(a: number, b: number): number {
		-    return a + b;
		+    return a + b + 1;
		 }
		@@ -5,3 +5,3 @@
		 export function formatString(s: string): string {
		-    return s.toUpperCase();
		+    return s.toLowerCase();
		 }
		@@ -9,1 +9,1 @@
		-export const magicNumber = 42;
		+export const magicNumber = 99;
		"""
	}

	/// Build a final state with only the first 2 hunks applied
	private func buildPartialFinal() -> String {
		return """
		export function calculateSum(a: number, b: number): number {
		    return a + b + 1;
		}

		export function formatString(s: string): string {
		    return s.toLowerCase();
		}

		export const magicNumber = 42;
		"""
	}

	// MARK: - Coverage Tests

	func testUnifiedPatchCoverageNormalizedScore() {
		let baseline = buildTSBaseline()
		let patch = buildFullPatch()
		let partialFinal = buildPartialFinal()

		// Test partial coverage: 2 out of 3 hunks applied
		let (applied, total) = UnifiedPatchGrader.coverage(baseline: baseline, final: partialFinal, patch: patch)

		XCTAssertEqual(applied, 2, "Expected 2 hunks to be detected as applied")
		XCTAssertEqual(total, 3, "Expected 3 total hunks in patch")

		let normalizedScore = total > 0 ? Double(applied) / Double(total) : 0.0
		XCTAssertEqual(normalizedScore, 2.0 / 3.0, accuracy: 0.0001)
	}

	func testUnifiedPatchCoverageFullApplication() {
		let baseline = buildTSBaseline()
		let patch = buildFullPatch()

		// Apply the full patch
		guard let fullFinal = SimpleUnifiedPatchApplier.apply(patch: patch, to: baseline) else {
			XCTFail("Failed to apply full patch")
			return
		}

		let (applied, total) = UnifiedPatchGrader.coverage(baseline: baseline, final: fullFinal, patch: patch)

		XCTAssertEqual(applied, 3, "Expected all 3 hunks to be applied")
		XCTAssertEqual(total, 3, "Expected 3 total hunks")

		let normalizedScore = Double(applied) / Double(total)
		XCTAssertEqual(normalizedScore, 1.0, accuracy: 0.0001)
	}

	func testUnifiedPatchCoverageZeroApplication() {
		let baseline = buildTSBaseline()
		let patch = buildFullPatch()

		// Final is unchanged (no hunks applied)
		let unchanged = baseline

		let (applied, total) = UnifiedPatchGrader.coverage(baseline: baseline, final: unchanged, patch: patch)

		XCTAssertEqual(applied, 0, "Expected no hunks to be detected as applied")
		XCTAssertEqual(total, 3, "Expected 3 total hunks")

		let normalizedScore = Double(applied) / Double(total)
		XCTAssertEqual(normalizedScore, 0.0, accuracy: 0.0001)
	}

	// MARK: - Points Award Tests for Hard Difficulty

	func testUnifiedPatch_HardDifficulty_AwardedPoints() {
		let baseline = buildTSBaseline()
		let patch = buildFullPatch()
		let partialFinal = buildPartialFinal()

		// Compute expected coverage
		let (applied, total) = UnifiedPatchGrader.coverage(baseline: baseline, final: partialFinal, patch: patch)
		let normalizedScore = Double(applied) / Double(total) // 2/3 = 0.666...

		// Create a stub verifier that returns the computed coverage score
		let verifier = StubVerifier { _ in
			BenchmarkVerifyOutput(pass: false, score: normalizedScore, reason: "diffMismatch", metrics: [:])
		}

		let reporter = BenchmarkReporter(verifier: verifier)

		// Create a hard difficulty unified patch task
		let task = BenchmarkTaskSpec(
			id: "patch-task",
			type: .applyUnifiedPatchTs,
			language: .ts,
			difficulty: .hard,
			format: "search_replace",
			selectFiles: ["src/test.ts"],
			newChat: true,
			maxEdits: 10,
			instructions: [],
			task: "Apply the patch",
			acceptance: [],
			params: ["patch": .string(patch)]
		)

		let execution = BenchmarkTaskExecution(
			task: task,
			baseline: BenchmarkMockFileSystemSnapshot(files: ["src/test.ts": baseline]),
			result: BenchmarkTaskExecResult(errors: [], edited: [
				BenchmarkEditedFile(path: "src/test.ts", content: partialFinal)
			], meta: nil)
		)

		let seedExec = BenchmarkSeedExecution(seed: 100, executions: [execution])
		let report = reporter.buildReport(coreSeed: 100, executions: [seedExec])

		// Hard difficulty: score 0.666... * 3 = 2.0
		// Quantized: round(2.0 * 2) / 2 = round(4.0) / 2 = 4 / 2 = 2.0
		XCTAssertEqual(report.perSeed[0].tasks[0].awardedPoints, 2.0, accuracy: 0.0001)
		XCTAssertEqual(report.perSeed[0].tasks[0].maxPoints, 3.0, accuracy: 0.0001)
	}

	// MARK: - Points Award Tests for VeryHard Difficulty

	func testUnifiedPatch_VeryHardDifficulty_AwardedPoints() {
		let baseline = buildTSBaseline()
		let patch = buildFullPatch()
		let partialFinal = buildPartialFinal()

		// Compute expected coverage: 2/3
		let (applied, total) = UnifiedPatchGrader.coverage(baseline: baseline, final: partialFinal, patch: patch)
		let normalizedScore = Double(applied) / Double(total)

		let verifier = StubVerifier { _ in
			BenchmarkVerifyOutput(pass: false, score: normalizedScore, reason: "diffMismatch", metrics: [:])
		}

		let reporter = BenchmarkReporter(verifier: verifier)

		// VeryHard difficulty
		let task = BenchmarkTaskSpec(
			id: "patch-task-vh",
			type: .applyUnifiedPatchTs,
			language: .ts,
			difficulty: .veryHard,
			format: "search_replace",
			selectFiles: ["src/test.ts"],
			newChat: true,
			maxEdits: 10,
			instructions: [],
			task: "Apply the patch",
			acceptance: [],
			params: ["patch": .string(patch)]
		)

		let execution = BenchmarkTaskExecution(
			task: task,
			baseline: BenchmarkMockFileSystemSnapshot(files: ["src/test.ts": baseline]),
			result: BenchmarkTaskExecResult(errors: [], edited: [
				BenchmarkEditedFile(path: "src/test.ts", content: partialFinal)
			], meta: nil)
		)

		let seedExec = BenchmarkSeedExecution(seed: 200, executions: [execution])
		let report = reporter.buildReport(coreSeed: 200, executions: [seedExec])

		// VeryHard difficulty: score 0.666... * 6 = 4.0
		// Quantized: round(4.0 * 2) / 2 = round(8.0) / 2 = 8 / 2 = 4.0
		XCTAssertEqual(report.perSeed[0].tasks[0].awardedPoints, 4.0, accuracy: 0.0001)
		XCTAssertEqual(report.perSeed[0].tasks[0].maxPoints, 6.0, accuracy: 0.0001)
	}

	// MARK: - Indentation Gate Tests

	func testIndentationGatePreventsPartialCredit_Tabs() {
		let baseline = buildTSBaseline()
		let patch = buildFullPatch()

		// Create a final state with tabs (TS should use spaces)
		let finalWithTabs = """
		export function calculateSum(a: number, b: number): number {
		\treturn a + b + 1;
		}

		export function formatString(s: string): string {
		\treturn s.toLowerCase();
		}

		export const magicNumber = 42;
		"""

		// Use real verifier to test indentation gate
		let verifier = BenchmarkVerifier()

		let task = BenchmarkTaskSpec(
			id: "tab-task",
			type: .applyUnifiedPatchTs,
			language: .ts,
			difficulty: .hard,
			format: "search_replace",
			selectFiles: ["src/test.ts"],
			newChat: true,
			maxEdits: 10,
			instructions: [],
			task: "Apply the patch",
			acceptance: [],
			params: ["patch": .string(patch)]
		)

		let execution = BenchmarkTaskExecution(
			task: task,
			baseline: BenchmarkMockFileSystemSnapshot(files: ["src/test.ts": baseline]),
			result: BenchmarkTaskExecResult(errors: [], edited: [
				BenchmarkEditedFile(path: "src/test.ts", content: finalWithTabs)
			], meta: nil)
		)

		let output = verifier.verify(execution)

		// Should fail with "tabFound" reason
		XCTAssertFalse(output.pass, "Expected verification to fail due to tabs")
		XCTAssertEqual(output.reason, "tabFound")
		XCTAssertEqual(output.score, 0.0, accuracy: 0.0001)
	}

	func testIndentationGateAllowsTabsForSwift() {
		// Swift uses tabs for indentation
		let baseline = """
		public func greet(name: String) -> String {
		\treturn "Hello, \\(name)"
		}
		"""

		let patch = """
		@@ -1,3 +1,3 @@
		 public func greet(name: String) -> String {
		-\treturn "Hello, \\(name)"
		+\treturn "Hi, \\(name)"
		 }
		"""

		guard let finalWithTabs = SimpleUnifiedPatchApplier.apply(patch: patch, to: baseline) else {
			XCTFail("Failed to apply patch")
			return
		}

		let verifier = BenchmarkVerifier()

		let task = BenchmarkTaskSpec(
			id: "swift-tab-task",
			type: .applyUnifiedPatchSwift,
			language: .swift,
			difficulty: .hard,
			format: "search_replace",
			selectFiles: ["src/test.swift"],
			newChat: true,
			maxEdits: 10,
			instructions: [],
			task: "Apply the patch",
			acceptance: [],
			params: ["patch": .string(patch)]
		)

		let execution = BenchmarkTaskExecution(
			task: task,
			baseline: BenchmarkMockFileSystemSnapshot(files: ["src/test.swift": baseline]),
			result: BenchmarkTaskExecResult(errors: [], edited: [
				BenchmarkEditedFile(path: "src/test.swift", content: finalWithTabs)
			], meta: nil)
		)

		let output = verifier.verify(execution)

		// Should pass for Swift with tabs
		XCTAssertTrue(output.pass, "Expected Swift with tabs to pass: \(output.reason)")
	}

	// MARK: - Helper Types

	struct StubVerifier: BenchmarkVerifying {
		let handler: (BenchmarkTaskExecution) -> BenchmarkVerifyOutput

		func verify(_ execution: BenchmarkTaskExecution) -> BenchmarkVerifyOutput {
			handler(execution)
		}
	}

	// MARK: - Edge Cases

	func testEmptyPatch() {
		let baseline = buildTSBaseline()
		let emptyPatch = ""

		let (applied, total) = UnifiedPatchGrader.coverage(baseline: baseline, final: baseline, patch: emptyPatch)

		XCTAssertEqual(applied, 0)
		XCTAssertEqual(total, 0)
	}

	func testSingleHunkPatch() {
		let baseline = """
		function foo() {
		    return 1;
		}
		"""

		let patch = """
		@@ -1,3 +1,3 @@
		 function foo() {
		-    return 1;
		+    return 2;
		 }
		"""

		guard let final = SimpleUnifiedPatchApplier.apply(patch: patch, to: baseline) else {
			XCTFail("Failed to apply single hunk patch")
			return
		}

		let (applied, total) = UnifiedPatchGrader.coverage(baseline: baseline, final: final, patch: patch)

		XCTAssertEqual(applied, 1)
		XCTAssertEqual(total, 1)

		let normalizedScore = Double(applied) / Double(total)
		XCTAssertEqual(normalizedScore, 1.0, accuracy: 0.0001)
	}

	func testPartialCreditWithMediumDifficulty() {
		// Medium difficulty should still use binary scoring even for unified patches
		let baseline = buildTSBaseline()
		let patch = buildFullPatch()
		let partialFinal = buildPartialFinal()

		// Compute coverage: 2/3
		let (applied, total) = UnifiedPatchGrader.coverage(baseline: baseline, final: partialFinal, patch: patch)
		let normalizedScore = Double(applied) / Double(total)

		let verifier = StubVerifier { _ in
			// Medium with score < threshold (0.8) means pass=false
			BenchmarkVerifyOutput(pass: false, score: normalizedScore, reason: "partial", metrics: [:])
		}

		let reporter = BenchmarkReporter(verifier: verifier)

		let task = BenchmarkTaskSpec(
			id: "medium-patch",
			type: .applyUnifiedPatchTs,
			language: .ts,
			difficulty: .medium,
			format: "search_replace",
			selectFiles: ["src/test.ts"],
			newChat: true,
			maxEdits: 10,
			instructions: [],
			task: "Apply the patch",
			acceptance: [],
			params: ["patch": .string(patch)]
		)

		let execution = BenchmarkTaskExecution(
			task: task,
			baseline: BenchmarkMockFileSystemSnapshot(files: ["src/test.ts": baseline]),
			result: BenchmarkTaskExecResult(errors: [], edited: [
				BenchmarkEditedFile(path: "src/test.ts", content: partialFinal)
			], meta: nil)
		)

		let seedExec = BenchmarkSeedExecution(seed: 300, executions: [execution])
		let report = reporter.buildReport(coreSeed: 300, executions: [seedExec])

		// Medium difficulty is binary: pass=false => 0.0 points
		XCTAssertEqual(report.perSeed[0].tasks[0].awardedPoints, 0.0, accuracy: 0.0001)
		XCTAssertEqual(report.perSeed[0].tasks[0].maxPoints, 1.0, accuracy: 0.0001)
	}
}
