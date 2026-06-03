import Foundation

final class BenchmarkRepoFileManager: RepoFileManagerViewModel {
	private let baseline: BenchmarkMockFileSystemSnapshot
	private let rootIdentifier = UUID()
	private let rootPath = "/benchmark"

	init(baseline: BenchmarkMockFileSystemSnapshot) {
		self.baseline = baseline
		super.init()
	}

	override func getFileSystemServiceForRelativePath(
		_ userPath: String,
		exactMatchOnly: Bool = false,
		profile: PathLocateProfile? = nil,
		rootScopeOverride: RepoFileManagerViewModel.LookupRootScope? = nil
	) async -> PathLocation? {
		let normalized = BenchmarkMockFileSystem.normalize(userPath)
		guard !normalized.isEmpty else { return nil }
		// For benchmarks, only return a path location if the file exists in the baseline
		// This ensures getBaselineContent can provide actual content for indentation detection
		guard baseline.contains(normalized) else {
			return nil
		}
		return PathLocation(rootPath: rootPath,
						   correctedPath: normalized,
						   rootIdentifier: rootIdentifier)
	}

	override func findFile(
		atPath relativePath: String,
		rootIdentifier: UUID?
	) async -> FileViewModel? {
		// Benchmark runs operate entirely in-memory; we do not surface actual FileViewModels.
		// The DiffParser will use getBaselineContent instead.
		return nil
	}

	override func getBaselineContent(forPath relativePath: String, rootIdentifier: UUID?) async -> String? {
		let normalized = BenchmarkMockFileSystem.normalize(relativePath)
		return baseline.content(for: normalized)
	}
}

enum BenchmarkDiffParserFactory {
	static func makeParser(baseline: BenchmarkMockFileSystemSnapshot) async -> DiffParser {
		await MainActor.run {
			let manager = BenchmarkRepoFileManager(baseline: baseline)
			#if DEBUG
			let config = DiffParser.DebugConfig(
				treatNonExistentFilesAsExisting: true,
				alwaysPreserveRewriteAction: true
			)
			return DiffParser(fileManager: manager, debugConfig: config)
			#else
			return DiffParser(fileManager: manager)
			#endif
		}
	}
}
