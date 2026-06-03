//
//  MCPFilesystemConstantsTests.swift
//  RepoPromptTests
//
//  Unit tests for MCP filesystem constants including socket directory
//  path generation and security considerations.
//

import XCTest
@testable import RepoPrompt

final class MCPFilesystemConstantsTests: XCTestCase {

	// MARK: - Socket Directory Tests

	func testSocketDirectoryIncludesUID() {
		let url = MCPFilesystemConstants.socketDirectoryURL()
		let uid = getuid()

		XCTAssertTrue(url.path.contains("-\(uid)"),
			"Socket directory should include UID for per-user isolation: \(url.path)")
	}

	func testSocketDirectoryIsInTmp() {
		let url = MCPFilesystemConstants.socketDirectoryURL()

		XCTAssertTrue(url.path.hasPrefix("/tmp/"),
			"Socket directory should be in /tmp for path length safety: \(url.path)")
	}

	func testSocketDirectoryNameIncludesRepoprompt() {
		let url = MCPFilesystemConstants.socketDirectoryURL()

		XCTAssertTrue(url.path.contains("repoprompt-mcp"),
			"Socket directory should include 'repoprompt-mcp': \(url.path)")
	}

	func testSocketDirectoryPathIsShort() {
		let url = MCPFilesystemConstants.socketDirectoryURL()

		// UNIX domain sockets have a ~104 byte path limit (sun_path size)
		// The directory path should leave room for socket filename
		XCTAssertLessThan(url.path.utf8.count, 80,
			"Socket directory path should leave room for socket filename: \(url.path)")
	}

	// MARK: - Bootstrap Socket Tests

	func testBootstrapSocketURL() {
		let url = MCPFilesystemConstants.bootstrapSocketURL()
		let dirURL = MCPFilesystemConstants.socketDirectoryURL()

		XCTAssertEqual(url.deletingLastPathComponent(), dirURL,
			"Bootstrap socket should be in the socket directory")
		XCTAssertEqual(url.lastPathComponent, MCPFilesystemConstants.bootstrapSocketName)
	}

	func testBootstrapSocketNameIsWellKnown() {
		XCTAssertEqual(MCPFilesystemConstants.bootstrapSocketName, "repoprompt.sock",
			"Bootstrap socket should have a well-known name for CLI to connect to")
	}

	func testBootstrapSocketPathFitsSunPath() {
		let url = MCPFilesystemConstants.bootstrapSocketURL()

		// sun_path is typically 104 bytes on macOS
		// We need to ensure our full socket path fits
		XCTAssertLessThanOrEqual(url.path.utf8.count, 100,
			"Bootstrap socket path must fit in sun_path (104 bytes): \(url.path)")
	}

	// MARK: - Directory Creation Tests

	func testEnsureSocketDirectoryExists() {
		// Clean up first if exists
		let url = MCPFilesystemConstants.socketDirectoryURL()
		try? FileManager.default.removeItem(at: url)

		// Create directory
		let result = MCPFilesystemConstants.ensureSocketDirectoryExists()
		XCTAssertTrue(result, "Should successfully create socket directory")

		// Verify it exists
		var isDir: ObjCBool = false
		let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
		XCTAssertTrue(exists, "Directory should exist after creation")
		XCTAssertTrue(isDir.boolValue, "Path should be a directory")

		// Calling again should also succeed (idempotent)
		let result2 = MCPFilesystemConstants.ensureSocketDirectoryExists()
		XCTAssertTrue(result2, "Should succeed when directory already exists")
	}

	func testSocketDirectoryHasSecurePermissions() {
		// Create directory
		let url = MCPFilesystemConstants.socketDirectoryURL()
		try? FileManager.default.removeItem(at: url)
		MCPFilesystemConstants.ensureSocketDirectoryExists()

		// Check permissions
		do {
			let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
			let permissions = attributes[.posixPermissions] as? Int

			// Should be 0700 (owner read/write/execute only)
			XCTAssertEqual(permissions, 0o700,
				"Socket directory should have 0700 permissions for security")
		} catch {
			XCTFail("Failed to get directory attributes: \(error)")
		}
	}

	// MARK: - Debug Logging Tests

