import SwiftUI
import Combine
import Foundation

@MainActor
class TokenCountingViewModel: ObservableObject {
	// MARK: - Token Counting Properties
	
	@Published private(set) var tokenCount: String = "0.00k"
	@Published private(set) var tokenCountFilesOnly: String = "0.00k"
	@Published private(set) var charCount: Int = 0
	@Published private(set) var totalTokenCount: Int = 0
	@Published private(set) var totalTokenCountFilesOnly: Int = 0
	@Published private(set) var totalTokenCountWithDiff: Int = 0
	@Published private(set) var tokenCountWithDiff: String = "0.00k"
	@Published private(set) var gitDiffTokenCount: Int = 0
	@Published private(set) var gitDiffTokenCountString: String = "0.00k"
	@Published private(set) var folderTokenInfo: [String: TokenInfo] = [:]
	@Published private(set) var fileTokenInfo: [UUID: TokenInfo] = [:]
	@Published private(set) var codeMapFileCount: Int = 0
	@Published private(set) var codeMapTokenCount: Int = 0
	@Published private(set) var cachedFileAPIs: [FileAPI] = []
	@Published private(set) var fileTreeContent: String = ""
	@Published private(set) var codeMapContent: String = ""
	@Published private(set) var scannedLanguages: Set<LanguageType> = []
	@Published private(set) var copyContextTotalTokens: Int = 0
	@Published private(set) var copyContextTokenCountString: String = "0.00k"
	
	/// Combined property preserving legacy behaviour
	var combinedTreeAndCodeMapContent: String {
		[fileTreeContent, codeMapContent]
			.filter { !$0.isEmpty }
			.joined(separator: "\n\n")
	}

	/// Total display tokens for files in the current mode.
	/// In .selected mode, this combines non-API file tokens + codemap tokens.
	/// Use this for consistent file token display across UI surfaces.
	var totalFileTokensDisplay: Int {
		totalTokenCountFilesOnly + codeMapTokenCount
	}

	/// Formatted string for total file tokens display.
	var fileTokensDisplayString: String {
		String(format: "%.2fk", Double(totalFileTokensDisplay) / 1000.0)
	}

	let tokenCalculationCompletedPublisher = PassthroughSubject<Void, Never>()
	
	// MARK: - Dirty Flags
	
	struct DirtyKind: OptionSet {
		let rawValue: Int
		static let selection    = DirtyKind(rawValue: 1 << 0) // selected files changed
		static let fileTree     = DirtyKind(rawValue: 1 << 1) // tree needs rebuild
		static let codeMap      = DirtyKind(rawValue: 1 << 2) // code-map cache changed
		static let settings     = DirtyKind(rawValue: 1 << 3) // settings affecting baseline
		static let gitDiff      = DirtyKind(rawValue: 1 << 4) // just diff tokens changed
		static let promptText   = DirtyKind(rawValue: 1 << 5) // user instructions text changed
		static let instructions = DirtyKind(rawValue: 1 << 6) // stored/meta instructions changed
	}
	
	private let heavyDirtyKinds: DirtyKind = [.selection, .fileTree, .codeMap, .settings]
	private var pendingDirty: DirtyKind = []
	
	/// Cached components to support light, incremental recomputation.
	private var didComputeBaseline: Bool = false
	private var lastBaseWithoutUserText: Int = 0        // Everything except user prompt/instructions
	private var lastPromptTokens: Int = 0               // Tokens for prompt text only
	private var lastDuplicatePromptTokens: Int = 0      // Duplicate prompt tokens (if setting is on)
	private var lastInstructionsTokens: Int = 0         // Tokens for meta/stored instructions
	private var lastGitDiffTokens: Int = 0
	private var lastMcpMetadataTokens: Int = 0
	private var lastFileTreeTokens: Int = 0
	
	// MARK: - Private Properties
	
	private var timer: Timer?
	private let tokenCalculationService = TokenCalculationService()
	private var updateTokenCountTask: Task<Void, Never>?
	private var cancellables = Set<AnyCancellable>()
	private var lastSelectedFileCount: Int = 0
	private var automaticRecountSuspendDepth: Int = 0
	
