import Foundation

// MARK: - Core Benchmark Enumerations

enum BenchmarkCaseType: String, CaseIterable, Codable, Sendable {
	// TypeScript tasks
	case removeXTs            = "remove_x_ts"
	case curlyFixTs           = "curly_fix_ts"
	case insertGuardTs        = "insert_guard_ts"
	case patchBlockTs         = "patch_block_ts"
	case swapArgsInRegionTs   = "swap_args_in_region_ts"
	case indexOnlyAppsTs      = "index_only_apps_ts"
	case renameExportImportsTs = "rename_export_and_imports_ts"
	case moveFunctionTs           = "move_function_ts"
	case insertFunctionBottomTs   = "insert_function_bottom_ts"
	case applyUnifiedPatchTs      = "apply_unified_patch_ts"

	// Go tasks
	case removeXGo            = "remove_x_go"
	case curlyFixGo           = "curly_fix_go"
	case insertGuardGo        = "insert_guard_go"
	case patchBlockGo         = "patch_block_go"
	case swapArgsInRegionGo   = "swap_args_in_region_go"
	case indexOnlyAppsGo      = "index_only_apps_go"
	case renameExportImportsGo = "rename_export_and_imports_go"
	case moveFunctionGo           = "move_function_go"
	case insertFunctionBottomGo   = "insert_function_bottom_go"
	case applyUnifiedPatchGo      = "apply_unified_patch_go"

	// Swift tasks
	case removeXSwift            = "remove_x_swift"
	case curlyFixSwift           = "curly_fix_swift"
	case insertGuardSwift        = "insert_guard_swift"
	case patchBlockSwift         = "patch_block_swift"
	case swapArgsInRegionSwift   = "swap_args_in_region_swift"
	case indexOnlyAppsSwift      = "index_only_apps_swift"
	case renameExportImportsSwift = "rename_export_and_imports_swift"
	case moveFunctionSwift           = "move_function_swift"
	case insertFunctionBottomSwift   = "insert_function_bottom_swift"
	case applyUnifiedPatchSwift      = "apply_unified_patch_swift"
}

enum BenchmarkLanguage: String, CaseIterable, Codable, Sendable {
	case ts
	case go
	case swift

	/// Returns the preferred indentation style for this language
	var usesTabIndentation: Bool {
		switch self {
		case .ts, .go:
			return false  // Use spaces
		case .swift:
			return true   // Use tabs
		}
	}

	/// Returns the indentation string for this language
	var indentString: String {
		usesTabIndentation ? "\t" : "    "
	}
}

enum BenchmarkSizePreset: String, CaseIterable, Codable, Sendable {
	case small  = "S"
	case medium = "M"
	case large  = "L"
}

// MARK: - Difficulty

enum BenchmarkDifficulty: String, CaseIterable, Codable, Sendable {
	/// Retained for decoding backward compatibility; no longer scheduled.
	case simple
	/// Acts as the lowest scheduled tier after removing `.simple` from the plan.
	case medium
	case hard
	case veryHard
}

// MARK: - Flexible JSON Payload Support

enum BenchmarkJSONValue: Codable, Sendable, Equatable {
	case string(String)
	case integer(Int)
	case double(Double)
	case boolean(Bool)
	case array([BenchmarkJSONValue])
	case object([String: BenchmarkJSONValue])
	case null
	
	init(from decoder: Decoder) throws {
		let container = try decoder.singleValueContainer()
		if container.decodeNil() {
			self = .null
			return
		}
		if let value = try? container.decode(Bool.self) {
			self = .boolean(value)
			return
		}
		if let value = try? container.decode(Int.self) {
			self = .integer(value)
			return
		}
		if let value = try? container.decode(Double.self) {
			self = .double(value)
			return
		}
		if let value = try? container.decode(String.self) {
			self = .string(value)
			return
		}
		if let value = try? container.decode([BenchmarkJSONValue].self) {
			self = .array(value)
			return
		}
		if let value = try? container.decode([String: BenchmarkJSONValue].self) {
			self = .object(value)
			return
		}
		throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
	}
	
	func encode(to encoder: Encoder) throws {
		var container = encoder.singleValueContainer()
		switch self {
		case .string(let value):
			try container.encode(value)
		case .integer(let value):
			try container.encode(value)
		case .double(let value):
			try container.encode(value)
		case .boolean(let value):
			try container.encode(value)
		case .array(let value):
			try container.encode(value)
		case .object(let value):
			try container.encode(value)
		case .null:
			try container.encodeNil()
		}
	}
	
	var stringValue: String? {
		if case .string(let value) = self { return value }
		return nil
	}
	
	var intValue: Int? {
		switch self {
		case .integer(let value): return value
		case .double(let value): return Int(value)
		case .string(let value): return Int(value)
		default: return nil
		}
	}
	
