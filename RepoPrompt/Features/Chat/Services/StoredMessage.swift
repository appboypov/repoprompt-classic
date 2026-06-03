import Foundation

/// Fallback shape that some older JSON files used:
/// `[ { "id": "<UUID>", "text": "<assistant-output>" }, … ]`
private struct LegacyDelegateResult: Codable {
	let id  : UUID
	let text: String
}

/// Minimal storage for one message's raw text, plus metadata.
struct StoredMessage: Codable {
	let id: UUID
	let isUser: Bool
	
	/// The user-facing text that ChatContentParser uses for parsing.
	let rawText: String
	
	/// OLD: The final combined text (unused for new data).
	let combinedRawText: String
	
	/// Token usage information
	let promptTokens: Int?
	let completionTokens: Int?
	let cost: Double?
	
	/// NEW: AI model name used for this assistant response (nil for user messages).
	let modelName: String?
	
	let timestamp: Date
	let sequenceIndex: Int
	
	/// NEW: For storing delegate edits separately. For older JSON, this may be missing or null.
	let delegateResults: [UUID: String]?
	
	/// NEW: The user's selected file paths at the time this message was created
	/// (may be nil for older data).
	let allowedFilePaths: [String]?
	
	enum CodingKeys: String, CodingKey {
		case id, isUser, rawText, combinedRawText, timestamp
		case sequenceIndex, delegateResults, allowedFilePaths
		case promptTokens, completionTokens, cost
		case modelName
	}
	
	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)

		self.id        = try container.decode(UUID.self   , forKey: .id)
		self.isUser    = try container.decode(Bool.self   , forKey: .isUser)
		self.rawText   = try container.decode(String.self , forKey: .rawText)
		self.timestamp = try container.decode(Date.self  , forKey: .timestamp)
		self.sequenceIndex =
			try container.decodeIfPresent(Int.self, forKey: .sequenceIndex) ?? 0
		self.allowedFilePaths =
			try container.decodeIfPresent([String].self, forKey: .allowedFilePaths)

		// -------- delegateResults (new ⇢ dictionary | old ⇢ array) --------
		if let dict = try? container.decode([UUID:String].self,
											forKey: .delegateResults) {
			self.delegateResults = dict
		} else if let arr = try? container.decode([LegacyDelegateResult].self,
												forKey: .delegateResults) {
			// migrate: array → dictionary
			self.delegateResults = Dictionary(uniqueKeysWithValues:
				arr.map { ($0.id, $0.text) })
		} else {
			self.delegateResults = [:]                       // none / corrupt
		}

		self.promptTokens     = try container.decodeIfPresent(Int.self   , forKey: .promptTokens)
		self.completionTokens = try container.decodeIfPresent(Int.self   , forKey: .completionTokens)
		self.cost             = try container.decodeIfPresent(Double.self, forKey: .cost)
		self.modelName        = try container.decodeIfPresent(String.self , forKey: .modelName)

		// Always rebuild `combinedRawText` from `rawText` + any delegate edits
		let editsJoined = delegateResults?.values.joined(separator: "\n") ?? ""
		self.combinedRawText = editsJoined.isEmpty
			? rawText
			: [rawText, editsJoined].joined(separator: "\n\n")
	}
	
	func encode(to encoder: Encoder) throws {
		var container = encoder.container(keyedBy: CodingKeys.self)
		try container.encode(id, forKey: .id)
		try container.encode(isUser, forKey: .isUser)
		try container.encode(rawText, forKey: .rawText)
		try container.encode(timestamp, forKey: .timestamp)
		try container.encode(sequenceIndex, forKey: .sequenceIndex)
		try container.encode(delegateResults, forKey: .delegateResults)
		try container.encode(allowedFilePaths, forKey: .allowedFilePaths)
		try container.encode(promptTokens, forKey: .promptTokens)
		try container.encode(completionTokens, forKey: .completionTokens)
		try container.encode(cost, forKey: .cost)
		try container.encode(modelName, forKey: .modelName)
		// We intentionally skip combinedRawText since it's derived.
	}
	
	init(
		id: UUID = UUID(),
		isUser: Bool,
		rawText: String,
		combinedRawText: String? = nil,
		timestamp: Date = Date(),
		delegateResults: [UUID: String]? = [:],
		sequenceIndex: Int = 0,
		allowedFilePaths: [String]? = nil,
		promptTokens: Int? = nil,
		completionTokens: Int? = nil,
		cost: Double? = nil,
		modelName: String? = nil
	) {
		self.id = id
		self.isUser = isUser
		self.rawText = rawText
		self.timestamp = timestamp
		self.delegateResults = delegateResults
		self.sequenceIndex = sequenceIndex
		self.allowedFilePaths = allowedFilePaths
		self.promptTokens = promptTokens
		self.completionTokens = completionTokens
		self.cost = cost
		self.modelName = modelName
		
		// Rebuild combinedRawText if not provided
		let delegateEdits = delegateResults?.values.joined(separator: "\n") ?? ""
		if let customCombined = combinedRawText, !customCombined.isEmpty {
			self.combinedRawText = customCombined
		} else if delegateEdits.isEmpty {
			self.combinedRawText = self.rawText
		} else {
			self.combinedRawText = [self.rawText, delegateEdits].joined(separator: "\n\n")
		}
	}
}