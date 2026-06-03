import XCTest
@testable import RepoPrompt

final class UnifiedPatchGenerationTests: XCTestCase {
	func testUnifiedPatchTask_GeneratedPatchAppliesAndVerifierPasses() throws {
		let config = BenchConfig(
			languages: [.ts],
			size: .small,
			sizeLines: nil,
			noise: 0.0,
			enabledTypes: [.applyUnifiedPatchTs],
			params: [:],
			tasksAreCumulative: false,
			mediumCount: 0,
			hardCount: 1,
			veryHardCount: 0,
			contextCharBudget: 50_000,
			decoyCharCap: 10_000,
			decoysMedium: 0,
			decoysHard: 0,
			decoysVeryHard: 0
		)
		let seed: UInt32 = 123_456_789
		let generator = BenchmarkTaskGenerator()
		let generated = generator.generateSeed(seed, config: config)
		guard
			let spec = generated.tasks.first(where: { $0.type == .applyUnifiedPatchTs }),
			let path = spec.selectFiles.first,
			let baseline = generated.fileSystem.content(for: path),
			let patch = spec.params["patch"]?.stringValue
		else {
			XCTFail("Failed to generate unified patch task")
			return
		}
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patch, to: baseline))
		let execution = BenchmarkTaskExecution(
			task: spec,
			baseline: generated.baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: path, content: expected)],
				meta: nil
			)
		)
		let output = BenchmarkVerifier().verify(execution)
		XCTAssertTrue(output.pass, "Expected verifier to pass: \(output.reason)")
		XCTAssertEqual(output.metrics["appliedOK"]?.boolValue, true)
	}
	
	func testUnifiedPatchTask_FailsOnMismatch() throws {
		let config = BenchConfig(
			languages: [.ts],
			size: .small,
			enabledTypes: [.applyUnifiedPatchTs],
			tasksAreCumulative: false,
			mediumCount: 1,
			hardCount: 0,
			veryHardCount: 0
		)
		let seed: UInt32 = 42
		let generator = BenchmarkTaskGenerator()
		let generated = generator.generateSeed(seed, config: config)
		guard
			let spec = generated.tasks.first(where: { $0.type == .applyUnifiedPatchTs }),
			let path = spec.selectFiles.first,
			let baseline = generated.fileSystem.content(for: path),
			let patch = spec.params["patch"]?.stringValue
		else {
			XCTFail("Missing generated unified patch spec")
			return
		}
		let expected = try XCTUnwrap(SimpleUnifiedPatchApplier.apply(patch: patch, to: baseline))
		let mutated = expected + "\n// trailing mutation"
		let execution = BenchmarkTaskExecution(
			task: spec,
			baseline: generated.baseline,
			result: BenchmarkTaskExecResult(
				errors: [],
				edited: [BenchmarkEditedFile(path: path, content: mutated)],
				meta: nil
			)
		)
		let output = BenchmarkVerifier().verify(execution)
		XCTAssertFalse(output.pass, "Expected mismatch to fail verification")
		XCTAssertEqual(output.reason, "diffMismatch")
		XCTAssertEqual(output.metrics["appliedOK"]?.boolValue, false)
	}
	
	func testUnifiedPatchTask_HardDifficultyIncludesNoise() {
		let config = BenchConfig(
			languages: [.ts],
			size: .small,
			enabledTypes: [.applyUnifiedPatchTs],
			tasksAreCumulative: false,
			mediumCount: 0,
			hardCount: 1,
			veryHardCount: 0
		)
		let seed: UInt32 = 777
		let generator = BenchmarkTaskGenerator()
		let generated = generator.generateSeed(seed, config: config)
		guard
			let spec = generated.tasks.first(where: { $0.type == .applyUnifiedPatchTs }),
			let patch = spec.params["patch"]?.stringValue
		else {
			XCTFail("Missing patch for noise test")
			return
		}
		let lines = patch.components(separatedBy: "\n")
		var foundNoise = false
		for index in 0..<(lines.count - 1) {
			let current = lines[index]
			let next = lines[index + 1]
			if current.hasPrefix("-") && next.hasPrefix("+") {
				let removed = String(current.dropFirst())
				let added = String(next.dropFirst())
				if removed == added {
					foundNoise = true
					break
				}
			}
		}
		XCTAssertTrue(foundNoise, "Expected no-op noise hunk in hard difficulty patch")
	}
}