	var doubleValue: Double? {
		switch self {
		case .double(let value): return value
		case .integer(let value): return Double(value)
		case .string(let value): return Double(value)
		default: return nil
		}
	}
	
	var boolValue: Bool? {
		switch self {
		case .boolean(let value): return value
		case .integer(let value): return value != 0
		case .double(let value): return value != 0
		case .string(let value):
			let lowered = value.lowercased()
			if lowered == "true" { return true }
			if lowered == "false" { return false }
			return nil
		default:
			return nil
		}
	}
	
	var objectValue: [String: BenchmarkJSONValue]? {
		if case .object(let value) = self { return value }
		return nil
	}
	
	var arrayValue: [BenchmarkJSONValue]? {
		if case .array(let value) = self { return value }
		return nil
	}
}

// MARK: - Task Specification

struct BenchmarkTaskSpec: Codable, Sendable {
	let id: String
	let type: BenchmarkCaseType
	let language: BenchmarkLanguage
	let difficulty: BenchmarkDifficulty
	let format: String
	let selectFiles: [String]
	let newChat: Bool
	let maxEdits: Int
	let instructions: [String]
	let task: String
	let acceptance: [String]
	let params: [String: BenchmarkJSONValue]
	
	init(
		id: String,
		type: BenchmarkCaseType,
		language: BenchmarkLanguage,
		difficulty: BenchmarkDifficulty = .medium,
		format: String = "search_replace",
		selectFiles: [String],
		newChat: Bool = true,
		maxEdits: Int,
		instructions: [String],
		task: String,
		acceptance: [String],
		params: [String: BenchmarkJSONValue]
	) {
		self.id = id
		self.type = type
		self.language = language
		self.difficulty = difficulty
		self.format = format
		self.selectFiles = selectFiles
		self.newChat = newChat
		self.maxEdits = maxEdits
		self.instructions = instructions
		self.task = task
		self.acceptance = acceptance
		self.params = params
	}
}

// MARK: - Execution Result Types

struct BenchmarkTaskError: Codable, Sendable, Equatable {
	let code: String
	let path: String?
	let detail: String?
	
	init(code: String, path: String? = nil, detail: String? = nil) {
		self.code = code
		self.path = path
		self.detail = detail
	}
}

struct BenchmarkEditedFile: Codable, Sendable, Equatable {
	let path: String
	let content: String
}

struct BenchmarkTaskExecResult: Codable, Sendable {
	let errors: [BenchmarkTaskError]
	let edited: [BenchmarkEditedFile]
	let meta: [String: BenchmarkJSONValue]?
	
	init(errors: [BenchmarkTaskError] = [], edited: [BenchmarkEditedFile] = [], meta: [String: BenchmarkJSONValue]? = nil) {
		self.errors = errors
		self.edited = edited
		self.meta = meta
	}
}

// MARK: - Benchmark Configuration

enum GuidanceVerbosity: String, Codable, Sendable {
	case none
	case minimal
	case standard
}

struct DecoyPolicy: Codable, Sendable {
	enum Style: String, Codable, Sendable {
		case off        // produce no decoys
		case relevant   // produce a small number of focused decoys
		case gauntlet   // produce many strong, confusing decoys
	}

	enum Placement: String, Codable, Sendable {
		case siblingDir // same subtree, sibling directories
		case crossRoot  // different top-level subtree
		case mixed      // mixture of sibling and cross-root
	}

	var style: Style
	var placement: Placement
	var maxDecoysPerTask: Int
	var preferExactClonesFirst: Bool
	var enableIntraFileShadows: Bool
	var maxIntraFileShadows: Int

	init(
		style: Style = .relevant,
		placement: Placement = .mixed,
		maxDecoysPerTask: Int = 3,
		preferExactClonesFirst: Bool = true,
		enableIntraFileShadows: Bool = true,
		maxIntraFileShadows: Int = 1
	) {
		self.style = style
		self.placement = placement
		self.maxDecoysPerTask = max(0, maxDecoysPerTask)
		self.preferExactClonesFirst = preferExactClonesFirst
		self.enableIntraFileShadows = enableIntraFileShadows
		self.maxIntraFileShadows = max(0, maxIntraFileShadows)
	}
}

struct BenchConfig: Codable, Sendable {
	let languages: [BenchmarkLanguage]
	let size: BenchmarkSizePreset
	let sizeLines: Int?
	let noise: Double
	let enabledTypes: [BenchmarkCaseType]
	let params: [String: BenchmarkJSONValue]
	let tasksAreCumulative: Bool
	let mediumCount: Int
	let hardCount: Int
	let veryHardCount: Int
	let contextCharBudget: Int
	let decoyCharCap: Int
	let decoysMedium: Int
	let decoysHard: Int
	let decoysVeryHard: Int
	// New fields for decoy planning and prompt guidance
	let decoyPolicy: DecoyPolicy
	let guidanceVerbosity: GuidanceVerbosity
	let includeAutoPlannedDecoys: Bool
	
