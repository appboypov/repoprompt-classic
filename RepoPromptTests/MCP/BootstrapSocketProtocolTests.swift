//
//  BootstrapSocketProtocolTests.swift
//  RepoPromptTests
//
//  Unit tests for the bootstrap socket handshake protocol,
//  including request/response encoding and validation.
//

import XCTest
@testable import RepoPrompt

final class BootstrapSocketProtocolTests: XCTestCase {

	// MARK: - MCPBootstrapRequest Tests

	func testBootstrapRequestEncodesToJSON() throws {
		let request = MCPBootstrapRequest(
			sessionToken: "test-token-123",
			clientPid: 12345,
			clientName: "Claude Code",
			protocolVersion: MCPBootstrapProtocol.currentVersion
		)

		let encoder = JSONEncoder()
		let data = try encoder.encode(request)
		let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

		XCTAssertEqual(json["type"] as? String, "connect")
		XCTAssertEqual(json["sessionToken"] as? String, "test-token-123")
		XCTAssertEqual(json["clientPid"] as? Int, 12345)
		XCTAssertEqual(json["clientName"] as? String, "Claude Code")
		XCTAssertEqual(json["protocolVersion"] as? Int, MCPBootstrapProtocol.currentVersion)
	}

	func testBootstrapRequestDecodesFromJSON() throws {
		let json: [String: Any] = [
			"type": "connect",
			"sessionToken": "abc-def-ghi",
			"clientPid": 99999,
			"clientName": "Cursor",
			"protocolVersion": 2
		]

		let data = try JSONSerialization.data(withJSONObject: json)
		let decoder = JSONDecoder()
		let request = try decoder.decode(MCPBootstrapRequest.self, from: data)

		XCTAssertEqual(request.type, "connect")
		XCTAssertEqual(request.sessionToken, "abc-def-ghi")
		XCTAssertEqual(request.clientPid, 99999)
		XCTAssertEqual(request.clientName, "Cursor")
		XCTAssertEqual(request.protocolVersion, 2)
	}

	func testBootstrapRequestDecodesWithNilClientName() throws {
		let json: [String: Any] = [
			"type": "connect",
			"sessionToken": "token",
			"clientPid": 1,
			"protocolVersion": 2
		]

		let data = try JSONSerialization.data(withJSONObject: json)
		let decoder = JSONDecoder()
		let request = try decoder.decode(MCPBootstrapRequest.self, from: data)

		XCTAssertNil(request.clientName)
	}

	func testCurrentProtocolVersionIsV2() {
		// Protocol version 2 adds client identity caching for reconnects
		XCTAssertEqual(MCPBootstrapProtocol.currentVersion, 2)
	}

	func testBootstrapTimingFailsFastEnoughForHostBudget() {
		XCTAssertEqual(MCPBootstrapTiming.initialResponseTimeout, 5, accuracy: 0.001)
		XCTAssertLessThan(MCPBootstrapTiming.initialResponseTimeout, 30)
	}

	// MARK: - MCPBootstrapResponse Tests

	func testBootstrapResponseAccepted() {
		let response = MCPBootstrapResponse.accepted()

		XCTAssertEqual(response.type, "accepted")
		XCTAssertNil(response.reason)
		XCTAssertNil(response.errorCode)
	}

	func testBootstrapResponseRejected() {
		let response = MCPBootstrapResponse.rejected(
			reason: "Connection limit reached",
			errorCode: "connection_limit"
		)

		XCTAssertEqual(response.type, "rejected")
		XCTAssertEqual(response.reason, "Connection limit reached")
		XCTAssertEqual(response.errorCode, "connection_limit")
	}

	func testBootstrapResponseEncodesToJSON() throws {
		let response = MCPBootstrapResponse.rejected(
			reason: "Test rejection",
			errorCode: "test_error"
		)

		let encoder = JSONEncoder()
		let data = try encoder.encode(response)
		let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

		XCTAssertEqual(json["type"] as? String, "rejected")
		XCTAssertEqual(json["reason"] as? String, "Test rejection")
		XCTAssertEqual(json["errorCode"] as? String, "test_error")
	}

	func testBootstrapResponseDecodesFromJSON() throws {
		let json: [String: Any] = [
			"type": "accepted"
		]

		let data = try JSONSerialization.data(withJSONObject: json)
		let decoder = JSONDecoder()
		let response = try decoder.decode(MCPBootstrapResponse.self, from: data)

		XCTAssertEqual(response.type, "accepted")
		XCTAssertNil(response.reason)
		XCTAssertNil(response.errorCode)
	}

	// MARK: - Newline-Delimited JSON Protocol Tests

