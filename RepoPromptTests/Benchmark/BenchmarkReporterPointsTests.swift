import XCTest
@testable import RepoPrompt

final class BenchmarkReporterPointsTests: XCTestCase {

	// MARK: - Helper Types

	/// Stub verifier that allows controlled pass/score outputs for testing
	struct StubVerifier: BenchmarkVerifying {
		let handler: (BenchmarkTaskExecution) -> BenchmarkVerifyOutput

		func verify(_ execution: BenchmarkTaskExecution) -> BenchmarkVerifyOutput {
			handler(execution)
		}
	}

	// MARK: - Helper Methods

	private func makeTaskSpec(
		id: String = UUID().uuidString,
		type: BenchmarkCaseType,
		language: BenchmarkLanguage = .ts,
		difficulty: BenchmarkDifficulty,
		selectFiles: [String],
		params: [String: BenchmarkJSONValue] = [:],
		maxEdits: Int = 10
	) -> BenchmarkTaskSpec {
		BenchmarkTaskSpec(
			id: id,
			type: type,
			language: language,
			difficulty: difficulty,
			format: "search_replace",
			selectFiles: selectFiles,
			newChat: true,
			maxEdits: maxEdits,
			instructions: [],
			task: "Test task",
			acceptance: [],
			params: params
		)
	}

	private func makeExecution(
		task: BenchmarkTaskSpec,
		baseline: [String: String] = [:],
		result: BenchmarkTaskExecResult? = nil
	) -> BenchmarkTaskExecution {
		let snapshot = BenchmarkMockFileSystemSnapshot(files: baseline)
		let execResult = result ?? BenchmarkTaskExecResult(errors: [], edited: [], meta: nil)
		return BenchmarkTaskExecution(task: task, baseline: snapshot, result: execResult)
	}

	// MARK: - Task Report Tests

	func testTaskReportCarriesDifficultyAndPoints() {
		// Create a stub verifier that returns controlled outputs based on difficulty
		let verifier = StubVerifier { execution in
			switch execution.task.difficulty {
			case .medium:
				return BenchmarkVerifyOutput(pass: true, score: 1.0, reason: "", metrics: [:])
			case .hard:
				return BenchmarkVerifyOutput(pass: false, score: 0.74, reason: "partial", metrics: [:])
			case .veryHard:
				return BenchmarkVerifyOutput(pass: false, score: 0.83, reason: "partial", metrics: [:])
			case .simple:
				return BenchmarkVerifyOutput(pass: true, score: 1.0, reason: "", metrics: [:])
			}
		}

		let reporter = BenchmarkReporter(verifier: verifier)

		// Create tasks with different difficulties
		let mediumTask = makeTaskSpec(
			id: "task1",
			type: .removeXTs,
			difficulty: .medium,
			selectFiles: ["src/file1.ts"]
		)
		let hardTask = makeTaskSpec(
			id: "task2",
			type: .curlyFixTs,
			difficulty: .hard,
			selectFiles: ["src/file2.ts"]
		)
		let veryHardTask = makeTaskSpec(
			id: "task3",
			type: .applyUnifiedPatchTs,
			difficulty: .veryHard,
			selectFiles: ["src/file3.ts"]
		)

		let executions = [
			makeExecution(task: mediumTask),
			makeExecution(task: hardTask),
			makeExecution(task: veryHardTask)
		]

		let seedExec = BenchmarkSeedExecution(seed: 123, executions: executions)
		let report = reporter.buildReport(coreSeed: 123, executions: [seedExec])

		// Validate task reports
		XCTAssertEqual(report.perSeed.count, 1)
		let seedReport = report.perSeed[0]
		XCTAssertEqual(seedReport.tasks.count, 3)

		// Medium task: pass = true => 1.0 points
		let task1Report = seedReport.tasks[0]
		XCTAssertEqual(task1Report.difficulty, .medium)
		XCTAssertEqual(task1Report.normalizedScore, 1.0, accuracy: 0.0001)
		XCTAssertEqual(task1Report.maxPoints, 1.0, accuracy: 0.0001)
		XCTAssertEqual(task1Report.awardedPoints, 1.0, accuracy: 0.0001)

		// Hard task: score = 0.74 => 2.0 points
		let task2Report = seedReport.tasks[1]
		XCTAssertEqual(task2Report.difficulty, .hard)
		XCTAssertEqual(task2Report.normalizedScore, 0.74, accuracy: 0.0001)
		XCTAssertEqual(task2Report.maxPoints, 3.0, accuracy: 0.0001)
		XCTAssertEqual(task2Report.awardedPoints, 2.0, accuracy: 0.0001)

		// VeryHard task: score = 0.83 => 5.0 points
		let task3Report = seedReport.tasks[2]
		XCTAssertEqual(task3Report.difficulty, .veryHard)
		XCTAssertEqual(task3Report.normalizedScore, 0.83, accuracy: 0.0001)
		XCTAssertEqual(task3Report.maxPoints, 6.0, accuracy: 0.0001)
		XCTAssertEqual(task3Report.awardedPoints, 5.0, accuracy: 0.0001)

		// Validate per-seed aggregation
		// Medium task with full pass gets 2x: 1.0 * 2 = 2.0
		// Hard task partial: 2.0 (no multiplier)
		// VeryHard task partial: 5.0 (no multiplier)
		XCTAssertEqual(seedReport.pointsEarned, 9.0, accuracy: 0.0001) // 2.0 + 2.0 + 5.0
		XCTAssertEqual(seedReport.maxPoints, 20.0, accuracy: 0.0001)    // (1 + 3 + 6) * 2
		XCTAssertEqual(seedReport.pointsRate, 9.0 / 20.0, accuracy: 0.0001)

		// Validate final aggregation
		XCTAssertEqual(report.totalMaxPoints, 20.0, accuracy: 0.0001)
		XCTAssertEqual(report.totalPointsEarned, 9.0, accuracy: 0.0001)
		XCTAssertEqual(report.pointsRate, 9.0 / 20.0, accuracy: 0.0001)
	}