	// Cache the diff-format prompt computations to avoid rebuilding for the same inputs.
	private var diffPromptCache: (language: String, allowRewrite: Bool, prompt: String, tokens: Int)?

	
	// MARK: - Dependencies
	
	private weak var fileManager: RepoFileManagerViewModel?
	private weak var gitViewModel: GitViewModel?
	private var getPromptText: (() -> String)?
	private var getSelectedInstructionsText: (() -> String)?
	private var getSettings: (() -> TokenCalculationSettings)?
	private var getCopyContext: (() -> CopyContextSnapshot)?
	
	// MARK: - Settings Structure
	
	struct TokenCalculationSettings {
		let fileTreeOption: FileTreeOption
		let codeMapUsage: CodeMapUsage
		let filePathDisplayOption: FilePathDisplay
		let xmlClipboardFormatPreference: DiffViewModel.PromptFormat
		let allowDiffModelsToRewrite: Bool
		let includeFilesInClipboard: Bool
		let duplicateUserInstructionsAtTop: Bool
		let onlyIncludeRootsWithSelectedFiles: Bool
		let codeMapsGloballyDisabled: Bool
	}
	
	struct CopyContextSnapshot {
		let includeFiles: Bool
		let includeUserPrompt: Bool
		let includeMetaPrompts: Bool
		let includeFileTree: Bool
		let xmlFormat: ApplyPromptFormat?
		let fileTreeMode: FileTreeOption
		let codeMapUsage: CodeMapUsage
		let gitInclusion: GitInclusion
		let duplicateUserInstructionsAtTop: Bool
		let mcpMetadata: String?
		let systemPromptFlavor: SystemPromptFlavor?  // For MCP system prompts
		
		static var `default`: CopyContextSnapshot {
			CopyContextSnapshot(
				includeFiles: true,
				includeUserPrompt: true,
				includeMetaPrompts: true,
				includeFileTree: true,
				xmlFormat: nil,
				fileTreeMode: .auto,
				codeMapUsage: .none,
				gitInclusion: .none,
				duplicateUserInstructionsAtTop: false,
				mcpMetadata: nil,
				systemPromptFlavor: nil
			)
		}
	}
	
	// MARK: - Initialization
	
	init() {
		// Initialize with empty state
	}
	
	func configure(
		fileManager: RepoFileManagerViewModel,
		gitViewModel: GitViewModel,
		getPromptText: @escaping () -> String,
		getSelectedInstructionsText: @escaping () -> String,
		getSettings: @escaping () -> TokenCalculationSettings,
		getCopyContext: @escaping () -> CopyContextSnapshot
	) {
		self.fileManager = fileManager
		self.gitViewModel = gitViewModel
		self.getPromptText = getPromptText
		self.getSelectedInstructionsText = getSelectedInstructionsText
		self.getSettings = getSettings
		self.getCopyContext = getCopyContext
		
		setupObservers()
		startTokenCountUpdateTimer()
	}
	
	// MARK: - Setup and Observer Configuration
	
	private func setupObservers() {
		guard let fileManager = fileManager else { return }
		
		fileManager.$selectedFiles
			.dropFirst()
			.sink { [weak self] _ in
				self?.markDirty(.selection)
			}
			.store(in: &cancellables)
		
		fileManager.$selectionSlicesByFileID
			.dropFirst()
			.sink { [weak self] _ in
				self?.markDirty(.selection)
			}
			.store(in: &cancellables)
		
		fileManager.codeMapUpdatePublisher
			.sink { [weak self] in
				self?.markDirty(.codeMap)
			}
			.store(in: &cancellables)
		
		// NEW: Clear caches when roots are added/removed/rebuilt so UI doesn't show stale data
		fileManager.fileSystemChangedPublisher
			.sink { [weak self] in
				self?.handleFileSystemTopologyChanged()
			}
			.store(in: &cancellables)
		
		// NEW: Explicitly handle the "all folders unloaded" signal
		fileManager.allFoldersUnloadedPublisher
			.sink { [weak self] in
				self?.handleFileSystemTopologyChanged()
			}
			.store(in: &cancellables)
		
		// Observe git diff mode changes to recalculate only diff tokens
		gitViewModel?.$gitDiffInclusionMode
			.dropFirst()
			.sink { [weak self] _ in
				self?.markDirty(.gitDiff)
			}
			.store(in: &cancellables)
		
		gitViewModel?.$selectedDiffBranch
			.dropFirst()
			.removeDuplicates()
			.sink { [weak self] _ in
				self?.markDirty(.gitDiff)
			}
			.store(in: &cancellables)
		
		gitViewModel?.$unstagedFiles
			.dropFirst()
			.removeDuplicates()
			.sink { [weak self] _ in
				self?.markDirty(.gitDiff)
			}
			.store(in: &cancellables)
		
		gitViewModel?.$selectedRootFolder
			.dropFirst()
			.map { $0?.fullPath }
			.removeDuplicates()
			.sink { [weak self] _ in
				self?.markDirty(.gitDiff)
			}
			.store(in: &cancellables)
	}
	
