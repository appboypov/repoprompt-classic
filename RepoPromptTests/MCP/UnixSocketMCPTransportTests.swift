//
//  UnixSocketMCPTransportTests.swift
//  RepoPromptTests
//
//  Unit tests for UnixSocketMCPTransport covering initialization
//  and basic functionality.
//

import XCTest
import Logging
@testable import RepoPrompt

final class UnixSocketMCPTransportTests: XCTestCase {

	// MARK: - Properties

	private var testSocketDir: URL!
	private var testSocketURL: URL!

	// MARK: - Setup/Teardown

	override func setUp() async throws {
		try await super.setUp()

		// Create a unique test directory in /tmp (not NSTemporaryDirectory which can be long)
		// UNIX sockets have a ~104 byte path limit (sun_path), so we need short paths
		let shortID = UUID().uuidString.prefix(8)
		testSocketDir = URL(fileURLWithPath: "/tmp/mcp-\(shortID)", isDirectory: true)
		try FileManager.default.createDirectory(at: testSocketDir, withIntermediateDirectories: true)
		testSocketURL = testSocketDir.appendingPathComponent("t.sock", isDirectory: false)
	}

	override func tearDown() async throws {
		// Clean up test directory
		if let testSocketDir = testSocketDir {
			try? FileManager.default.removeItem(at: testSocketDir)
		}
		try await super.tearDown()
	}

	// MARK: - Initialization Tests

	func testInitWithSocketURL() async {
		let transport = UnixSocketMCPTransport(socketURL: testSocketURL)

		// Transport should not be connected initially
		let activity = await transport.secondsSinceLastActivity()
		XCTAssertNil(activity, "Transport should have no activity before connection")
	}

	func testInitialActivityIsNil() async {
		let transport = UnixSocketMCPTransport(socketURL: testSocketURL)
		let activity = await transport.secondsSinceLastActivity()
		XCTAssertNil(activity, "Activity should be nil before any connection")
	}

	// MARK: - Connection Tests

	func testConnectToNonExistentSocketTimesOut() async {
		// Use a socket URL that doesn't exist
		let nonExistentSocket = testSocketDir.appendingPathComponent("nonexistent.sock", isDirectory: false)
		let transport = UnixSocketMCPTransport(socketURL: nonExistentSocket)

		// Since we can't override timeout, we'll verify it throws via cancellation
		do {
			try await withThrowingTaskGroup(of: Void.self) { group in
				group.addTask {
					try await transport.connect()
				}
				group.addTask {
					try await Task.sleep(nanoseconds: 500_000_000) // 500ms
					throw CancellationError()
				}
				try await group.next()
				group.cancelAll()
			}
			XCTFail("Connect should have failed or been cancelled")
		} catch {
			// Expected - either timeout or cancellation
		}
	}