	// MARK: - Medium Binary Points Tests

	func testMediumBinaryPointsRespectPassThresholdButPointsBinary() {
		// Create stub verifier: one medium task fails despite high score, one passes
		let verifier = StubVerifier { execution in
			if execution.task.id == "fail-task" {
				// Despite high score, pass=false means 0 points for medium
				return BenchmarkVerifyOutput(pass: false, score: 0.95, reason: "threshold", metrics: [:])
			} else {
				return BenchmarkVerifyOutput(pass: true, score: 0.80, reason: "", metrics: [:])
			}
		}

		let reporter = BenchmarkReporter(verifier: verifier)

		let task1 = makeTaskSpec(
			id: "fail-task",
			type: .removeXTs,
			difficulty: .medium,
			selectFiles: ["src/file1.ts"]
		)
		let task2 = makeTaskSpec(
			id: "pass-task",
			type: .removeXTs,
			difficulty: .medium,
			selectFiles: ["src/file2.ts"]
		)

		let executions = [
			makeExecution(task: task1),
			makeExecution(task: task2)
		]

		let seedExec = BenchmarkSeedExecution(seed: 456, executions: executions)
		let report = reporter.buildReport(coreSeed: 456, executions: [seedExec])

		let seedReport = report.perSeed[0]

		// First task: pass=false => 0.0 points despite 0.95 score
		XCTAssertEqual(seedReport.tasks[0].awardedPoints, 0.0, accuracy: 0.0001)

		// Second task: pass=true => 1.0 points
		XCTAssertEqual(seedReport.tasks[1].awardedPoints, 1.0, accuracy: 0.0001)

		// Seed totals
		// Second task has pass=true but score=0.80 (not 1.0), so no 2x multiplier
		XCTAssertEqual(seedReport.pointsEarned, 1.0, accuracy: 0.0001)
		XCTAssertEqual(seedReport.maxPoints, 4.0, accuracy: 0.0001) // (1 + 1) * 2
		XCTAssertEqual(seedReport.pointsRate, 1.0 / 4.0, accuracy: 0.0001)
	}

	// MARK: - Multiple Seeds Aggregation Tests

