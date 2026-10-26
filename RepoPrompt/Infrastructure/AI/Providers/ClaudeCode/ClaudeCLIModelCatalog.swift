import Foundation
import Logging

/// A Claude model as the Claude CLI lists it.
struct ClaudeCLIModel: Equatable, Sendable {
	/// Model ID the CLI accepts with `--model`, such as `claude-opus-5-5`.
	let id: String
	let displayName: String
	let description: String?
	/// Model family, such as `opus`, `sonnet` or `haiku`.
	let family: String?
	let efforts: [ClaudeCodeEffortLevel]
	let contextWindowTokens: Int?
}

/// The Claude models the Claude CLI offers.
///
/// The CLI downloads Anthropic's model catalog into `~/.claude/cache/model-catalog`. `current`
/// reads its newest copy, so new Claude models show up without an app change. Without a readable
/// copy, and in test processes, it uses `builtIn`.
struct ClaudeCLIModelCatalog: Equatable, Sendable {
	/// Models in the CLI's order: newest first within the main section, then older ones.
	let models: [ClaudeCLIModel]
	/// Alias (`opus`, `sonnet`, `haiku`) to the model ID the alias runs.
	let aliasTargets: [String: String]

	func model(id: String) -> ClaudeCLIModel? {
		let normalized = Self.normalized(id)
		return models.first { $0.id == normalized }
	}

	/// Efforts of a model ID or an alias, with or without the `[1m]` suffix. `nil` when the catalog
	/// does not know the model.
	func efforts(forBaseModelRaw rawModel: String) -> [ClaudeCodeEffortLevel]? {
		var normalized = Self.normalized(rawModel)
		if normalized.hasSuffix(Self.oneMillionContextSuffix) {
			normalized.removeLast(Self.oneMillionContextSuffix.count)
		}
		if let target = aliasTargets[normalized] {
			normalized = target
		}
		return model(id: normalized)?.efforts
	}

	private static let oneMillionContextSuffix = "[1m]"

	private static func normalized(_ value: String) -> String {
		value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}
}

// MARK: - Loading

extension ClaudeCLIModelCatalog {
	static var current: ClaudeCLIModelCatalog {
		cache.value()
	}

	static var cacheDirectory: URL {
		URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
			.appendingPathComponent(".claude", isDirectory: true)
			.appendingPathComponent("cache", isDirectory: true)
			.appendingPathComponent("model-catalog", isDirectory: true)
	}

