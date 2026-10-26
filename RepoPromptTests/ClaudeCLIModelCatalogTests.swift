import XCTest
@testable import RepoPrompt

final class ClaudeCLIModelCatalogTests: XCTestCase {
	private var directory: URL!

	override func setUpWithError() throws {
		directory = FileManager.default.temporaryDirectory
			.appendingPathComponent("ClaudeCLIModelCatalogTests-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		try? FileManager.default.removeItem(at: directory)
	}

	func testParsesModelsEffortsAndAliasTargets() throws {
		let copy = try XCTUnwrap(ClaudeCLIModelCatalog.parse(catalogJSON(fetchedAt: 10, models: [
			model(id: "claude-opus-9", name: "Opus 9", family: "opus", efforts: ["low", "xhigh", "max"], context: 1_000_000),
			model(id: "claude-haiku-9", name: "Haiku 9", family: "haiku", efforts: nil, context: 200_000),
		], aliases: ["opus": "claude-opus-9"])))

		XCTAssertEqual(copy.fetchedAt, 10)
		XCTAssertEqual(copy.catalog.models, [
			ClaudeCLIModel(id: "claude-opus-9", displayName: "Opus 9", description: "Desc claude-opus-9", family: "opus", efforts: [.low, .xhigh, .max], contextWindowTokens: 1_000_000),
			ClaudeCLIModel(id: "claude-haiku-9", displayName: "Haiku 9", description: "Desc claude-haiku-9", family: "haiku", efforts: [], contextWindowTokens: 200_000),
		])
		XCTAssertEqual(copy.catalog.aliasTargets, ["opus": "claude-opus-9"])
	}

	func testNewestFetchedCopyWinsAndBrokenCopiesAreSkipped() throws {
		try write(catalogJSON(fetchedAt: 100, models: [model(id: "claude-old", name: "Old", family: "opus", efforts: [], context: 1)]), as: "a-cc.json")
		try write(catalogJSON(fetchedAt: 200, models: [model(id: "claude-new", name: "New", family: "opus", efforts: [], context: 1)]), as: "b-cc.json")
		try write(Data("not json".utf8), as: "c-cc.json")
		try write(catalogJSON(fetchedAt: 300, models: []), as: "d-cc.json")
		try write(catalogJSON(fetchedAt: 400, models: [model(id: "claude-other", name: "Other", family: "opus", efforts: [], context: 1)]), as: "e-other.json")

		let catalog = try XCTUnwrap(ClaudeCLIModelCatalog.newest(in: directory))

		XCTAssertEqual(catalog.models.map(\.id), ["claude-new"])
	}

	func testNoReadableCopyGivesNil() throws {
		XCTAssertNil(ClaudeCLIModelCatalog.newest(in: directory.appendingPathComponent("missing")))
		try write(Data("{}".utf8), as: "a-cc.json")
		XCTAssertNil(ClaudeCLIModelCatalog.newest(in: directory))
	}

	func testEffortsResolveAliasesAndTheOneMillionContextSuffix() {
		let catalog = ClaudeCLIModelCatalog(
			models: [
				ClaudeCLIModel(id: "claude-opus-9", displayName: "Opus 9", description: nil, family: "opus", efforts: [.high, .xhigh], contextWindowTokens: nil),
				ClaudeCLIModel(id: "claude-haiku-9", displayName: "Haiku 9", description: nil, family: "haiku", efforts: [], contextWindowTokens: nil),
			],
			aliasTargets: ["opus": "claude-opus-9"]
		)

		XCTAssertEqual(catalog.efforts(forBaseModelRaw: "opus"), [.high, .xhigh])
		XCTAssertEqual(catalog.efforts(forBaseModelRaw: "opus[1m]"), [.high, .xhigh])
		XCTAssertEqual(catalog.efforts(forBaseModelRaw: " Claude-Opus-9 "), [.high, .xhigh])
		XCTAssertEqual(catalog.efforts(forBaseModelRaw: "claude-haiku-9"), [])
		XCTAssertNil(catalog.efforts(forBaseModelRaw: "sonnet"))
		XCTAssertNil(catalog.efforts(forBaseModelRaw: "claude-unknown"))
	}

	// MARK: - Helpers

	private func write(_ data: Data, as name: String) throws {
		try data.write(to: directory.appendingPathComponent(name))
	}

	private func model(id: String, name: String, family: String, efforts: [String]?, context: Int) -> [String: Any] {
		var runtime: [String: Any] = ["family": family, "max_input_tokens": context]
		if let efforts {
			runtime["effort_levels"] = efforts
		}
		return ["id": id, "name": name, "description": "Desc \(id)", "runtime": runtime]
	}

	private func catalogJSON(fetchedAt: Int, models: [[String: Any]], aliases: [String: String] = [:]) throws -> Data {
		let aliasTargets = aliases.mapValues { ["default": $0] }
		let root: [String: Any] = [
			"version": 2,
			"fetchedAt": fetchedAt,
			"catalog": ["config": ["models": models, "provider_alias_targets": aliasTargets]],
		]
		return try JSONSerialization.data(withJSONObject: root)
	}
}
