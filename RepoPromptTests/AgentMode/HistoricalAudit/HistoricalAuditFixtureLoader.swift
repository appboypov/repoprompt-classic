import Foundation
@testable import RepoPrompt

private final class HistoricalAuditBundleToken {}

enum HistoricalAuditFixtureLoader {
	enum LoaderError: Error, CustomStringConvertible {
		case fixtureRootNotFound(startingAt: String)
		case fixtureMissing(String)

		var description: String {
			switch self {
			case .fixtureRootNotFound(let path):
				return "Could not locate HistoricalAudit v1 fixture root from \(path)"
			case .fixtureMissing(let path):
				return "HistoricalAudit fixture is missing: \(path)"
			}
		}
	}

	static let relativeFixtureRoot = "Fixtures/AgentSessions/HistoricalAudit/v1"
	static let manifestFileName = "manifest.json"

	static func fixtureRoot(sourceFile: StaticString = #filePath) throws -> URL {
		let sourcePath = String(describing: sourceFile)
		var directory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
		let fileManager = FileManager.default

		for _ in 0..<10 {
			let candidate = directory.appendingPathComponent(relativeFixtureRoot, isDirectory: true)
			if fileManager.fileExists(atPath: candidate.appendingPathComponent(manifestFileName).path) {
				return candidate
			}
			let parent = directory.deletingLastPathComponent()
			if parent.path == directory.path { break }
			directory = parent
		}

		let bundle = Bundle(for: HistoricalAuditBundleToken.self)
		if let bundled = bundle.url(
			forResource: "manifest",
			withExtension: "json",
			subdirectory: relativeFixtureRoot
		)?.deletingLastPathComponent() {
			return bundled
		}

		throw LoaderError.fixtureRootNotFound(startingAt: sourcePath)
	}

	static func manifestURL(sourceFile: StaticString = #filePath) throws -> URL {
		try fixtureRoot(sourceFile: sourceFile).appendingPathComponent(manifestFileName)
	}

	static func loadManifest(sourceFile: StaticString = #filePath) throws -> HistoricalAuditManifest {
		let data = try Data(contentsOf: manifestURL(sourceFile: sourceFile))
		return try JSONDecoder().decode(HistoricalAuditManifest.self, from: data)
	}

	static func fixtureURL(for auditCase: HistoricalAuditCase, sourceFile: StaticString = #filePath) throws -> URL {
		let url = try fixtureRoot(sourceFile: sourceFile).appendingPathComponent(auditCase.fixturePath)
		guard FileManager.default.fileExists(atPath: url.path) else {
			throw LoaderError.fixtureMissing(url.path)
		}
		return url
	}

	static func fixtureData(for auditCase: HistoricalAuditCase, sourceFile: StaticString = #filePath) throws -> Data {
		try Data(contentsOf: fixtureURL(for: auditCase, sourceFile: sourceFile))
	}

	static func loadSession(for auditCase: HistoricalAuditCase, sourceFile: StaticString = #filePath) throws -> AgentSession {
		try JSONDecoder().decode(AgentSession.self, from: fixtureData(for: auditCase, sourceFile: sourceFile))
	}

	static func copyFixtureToTemporarySessionFile(
		for auditCase: HistoricalAuditCase,
		temporaryRoot: URL? = nil,
		sourceFile: StaticString = #filePath
	) throws -> URL {
		let session = try loadSession(for: auditCase, sourceFile: sourceFile)
		let data = try fixtureData(for: auditCase, sourceFile: sourceFile)
		let root = temporaryRoot ?? FileManager.default.temporaryDirectory
		let directory = root.appendingPathComponent("RepoPrompt-HistoricalAudit-\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
		let url = directory.appendingPathComponent("AgentSession-\(session.id.uuidString).json")
		try data.write(to: url, options: .atomic)
		return url
	}

	static func makeTemporaryWorkspace(name: String = "HistoricalAudit", root: URL) -> WorkspaceModel {
		WorkspaceModel(
			name: name,
			repoPaths: [root.path],
			customStoragePath: root,
			ephemeralFlag: true
		)
	}
}