	func testMultipleSeedsAggregateCorrectly() {
		// Stub verifier that varies based on task ID
		let verifier = StubVerifier { execution in
			switch execution.task.id {
			case "seed1-task1":
				return BenchmarkVerifyOutput(pass: true, score: 1.0, reason: "", metrics: [:])
			case "seed1-task2":
				return BenchmarkVerifyOutput(pass: false, score: 0.50, reason: "partial", metrics: [:])
			case "seed2-task1":
				return BenchmarkVerifyOutput(pass: false, score: 0.66, reason: "partial", metrics: [:])
			case "seed2-task2":
				return BenchmarkVerifyOutput(pass: true, score: 1.0, reason: "", metrics: [:])
			default:
				return BenchmarkVerifyOutput(pass: false, score: 0.0, reason: "unknown", metrics: [:])
			}
		}

		let reporter = BenchmarkReporter(verifier: verifier)

		// Seed 1: medium (pass) + hard (0.50 score)
		let seed1Task1 = makeTaskSpec(
			id: "seed1-task1",
			type: .removeXTs,
			difficulty: .medium,
			selectFiles: ["src/file1.ts"]
		)
		let seed1Task2 = makeTaskSpec(
			id: "seed1-task2",
			type: .applyUnifiedPatchTs,
			difficulty: .hard,
			selectFiles: ["src/file2.ts"]
		)

		// Seed 2: veryHard (0.66 score) + medium (pass)
		let seed2Task1 = makeTaskSpec(
			id: "seed2-task1",
			type: .moveFunctionTs,
			difficulty: .veryHard,
			selectFiles: ["src/file3.ts"]
		)
		let seed2Task2 = makeTaskSpec(
			id: "seed2-task2",
			type: .insertGuardTs,
			difficulty: .medium,
			selectFiles: ["src/file4.ts"]
		)

		let seed1Execs = [
			makeExecution(task: seed1Task1),
			makeExecution(task: seed1Task2)
		]
		let seed2Execs = [
			makeExecution(task: seed2Task1),
			makeExecution(task: seed2Task2)
		]

		let seedExec1 = BenchmarkSeedExecution(seed: 100, executions: seed1Execs)
		let seedExec2 = BenchmarkSeedExecution(seed: 200, executions: seed2Execs)

		let report = reporter.buildReport(coreSeed: 999, executions: [seedExec1, seedExec2])

		// Validate seed 1
		let seed1Report = report.perSeed[0]
		// seed1-task1 (medium, pass=true, score=1.0): 1.0 * 2 = 2.0 points
		// seed1-task2 (hard, 0.50): 1.5 points (no multiplier)
		XCTAssertEqual(seed1Report.pointsEarned, 3.5, accuracy: 0.0001)
		XCTAssertEqual(seed1Report.maxPoints, 8.0, accuracy: 0.0001) // (1 + 3) * 2
		XCTAssertEqual(seed1Report.pointsRate, 3.5 / 8.0, accuracy: 0.0001)

		// Validate seed 2
		let seed2Report = report.perSeed[1]
		// seed2-task1 (veryHard, 0.66): 4.0 points (no multiplier)
		// seed2-task2 (medium, pass=true, score=1.0): 1.0 * 2 = 2.0 points
		XCTAssertEqual(seed2Report.pointsEarned, 6.0, accuracy: 0.0001)
		XCTAssertEqual(seed2Report.maxPoints, 14.0, accuracy: 0.0001) // (6 + 1) * 2
		XCTAssertEqual(seed2Report.pointsRate, 6.0 / 14.0, accuracy: 0.0001)

		// Validate final totals
		XCTAssertEqual(report.totalMaxPoints, 22.0, accuracy: 0.0001) // (4 + 7) * 2
		XCTAssertEqual(report.totalPointsEarned, 9.5, accuracy: 0.0001) // 3.5 + 6.0
		XCTAssertEqual(report.pointsRate, 9.5 / 22.0, accuracy: 0.0001)
	}

	// MARK: - Per-Type Aggregation Tests