	func testMCPDebugLoggingDefaultsToOff() {
		// By default, debug logging should be off to avoid console spam
		XCTAssertFalse(MCPDebugLogging.enabled,
			"MCP debug logging should be disabled by default")
	}

	func testMCPDebugLoggingTransportFlagDefaultsToOff() {
		XCTAssertFalse(MCPDebugLogging.transportVerbose,
			"Transport verbose logging should be disabled by default")
	}

	func testMCPDebugLoggingConnectionFlagDefaultsToOff() {
		XCTAssertFalse(MCPDebugLogging.connectionLifecycle,
			"Connection lifecycle logging should be disabled by default")
	}

	func testMCPDebugLoggingRoutingFlagDefaultsToOff() {
		XCTAssertFalse(MCPDebugLogging.routing,
			"Routing debug logging should be disabled by default")
	}

	// MARK: - Path Consistency Tests

	func testSocketDirectoryIsConsistentAcrossCalls() {
		let url1 = MCPFilesystemConstants.socketDirectoryURL()
		let url2 = MCPFilesystemConstants.socketDirectoryURL()

		XCTAssertEqual(url1, url2, "Socket directory URL should be consistent across calls")
	}

	func testBootstrapSocketIsConsistentAcrossCalls() {
		let url1 = MCPFilesystemConstants.bootstrapSocketURL()
		let url2 = MCPFilesystemConstants.bootstrapSocketURL()

		XCTAssertEqual(url1, url2, "Bootstrap socket URL should be consistent across calls")
	}

	// MARK: - Edge Case Tests

	func testSocketDirectoryWithDifferentUsers() {
		// This is a design verification test - we expect the path to include UID
		// to prevent cross-user collisions or security issues
		let url = MCPFilesystemConstants.socketDirectoryURL()
		let pathComponents = url.path.components(separatedBy: "-")

		// Should have at least 3 components: /tmp/repoprompt-mcp-<uid>
		XCTAssertGreaterThanOrEqual(pathComponents.count, 2,
			"Path should have UID suffix: \(url.path)")

		// Last component should be parseable as a number (the UID)
		if let lastComponent = pathComponents.last,
		   let _ = UInt32(lastComponent) {
			// Valid UID format
		} else {
			XCTFail("Socket directory path should end with numeric UID: \(url.path)")
		}
	}
}

// MARK: - Integration Tests

final class MCPFilesystemConstantsIntegrationTests: XCTestCase {

	func testCanCreateSocketInDirectory() throws {
		// Ensure directory exists
		MCPFilesystemConstants.ensureSocketDirectoryExists()

		let testSocketURL = MCPFilesystemConstants.socketDirectoryURL()
			.appendingPathComponent("test-\(UUID().uuidString).sock", isDirectory: false)

		defer {
			try? FileManager.default.removeItem(at: testSocketURL)
		}

		// Create a listening socket to verify the directory is usable
		let fd = socket(AF_UNIX, SOCK_STREAM, 0)
		XCTAssertGreaterThanOrEqual(fd, 0, "Should be able to create socket")

		defer { Darwin.close(fd) }

		// Bind to socket path
		var addr = sockaddr_un()
		addr.sun_family = sa_family_t(AF_UNIX)

		let path = testSocketURL.path
		withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
			path.withCString { cstr in
				_ = strcpy(UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self), cstr)
			}
		}

		let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
		let bindResult = withUnsafePointer(to: &addr) { addrPtr in
			addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
				Darwin.bind(fd, sockaddrPtr, addrLen)
			}
		}

		XCTAssertEqual(bindResult, 0,
			"Should be able to bind socket in MCP directory (errno: \(errno))")
	}

	func testBootstrapSocketPathIsValidUnixSocket() {
		let url = MCPFilesystemConstants.bootstrapSocketURL()

		// Verify path is absolute
		XCTAssertTrue(url.path.hasPrefix("/"),
			"Bootstrap socket path should be absolute")

		// Verify path ends with .sock
		XCTAssertEqual(url.pathExtension, "sock",
			"Bootstrap socket should have .sock extension")

		// Verify parent directory is the socket directory
		XCTAssertEqual(url.deletingLastPathComponent(),
			MCPFilesystemConstants.socketDirectoryURL(),
			"Bootstrap socket should be in the socket directory")
	}
}
