import XCTest
import Darwin
@testable import RepoPrompt

final class FDWriteSupportTests: XCTestCase {
	func testWriteAllReturnsBrokenPipeWhenReadEndIsClosed() throws {
		var pipePair = try makePipePair()
		XCTAssertTrue(FDWriteSupport.configureNoSigPipe(fd: pipePair.writeFD))
		_ = Darwin.close(pipePair.readFD)
		pipePair.readFD = -1

		do {
			try FDWriteSupport.writeAll(Data("hello".utf8), to: pipePair.writeFD)
			XCTFail("Expected broken pipe error")
		} catch let error as FDWriteError {
			XCTAssertEqual(error, .brokenPipe(errno: EPIPE))
		}

		pipePair.closeAll()
	}

	func testWriteAllReturnsBadDescriptorForClosedFD() throws {
		var pipePair = try makePipePair()
		let closedFD = pipePair.writeFD
		_ = Darwin.close(closedFD)
		pipePair.writeFD = -1

		do {
			try FDWriteSupport.writeAll(Data("hello".utf8), to: closedFD)
			XCTFail("Expected bad descriptor error")
		} catch let error as FDWriteError {
			XCTAssertEqual(error, .badDescriptor(errno: EBADF))
		}

		pipePair.closeAll()
	}

	func testConfigureNoSigPipeAllowsRecoverablePipeFailure() throws {
		var pipePair = try makePipePair()
		XCTAssertTrue(FDWriteSupport.configureNoSigPipe(fd: pipePair.writeFD))
		_ = Darwin.close(pipePair.readFD)
		pipePair.readFD = -1

		XCTAssertThrowsError(try FDWriteSupport.writeAll(Data("payload".utf8), to: pipePair.writeFD)) { error in
			guard case FDWriteError.brokenPipe(let errno) = error else {
				return XCTFail("Expected broken pipe error, got: \(error)")
			}
			XCTAssertEqual(errno, EPIPE)
		}

		pipePair.closeAll()
	}

	private struct PipePair {
		var readFD: Int32
		var writeFD: Int32

		mutating func closeAll() {
			if readFD >= 0 {
				_ = Darwin.close(readFD)
				readFD = -1
			}
			if writeFD >= 0 {
				_ = Darwin.close(writeFD)
				writeFD = -1
			}
		}
	}

	private func makePipePair() throws -> PipePair {
		var fds: [Int32] = [-1, -1]
		guard Darwin.pipe(&fds) == 0 else {
			throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
		}
		return PipePair(readFD: fds[0], writeFD: fds[1])
	}
}
