import Foundation

struct ToolResultPayloadSource: Equatable {
	let itemID: UUID
	let storedPayload: String?
	let rawPayload: String?

	init(itemID: UUID, storedPayload: String?, rawPayload: String?) {
		self.itemID = itemID
		self.storedPayload = Self.normalizedPayload(storedPayload)
		self.rawPayload = Self.normalizedPayload(rawPayload)
	}

	var preferredPayload: String? {
		rawPayload ?? storedPayload
	}

	var hasRawPayload: Bool {
		rawPayload != nil
	}

	func decode<T: Decodable>(_ type: T.Type) -> T? {
		if let raw = rawPayload,
			let decoded = ToolJSON.decodeResult(type, from: raw) {
			return decoded
		}
		return ToolJSON.decodeResult(type, from: storedPayload)
	}

	private static func normalizedPayload(_ payload: String?) -> String? {
		guard let trimmed = payload?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
			return nil
		}
		return trimmed
	}
}

enum ToolJSON {
	private static let strictEnvelopeKeys = [
		"Ok",
		"ok",
		"Err",
		"err",
		"structuredContent",
		"structured_content",
		"structuredResult",
		"structured_result",
		"toolResult",
		"tool_result"
	]

	private static let singleKeyEnvelopeKeys = [
		"result",
		"output",
		"response",
		"payload",
		"data",
		"value"
	]

	private static let contentEnvelopeKeys = [
		"json",
		"structuredContent",
		"structured_content",
		"text"
	]

	static func data(from json: String?) -> Data? {
		guard let raw = json?.trimmingCharacters(in: .whitespacesAndNewlines),
			!raw.isEmpty
		else { return nil }
		return raw.data(using: .utf8)
	}
	
	/// Decode args DTOs (uses convertFromSnakeCase for DTOs without explicit CodingKeys)
	static func decodeArgs<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
		guard let data = data(from: json) else { return nil }
		let decoder = JSONDecoder()
		decoder.keyDecodingStrategy = .convertFromSnakeCase
		return try? decoder.decode(type, from: data)
	}
	
	/// Decode result DTOs (no key conversion - result DTOs have explicit CodingKeys)
	static func decodeResult<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
		guard let directData = data(from: json) else { return nil }
		let decoder = JSONDecoder()
		if let nestedJSON = preferredStructuredResultJSON(from: json, requireEnvelope: true),
			let nestedData = data(from: nestedJSON),
			let nested = try? decoder.decode(type, from: nestedData) {
			return nested
		}
		return try? decoder.decode(type, from: directData)
	}

	static func resultPayloadSource(for item: AgentChatItem, rawPayload: String?) -> ToolResultPayloadSource {
		ToolResultPayloadSource(
			itemID: item.id,
			storedPayload: item.toolResultJSON,
			rawPayload: rawPayload
		)
	}

	static func decodeResult<T: Decodable>(_ type: T.Type, from source: ToolResultPayloadSource) -> T? {
		source.decode(type)
	}

	static func payloadHasContent(_ payload: String?) -> Bool {
		data(from: payload) != nil
	}

	static func payloadIsSummaryOnly(_ payload: String?) -> Bool {
		guard let object = structuredResultObject(from: payload) else { return false }
		return boolValue(in: object, key: "summary_only") == true
			|| boolValue(in: object, key: "summaryOnly") == true
	}
	
	/// Legacy decode - prefer decodeArgs or decodeResult
	static func decode<T: Decodable>(_ type: T.Type, from json: String?) -> T? {
		return decodeResult(type, from: json)
	}

	static func preferredStructuredResultJSON(from json: String?, requireEnvelope: Bool = false) -> String? {
		guard let data = data(from: json),
			let root = try? JSONSerialization.jsonObject(with: data)
		else {
			return requireEnvelope ? nil : json?.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		guard let preferred = preferredStructuredValue(in: root) else {
			return requireEnvelope ? nil : json?.trimmingCharacters(in: .whitespacesAndNewlines)
		}
		return canonicalJSONString(from: preferred)
	}
	
	static func structuredResultObject(from json: String?) -> [String: Any]? {
		if let preferred = preferredStructuredResultJSON(from: json),
			let data = preferred.data(using: .utf8),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
			return object
		}
		guard let data = data(from: json),
			let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
		else {
			return nil
		}
		return object
	}

	static func prettyPrinted(_ json: String) -> String {
		guard let data = data(from: json),
			let obj = try? JSONSerialization.jsonObject(with: data),
			let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
			let prettyString = String(data: pretty, encoding: .utf8)
		else {
			return json
		}
		return prettyString
	}
	
	static func looksLikeJSON(_ s: String?) -> Bool {
		guard let raw = s?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
			return false
		}
		if (raw.hasPrefix("{") && raw.hasSuffix("}")) || (raw.hasPrefix("[") && raw.hasSuffix("]")) {
			return true
		}
		return false
	}
	
	static func displayArgsJSON(from argsJSON: String?) -> String? {
		guard let data = data(from: argsJSON),
			let obj = try? JSONSerialization.jsonObject(with: data)
		else { return nil }
		
		if var dict = obj as? [String: Any] {
			dict.removeValue(forKey: "_windowID")
			dict.removeValue(forKey: "_rawJSON")
			dict.removeValue(forKey: "_tabID")
			guard !dict.isEmpty else { return nil }
			guard let pretty = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
				let prettyString = String(data: pretty, encoding: .utf8)
			else { return argsJSON }
			return prettyString
		}
		
		return prettyPrinted(String(data: data, encoding: .utf8) ?? "")
	}

	private static func boolValue(in object: [String: Any], key: String) -> Bool? {
		guard let value = object[key] else { return nil }
		if let bool = value as? Bool { return bool }
		if let number = value as? NSNumber { return number.boolValue }
		if let string = value as? String {
			switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
			case "true", "1", "yes": return true
			case "false", "0", "no": return false
			default: return nil
			}
		}
		return nil
	}

	private static func preferredStructuredValue(in value: Any, depth: Int = 0) -> Any? {
		guard depth < 4 else { return nil }

		if let object = value as? [String: Any] {
			for key in strictEnvelopeKeys {
				if let nested = object[key] {
					if let preferred = preferredStructuredValue(in: nested, depth: depth + 1) {
						return preferred
					}
					return nested
				}
			}

			if object.count == 1,
				let singleKey = object.keys.first,
				singleKeyEnvelopeKeys.contains(singleKey),
				let nested = object[singleKey] {
				if let preferred = preferredStructuredValue(in: nested, depth: depth + 1) {
					return preferred
				}
				return nested
			}

			if let content = object["content"] as? [Any] {
				for element in content {
					if let preferred = preferredStructuredValue(in: element, depth: depth + 1) {
						return preferred
					}
					guard let contentObject = element as? [String: Any] else { continue }
					for key in contentEnvelopeKeys {
						guard let nested = contentObject[key] else { continue }
						if let preferred = preferredStructuredValue(in: nested, depth: depth + 1) {
							return preferred
						}
						return nested
					}
				}
			}
		} else if let array = value as? [Any] {
			for element in array {
				if let preferred = preferredStructuredValue(in: element, depth: depth + 1) {
					return preferred
				}
			}
		}

		return nil
	}

	private static func canonicalJSONString(from value: Any) -> String? {
		if let string = value as? String {
			let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
			return trimmed.isEmpty ? nil : trimmed
		}
		guard JSONSerialization.isValidJSONObject(value),
			let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
		else {
			return nil
		}
		return String(data: data, encoding: .utf8)
	}
}
