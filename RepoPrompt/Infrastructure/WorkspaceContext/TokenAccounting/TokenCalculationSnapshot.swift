import Foundation

struct PromptFileEntrySnapshot: Sendable {
	let fileID: UUID
	let relativePath: String
	let isCodemapRequested: Bool
	let ranges: [LineRange]?
	let cachedFullTokenCount: Int?
	let loadedContent: String?
	let codeMapContent: String?
	let availableCodeMapTokenCount: Int
}

enum TokenCalculationFileTreeInput: Sendable {
	case none
	case rendered(String)
	case snapshot(FileTreeSelectionSnapshot)
}

struct TokenCalculationSnapshot: Sendable {
	let promptText: String
	let selectedInstructionsText: String
	let includeDiffFormatting: Bool
	let xmlFormattingPrompt: String
	let duplicateUserInstructionsAtTop: Bool
	let promptEntries: [PromptFileEntrySnapshot]
	let fileTree: TokenCalculationFileTreeInput
}