	/// The catalog of the copy with the newest `fetchedAt` in `directory`, or `nil` when no copy parses.
	static func newest(in directory: URL, fileManager: FileManager = .default) -> ClaudeCLIModelCatalog? {
		guard let urls = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
			return nil
		}
		var newest: ParsedCopy?
		for url in urls where url.lastPathComponent.hasSuffix(catalogFileSuffix) {
			guard let data = try? Data(contentsOf: url), let copy = parse(data) else { continue }
			if newest.map({ copy.fetchedAt > $0.fetchedAt }) ?? true {
				newest = copy
			}
		}
		return newest?.catalog
	}

	struct ParsedCopy {
		let fetchedAt: Double
		let catalog: ClaudeCLIModelCatalog
	}

	/// Parses one cached copy: `{fetchedAt, catalog: {config: {models, provider_alias_targets}}}`.
	static func parse(_ data: Data) -> ParsedCopy? {
		guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
			let catalog = root["catalog"] as? [String: Any],
			let config = catalog["config"] as? [String: Any],
			let rawModels = config["models"] as? [[String: Any]] else {
			return nil
		}
		let models = rawModels.compactMap(parseModel)
		guard !models.isEmpty else { return nil }

		var aliasTargets: [String: String] = [:]
		for (alias, value) in (config["provider_alias_targets"] as? [String: Any]) ?? [:] {
			guard let target = (value as? [String: Any])?["default"] as? String else { continue }
			aliasTargets[normalized(alias)] = normalized(target)
		}
		let fetchedAt = (root["fetchedAt"] as? NSNumber)?.doubleValue ?? 0
		return ParsedCopy(fetchedAt: fetchedAt, catalog: ClaudeCLIModelCatalog(models: models, aliasTargets: aliasTargets))
	}

	private static func parseModel(_ raw: [String: Any]) -> ClaudeCLIModel? {
		guard let id = (raw["id"] as? String).map(normalized), !id.isEmpty else { return nil }
		let runtime = raw["runtime"] as? [String: Any]
		let effortIDs = (runtime?["effort_levels"] as? [String])
			?? ((raw["thinking"] as? [String: Any])?["effort_options"] as? [[String: Any]])?
				.compactMap { $0["id"] as? String }
			?? []
		let name = (raw["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
		let description = (raw["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
		return ClaudeCLIModel(
			id: id,
			displayName: name.flatMap { $0.isEmpty ? nil : $0 } ?? id,
			description: description.flatMap { $0.isEmpty ? nil : $0 },
			family: (runtime?["family"] as? String).map(normalized),
			efforts: effortIDs.compactMap(ClaudeCodeEffortLevel.parse),
			contextWindowTokens: (runtime?["max_input_tokens"] as? NSNumber)?.intValue
		)
	}

	private static let catalogFileSuffix = "-cc.json"
	private static let logger = Logger(label: "com.repoprompt.claudecode.modelcatalog")
	private static let cache = Cache()

	private static func load() -> ClaudeCLIModelCatalog {
		if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
			return builtIn
		}
		guard let catalog = newest(in: cacheDirectory) else {
			logger.info("No readable Claude CLI model catalog in \(cacheDirectory.path); using the built-in list")
			return builtIn
		}
		logger.debug("Loaded \(catalog.models.count) Claude models from the Claude CLI catalog")
		return catalog
	}

	/// Reads the catalog again at most every few minutes, since the CLI refreshes its copy hourly.
	private final class Cache: @unchecked Sendable {
		private static let maxAge: TimeInterval = 300
		private let lock = NSLock()
		private var catalog: ClaudeCLIModelCatalog?
		private var loadedAt = Date.distantPast

		func value() -> ClaudeCLIModelCatalog {
			lock.lock()
			defer { lock.unlock() }
			if let catalog, Date().timeIntervalSince(loadedAt) < Self.maxAge {
				return catalog
			}
			let loaded = ClaudeCLIModelCatalog.load()
			catalog = loaded
			loadedAt = Date()
			return loaded
		}
	}
}

// MARK: - Built-in List

extension ClaudeCLIModelCatalog {
	/// Anthropic's Claude Code catalog of 2026-10-26.
	static let builtIn: ClaudeCLIModelCatalog = {
		let all: [ClaudeCodeEffortLevel] = [.low, .medium, .high, .xhigh, .max]
		let withoutXHigh: [ClaudeCodeEffortLevel] = [.low, .medium, .high, .max]
		func model(_ id: String, _ name: String, _ family: String, _ efforts: [ClaudeCodeEffortLevel], _ context: Int) -> ClaudeCLIModel {
			ClaudeCLIModel(id: id, displayName: name, description: nil, family: family, efforts: efforts, contextWindowTokens: context)
		}
		return ClaudeCLIModelCatalog(
			models: [
				model("claude-opus-5-5", "Opus 5.5", "opus", all, 1_000_000),
				model("claude-fable-5-1", "Fable 5.1", "fable", all, 1_000_000),
				model("claude-sonnet-5-5", "Sonnet 5.5", "sonnet", all, 1_000_000),
				model("claude-haiku-5-5", "Haiku 5.5", "haiku", all, 1_000_000),
				model("claude-haiku-4-5-20251001", "Haiku 4.5", "haiku", [], 200_000),
				model("claude-sonnet-5", "Sonnet 5", "sonnet", all, 1_000_000),
				model("claude-opus-5", "Opus 5", "opus", all, 1_000_000),
				model("claude-fable-5", "Fable 5", "fable", all, 1_000_000),
				model("claude-opus-4-8", "Opus 4.8", "opus", all, 1_000_000),
				model("claude-opus-4-7", "Opus 4.7", "opus", all, 1_000_000),
				model("claude-opus-4-6", "Opus 4.6", "opus", withoutXHigh, 1_000_000),
				model("claude-sonnet-4-6", "Sonnet 4.6", "sonnet", withoutXHigh, 1_000_000),
			],
			aliasTargets: [
				"opus": "claude-opus-5-5",
				"sonnet": "claude-sonnet-5-5",
				"haiku": "claude-haiku-5-5",
				"fable": "claude-fable-5-1",
			]
		)
	}()
}