	init(
		languages: [BenchmarkLanguage] = [.ts, .go],
		size: BenchmarkSizePreset = .medium,
		sizeLines: Int? = nil,
		noise: Double = 0.0,
		enabledTypes: [BenchmarkCaseType] = BenchmarkCaseType.allCases,
		params: [String: BenchmarkJSONValue] = [:],
		tasksAreCumulative: Bool = false,
		mediumCount: Int = 2,
		hardCount: Int = 3,
		veryHardCount: Int = 1,
		contextCharBudget: Int = 200_000,
		decoyCharCap: Int = 40_000,
		decoysMedium: Int = 2,
		decoysHard: Int = 3,
		decoysVeryHard: Int = 6,
		// New parameters with defaults
		decoyPolicy: DecoyPolicy = DecoyPolicy(
			style: .relevant,
			placement: .mixed,
			maxDecoysPerTask: 3,
			preferExactClonesFirst: true,
			enableIntraFileShadows: true,
			maxIntraFileShadows: 1
		),
		guidanceVerbosity: GuidanceVerbosity = .minimal,
		includeAutoPlannedDecoys: Bool = true
	) {
		self.languages = languages
		self.size = size
		self.sizeLines = sizeLines
		self.noise = noise
		self.enabledTypes = enabledTypes
		self.params = params
		self.tasksAreCumulative = tasksAreCumulative
		self.mediumCount = max(0, mediumCount)
		self.hardCount = max(0, hardCount)
		self.veryHardCount = max(0, veryHardCount)
		self.contextCharBudget = max(10_000, contextCharBudget)
		self.decoyCharCap = max(2_000, decoyCharCap)
		self.decoysMedium = max(0, decoysMedium)
		self.decoysHard = max(0, decoysHard)
		self.decoysVeryHard = max(0, decoysVeryHard)
		self.decoyPolicy = decoyPolicy
		self.guidanceVerbosity = guidanceVerbosity
		self.includeAutoPlannedDecoys = includeAutoPlannedDecoys
	}
}

struct RunConfig: Codable, Sendable {
	let coreSeed: UInt32
	let subSeedCount: Int
	
	init(coreSeed: UInt32, subSeedCount: Int = 5) {
		self.coreSeed = coreSeed
		self.subSeedCount = subSeedCount
	}
}

// MARK: - Verification Contracts

struct BenchmarkVerifyInput: Sendable {
	let taskSpec: BenchmarkTaskSpec
	let baseline: BenchmarkMockFileSystemSnapshot
	let edited: [BenchmarkEditedFile]
	let errors: [BenchmarkTaskError]
}

struct BenchmarkVerifyOutput: Sendable {
	let pass: Bool
	let score: Double
	let reason: String
	let metrics: [String: BenchmarkJSONValue]
	
	static func failure(reason: String, metrics: [String: BenchmarkJSONValue] = [:]) -> BenchmarkVerifyOutput {
		BenchmarkVerifyOutput(pass: false, score: 0.0, reason: reason, metrics: metrics)
	}
	
	static func success(score: Double = 1.0, metrics: [String: BenchmarkJSONValue] = [:]) -> BenchmarkVerifyOutput {
		BenchmarkVerifyOutput(pass: true, score: score, reason: "", metrics: metrics)
	}
}

// MARK: - Reporting

struct BenchmarkTaskReport: Sendable {
	let id: String
	let type: BenchmarkCaseType
	let pass: Bool
	let score: Double
	let reason: String
	let metrics: [String: BenchmarkJSONValue]
	let errors: [BenchmarkTaskError]

	// New point-based scoring fields
	let difficulty: BenchmarkDifficulty
	let normalizedScore: Double
	let maxPoints: Double
	let awardedPoints: Double

	init(
		id: String,
		type: BenchmarkCaseType,
		pass: Bool,
		score: Double,
		reason: String,
		metrics: [String: BenchmarkJSONValue],
		errors: [BenchmarkTaskError],
		difficulty: BenchmarkDifficulty = .medium,
		normalizedScore: Double = 0.0,
		maxPoints: Double = 1.0,
		awardedPoints: Double = 0.0
	) {
		self.id = id
		self.type = type
		self.pass = pass
		self.score = score
		self.reason = reason
		self.metrics = metrics
		self.errors = errors
		self.difficulty = difficulty
		self.normalizedScore = normalizedScore
		self.maxPoints = maxPoints
		self.awardedPoints = awardedPoints
	}
}

struct BenchmarkSeedReport: Sendable {
	let seed: UInt32
	let tasks: [BenchmarkTaskReport]
	let passRate: Double
	let averageScore: Double