	// MARK: - Timer Management
	
	func startTokenCountUpdateTimer() {
		timer?.invalidate()
		timer = nil
		
		timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
			guard let self = self else { return }
			Task { @MainActor [weak self] in
				guard let self = self, let fileManager = self.fileManager else { return }
				
				let currentCount = fileManager.selectedFiles.count
				
				if currentCount != self.lastSelectedFileCount {
					self.updateTokenCountTask?.cancel()
					self.lastSelectedFileCount = currentCount
				}
				
				guard self.automaticRecountSuspendDepth == 0,
					  !self.pendingDirty.isEmpty,
					  self.updateTokenCountTask == nil else { return }
				
				// Snapshot and clear to coalesce changes; anything that happens during compute will be queued for next tick
				let kindsToProcess = self.pendingDirty
				self.pendingDirty = []
				
				let needsHeavy = !kindsToProcess.intersection(self.heavyDirtyKinds).isEmpty
				
				self.updateTokenCountTask = Task { @MainActor [weak self] in
					guard let self = self else { return }
					if needsHeavy {
						await self.performTokenCountOffMainThread()
					} else {
						await self.recalculateLight(kinds: kindsToProcess)
					}
					self.updateTokenCountTask = nil
				}
			}
		}
	}
	
	func stopTokenCountUpdateTimer() async {
		timer?.invalidate()
		timer = nil
		updateTokenCountTask?.cancel()
		updateTokenCountTask = nil
		await tokenCalculationService.shutdown()
	}
	
	// MARK: - Dirty Markers (Public)
	
	/// Backwards-compatible "everything changed" flag (used by existing callers).
	func markDirty() {
		markDirty(.selection.union(.fileTree).union(.codeMap).union(.settings))
	}
	
	func markDirty(_ kind: DirtyKind) {
		pendingDirty.formUnion(kind)
	}
	
	func markPromptDirty() {
		pendingDirty.insert(.promptText)
	}
	
	func markInstructionsDirty() {
		pendingDirty.insert(.instructions)
	}
	
	func markGitDiffDirty() {
		pendingDirty.insert(.gitDiff)
	}

	func suspendAutomaticRecounts() {
		automaticRecountSuspendDepth += 1
	}

	func resumeAutomaticRecounts() {
		automaticRecountSuspendDepth = max(0, automaticRecountSuspendDepth - 1)
	}

	@MainActor
	func forceImmediateRecount() async {
		updateTokenCountTask?.cancel()
		updateTokenCountTask = nil
		pendingDirty = []
		await performTokenCountOffMainThread()
	}
	
	private func resolveCopyContextSnapshot() -> CopyContextSnapshot {
		getCopyContext?() ?? .default
	}
	
	// MARK: - Token Calculation
	
	/// Heavy path (rebuild baseline and everything else).
	private func performTokenCountOffMainThread() async {
		guard let fileManager = fileManager,
				let promptSource = getPromptText?(),
				let instructionsSource = getSelectedInstructionsText?(),
				let settings = getSettings?() else {
			return
		}
		
		let copySnapshot = resolveCopyContextSnapshot()
		let includeFiles = copySnapshot.includeFiles
		let includeUserPrompt = copySnapshot.includeUserPrompt
		let includeMetaPrompts = copySnapshot.includeMetaPrompts
		let includeFileTree = copySnapshot.includeFileTree
		
		let promptText = includeUserPrompt ? promptSource : ""
		// For MCP system prompts, always include them even if includeMetaPrompts is false
		// (e.g., MCP Discover has includeMetaPrompts=false but still needs system prompt counted)
		var selectedInstructionsText = includeMetaPrompts ? instructionsSource : ""
		if !includeMetaPrompts, let flavor = copySnapshot.systemPromptFlavor {
			// MCP prompts should be counted even when meta prompts are disabled
			let isMCPPrompt = [SystemPromptFlavor.mcpAgent, .mcpPairProgram, .mcpDiscover].contains(flavor)
			if isMCPPrompt {
				let systemContent = SystemPromptService.systemPrompt(for: flavor, language: "Swift")
				if !systemContent.isEmpty {
					selectedInstructionsText = systemContent
				}
			}
		}
		let duplicatePromptAtTop = includeUserPrompt ? copySnapshot.duplicateUserInstructionsAtTop : false
		
		let allFileViewModels = fileManager.allFilesSnapshot(sorted: false)
		let allFileAPIs = fileManager.validatedFileAPIsSnapshot(sorted: false)
		
		// Cache the file APIs for reuse
		self.cachedFileAPIs = allFileAPIs
		
		// Derive and publish the set of detected languages
		let detectedExts = allFileViewModels.map { ($0.fileExtension ?? "").lowercased() }
		let detectedLangs = detectedExts.compactMap { SyntaxManager.shared.extensionToLanguage[$0] }
		self.scannedLanguages = Set(detectedLangs)
		
		let rendersFileTree = includeFileTree && copySnapshot.fileTreeMode != .none
		let rootFoldersForTree: [FolderViewModel] = rendersFileTree ? fileManager.visibleRootFolders : []
		
		let effectiveCodeMapUsage = copySnapshot.codeMapUsage
		let allEntries = fileManager.buildPromptEntries(
			codeMapUsage: effectiveCodeMapUsage,
			allFileAPIs: allFileAPIs
		)
		let fileEntries: [PromptFileEntry] = includeFiles ? allEntries : []
		let selectedFilesForStats = includeFiles ? fileManager.selectedFiles : []
		
		let effectiveFileTreeOption: FileTreeOption = rendersFileTree ? copySnapshot.fileTreeMode : .none
		let xmlFormat = copySnapshot.xmlFormat
		let xmlFormattingPromptForCopy = xmlFormat
			.map { format -> String in
				let promptFormat: DiffViewModel.PromptFormat = {
					switch format {
					case .diff: return .diff
					case .whole, .architect: return .whole
					}
				}()
				let language = SystemPromptService.predominantLanguage(from: selectedFilesForStats)
				return SystemPromptService.getApplyInstructions(
					format: promptFormat,
					allowRewrite: settings.allowDiffModelsToRewrite,
					language: language
				)
			} ?? ""
		let includeDiffFormattingForCopy = (xmlFormat != nil)
		let fileTreeContext: FileTreeSelectionContext? = rendersFileTree
			? FileTreeSelectionContext(
				rootFolders: rootFoldersForTree,
				selectedFileIDs: Set(selectedFilesForStats.map(\.id)),
				option: effectiveFileTreeOption,
				filePathDisplay: settings.filePathDisplayOption,
				onlyIncludeRootsWithSelectedFiles: settings.onlyIncludeRootsWithSelectedFiles,
				includeLegend: true,
				isMCPContext: false,
				showCodeMapMarkers: !settings.codeMapsGloballyDisabled
			)
			: nil
		guard let calculationSnapshot = await buildTokenCalculationSnapshot(
			promptText: promptText,
			selectedInstructionsText: selectedInstructionsText,
			includeDiffFormatting: includeDiffFormattingForCopy,
			xmlFormattingPrompt: xmlFormattingPromptForCopy,
			duplicateUserInstructionsAtTop: duplicatePromptAtTop,
			fileEntries: fileEntries,
			filePathDisplay: settings.filePathDisplayOption,
			fileTreeContext: fileTreeContext
		) else {
			return
		}
		let result = await tokenCalculationService.calculatePromptStats(snapshot: calculationSnapshot)
		
		// Git diff tokens: only count generated diffs from GitViewModel when no artifact files are selected.
		// Artifact files (_git_data/*.diff/*.patch) are already counted as normal files in calculatePromptStats,
		// so we don't double-count them here. gitDiffTokenCount represents ONLY generated diffs.
		let (diffEntries, _) = PromptPackagingService.partitionPromptEntriesForGitDiff(fileEntries)
		let hasSelectedArtifacts = !diffEntries.isEmpty
		
		var gitDiffTokens = 0
		if !hasSelectedArtifacts, let gitViewModel = self.gitViewModel {
			// No artifact files selected - use GitViewModel to generate diff if git inclusion is enabled
			switch copySnapshot.gitInclusion {
			case .none:
				break
			case .selected:
				if let diff = await gitViewModel.getDiffUsing(inclusionMode: .selectedFiles) {
					gitDiffTokens = TokenCalculationService.estimateTokens(for: diff)
				}
			case .complete:
				if let diff = await gitViewModel.getDiffUsing(inclusionMode: .all) {
					gitDiffTokens = TokenCalculationService.estimateTokens(for: diff)
				}
			}
		}
		// When artifact files ARE selected, gitDiffTokens stays 0 - those files are counted in totalTokenCountFilesOnly
		
		let mcpTokens = TokenCalculationService.estimateTokens(for: copySnapshot.mcpMetadata ?? "")
		let copyTotal = result.totalTokenCount + gitDiffTokens + mcpTokens
		let copyTokenString = String(format: "%.2fk", Double(copyTotal) / 1000.0)
		
		self.fileTokenInfo = result.fileTokenInfo
		self.folderTokenInfo = result.folderTokenInfo
		self.fileTreeContent = result.fileTreeContent
		self.codeMapContent = result.codeMapContent
		self.lastFileTreeTokens = result.fileTreeTokenCountRaw
		self.charCount = result.charCount
		self.totalTokenCount = copyTotal
		self.tokenCount = copyTokenString
		self.tokenCountFilesOnly = result.tokenCountFilesOnlyString
		self.totalTokenCountFilesOnly = result.totalTokenCountFilesOnly
		self.codeMapFileCount = result.codeMapFileCount
		self.codeMapTokenCount = result.codeMapTokenCount
		
		let predominantLanguage = SystemPromptService.predominantLanguage(from: selectedFilesForStats)
		let allowRewrite = settings.allowDiffModelsToRewrite
		let diffPromptTokens: Int = {
			if let cached = diffPromptCache,
			   cached.language == predominantLanguage,
			   cached.allowRewrite == allowRewrite {
				return cached.tokens
			}
			let diffPrompt = SystemPromptService.getCodeEditPromptFor(
				format: .diff,
				allowRewrite: allowRewrite,
				language: predominantLanguage
			)
			let tokens = TokenCalculationService.estimateTokens(for: diffPrompt)
			diffPromptCache = (language: predominantLanguage, allowRewrite: allowRewrite, prompt: diffPrompt, tokens: tokens)
			return tokens
		}()
		
		self.gitDiffTokenCount = gitDiffTokens
		self.gitDiffTokenCountString = String(format: "%.2fk", Double(gitDiffTokens) / 1000.0)
		
		let withDiffTotal = result.totalTokenCount + diffPromptTokens + gitDiffTokens + mcpTokens
		self.totalTokenCountWithDiff = withDiffTotal
		self.tokenCountWithDiff = String(format: "%.2fk", Double(withDiffTotal) / 1000.0)
		
		let promptTokensLocal = TokenCalculationService.estimateTokens(for: promptText)
		let instructionsTokensLocal = TokenCalculationService.estimateTokens(for: selectedInstructionsText)
		let duplicatePromptTokensLocal = duplicatePromptAtTop ? promptTokensLocal : 0
		
		self.lastBaseWithoutUserText = max(
			0,
			result.totalTokenCount - promptTokensLocal - duplicatePromptTokensLocal - instructionsTokensLocal
		)
		self.lastPromptTokens = promptTokensLocal
		self.lastDuplicatePromptTokens = duplicatePromptTokensLocal
		self.lastInstructionsTokens = instructionsTokensLocal
		self.lastGitDiffTokens = gitDiffTokens
		self.lastMcpMetadataTokens = mcpTokens
		self.copyContextTotalTokens = copyTotal
		self.copyContextTokenCountString = copyTokenString
		self.didComputeBaseline = true
		
		tokenCalculationCompletedPublisher.send()
	}
	
	private func buildTokenCalculationSnapshot(
		promptText: String,
		selectedInstructionsText: String,
		includeDiffFormatting: Bool,
		xmlFormattingPrompt: String,
		duplicateUserInstructionsAtTop: Bool,
		fileEntries: [PromptFileEntry],
		filePathDisplay: FilePathDisplay,
		fileTreeContext: FileTreeSelectionContext?
	) async -> TokenCalculationSnapshot? {
		let promptEntrySnapshots = await buildPromptEntrySnapshots(
			from: fileEntries,
			filePathDisplay: filePathDisplay
		)
		guard !Task.isCancelled else { return nil }
		let fileTree: TokenCalculationFileTreeInput = if let fileTreeContext, fileTreeContext.option != .none {
			.snapshot(CodeMapExtractor.makeFileTreeSnapshot(using: fileTreeContext))
		} else {
			.none
		}
		guard !Task.isCancelled else { return nil }
		return TokenCalculationSnapshot(
			promptText: promptText,
			selectedInstructionsText: selectedInstructionsText,
			includeDiffFormatting: includeDiffFormatting,
			xmlFormattingPrompt: xmlFormattingPrompt,
			duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
			promptEntries: promptEntrySnapshots,
			fileTree: fileTree
		)
	}
	
	func buildPromptEntrySnapshots(
		from fileEntries: [PromptFileEntry],
		filePathDisplay: FilePathDisplay
	) async -> [PromptFileEntrySnapshot] {
		guard !fileEntries.isEmpty else { return [] }
		let hasMultipleRoots = Set(fileEntries.map { $0.file.rootFolderPath }).count > 1
		let displayPath: (FileViewModel) -> String = { file in
			if filePathDisplay == .relative {
				return hasMultipleRoots ? file.uniqueRelativePath : file.relativePath
			}
			return file.fullPath
		}
		var snapshots: [PromptFileEntrySnapshot] = []
		snapshots.reserveCapacity(fileEntries.count)
		for entry in fileEntries {
			if Task.isCancelled { break }
			let file = entry.file
			let cachedTokenCount = file.cachedTokenCount
			let requiresContent: Bool = {
				guard !entry.isCodemap else { return false }
				if let ranges = entry.ranges, !ranges.isEmpty {
					return true
				}
				return cachedTokenCount == nil
			}()
			let loadedContent: String?
			if requiresContent {
				let cachedSnapshot = await file.cachedContentSnapshot()
				if cachedSnapshot.isFresh, let content = cachedSnapshot.content {
					loadedContent = content
				} else {
					loadedContent = await file.latestContent
				}
			} else {
				loadedContent = nil
			}
			let availableAPI = fileManager?.validatedFileAPI(for: file)
			let availableCodeMapTokenCount = availableAPI?.apiTokenCount ?? 0
			let codeMapContent: String?
			if entry.isCodemap, let api = availableAPI {
				let description = api.getFullAPIDescription(displayPath: displayPath(file))
				codeMapContent = description.isEmpty ? nil : description
			} else {
				codeMapContent = nil
			}
			snapshots.append(PromptFileEntrySnapshot(
				fileID: file.id,
				relativePath: file.relativePath,
				isCodemapRequested: entry.isCodemap,
				ranges: entry.ranges,
				cachedFullTokenCount: cachedTokenCount,
				loadedContent: loadedContent,
				codeMapContent: codeMapContent,
				availableCodeMapTokenCount: availableCodeMapTokenCount
			))
		}
		return snapshots
	}
	
	/// Light path (prompt text and/or meta instructions and/or git diff only).
	private func recalculateLight(kinds: DirtyKind) async {
		guard didComputeBaseline,
				let promptSource = getPromptText?(),
				let instructionsSource = getSelectedInstructionsText?(),
				let settings = getSettings?() else {
			await performTokenCountOffMainThread()
			return
		}
		
		let copySnapshot = resolveCopyContextSnapshot()
		let includeUserPrompt = copySnapshot.includeUserPrompt
		let includeMetaPrompts = copySnapshot.includeMetaPrompts
		let promptText = includeUserPrompt ? promptSource : ""
		let selectedInstructionsText = includeMetaPrompts ? instructionsSource : ""
		let duplicatePrompt = includeUserPrompt ? copySnapshot.duplicateUserInstructionsAtTop : false
		
		let promptTokens = TokenCalculationService.estimateTokens(for: promptText)
		let duplicatePromptTokens = duplicatePrompt ? promptTokens : 0
		let instructionsTokens = TokenCalculationService.estimateTokens(for: selectedInstructionsText)
		
		var gitDiffTokens = self.gitDiffTokenCount
		if kinds.contains(.gitDiff) {
			if let fileManager = fileManager {
				// Build entries respecting includeFiles setting
				let allEntries = fileManager.buildPromptEntries(
					codeMapUsage: copySnapshot.codeMapUsage,
					allFileAPIs: cachedFileAPIs
				)
				let fileEntries = copySnapshot.includeFiles ? allEntries : []
				
				// Check if artifact files are selected - if so, they're already counted as normal files
				let (diffEntries, _) = PromptPackagingService.partitionPromptEntriesForGitDiff(fileEntries)
				let hasSelectedArtifacts = !diffEntries.isEmpty
				
				if hasSelectedArtifacts {
					// Artifact files are selected - they're counted as normal files, not as gitDiffTokens
					gitDiffTokens = 0
				} else if let gitViewModel = self.gitViewModel {
					// No artifact files - use GitViewModel to generate diff if git inclusion is enabled
					switch copySnapshot.gitInclusion {
					case .none:
						gitDiffTokens = 0
					case .selected:
						if let diff = await gitViewModel.getDiffUsing(inclusionMode: .selectedFiles) {
							gitDiffTokens = TokenCalculationService.estimateTokens(for: diff)
						} else {
							gitDiffTokens = 0
						}
					case .complete:
						if let diff = await gitViewModel.getDiffUsing(inclusionMode: .all) {
							gitDiffTokens = TokenCalculationService.estimateTokens(for: diff)
						} else {
							gitDiffTokens = 0
						}
					}
				} else {
					gitDiffTokens = 0
				}
			} else {
				gitDiffTokens = 0
			}
			self.gitDiffTokenCount = gitDiffTokens
			self.gitDiffTokenCountString = String(format: "%.2fk", Double(gitDiffTokens) / 1000.0)
			self.lastGitDiffTokens = gitDiffTokens
		}
		
		let mainTotal = lastBaseWithoutUserText + promptTokens + duplicatePromptTokens + instructionsTokens + lastMcpMetadataTokens
		let totalWithGit = mainTotal + gitDiffTokens
		
		let copyTokenString = String(format: "%.2fk", Double(totalWithGit) / 1000.0)
		self.totalTokenCount = totalWithGit
		self.tokenCount = copyTokenString
		self.copyContextTotalTokens = totalWithGit
		self.copyContextTokenCountString = copyTokenString
		
		let predominantLanguage = SystemPromptService.predominantLanguage(from: fileManager?.selectedFiles ?? [])
		let allowRewrite = settings.allowDiffModelsToRewrite
		let diffPromptTokens: Int = {
			if let cached = diffPromptCache,
			   cached.language == predominantLanguage,
			   cached.allowRewrite == allowRewrite {
				return cached.tokens
			}
			let diffPrompt = SystemPromptService.getCodeEditPromptFor(
				format: .diff,
				allowRewrite: allowRewrite,
				language: predominantLanguage
			)
			let tokens = TokenCalculationService.estimateTokens(for: diffPrompt)
			diffPromptCache = (language: predominantLanguage, allowRewrite: allowRewrite, prompt: diffPrompt, tokens: tokens)
			return tokens
		}()
		let withDiffTotal = mainTotal + diffPromptTokens + gitDiffTokens
		self.totalTokenCountWithDiff = withDiffTotal
		self.tokenCountWithDiff = String(format: "%.2fk", Double(withDiffTotal) / 1000.0)
		
		self.lastPromptTokens = promptTokens
		self.lastDuplicatePromptTokens = duplicatePromptTokens
		self.lastInstructionsTokens = instructionsTokens
		
		tokenCalculationCompletedPublisher.send()
	}
	
	// MARK: - Public Interface
	
	// MARK: - File Tree Properties
	
	var fileTreeTokenCount: Double {
		Double(lastFileTreeTokens) / 1000.0
	}
	
	var tooManyFileTreeTokens: Bool {
		return fileTreeTokenCount > 10
	}
	
	struct TokenBreakdown {
		let total: Int
		let files: Int
		let prompt: Int
		let meta: Int
		let fileTree: Int
		let git: Int
		let other: Int
	}
	
	func latestTokenBreakdown() -> TokenBreakdown {
		let promptSource = getPromptText?() ?? ""
		let instructionsSource = getSelectedInstructionsText?() ?? ""
		let promptTokens = didComputeBaseline
			? (lastPromptTokens + lastDuplicatePromptTokens)
			: (promptSource.isEmpty ? 0 : TokenCalculationService.estimateTokens(for: promptSource))
		let metaTokens = didComputeBaseline
			? lastInstructionsTokens
			: (instructionsSource.isEmpty ? 0 : TokenCalculationService.estimateTokens(for: instructionsSource))
		let gitTokens = didComputeBaseline ? lastGitDiffTokens : 0
		let fileTreeTokens = didComputeBaseline
			? lastFileTreeTokens
			: (fileTreeContent.isEmpty ? 0 : TokenCalculationService.estimateTokens(for: fileTreeContent))
		let filesTokens = totalTokenCountFilesOnly
		let total = didComputeBaseline
			? totalTokenCount
			: (promptTokens + filesTokens + metaTokens + gitTokens + fileTreeTokens)
		let otherTokens = max(total - (filesTokens + promptTokens + metaTokens + gitTokens + fileTreeTokens), 0)
		return TokenBreakdown(
			total: total,
			files: filesTokens,
			prompt: promptTokens,
			meta: metaTokens,
			fileTree: fileTreeTokens,
			git: gitTokens,
			other: otherTokens
		)
	}
	
	// MARK: - Token Breakdown
	
	var tokenBreakdownDescription: String {
		var parts: [String] = []
		
		if totalTokenCountFilesOnly > 0 {
			parts.append("• Files: \(tokenCountFilesOnly)")
		}
		
		if codeMapTokenCount > 0 {
			parts.append("• Code Maps: \(String(format: "%.2fk", Double(codeMapTokenCount) / 1000.0))")
		}
		
		if gitDiffTokenCount > 0 {
			parts.append("• Git Diff: \(gitDiffTokenCountString)")
		}
		
		let treeTokens = Int(fileTreeTokenCount * 1000)
		if treeTokens > 0 {
			parts.append("• File Tree: \(String(format: "%.2fk", fileTreeTokenCount))")
		}
		
		// Add other components like prompt text, instructions, etc.
		let otherTokens = totalTokenCount - totalTokenCountFilesOnly - codeMapTokenCount - gitDiffTokenCount - treeTokens
		if otherTokens > 0 {
			parts.append("• Other: \(String(format: "%.2fk", Double(otherTokens) / 1000.0))")
		}
		
		return parts.joined(separator: "\n")
	}
	
	// MARK: - Cleanup
	
	deinit {
		timer?.invalidate()
		timer = nil
		updateTokenCountTask?.cancel()
		updateTokenCountTask = nil
		cancellables.removeAll()
	}
	
	// MARK: - File System Topology
	
	private func handleFileSystemTopologyChanged() {
		// Immediately clear caches used by UI previews so we don't show stale data
		self.cachedFileAPIs = []
		self.scannedLanguages = []
		self.codeMapContent = ""
		self.fileTreeContent = ""
		self.codeMapFileCount = 0
		self.codeMapTokenCount = 0
		self.lastFileTreeTokens = 0
		
		// Mark heavy recomputation so totals and tree are rebuilt next tick
		let heavy: DirtyKind = [.selection, .fileTree, .codeMap, .settings]
		self.pendingDirty.formUnion(heavy)
	}
}
