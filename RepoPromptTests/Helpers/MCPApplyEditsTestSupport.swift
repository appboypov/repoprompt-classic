import XCTest
import MCP
@testable import RepoPrompt

enum MCPTestValue {
	static func s(_ value: String) -> MCP.Value {
		.string(value)
	}

	static func b(_ value: Bool) -> MCP.Value {
		.bool(value)
	}

	static func i(_ value: Int) -> MCP.Value {
		.int(value)
	}

	static func d(_ value: Double) -> MCP.Value {
		.double(value)
	}

	static func o(_ value: [String: MCP.Value]) -> MCP.Value {
		.object(value)
	}

	static func json(_ raw: String) -> MCP.Value {
		.string(raw)
	}

	static func a(_ value: [MCP.Value]) -> MCP.Value {
		.array(value)
	}
}

func XCTAssertThrowsErrorAsync<T>(
	_ expression: @autoclosure () async throws -> T,
	file: StaticString = #filePath,
	line: UInt = #line,
	_ inspect: (Error) -> Void = { _ in }
) async {
	do {
		_ = try await expression()
		XCTFail("Expected error but got success", file: file, line: line)
	} catch {
		inspect(error)
	}
}

enum CallToolResultJSON {
	static func textBody(_ result: CallTool.Result) -> String? {
		guard let first = result.content.first else { return nil }
		if case .text(let text, _, _) = first {
			return text
		}
		return nil
	}

	static func object(_ result: CallTool.Result) -> [String: Any]? {
		guard let text = textBody(result),
			let data = text.data(using: .utf8) else {
			return nil
		}
		return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
	}

	static func decode<T: Decodable>(_ type: T.Type, from result: CallTool.Result) -> T? {
		guard let text = textBody(result),
			let data = text.data(using: .utf8) else {
			return nil
		}
		return try? JSONDecoder().decode(T.self, from: data)
	}

	static func string(_ key: String, in result: CallTool.Result) -> String? {
		guard let obj = object(result) else { return nil }
		return obj[key] as? String
	}
}
