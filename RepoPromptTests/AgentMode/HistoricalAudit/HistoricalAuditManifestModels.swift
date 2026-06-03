import Foundation

struct HistoricalAuditManifest: Decodable {
	let version: Int
	let createdAt: String?
	let description: String?
	let globalPolicies: HistoricalAuditGlobalPolicies
	let cases: [HistoricalAuditCase]
	let deferredSamples: [HistoricalAuditDeferredSample]?
}

struct HistoricalAuditCase: Decodable, Identifiable {
	var id: String { caseID }

	let caseID: String
	let agentKind: String
	let provider: String?
	let fixturePath: String
	let issues: [String]
	let expectedMetricsCurrent: [String: Int]?
	let expectedMetricsAfterFix: [String: Int]?
	let sourceOriginalMetrics: [String: Int]?
	let source: HistoricalAuditSource?
	let minimization: HistoricalAuditMinimization?
}

struct HistoricalAuditGlobalPolicies: Decodable {
	let maxPersistedToolSummaryBytes: Int
	let rawToolPayloadsCommitted: Bool
	let redaction: String
	let timestamps: String
	let uuidRemapping: String

	private enum CodingKeys: String, CodingKey {
		case maxPersistedToolSummaryBytes
		case maxCommittedToolPayloadChars
		case rawToolPayloadsCommitted
		case rawPayloadsCommitted
		case redaction
		case timestamps
		case uuidRemapping
	}

	init(from decoder: Decoder) throws {
		let container = try decoder.container(keyedBy: CodingKeys.self)
		maxPersistedToolSummaryBytes = try container.decodeIfPresent(Int.self, forKey: .maxPersistedToolSummaryBytes)
			?? container.decode(Int.self, forKey: .maxCommittedToolPayloadChars)
		rawToolPayloadsCommitted = try container.decodeIfPresent(Bool.self, forKey: .rawToolPayloadsCommitted)
			?? container.decode(Bool.self, forKey: .rawPayloadsCommitted)
		redaction = try container.decode(String.self, forKey: .redaction)
		timestamps = try container.decode(String.self, forKey: .timestamps)
		uuidRemapping = try container.decode(String.self, forKey: .uuidRemapping)
	}
}

struct HistoricalAuditSource: Decodable {
	let sourceByteCount: Int?
	let sourceFileName: String?
	let sourceFileSHA256: String?
	let sourceLabel: String?
	let sourceProviderSessionIDHash: String?
	let sourceSessionID: String?
	let sourceWorkspaceIDHash: String?
}

struct HistoricalAuditMinimization: Decodable {
	let fixtureByteCount: Int?
	let payloadPolicy: String?
	let preservedExactTexts: [String]?
	let preservedSequenceIndexes: [Int]?
	let strategy: String?
}

struct HistoricalAuditDeferredSample: Decodable {
	let caseID: String
	let reason: String
	let sourceLabel: String?
}
