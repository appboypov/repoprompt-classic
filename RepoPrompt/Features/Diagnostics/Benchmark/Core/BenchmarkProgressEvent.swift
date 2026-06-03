import Foundation

/// Progress updates emitted while running the benchmark engine.
/// Designed to mirror the Context Builder's progress UI with coarse-grained stages.
enum BenchmarkProgressEvent: Sendable {
	case started(totalSeeds: Int)
	case seedStarted(index: Int, seed: UInt32, totalSeeds: Int, taskCount: Int, taskTypes: [BenchmarkCaseType])
	case taskCompleted(seed: UInt32, completed: Int, total: Int)
	case seedCompleted(index: Int, seed: UInt32)
	case finished(totalSeeds: Int)
	case cancelled
}
