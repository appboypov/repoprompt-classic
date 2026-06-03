import Foundation

protocol DiffChunkGenerator {
	func makeDiffChunks(
		filePath: String,
		originalText: String,
		search: String?,
		replace: String,
		replaceAll: Bool,
		treatAsRewrite: Bool
	) async throws -> (chunks: [DiffChunk], fileAction: FileAction)
}

protocol DiffChunkApplier {
	func apply(chunks: [DiffChunk], to originalText: String, fileAction: FileAction) throws -> String
}

protocol UnifiedDiffRendering {
	func render(filePath: String, chunks: [DiffChunk]) -> String
}
