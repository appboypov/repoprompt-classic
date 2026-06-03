import XCTest
@testable import RepoPrompt

final class SyntaxManagerConcurrencyTests: XCTestCase {
	private struct Snippet: Sendable {
		let fileExtension: String
		let content: String
	}

	private struct MixedStressResult: Sendable {
		var codeMapCaptures = 0
		var highlightRanges = 0
		var previewSliceHighlightRanges = 0
		var parseCount = 0

		mutating func merge(_ other: MixedStressResult) {
			codeMapCaptures += other.codeMapCaptures
			highlightRanges += other.highlightRanges
			previewSliceHighlightRanges += other.previewSliceHighlightRanges
			parseCount += other.parseCount
		}
	}

	private enum StressFailure: Error, CustomStringConvertible, Sendable {
		case emptyCaptures(worker: Int, iteration: Int, fileExtension: String)
		case parseFailed(worker: Int, iteration: Int, fileExtension: String)

		var description: String {
			switch self {
			case .emptyCaptures(let worker, let iteration, let fileExtension):
				return "Expected captures for .\(fileExtension) in worker \(worker), iteration \(iteration)"
			case .parseFailed(let worker, let iteration, let fileExtension):
				return "Expected parse tree for .\(fileExtension) in worker \(worker), iteration \(iteration)"
			}
		}
	}

	func testConcurrentCodeMapCallsCompleteWithoutCrashing() async throws {
		let workerCount = 24
		let iterationsPerWorker = 12
		let snippets = Self.snippets
		var totalCaptures = 0

		try await withThrowingTaskGroup(of: Int.self) { group in
			for worker in 0..<workerCount {
				group.addTask {
					var workerCaptures = 0
					for iteration in 0..<iterationsPerWorker {
						let snippet = snippets[(worker + iteration) % snippets.count]
						let captures = try SyntaxManager.shared.codeMap(
							content: snippet.content,
							fileExtension: snippet.fileExtension
						)
						guard !captures.isEmpty else {
							throw StressFailure.emptyCaptures(
								worker: worker,
								iteration: iteration,
								fileExtension: snippet.fileExtension
							)
						}
						workerCaptures += captures.count
					}
					return workerCaptures
				}
			}

			while let captures = try await group.next() {
				totalCaptures += captures
			}
		}

		XCTAssertGreaterThan(totalCaptures, 0)
	}

	func testConcurrentMixedTreeSitterOperationsCompleteWithoutCrashing() async throws {
		let workerCount = 16
		let iterationsPerWorker = 8
		let snippets = Self.snippets
		var totals = MixedStressResult()

		try await withThrowingTaskGroup(of: MixedStressResult.self) { group in
			for worker in 0..<workerCount {
				group.addTask {
					var result = MixedStressResult()
					for iteration in 0..<iterationsPerWorker {
						let snippet = snippets[(worker + iteration) % snippets.count]
						let originName = "mixed-worker-\(worker)-iteration-\(iteration)"

						let captures = try SyntaxManager.shared.codeMap(
							content: snippet.content,
							fileExtension: snippet.fileExtension,
							origin: .test(name: "\(originName)-codemap")
						)
						guard !captures.isEmpty else {
							throw StressFailure.emptyCaptures(
								worker: worker,
								iteration: iteration,
								fileExtension: snippet.fileExtension
							)
						}
						result.codeMapCaptures += captures.count

						let highlightRanges = try SyntaxManager.shared.highlight(
							content: snippet.content,
							fileExtension: snippet.fileExtension,
							origin: .test(name: "\(originName)-highlight")
						)
						result.highlightRanges += highlightRanges.count

						let parseSucceeded = try SyntaxManager.shared.parseSucceeds(
							content: snippet.content,
							fileExtension: snippet.fileExtension,
							origin: .test(name: "\(originName)-parse")
						)
						guard parseSucceeded else {
							throw StressFailure.parseFailed(
								worker: worker,
								iteration: iteration,
								fileExtension: snippet.fileExtension
							)
						}
						result.parseCount += 1

						let previewSliceContent = Self.previewSliceContent(for: snippet)
						let previewRanges = try SyntaxManager.shared.highlight(
							content: previewSliceContent,
							fileExtension: snippet.fileExtension,
							origin: .previewSlice(
								relativePath: "StressHarness/example.\(snippet.fileExtension)",
								sliceCount: 1
							)
						)
						result.previewSliceHighlightRanges += previewRanges.count
					}
					return result
				}
			}

			while let result = try await group.next() {
				totals.merge(result)
			}
		}

		XCTAssertGreaterThan(totals.codeMapCaptures, 0)
		XCTAssertGreaterThan(totals.parseCount, 0)
	}

	private static func previewSliceContent(for snippet: Snippet) -> String {
		let commentPrefix = commentPrefix(for: snippet.fileExtension)
		let body = snippet.content
			.split(separator: "\n", omittingEmptySubsequences: false)
			.prefix(6)
			.joined(separator: "\n")
		return "\(commentPrefix) (lines 1-6: stress preview slice)\n\(body)"
	}

	private static func commentPrefix(for fileExtension: String) -> String {
		switch fileExtension {
		case "py", "rb":
			return "#"
		default:
			return "//"
		}
	}

	private static let snippets: [Snippet] = [
		Snippet(
			fileExtension: "swift",
			content: """
			import Foundation

			final class StressHarness {
				func run(value: Int) -> String {
					String(value)
				}
			}

			struct StressValue {
				let id: UUID
			}
			"""
		),
		Snippet(
			fileExtension: "ts",
			content: """
			export interface StressShape {
				id: string
				run(value: number): string
			}

			export class StressRunner implements StressShape {
				id = "runner"

				run(value: number): string {
					return `value: ${value}`
				}
			}
			"""
		),
		Snippet(
			fileExtension: "js",
			content: """
			export class StressRunner {
				run(value) {
					return `value: ${value}`
				}
			}

			export function makeRunner() {
				return new StressRunner()
			}
			"""
		),
		Snippet(
			fileExtension: "py",
			content: """
			class StressRunner:
			    def run(self, value: int) -> str:
			        return f"value: {value}"

			def make_runner() -> StressRunner:
			    return StressRunner()
			"""
		),
		Snippet(
			fileExtension: "php",
			content: """
			<?php

			class StressRunner {
				public function run(int $value): string {
					return "value: " . $value;
				}
			}

			function makeRunner(): StressRunner {
				return new StressRunner();
			}
			"""
		),
		Snippet(
			fileExtension: "rb",
			content: """
			class StressRunner
			  def run(value)
			    "value: #{value}"
			  end
			end

			def make_runner
			  StressRunner.new
			end
			"""
		)
	]
}
