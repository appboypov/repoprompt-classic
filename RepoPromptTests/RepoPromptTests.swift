//
//  RepoPromptTests.swift
//  RepoPromptTests
//
//  Created by Eric Provencher on 2024-06-25.
//

import XCTest
@testable import RepoPrompt

final class RepoPromptTests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct results.
        // Any test you write for XCTest can be annotated as throws and async.
        // Mark your test throws to produce an unexpected failure when your test encounters an uncaught error.
        // Mark your test async to allow awaiting for asynchronous code to complete. Check the results with assertions afterwards.
		print("Pass")
		XCTAssert(true)
    }

    func testPerformanceExample() throws {
        // This is an example of a performance test case.
        self.measure {
            // Put the code you want to measure the time of here.
        }
		XCTAssert(true)
    }

	// MARK: - Process Deadlock Prevention Smoke Tests

	/// Tests that large stdout + large stdin don't cause cross-pipe deadlock.
	/// Child writes 8MB to stdout, then reads stdin fully, then exits.
	func testLargeStdoutAndLargeStdinNoDeadlock() async throws {
		let config = CLIProcessConfiguration(command: "/bin/sh", enableDebugLogging: false)
		let runner = CLIProcessRunner(config: config)

		// Create 8MB of stdin data
		let largeIn = String(repeating: "X", count: 8 * 1024 * 1024)

		// Child command: write 8MB to stdout, then consume stdin, then exit
		// This tests that readers drain stdout while stdin is being written
		let result = try await runner.run(
			args: ["-lc", "dd if=/dev/zero bs=1m count=8 2>/dev/null; cat >/dev/null"],
			stdin: largeIn,
			outputMode: .none,
			timeout: 10
		)

		XCTAssertEqual(result.status, 0, "Command should complete successfully without deadlock")
	}

	func testStreamingEmitsStdoutAndTermination() async throws {
		let config = CLIProcessConfiguration(command: "/bin/sh", enableDebugLogging: false)
		let runner = CLIProcessRunner(config: config)

		let stream = try await runner.runStreaming(
			args: ["-lc", "printf streamed"],
			stdin: nil,
			outputMode: .none,
			timeout: 5
		)

		var stdout = Data()
		var termination: (status: Int32, timedOut: Bool)?
		for try await event in stream {
			switch event {
			case .stdout(let data):
				stdout.append(data)
			case .stderr:
				break
			case .terminated(let status, let timedOut):
				termination = (status, timedOut)
			}
		}

		XCTAssertEqual(String(data: stdout, encoding: .utf8), "streamed")
		XCTAssertEqual(termination?.status, 0)
		XCTAssertEqual(termination?.timedOut, false)
	}

	/// Tests that a grandchild holding stdout doesn't hang readers on cancel.
	/// Child spawns a long-lived grandchild that inherits stdout, then sleeps.
	/// Cancel streaming and ensure stream finishes (gate released).
	func testGrandchildDoesNotHangReadersOnCancel() async throws {
		let config = CLIProcessConfiguration(command: "/bin/sh", enableDebugLogging: false)
		let runner = CLIProcessRunner(config: config)

		let stream = try await runner.runStreaming(
			args: ["-lc", "(sleep 60 &) ; echo started ; sleep 60"],
			stdin: nil,
			outputMode: .none,
			timeout: 10
		)

		let finishedExpectation = expectation(description: "stream task finishes after cancellation")
		let t = Task {
			defer { finishedExpectation.fulfill() }
			do {
				for try await _ in stream {}
			} catch is CancellationError {
				// Expected when the consumer task is cancelled.
			} catch {
				// Process cancellation can surface through stream termination paths; the assertion is that it does not hang.
			}
		}

		// Give the shell a short chance to spawn before cancelling.
		try await Task.sleep(nanoseconds: 300_000_000)

		// Cancel should trigger SIGTERM and close FDs, unblocking readers.
		t.cancel()

		// Wait for task to complete - should not hang.
		await fulfillment(of: [finishedExpectation], timeout: 5.0)
		_ = await t.result
	}

}