	func testPerTypeAggregation() {
		// Create tasks with different types
		let verifier = StubVerifier { execution in
			switch execution.task.type {
			case .removeXTs:
				return BenchmarkVerifyOutput(pass: true, score: 1.0, reason: "", metrics: [:])
			case .applyUnifiedPatchTs:
				return BenchmarkVerifyOutput(pass: false, score: 0.75, reason: "partial", metrics: [:])
			default:
				return BenchmarkVerifyOutput(pass: false, score: 0.5, reason: "partial", metrics: [:])
			}
		}

		let reporter = BenchmarkReporter(verifier: verifier)

		// Two removeXTs tasks (both medium)
		let task1 = makeTaskSpec(
			id: "task1",
			type: .removeXTs,
			difficulty: .medium,
			selectFiles: ["src/file1.ts"]
		)
		let task2 = makeTaskSpec(
			id: "task2",
			type: .removeXTs,
			difficulty: .medium,
			selectFiles: ["src/file2.ts"]
		)

		// One applyUnifiedPatchTs task (hard)
		let task3 = makeTaskSpec(
			id: "task3",
			type: .applyUnifiedPatchTs,
			difficulty: .hard,
			selectFiles: ["src/file3.ts"]
		)

		let executions = [
			makeExecution(task: task1),
			makeExecution(task: task2),
			makeExecution(task: task3)
		]

		let seedExec = BenchmarkSeedExecution(seed: 111, executions: executions)
		let report = reporter.buildReport(coreSeed: 111, executions: [seedExec])

		// Validate per-type stats for removeXTs
		guard let removeXStats = report.perType[.removeXTs] else {
			XCTFail("Missing perType stats for removeXTs")
			return
		}
		XCTAssertEqual(removeXStats.count, 2)
		XCTAssertEqual(removeXStats.maxPoints, 4.0, accuracy: 0.0001) // (1 + 1) * 2
		// Both tasks pass with score=1.0, so each gets 2x: (1.0 * 2) + (1.0 * 2) = 4.0
		XCTAssertEqual(removeXStats.pointsEarned, 4.0, accuracy: 0.0001)
		XCTAssertEqual(removeXStats.pointsRate, 1.0, accuracy: 0.0001)

		// Validate per-type stats for applyUnifiedPatchTs
		guard let patchStats = report.perType[.applyUnifiedPatchTs] else {
			XCTFail("Missing perType stats for applyUnifiedPatchTs")
			return
		}
		XCTAssertEqual(patchStats.count, 1)
		XCTAssertEqual(patchStats.maxPoints, 6.0, accuracy: 0.0001) // 3 * 2
		// pass=false, so no multiplier: 0.75 * 3 => 2.0
		XCTAssertEqual(patchStats.pointsEarned, 2.0, accuracy: 0.0001)
		XCTAssertEqual(patchStats.pointsRate, 2.0 / 6.0, accuracy: 0.0001)
	}

	// MARK: - Edge Cases

	func testEmptyExecutions() {
		let verifier = StubVerifier { _ in
			BenchmarkVerifyOutput(pass: false, score: 0.0, reason: "", metrics: [:])
		}
		let reporter = BenchmarkReporter(verifier: verifier)

		let report = reporter.buildReport(coreSeed: 0, executions: [])

		XCTAssertEqual(report.totalTasks, 0)
		XCTAssertEqual(report.totalMaxPoints, 0.0, accuracy: 0.0001)
		XCTAssertEqual(report.totalPointsEarned, 0.0, accuracy: 0.0001)
		XCTAssertEqual(report.pointsRate, 0.0, accuracy: 0.0001)
	}

	func testAllTasksFail() {
		let verifier = StubVerifier { _ in
			BenchmarkVerifyOutput(pass: false, score: 0.0, reason: "failed", metrics: [:])
		}
		let reporter = BenchmarkReporter(verifier: verifier)

		let task1 = makeTaskSpec(
			id: "task1",
			type: .removeXTs,
			difficulty: .medium,
			selectFiles: ["src/file1.ts"]
		)
		let task2 = makeTaskSpec(
			id: "task2",
			type: .applyUnifiedPatchTs,
			difficulty: .hard,
			selectFiles: ["src/file2.ts"]
		)

		let executions = [
			makeExecution(task: task1),
			makeExecution(task: task2)
		]

		let seedExec = BenchmarkSeedExecution(seed: 999, executions: executions)
		let report = reporter.buildReport(coreSeed: 999, executions: [seedExec])

		XCTAssertEqual(report.totalPointsEarned, 0.0, accuracy: 0.0001)
		XCTAssertEqual(report.totalMaxPoints, 8.0, accuracy: 0.0001) // (1 + 3) * 2
		XCTAssertEqual(report.pointsRate, 0.0, accuracy: 0.0001)
	}
}