	// New point aggregates
	let pointsEarned: Double
	let maxPoints: Double
	let pointsRate: Double

	init(
		seed: UInt32,
		tasks: [BenchmarkTaskReport],
		passRate: Double,
		averageScore: Double,
		pointsEarned: Double = 0.0,
		maxPoints: Double = 0.0,
		pointsRate: Double = 0.0
	) {
		self.seed = seed
		self.tasks = tasks
		self.passRate = passRate
		self.averageScore = averageScore
		self.pointsEarned = pointsEarned
		self.maxPoints = maxPoints
		self.pointsRate = pointsRate
	}
}

struct BenchmarkFinalReport: Sendable {
	let coreSeed: UInt32
	let subSeeds: [UInt32]
	let totalTasks: Int
	let passRate: Double
	let averageScore: Double
	let perType: [BenchmarkCaseType: BenchmarkTypeStats]
	let perSeed: [BenchmarkSeedReport]

	// New overall point totals
	let totalMaxPoints: Double
	let totalPointsEarned: Double
	let pointsRate: Double

	init(
		coreSeed: UInt32,
		subSeeds: [UInt32],
		totalTasks: Int,
		passRate: Double,
		averageScore: Double,
		perType: [BenchmarkCaseType: BenchmarkTypeStats],
		perSeed: [BenchmarkSeedReport],
		totalMaxPoints: Double = 0.0,
		totalPointsEarned: Double = 0.0,
		pointsRate: Double = 0.0
	) {
		self.coreSeed = coreSeed
		self.subSeeds = subSeeds
		self.totalTasks = totalTasks
		self.passRate = passRate
		self.averageScore = averageScore
		self.perType = perType
		self.perSeed = perSeed
		self.totalMaxPoints = totalMaxPoints
		self.totalPointsEarned = totalPointsEarned
		self.pointsRate = pointsRate
	}
}

struct BenchmarkTypeStats: Sendable {
	let count: Int
	let passRate: Double
	let averageScore: Double

	// New point aggregates
	let pointsEarned: Double
	let maxPoints: Double
	let pointsRate: Double

	init(
		count: Int,
		passRate: Double,
		averageScore: Double,
		pointsEarned: Double = 0.0,
		maxPoints: Double = 0.0,
		pointsRate: Double = 0.0
	) {
		self.count = count
		self.passRate = passRate
		self.averageScore = averageScore
		self.pointsEarned = pointsEarned
		self.maxPoints = maxPoints
		self.pointsRate = pointsRate
	}
}

extension BenchConfig {
	func difficultyPlan() -> [BenchmarkDifficulty] {
		// Ordered plan: medium → hard → veryHard; `.simple` is no longer scheduled.
		var plan: [BenchmarkDifficulty] = []
		if mediumCount > 0 {
			plan += Array(repeating: .medium, count: mediumCount)
		}
		if hardCount > 0 {
			plan += Array(repeating: .hard, count: hardCount)
		}
		if veryHardCount > 0 {
			plan += Array(repeating: .veryHard, count: veryHardCount)
		}
		return plan
	}
}

extension BenchmarkLanguage {
	var displayName: String {
		switch self {
		case .ts: return "TypeScript"
		case .go: return "Go"
		case .swift: return "Swift"
		}
	}
	
	var codeFenceIdentifier: String {
		switch self {
		case .ts: return "ts"
		case .go: return "go"
		case .swift: return "swift"
		}
	}
}

extension BenchmarkDifficulty {
	/// Maximum point value awarded for a task at this difficulty
	var maxPoints: Double {
		switch self {
		case .simple:
			return 1.0
		case .medium:
			return 1.0
		case .hard:
			return 3.0
		case .veryHard:
			return 6.0
		}
	}
}

struct BenchmarkPointScales {
	@inline(__always)
	private static func clamp(_ v: Double, _ lo: Double = 0.0, _ hi: Double = 1.0) -> Double {
		return min(max(v, lo), hi)
	}
	
	/// Maps a normalized score [0,1] and pass/fail into difficulty-weighted points.
	/// - medium/simple: binary – pass => 1.0, fail => 0.0
	/// - hard: scaled to 0...3, quantized to 0.5
	/// - veryHard: scaled to 0...6, quantized to 0.5
	static func points(for difficulty: BenchmarkDifficulty, normalizedScore: Double, pass: Bool) -> Double {
		switch difficulty {
		case .simple, .medium:
			return pass ? 1.0 : 0.0
		case .hard:
			let p = clamp(normalizedScore) * 3.0
			return (p * 2.0).rounded(.toNearestOrEven) / 2.0
		case .veryHard:
			let p = clamp(normalizedScore) * 6.0
			return (p * 2.0).rounded(.toNearestOrEven) / 2.0
		}
	}
}
