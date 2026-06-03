import XCTest
@testable import RepoPrompt

final class BenchmarkPointScalesTests: XCTestCase {

	// MARK: - Medium Difficulty Tests

	func testMediumPoints_Binary() {
		// Pass = true should award full point
		XCTAssertEqual(BenchmarkPointScales.points(for: .medium, normalizedScore: 0.0, pass: true), 1.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .medium, normalizedScore: 0.5, pass: true), 1.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .medium, normalizedScore: 1.0, pass: true), 1.0, accuracy: 0.0001)

		// Pass = false should award zero
		XCTAssertEqual(BenchmarkPointScales.points(for: .medium, normalizedScore: 0.0, pass: false), 0.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .medium, normalizedScore: 0.95, pass: false), 0.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .medium, normalizedScore: 1.0, pass: false), 0.0, accuracy: 0.0001)
	}

	// MARK: - Simple Difficulty Tests

	func testSimplePoints_Binary() {
		// Pass = true should award full point
		XCTAssertEqual(BenchmarkPointScales.points(for: .simple, normalizedScore: 0.0, pass: true), 1.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .simple, normalizedScore: 0.5, pass: true), 1.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .simple, normalizedScore: 1.0, pass: true), 1.0, accuracy: 0.0001)

		// Pass = false should award zero
		XCTAssertEqual(BenchmarkPointScales.points(for: .simple, normalizedScore: 0.0, pass: false), 0.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .simple, normalizedScore: 0.95, pass: false), 0.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .simple, normalizedScore: 1.0, pass: false), 0.0, accuracy: 0.0001)
	}

	// MARK: - Hard Difficulty Tests

	func testHardPoints_QuantizationAndClamp() {
		// Test clamping below 0
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: -0.1, pass: false), 0.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: -0.1, pass: true), 0.0, accuracy: 0.0001)

		// Test zero
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.0, pass: false), 0.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.0, pass: true), 0.0, accuracy: 0.0001)

		// Test quantization boundaries
		// 0.24 * 3 = 0.72; round(0.72 * 2) / 2 = round(1.44) / 2 = 1.0 / 2 = 0.5
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.24, pass: false), 0.5, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.24, pass: true), 0.5, accuracy: 0.0001)

		// 0.26 * 3 = 0.78; round(0.78 * 2) / 2 = round(1.56) / 2 = 2.0 / 2 = 1.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.26, pass: false), 1.0, accuracy: 0.0001)

		// 0.49 * 3 = 1.47; round(1.47 * 2) / 2 = round(2.94) / 2 = 3.0 / 2 = 1.5
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.49, pass: false), 1.5, accuracy: 0.0001)

		// Exact 0.5: 0.5 * 3 = 1.5; round(1.5 * 2) / 2 = round(3.0) / 2 = 3.0 / 2 = 1.5
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.50, pass: false), 1.5, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.50, pass: true), 1.5, accuracy: 0.0001)

		// 0.74 * 3 = 2.22; round(2.22 * 2) / 2 = round(4.44) / 2 = 4.0 / 2 = 2.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.74, pass: false), 2.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.74, pass: true), 2.0, accuracy: 0.0001)

		// Exact 0.75: 0.75 * 3 = 2.25; round(2.25 * 2) / 2 = round(4.5) / 2 = 4.0 / 2 = 2.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.75, pass: false), 2.0, accuracy: 0.0001)

		// 0.99 * 3 = 2.97; round(2.97 * 2) / 2 = round(5.94) / 2 = 6.0 / 2 = 3.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 0.99, pass: false), 3.0, accuracy: 0.0001)

		// Exact 1.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 1.0, pass: false), 3.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 1.0, pass: true), 3.0, accuracy: 0.0001)

		// Test clamping above 1.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 1.5, pass: false), 3.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .hard, normalizedScore: 1.5, pass: true), 3.0, accuracy: 0.0001)
	}

	// MARK: - VeryHard Difficulty Tests

	func testVeryHardPoints_QuantizationAndClamp() {
		// Test clamping below 0
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: -0.1, pass: false), 0.0, accuracy: 0.0001)

		// Test zero
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 0.0, pass: false), 0.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 0.0, pass: true), 0.0, accuracy: 0.0001)

		// 0.16 * 6 = 0.96; round(0.96 * 2) / 2 = round(1.92) / 2 = 2.0 / 2 = 1.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 0.16, pass: false), 1.0, accuracy: 0.0001)

		// 0.33 * 6 = 1.98; round(1.98 * 2) / 2 = round(3.96) / 2 = 4.0 / 2 = 2.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 0.33, pass: false), 2.0, accuracy: 0.0001)

		// 0.49 * 6 = 2.94; round(2.94 * 2) / 2 = round(5.88) / 2 = 6.0 / 2 = 3.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 0.49, pass: false), 3.0, accuracy: 0.0001)

		// 0.66 * 6 = 3.96; round(3.96 * 2) / 2 = round(7.92) / 2 = 8.0 / 2 = 4.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 0.66, pass: false), 4.0, accuracy: 0.0001)

		// 0.83 * 6 = 4.98; round(4.98 * 2) / 2 = round(9.96) / 2 = 10.0 / 2 = 5.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 0.83, pass: false), 5.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 0.83, pass: true), 5.0, accuracy: 0.0001)

		// Exact 1.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 1.0, pass: false), 6.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 1.0, pass: true), 6.0, accuracy: 0.0001)

		// Test clamping above 1.0
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 1.25, pass: false), 6.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkPointScales.points(for: .veryHard, normalizedScore: 1.25, pass: true), 6.0, accuracy: 0.0001)
	}

	// MARK: - MaxPoints Accessor Tests

	func testMaxPointsAccessor() {
		XCTAssertEqual(BenchmarkDifficulty.simple.maxPoints, 1.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkDifficulty.medium.maxPoints, 1.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkDifficulty.hard.maxPoints, 3.0, accuracy: 0.0001)
		XCTAssertEqual(BenchmarkDifficulty.veryHard.maxPoints, 6.0, accuracy: 0.0001)
	}
}