	func testConnectAndDisconnect() async throws {
		// Create a listening socket to accept connections
		let listenFD = socket(AF_UNIX, SOCK_STREAM, 0)
		XCTAssertGreaterThanOrEqual(listenFD, 0, "Failed to create socket")

		defer {
			Darwin.close(listenFD)
			unlink(testSocketURL.path)
		}

		// Bind and listen
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)
		withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
			testSocketURL.path.withCString { cstr in
				_ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
			}
		}

		let bindResult = withUnsafePointer(to: &addr) { ptr in
			ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
				Darwin.bind(listenFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
			}
		}
		XCTAssertEqual(bindResult, 0, "bind should succeed")

		let listenResult = listen(listenFD, 1)
		XCTAssertEqual(listenResult, 0, "listen should succeed")

		// Set non-blocking for accept
		let flags = fcntl(listenFD, F_GETFL)
		_ = fcntl(listenFD, F_SETFL, flags | O_NONBLOCK)

		// Create transport
		let transport = UnixSocketMCPTransport(socketURL: testSocketURL)

		// Accept connection in background
		let acceptTask = Task { () -> Int32 in
			var clientAddr = sockaddr_un()
			var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

			var clientFD: Int32 = -1
			let deadline = Date().addingTimeInterval(5.0)

			while clientFD < 0 && Date() < deadline {
				clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
					ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
						accept(listenFD, sockaddrPtr, &addrLen)
					}
				}
				if clientFD < 0 && errno == EAGAIN {
					try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
				}
			}
			return clientFD
		}

		// Connect
		try await transport.connect()

		// Wait for accept to complete
		let clientFD = await acceptTask.value
		XCTAssertGreaterThanOrEqual(clientFD, 0, "Accept should succeed")

		defer { if clientFD >= 0 { Darwin.close(clientFD) } }

		// Verify connected state
		let activity = await transport.secondsSinceLastActivity()
		XCTAssertNotNil(activity, "Transport should have activity after connection")

		// Disconnect
		await transport.disconnect()
	}

	// MARK: - Socket Pair Utility Tests (test the test infrastructure)

	func testSocketPairCreation() {
		var sockets: [Int32] = [0, 0]
		let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
		XCTAssertEqual(result, 0, "socketpair should succeed")

		defer {
			Darwin.close(sockets[0])
			Darwin.close(sockets[1])
		}

		// Write to one end, read from the other
		let testData = "Hello".data(using: .utf8)!
		let written = testData.withUnsafeBytes { buf in
			Darwin.write(sockets[0], buf.baseAddress!, buf.count)
		}
		XCTAssertEqual(written, testData.count)

		var readBuffer = [UInt8](repeating: 0, count: 16)
		let bytesRead = Darwin.read(sockets[1], &readBuffer, readBuffer.count)
		XCTAssertEqual(bytesRead, testData.count)

		let received = String(bytes: readBuffer[0..<bytesRead], encoding: .utf8)
		XCTAssertEqual(received, "Hello")
	}

	// MARK: - Transport with Existing FD Tests

	func testInitWithExistingFDHasActivity() async throws {
		var sockets: [Int32] = [0, 0]
		let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
		XCTAssertEqual(result, 0, "socketpair should succeed")

		// Close the other end immediately to prevent read source from blocking
		Darwin.close(sockets[1])

		let transport = UnixSocketMCPTransport(connectedFD: sockets[0])

		// Connect starts the read source, but since peer is closed,
		// it should detect EOF quickly
		try await transport.connect()

		// Activity should be set after connect
		let activity = await transport.secondsSinceLastActivity()
		XCTAssertNotNil(activity, "Transport should have activity after connect")

		// Give read source time to detect EOF and clean up
		try await Task.sleep(nanoseconds: 100_000_000) // 100ms

		await transport.disconnect()
	}

	func testReceiveStreamExistsAfterConnect() async throws {
		var sockets: [Int32] = [0, 0]
		let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
		XCTAssertEqual(result, 0, "socketpair should succeed")

		// Close peer immediately
		Darwin.close(sockets[1])

		let transport = UnixSocketMCPTransport(connectedFD: sockets[0])
		try await transport.connect()

		// Just verify we can get the receive stream
		let stream = await transport.receive()
		XCTAssertNotNil(stream, "Should have a receive stream after connect")

		try await Task.sleep(nanoseconds: 100_000_000)
		await transport.disconnect()
	}

	func testClosedStreamExistsAfterConnect() async throws {
		var sockets: [Int32] = [0, 0]
		let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
		XCTAssertEqual(result, 0, "socketpair should succeed")

		// Close peer immediately
		Darwin.close(sockets[1])

		let transport = UnixSocketMCPTransport(connectedFD: sockets[0])
		try await transport.connect()

		// Just verify we can get the closed stream
		let stream = await transport.closed()
		XCTAssertNotNil(stream, "Should have a closed stream after connect")

		try await Task.sleep(nanoseconds: 100_000_000)
		await transport.disconnect()
	}

	// MARK: - Error Condition Tests

	func testSendOnDisconnectedTransportThrows() async throws {
		let transport = UnixSocketMCPTransport(socketURL: testSocketURL)

		// Try to send without connecting - should throw
		do {
			try await transport.send("test".data(using: .utf8)!)
			XCTFail("Send should throw on disconnected transport")
		} catch {
			// Expected
		}
	}

	func testSendBrokenPipeClosesAndSignalsClosed() async throws {
		var sockets: [Int32] = [0, 0]
		let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
		XCTAssertEqual(result, 0, "socketpair should succeed")

		let transport = UnixSocketMCPTransport(
			connectedFD: sockets[0],
			writeStallTimeout: 1.0,
			writePollIntervalMilliseconds: 10
		)
		try await transport.connect()

		let closedStream = await transport.closed()
		let closedTask = Task { await Self.waitForClosedSignal(closedStream, timeoutNanoseconds: 2_000_000_000) }

		// Close the peer so the transport's next write fails with closed-peer semantics.
		Darwin.close(sockets[1])
		sockets[1] = -1

		do {
			try await transport.send(Data(repeating: 0x61, count: 1024))
			XCTFail("Send should throw when peer is closed")
		} catch {
			// Expected: either send-side EPIPE/ECONNRESET or the read side racing to closed.
		}

		let didSignalClosed = await closedTask.value
		XCTAssertTrue(didSignalClosed, "send-side fatal failure should signal closed()")
		await transport.disconnect()
	}

	func testSendBackpressureStallTimeoutClosesAndSignalsClosed() async throws {
		var sockets: [Int32] = [0, 0]
		let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
		XCTAssertEqual(result, 0, "socketpair should succeed")

		var bufferSize: Int32 = 4096
		setsockopt(sockets[0], SOL_SOCKET, SO_SNDBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))
		setsockopt(sockets[1], SOL_SOCKET, SO_RCVBUF, &bufferSize, socklen_t(MemoryLayout<Int32>.size))

		let transport = UnixSocketMCPTransport(
			connectedFD: sockets[0],
			writeStallTimeout: 0.05,
			writePollIntervalMilliseconds: 0
		)
		try await transport.connect()

		let closedStream = await transport.closed()
		let closedTask = Task { await Self.waitForClosedSignal(closedStream, timeoutNanoseconds: 2_000_000_000) }

		do {
			try await transport.send(Data(repeating: 0x62, count: 8 * 1024 * 1024))
			XCTFail("Send should stall and time out when peer stops draining")
		} catch {
			// Expected bounded no-progress timeout.
		}

		let didSignalClosed = await closedTask.value
		XCTAssertTrue(didSignalClosed, "write stall timeout should signal closed()")
		Darwin.close(sockets[1])
		await transport.disconnect()
	}

	func testConnectWithNegativeExistingFDThrowsAndSignalsClosed() async {
		let transport = UnixSocketMCPTransport(connectedFD: -1)
		let closedStream = await transport.closed()
		let closedTask = Task { await Self.waitForClosedSignal(closedStream, timeoutNanoseconds: 2_000_000_000) }

		do {
			try await transport.connect()
			XCTFail("Connect should throw for a negative existing FD")
		} catch {
			// Expected: invalid FD must fail before DispatchSource creation.
		}

		let didSignalClosed = await closedTask.value
		XCTAssertTrue(didSignalClosed, "invalid existing FD should signal closed()")
	}

	func testConnectWithClosedExistingFDThrowsAndSignalsClosed() async throws {
		var sockets: [Int32] = [0, 0]
		let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
		XCTAssertEqual(result, 0, "socketpair should succeed")

		let closedFD = sockets[0]
		Darwin.close(sockets[0])
		sockets[0] = -1
		defer {
			if sockets[1] >= 0 { Darwin.close(sockets[1]) }
		}

		let transport = UnixSocketMCPTransport(connectedFD: closedFD)
		let closedStream = await transport.closed()
		let closedTask = Task { await Self.waitForClosedSignal(closedStream, timeoutNanoseconds: 2_000_000_000) }

		do {
			try await transport.connect()
			XCTFail("Connect should throw for an already-closed existing FD")
		} catch {
			// Expected: closed FD must fail before DispatchSource creation.
		}

		let didSignalClosed = await closedTask.value
		XCTAssertTrue(didSignalClosed, "closed existing FD should signal closed()")
	}

	func testExistingFDSecondConnectAfterEOFThrowsWithoutRestartingReader() async throws {
		var sockets: [Int32] = [0, 0]
		let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
		XCTAssertEqual(result, 0, "socketpair should succeed")

		let transport = UnixSocketMCPTransport(connectedFD: sockets[0])
		try await transport.connect()

		let closedStream = await transport.closed()
		let closedTask = Task { await Self.waitForClosedSignal(closedStream, timeoutNanoseconds: 2_000_000_000) }

		Darwin.close(sockets[1])
		sockets[1] = -1

		let didSignalClosed = await closedTask.value
		XCTAssertTrue(didSignalClosed, "peer EOF should signal closed()")

		do {
			try await transport.connect()
			XCTFail("Second connect after EOF should throw instead of restarting a reader on fd -1")
		} catch {
			// Expected: accepted-FD transports are terminal after EOF.
		}

		await transport.disconnect()
	}

	func testNewlineDelimitedSocketReaderStartWithNegativeFDThrowsWithoutCallbacks() {
		var callbackInvoked = false
		let reader = NewlineDelimitedSocketReader(
			fd: -1,
			queue: DispatchQueue(label: "test.newline-reader.negative"),
			logger: Self.testLogger(),
			onFrame: { _ in callbackInvoked = true },
			onEOF: { _ in callbackInvoked = true },
			onError: { _ in callbackInvoked = true }
		)

		XCTAssertThrowsError(try reader.start())
		XCTAssertFalse(callbackInvoked, "Invalid FD preflight should throw synchronously without invoking callbacks")
	}

	func testNewlineDelimitedSocketReaderStartWithClosedFDThrowsWithoutCallbacks() throws {
		var sockets: [Int32] = [0, 0]
		let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets)
		XCTAssertEqual(result, 0, "socketpair should succeed")

		let closedFD = sockets[0]
		Darwin.close(sockets[0])
		sockets[0] = -1
		defer {
			if sockets[1] >= 0 { Darwin.close(sockets[1]) }
		}

		var callbackInvoked = false
		let reader = NewlineDelimitedSocketReader(
			fd: closedFD,
			queue: DispatchQueue(label: "test.newline-reader.closed"),
			logger: Self.testLogger(),
			onFrame: { _ in callbackInvoked = true },
			onEOF: { _ in callbackInvoked = true },
			onError: { _ in callbackInvoked = true }
		)

		XCTAssertThrowsError(try reader.start())
		XCTAssertFalse(callbackInvoked, "Closed FD preflight should throw synchronously without invoking callbacks")
	}

	private static func testLogger() -> Logger {
		Logger(label: "com.repoprompt.tests.newline-reader") { _ in SwiftLogNoOpLogHandler() }
	}

	private static func waitForClosedSignal(_ stream: AsyncStream<Void>, timeoutNanoseconds: UInt64) async -> Bool {
		await withTaskGroup(of: Bool.self) { group in
			group.addTask {
				var iterator = stream.makeAsyncIterator()
				return await iterator.next() != nil
			}
			group.addTask {
				try? await Task.sleep(nanoseconds: timeoutNanoseconds)
				return false
			}

			let result = await group.next() ?? false
			group.cancelAll()
			return result
		}
	}
}
