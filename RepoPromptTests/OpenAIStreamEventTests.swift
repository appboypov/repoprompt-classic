import XCTest
@testable import SwiftOpenAI

final class OpenAIStreamEventTests: XCTestCase {

  // MARK: - Forward Compatibility Tests

  /// Verifies that unknown event types don't throw errors - they decode to .unknown
  /// This ensures the app won't crash when OpenAI adds new event types
  func testUnknownEventTypeDoesNotThrow() throws {
    let json = """
      {
        "type": "response.some_future_event",
        "data": "some data"
      }
      """

    let decoder = JSONDecoder()
    let event = try decoder.decode(ResponseStreamEvent.self, from: json.data(using: .utf8)!)

    // Should decode as .unknown with the type captured for forward compatibility
    if case .unknown(let type) = event {
      XCTAssertEqual(type, "response.some_future_event")
    } else {
      XCTFail("Expected unknown event case, got \(event)")
    }
  }

  /// Verifies keepalive events (server heartbeats) decode correctly
  /// OpenAI sends these to keep connections alive during long operations
  func testKeepaliveEvent() throws {
    let json = """
      {
        "type": "keepalive"
      }
      """

    let decoder = JSONDecoder()
    let event = try decoder.decode(ResponseStreamEvent.self, from: json.data(using: .utf8)!)

    if case .keepalive = event {
      // Success - keepalive events are server heartbeats with no payload
    } else {
      XCTFail("Expected keepalive event, got \(event)")
    }
  }

  /// Verifies that multiple unknown event types in a stream don't cause issues
  func testMultipleUnknownEventsInSequence() throws {
    let events = [
      #"{"type": "response.created", "sequence_number": 1, "response": {"id": "resp_123", "object": "model_response", "created_at": 1704067200, "model": "gpt-4o", "usage": {"prompt_tokens": 10, "completion_tokens": 0, "total_tokens": 10}, "output": [], "status": "in_progress", "metadata": {}, "parallel_tool_calls": true, "text": {"format": {"type": "text"}}, "tool_choice": "none", "tools": []}}"#,
      #"{"type": "keepalive"}"#,
      #"{"type": "response.new_feature.started", "item_id": "x"}"#,
      #"{"type": "response.output_text.delta", "item_id": "item_123", "output_index": 0, "content_index": 0, "delta": "Hello", "sequence_number": 2}"#,
      #"{"type": "keepalive"}"#,
      #"{"type": "response.new_feature.completed", "item_id": "x"}"#,
    ]

    let decoder = JSONDecoder()
    var decodedEvents: [ResponseStreamEvent] = []

    for json in events {
      let event = try decoder.decode(ResponseStreamEvent.self, from: json.data(using: .utf8)!)
      decodedEvents.append(event)
    }

    XCTAssertEqual(decodedEvents.count, 6)

    // Verify known events decoded correctly
    if case .responseCreated = decodedEvents[0] {} else {
      XCTFail("Expected responseCreated")
    }

    if case .keepalive = decodedEvents[1] {} else {
      XCTFail("Expected keepalive")
    }

    if case .unknown(let type) = decodedEvents[2] {
      XCTAssertEqual(type, "response.new_feature.started")
    } else {
      XCTFail("Expected unknown")
    }

    if case .outputTextDelta(let delta) = decodedEvents[3] {
      XCTAssertEqual(delta.delta, "Hello")
    } else {
      XCTFail("Expected outputTextDelta")
    }

    if case .keepalive = decodedEvents[4] {} else {
      XCTFail("Expected keepalive")
    }

    if case .unknown(let type) = decodedEvents[5] {
      XCTAssertEqual(type, "response.new_feature.completed")
    } else {
      XCTFail("Expected unknown")
    }
  }
}