	func testRequestEndsWithNewline() throws {
		let request = MCPBootstrapRequest(
			sessionToken: "token",
			clientPid: 1,
			clientName: nil,
			protocolVersion: 2
		)

		let encoder = JSONEncoder()
		var data = try encoder.encode(request)
		data.append(UInt8(ascii: "\n"))

		// Should end with exactly one newline
		XCTAssertEqual(data.last, UInt8(ascii: "\n"))

		// Should be parseable without the newline
		let jsonData = data.dropLast()
		let decoded = try JSONDecoder().decode(MCPBootstrapRequest.self, from: Data(jsonData))
		XCTAssertEqual(decoded.sessionToken, "token")
	}

	func testResponseEndsWithNewline() throws {
		let response = MCPBootstrapResponse.accepted()

		let encoder = JSONEncoder()
		var data = try encoder.encode(response)
		data.append(UInt8(ascii: "\n"))

		XCTAssertEqual(data.last, UInt8(ascii: "\n"))

		let jsonData = data.dropLast()
		let decoded = try JSONDecoder().decode(MCPBootstrapResponse.self, from: Data(jsonData))
		XCTAssertEqual(decoded.type, "accepted")
	}

	// MARK: - Error Cases

	func testBootstrapRequestFailsWithMissingRequiredFields() {
		// Missing sessionToken
		let json: [String: Any] = [
			"type": "connect",
			"clientPid": 1,
			"protocolVersion": 2
		]

		let data = try! JSONSerialization.data(withJSONObject: json)
		let decoder = JSONDecoder()

		XCTAssertThrowsError(try decoder.decode(MCPBootstrapRequest.self, from: data))
	}

	func testBootstrapRequestFailsWithInvalidJSON() {
		let invalidData = "not valid json".data(using: .utf8)!
		let decoder = JSONDecoder()

		XCTAssertThrowsError(try decoder.decode(MCPBootstrapRequest.self, from: invalidData))
	}

	// MARK: - Protocol Version Compatibility

	func testProtocolVersionMismatchCanBeDetected() {
		let v1Request = MCPBootstrapRequest(
			sessionToken: "token",
			clientPid: 1,
			clientName: nil,
			protocolVersion: 1
		)

		// App should reject v1 requests if it expects v2
		let currentVersion = MCPBootstrapProtocol.currentVersion
		XCTAssertNotEqual(v1Request.protocolVersion, currentVersion)
	}

	// MARK: - Session Token Validation

	func testSessionTokenIsPreservedExactly() throws {
		let specialToken = "token-with-special-chars_123/abc"

		let request = MCPBootstrapRequest(
			sessionToken: specialToken,
			clientPid: 1,
			clientName: nil,
			protocolVersion: 2
		)

		let encoder = JSONEncoder()
		let data = try encoder.encode(request)
		let decoded = try JSONDecoder().decode(MCPBootstrapRequest.self, from: data)

		XCTAssertEqual(decoded.sessionToken, specialToken)
	}

	func testUUIDSessionToken() throws {
		let uuidToken = UUID().uuidString

		let request = MCPBootstrapRequest(
			sessionToken: uuidToken,
			clientPid: 1,
			clientName: nil,
			protocolVersion: 2
		)

		let encoder = JSONEncoder()
		let data = try encoder.encode(request)
		let decoded = try JSONDecoder().decode(MCPBootstrapRequest.self, from: data)

		XCTAssertEqual(decoded.sessionToken, uuidToken)
	}
}

// MARK: - BootstrapSocketError Tests

final class BootstrapSocketErrorTests: XCTestCase {

	func testSocketCreationFailedCapturesErrno() {
		let error = BootstrapSocketError.socketCreationFailed(errno: EMFILE)

		if case .socketCreationFailed(let capturedErrno) = error {
			XCTAssertEqual(capturedErrno, EMFILE)
		} else {
			XCTFail("Wrong error case")
		}
	}

	func testBindFailedCapturesErrno() {
		let error = BootstrapSocketError.bindFailed(errno: EADDRINUSE)

		if case .bindFailed(let capturedErrno) = error {
			XCTAssertEqual(capturedErrno, EADDRINUSE)
		} else {
			XCTFail("Wrong error case")
		}
	}

	func testListenFailedCapturesErrno() {
		let error = BootstrapSocketError.listenFailed(errno: EOPNOTSUPP)

		if case .listenFailed(let capturedErrno) = error {
			XCTAssertEqual(capturedErrno, EOPNOTSUPP)
		} else {
			XCTFail("Wrong error case")
		}
	}

	func testPathTooLongError() {
		let error = BootstrapSocketError.pathTooLong

		if case .pathTooLong = error {
			// Expected
		} else {
			XCTFail("Wrong error case")
		}
	}
}
