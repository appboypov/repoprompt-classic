import XCTest
@testable import RepoPrompt
import Darwin

final class ProcessTerminationTests: XCTestCase {
	private func spawnShell(_ script: String) throws -> SpawnedProcess {
		try ProcessLauncher.spawn(
			command: "/bin/sh",
			arguments: ["-c", script],
			environment: ProcessInfo.processInfo.environment,
			workingDirectory: nil
		)
	}

	private func closeHandles(_ process: SpawnedProcess) {
		process.stdin?.closeFile()
		process.stdout.closeFile()
		process.stderr.closeFile()
	}

	func testWaitForTerminationReturnsExitCodeForNormalExit() async throws {
		let process = try spawnShell("exit 7")
		defer { closeHandles(process) }

		let result = try await ProcessTermination.waitForTermination(pid: process.pid, timeout: 2)

		XCTAssertEqual(result.exitCode, 7)
		XCTAssertFalse(result.timedOut)
	}

	func testWaitForTerminationTimesOutAndTerminatesProcess() async throws {
		let process = try spawnShell("sleep 30")
		defer { closeHandles(process) }

		let result = try await ProcessTermination.waitForTermination(pid: process.pid, timeout: 0.1)

		XCTAssertTrue(result.timedOut)
		XCTAssertGreaterThanOrEqual(result.exitCode, 128)
	}

	func testWaitForTerminationCancellationTerminatesProcess() async throws {
		let process = try spawnShell("sleep 30")
		defer { closeHandles(process) }

		let task = Task {
			try await ProcessTermination.waitForTermination(pid: process.pid, timeout: nil)
		}
		try await Task.sleep(nanoseconds: 100_000_000)
		task.cancel()

		let result = try await task.value
		XCTAssertFalse(result.timedOut)
		XCTAssertGreaterThanOrEqual(result.exitCode, 128)
	}

	func testTerminateAndReapEscalatesToSigkillWhenSigtermIgnored() async throws {
		let process = try spawnShell("trap '' TERM; while true; do sleep 1; done")
		defer { closeHandles(process) }

		let exitCode = await ProcessTermination.terminateAndReap(
			pid: process.pid,
			sigtermGrace: 0.05,
			sigkillGrace: 0.05
		)

		XCTAssertEqual(exitCode, 128 + SIGKILL)
	}

	func testTerminateAndReapReturnsOriginalExitCodeForAlreadyExitedChild() async throws {
		let process = try spawnShell("exit 11")
		defer { closeHandles(process) }
		try await Task.sleep(nanoseconds: 100_000_000)

		let exitCode = await ProcessTermination.terminateAndReap(pid: process.pid)
		XCTAssertEqual(exitCode, 11)
	}

	func testWaitForTerminationHandlesAlreadyReapedChildWithoutHanging() async throws {
		let process = try spawnShell("exit 0")
		defer { closeHandles(process) }

		var status: Int32 = 0
		let waitedPID = Darwin.waitpid(process.pid, &status, 0)
		XCTAssertEqual(waitedPID, process.pid)

		let result = try await ProcessTermination.waitForTermination(pid: process.pid, timeout: 0.2)
		XCTAssertFalse(result.timedOut)
		XCTAssertEqual(result.exitCode, 0)
	}
}
