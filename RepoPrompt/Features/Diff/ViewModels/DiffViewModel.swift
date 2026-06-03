import Foundation
import SwiftUI

/**
 A view model that handles parsing AI-provided diff XML, tracking selected changes,
 and ultimately generating `FileChanges` for merging into the codebase.
 
 This class is annotated with `@MainActor` to ensure all UI-bound state and
 Published properties remain isolated on the main thread. Actual heavy-lifting
 (parsing XML, generating diffs) is dispatched onto a background thread via
 detached tasks or helper methods, so that these operations do not stall
 the main actor.
 
 Additionally, every major async operation stores its Task reference so
 we can cancel old inflight tasks whenever a new request arrives.
 */
@MainActor
class DiffViewModel: ObservableObject {
	// MARK: - Nested Types
	
	enum PromptFormat: String, CaseIterable {
		case diff = "Diff"
		case whole = "Whole"
		
		static let userDefaultsKey = "selectedPromptFormat"
	}
	
	enum ParsingStatus {
		case idle, loading, success, failure
	}
	
	// MARK: - Published Properties
	
	@Published var xmlInput: String = ""
	@Published var instructionsText: String = ""
	@Published var selectedPromptFormat: PromptFormat {
		didSet {
			UserDefaults.standard.set(selectedPromptFormat.rawValue, forKey: PromptFormat.userDefaultsKey)
		}
	}
	@Published var showFormatInfo = false
	
	@Published var parsedFiles: [ParsedFile] = []
	@Published var isLoading: Bool = false
	@Published var errorMessage: String?
	@Published var hasSelectedChanges: Bool = false
	@Published var isDiffFormattingInstructionsIncluded: Bool = true
	@Published var parsingStatus: ParsingStatus = .idle
	@Published var fileLoadingWarning: String?
	@Published var isProcessing: Bool = false
	@Published var processedChanges: [FileChanges] = []
	@Published var visibleFileIds: Set<UUID> = []
	@Published var generatedChangesCount: Int = 0
	
	var totalSelectedChanges: Int {
		parsedFiles.reduce(0) { $0 + $1.changes.filter(\.isSelected).count }
	}
	
	@AppStorage("diffView.includeFileTree") var includeFileTree: Bool = true
	@AppStorage("diffPrecision") private var diffPrecision: DiffPrecision = .normal
	
	var getDiffPrecision: DiffPrecision {
		get{ return diffPrecision }
	}
	
	// MARK: - Delegate-edit helpers
	/// `true` if the current XML contains at least one `<delegateEdit …>` block.
	var hasDelegateEdits: Bool {
		delegateEditCount > 0
	}

	/// Total number of delegate-edit blocks in the current `xmlInput`.
	var delegateEditCount: Int {
		guard !xmlInput.isEmpty else { return 0 }

		// Return cached value when available
		if let cached = parsedContentCache[xmlInput] {
			return cached.delegateEdits.count
		}

		// Otherwise parse once, cache, and return
		var alreadySeenHashes = Set<Int>()
		let (items, _, delegateEdits) = ChatContentParser.parseContent(
			xmlInput,
			processedDelegateEditHashes: &alreadySeenHashes,
			isFinal: true
		)
		parsedContentCache[xmlInput] = (items, delegateEdits)
		return delegateEdits.count
	}
	
	// Callback for Pro Edit feature
	var proEditAction: ((_ instructions: String, _ xml: String) -> Void)?
	
	/// Kicks off the Pro-Edit flow.
	///
	/// 1.	Collect every `<file …>` delegate-edit reference.
	/// 2.	Let `RepoFileManagerViewModel` resolve each path against the user's
	///     current workspace (case-insensitive & fuzzy, same logic used during
	///     normal change application).
	/// 3.	If a better match is found, patch the XML _in-place_ **before** it is
	///     handed to `ChatViewModel`.  This means the subsequent
	///     `ChatContentParser` run inside `ChatViewModel.startProEditSession`
	///     receives only fully-validated, canonical paths.
	func triggerProEdit(instructions: String) {
		guard hasDelegateEdits else { return }
		
		// Retrieve (or freshly parse) the delegate edits once
		let delegateEdits: [DelegateEditItem] = {
			if let cached = parsedContentCache[xmlInput]?.delegateEdits { return cached }
			var hashes = Set<Int>()
			let (_, _, dels) = ChatContentParser.parseContent(
				xmlInput,
				processedDelegateEditHashes: &hashes,
				isFinal: true
			)
			return dels
		}()
		
		let originalXML = xmlInput  // capture current text
		
		// Perform path-validation off the main actor
		Task.detached { [weak self] in
			guard let self else { return }
			
			var patchedXML = originalXML
			for item in delegateEdits {
				if let location = await self.fileManager
						.getFileSystemServiceForRelativePath(item.filePath,
															exactMatchOnly: false)
				{
					let corrected = location.correctedPath
					if corrected != item.filePath {
						patchedXML = DiffProcessingHelper.rewriteFilePath(in: patchedXML,
														from: item.filePath,
														to:   corrected)
					}
				}
			}
			let finalPatchedXML = patchedXML
			
			// Hop back to MainActor to launch Pro-Edit
			await MainActor.run {
				self.proEditAction?(instructions, finalPatchedXML)
			}
		}
	}
	
	// MARK: - Dependencies
	
	private let diffParser: DiffParser
	private let fileManager: RepoFileManagerViewModel
	private let aiResponseViewModel: AIResponseViewModel
	
	// MARK: - Storage for Parsed Results
	
	/// Maps the raw input XML (or a hash) to the final list of FileChanges objects
	private var diffResultHistory: [String: [FileChanges]] = [:]
	
	/// Tracks which XML text string was last parsed successfully
	@Published var lastXMLTextKey: String?
	
	/// Maps XML text to query identifiers for consistent reference
	private var xmlToQueryId: [String: UUID] = [:]
	
	/// Caches the parsed content from ChatContentParser
	private var parsedContentCache: [String: (items: [ContentItem], delegateEdits: [DelegateEditItem])] = [:]
	
	// MARK: - Task References (to cancel old tasks when new ones arrive)
	
	private var debouncedParseTask: Task<Void, Never>?
	private var parseChangesTask: Task<Void, Never>?
	private var processChangesTask: Task<Void, Never>?
	private var parseAIResponseTask: Task<Void, Never>?
	
	// An optional closure for performing a UI-level merge action
	var mergeAction: (() -> Void)?
	
	// MARK: - Initialization
	
	init(diffParser: DiffParser, fileManager: RepoFileManagerViewModel, aiResponseViewModel: AIResponseViewModel) {
		let savedFormat = UserDefaults.standard.string(forKey: PromptFormat.userDefaultsKey)
		self.selectedPromptFormat = PromptFormat(rawValue: savedFormat ?? "") ?? .diff
		
		self.diffParser = diffParser
		self.fileManager = fileManager
		self.aiResponseViewModel = aiResponseViewModel
	}
	
	// MARK: - Public Methods
	
	func clearError() {
		errorMessage = nil
	}
	
	func setMergeAction(_ action: @escaping () -> Void) {
		self.mergeAction = action
	}
	
	/**
	 Kicks off XML parsing on a background thread. The main actor sets loading states,
	 while heavy parsing happens off-thread. We store the Task in `parseChangesTask`
	 so we can cancel any previous request if called again.
	
	This method now:
	1. Parses the XML input into ParsedFile objects
	2. Creates FileChanges from the ParsedFile objects
	3. Stores the FileChanges in diffResultHistory for later merging
	4. Updates UI state
	5. Immediately adds the parsed changes to AIResponseViewModel under a new query ID
	 */
	func parseChanges() {
		parseChangesTask?.cancel()
		
		// Early exit if input is empty or only whitespace
		let trimmedInput = xmlInput.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmedInput.isEmpty else {
			parsingStatus = .idle
			isLoading = false
			errorMessage = nil
			fileLoadingWarning = nil
			parsedFiles.removeAll()
			return
		}
		
		isLoading = true
		parsingStatus = .loading
		errorMessage = nil
		fileLoadingWarning = nil
		parsedFiles.removeAll()
		parsedContentCache.removeValue(forKey: xmlInput)
		
		let input = xmlInput
		// Use existing UUID for this XML if available, or create a new one
		let queryId = xmlToQueryId[input] ?? UUID()
		xmlToQueryId[input] = queryId  // Store the mapping
		
		parseChangesTask = Task.detached { [weak self] in
			guard let self = self else { return }
			
			do {
				// Parse XML into ParsedFile objects
				let parsedResult = try await self.diffParser.parse(input)
				
				// Generate FileChanges from ParsedFile objects
				let fileChanges = await DiffProcessingHelper.createFileChanges(
					from: parsedResult,
					fileManager: self.fileManager,
					diffPrecision: self.getDiffPrecision
				)
				
				await MainActor.run {
					// Store results in diffResultHistory
					self.diffResultHistory[input] = fileChanges
					self.lastXMLTextKey = input
					
					// Update UI state
					self.updateAfterParsingSuccess(parsedResult)
					
					// Update generated changes count
					self.generatedChangesCount = fileChanges.reduce(0) { $0 + $1.changes.count }
					
					// Immediately add responses to AIResponseViewModel after parsing
					Task {
						await self.aiResponseViewModel.addResponses(fileChanges, forQueryId: queryId)
						// Now explicitly set this queryId as active
						self.aiResponseViewModel.updateQueryIdentifier(queryId)
					}
				}
			} catch {
				await self.updateAfterParsingFailure(error)
			}
		}
	}
	
	/**
	 Loads the parsed files for visual display with a staggered effect.
	 Typically invoked after `parsedFiles` updates. This remains on the main actor
	 but uses `DispatchQueue.main.asyncAfter` to sequence the file reveals.
	 */
	func loadFilesStaged() {
		guard !parsedFiles.isEmpty else { return }
		visibleFileIds.removeAll()
		
		for (index, file) in parsedFiles.enumerated() {
			DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.2) {
				self.visibleFileIds.insert(file.id)
			}
		}
	}
	
	/**
	 Toggles all changes for a given file. Called on the main actor.
	 */
	func toggleAllChangesForFile(fileId: UUID) {
		guard let fileIndex = parsedFiles.firstIndex(where: { $0.id == fileId }) else {
			return
		}
		
		let currentState = fileSelectionState(for: fileId)
		let newStateIsChecked = (currentState != .checked)
		
		parsedFiles[fileIndex].changes = parsedFiles[fileIndex].changes.map { change in
			var updatedChange = change
			updatedChange.isSelected = newStateIsChecked
			return updatedChange
		}
		
		updateHasSelectedChanges()
	}
	
	/**
	 Toggles the selection state of an individual change in a file.
	 */
	func toggleChangeSelection(fileId: UUID, changeId: UUID) {
		guard let fileIndex = parsedFiles.firstIndex(where: { $0.id == fileId }),
			  let changeIndex = parsedFiles[fileIndex].changes.firstIndex(where: { $0.id == changeId }) else {
			return
		}
		
		parsedFiles[fileIndex].changes[changeIndex].isSelected.toggle()
		updateHasSelectedChanges()
	}
	
	/**
	 Returns the checkbox state for all changes within a single file.
	 */
	func fileSelectionState(for fileId: UUID) -> CheckboxState {
		guard let file = parsedFiles.first(where: { $0.id == fileId }) else {
			return .unchecked
		}
		
		let selectedCount = file.changes.filter { $0.isSelected }.count
		let totalCount = file.changes.count
		
		if selectedCount == totalCount {
			return .checked
		} else if selectedCount == 0 {
			return .unchecked
		} else {
			return .mixed
		}
	}
	
	/**
	 Returns the selection state of a single change.
	 */
	func changeSelectionState(for fileId: UUID, changeId: UUID) -> CheckboxState {
		guard let file = parsedFiles.first(where: { $0.id == fileId }),
			  let change = file.changes.first(where: { $0.id == changeId }) else {
			return .unchecked
		}
		return change.isSelected ? .checked : .unchecked
	}
	
	/**
	 Starts the process that generates `FileChanges` from the currently selected changes.
	 Heavy-lifting is done off the main actor. We store the Task reference so we can cancel
	 any old in-flight job if it's called again.
	
	This method now stores processed changes in diffResultHistory for later merging.
	 */
	func processChanges() {
		processChangesTask?.cancel()
		
		guard !isProcessing else { return }
		isProcessing = true
		errorMessage = nil
		
		let input = xmlInput
		
		processChangesTask = Task {
			let result = await createFileChanges()
			processedChanges = result
			
			// Store processed changes in diffResultHistory
			diffResultHistory[input] = result
			lastXMLTextKey = input
			
			// Update generated changes count
			generatedChangesCount = result.reduce(0) { $0 + $1.changes.count }
			
			isProcessing = false
		}
	}
	
	func retryParsing() {
		// Clear cache entries related to the current XML input
		diffResultHistory.removeValue(forKey: xmlInput)
		xmlToQueryId.removeValue(forKey: xmlInput)
		lastXMLTextKey = nil
		processedChanges.removeAll()
		parsedContentCache.removeValue(forKey: xmlInput)
		
		parseChanges()
	}
	
	func clearXMLInput() {
		// Reset all user-supplied XML and related caches
		xmlInput = ""
		parsedFiles = []
		processedChanges = []
		diffResultHistory.removeAll()
		xmlToQueryId.removeAll()
		lastXMLTextKey = nil
		parsedContentCache.removeAll()
		
		// Reset UI state
		errorMessage = nil
		fileLoadingWarning = nil
		parsingStatus = .idle
		visibleFileIds.removeAll()
		generatedChangesCount = 0
	}
	
	func clearInstructionsText() {
		instructionsText = ""
	}
	
	/**
	Merges the currently parsed changes into AIResponseViewModel.
	Since changes are already added to AIResponseViewModel during parsing,
	this method simply sets those changes active and triggers the merge action.
	*/
	func mergeChanges() {
		guard let key = lastXMLTextKey,
			let changes = diffResultHistory[key],
			let queryId = xmlToQueryId[key],
			!changes.isEmpty else {
			return
		}
		// Execute optional merge action if provided
		self.mergeAction?()
		// Set the active changes using the mapped queryId associated with this XML
		aiResponseViewModel.setActiveChangedFiles(forQueryId: queryId)
	}
	
	/**
	 Debounced parse request. Cancels any in-flight debounced task
	 and starts a new one after a short delay.
	 */
	func debouncedParseChanges(_ input: String) {
		debouncedParseTask?.cancel()
		debouncedParseTask = Task {
			try? await Task.sleep(nanoseconds: 200_000_000) // 200ms
			if !Task.isCancelled {
				xmlInput = input
				parseChanges()
			}
		}
	}
	
	func selectAllChanges() {
		for fileIndex in parsedFiles.indices {
			for changeIndex in parsedFiles[fileIndex].changes.indices {
				parsedFiles[fileIndex].changes[changeIndex].isSelected = true
			}
		}
		updateHasSelectedChanges()
	}
	
	/**
	 Creates file changes by reading from the currently selected `parsedFiles`.
	 Internally calls `DiffProcessingHelper` for concurrency.
	 */
	func createFileChanges() async -> [FileChanges] {
		let currentPrecision = diffPrecision
		let snapshot = parsedFiles
		
		return await DiffProcessingHelper.createFileChanges(
			from: snapshot,
			fileManager: fileManager,
			diffPrecision: currentPrecision
		)
	}
	
	/**
	 Creates file changes by parsing a raw AI response, then generating diffs.
	Also stores the results in diffResultHistory for later merging.
	 */
	func createFileChanges(from response: String) async -> [FileChanges] {
		do {
			// Parse on a background thread via the helper
			let newParsedFiles = try await DiffProcessingHelper.parseAIResponse(response, using: diffParser)
			
			let currentPrecision = diffPrecision
			let result = await DiffProcessingHelper.createFileChanges(
				from: newParsedFiles,
				fileManager: fileManager,
				diffPrecision: currentPrecision
			)
			
			// Store results in diffResultHistory
			diffResultHistory[response] = result
			lastXMLTextKey = response
			
			// Ensure we have a UUID mapped for this response
			if xmlToQueryId[response] == nil {
				xmlToQueryId[response] = UUID()
				print("Reset id")
			}
			
			// Update main-actor state
			self.parsedFiles = newParsedFiles
			self.updateHasSelectedChanges()
			
			if newParsedFiles.isEmpty {
				self.errorMessage = "No valid changes found in the input."
				self.parsingStatus = .failure
			} else {
				self.parsingStatus = .success
				if newParsedFiles.contains(where: { !$0.canBeLoaded }) {
					self.fileLoadingWarning = "Some files cannot be loaded. Please add the folder containing these files to process AI changes correctly."
				}
			}
			
			return result
		} catch {
			self.errorMessage = "Failed to parse changes: \(error.localizedDescription)"
			self.parsingStatus = .failure
			return []
		}
	}
	
	/**
	 A variant that allows passing in `ParsedFile` objects plus optional delegate items.
	 Internally calls `DiffProcessingHelper` for concurrency.
	 */
	func createFileChanges(
		from parsedFiles: [ParsedFile],
		delegateEditItems: [DelegateEditItem] = [],
		overrideContent: String? = nil
	) async -> [FileChanges] {
		let currentPrecision = diffPrecision
		
		do {
			let result = await DiffProcessingHelper.createFileChanges(
				from: parsedFiles,
				fileManager: fileManager,
				diffPrecision: currentPrecision,
				delegateEditItems: delegateEditItems,
				overrideContent: overrideContent
			)
			
			self.parsedFiles = parsedFiles
			self.updateHasSelectedChanges()
			
			if parsedFiles.isEmpty {
				self.errorMessage = "No valid changes found in the input."
				self.parsingStatus = .failure
			} else {
				self.parsingStatus = .success
				if parsedFiles.contains(where: { !$0.canBeLoaded }) {
					self.fileLoadingWarning = "Some files cannot be loaded. Please add the folder containing these files to process AI changes correctly."
				}
			}
			
			return result
		} catch {
			self.errorMessage = "Failed to parse changes: \(error.localizedDescription)"
			self.parsingStatus = .failure
			return []
		}
	}
	
	/**
	 Parses a raw AI response on a background thread, then updates the main-actor state.
	 We store the Task in `parseAIResponseTask` so we can cancel any previous calls
	 before running a new one.
	
	This method now stores the parsed result in diffResultHistory for later merging.
	 */
	func parseAIResponse(_ response: String) {
		parseAIResponseTask?.cancel()
		
		isLoading = true
		parsingStatus = .loading
		errorMessage = nil
		fileLoadingWarning = nil
		parsedFiles.removeAll()
		parsedContentCache.removeValue(forKey: response)
		
		// Use existing UUID for this response if available, or create a new one
		let queryId = xmlToQueryId[response] ?? UUID()
		xmlToQueryId[response] = queryId
		
		parseAIResponseTask = Task.detached { [weak self] in
			guard let self = self else { return }
			
			do {
				// Use DiffProcessingHelper for parsing
				let parsed = try await DiffProcessingHelper.parseAIResponse(
					response,
					using: self.diffParser
				)
				
				// Generate FileChanges from parsed files
				let fileChanges = await DiffProcessingHelper.createFileChanges(
					from: parsed,
					fileManager: self.fileManager,
					diffPrecision: self.getDiffPrecision
				)
				
				await MainActor.run {
					// Store results in diffResultHistory
					self.diffResultHistory[response] = fileChanges
					self.lastXMLTextKey = response
					
					// Update UI state
					self.parsedFiles = parsed
					self.isLoading = false
					self.updateHasSelectedChanges()
					
					if parsed.isEmpty {
						self.errorMessage = "No valid changes found in the input."
						self.parsingStatus = .failure
					} else {
						self.parsingStatus = .success
						if parsed.contains(where: { !$0.canBeLoaded }) {
							self.fileLoadingWarning = "Some files cannot be loaded. Please add the folder containing these files to process AI changes correctly."
						}
					}
				}
			} catch {
				await MainActor.run {
					self.isLoading = false
					self.errorMessage = "Failed to parse changes: \(error.localizedDescription)"
					self.parsingStatus = .failure
				}
			}
		}
	}
	
	// MARK: - Private Actor-Isolated Helpers
	
	/**
	 Updates the `hasSelectedChanges` flag whenever changes are toggled.
	 */
	private func updateHasSelectedChanges() {
		hasSelectedChanges = parsedFiles.contains { file in
			file.changes.contains { $0.isSelected }
		}
	}
	
	/**
	 Called back onto the main actor after an off-main parse operation completes successfully.
	 */
	private func updateAfterParsingSuccess(_ parsed: [ParsedFile]) {
		self.parsedFiles = parsed
		self.isLoading = false
		self.updateHasSelectedChanges()
		
		if parsed.isEmpty {
			self.errorMessage = "No valid changes found in the input."
			self.parsingStatus = .failure
		} else {
			self.parsingStatus = .success
			if parsed.contains(where: { !$0.canBeLoaded }) {
				self.fileLoadingWarning = "Some files cannot be loaded. Please add the folder containing these files to process AI changes correctly."
			}
		}
	}
	
	/**
	 Called back onto the main actor after an off-main parse operation fails.
	 */
	private func updateAfterParsingFailure(_ error: Error) {
		self.isLoading = false
		self.errorMessage = "Failed to parse changes: \(error.localizedDescription)"
		self.parsingStatus = .failure
	}
}

// MARK: - DiffProcessingHelper

struct DiffProcessingHelper {
	
	// Pin-pointed failure coming from diff generation for a single file
	struct DiffProcessingFailure: Identifiable {
		let id = UUID()
		let filePath: String
		let reason: String
	}
	
	// MARK: - PUBLIC helper that also returns failures
	static nonisolated func createFileChangesDetailed(
		from parsedFiles: [ParsedFile],
		fileManager: RepoFileManagerViewModel,
		diffPrecision: DiffPrecision,
		delegateEditItems: [DelegateEditItem] = [],
		overrideContent: String? = nil
	) async -> ([FileChanges], [DiffProcessingFailure]) {
		// Early exit if no parsedFiles
		guard !parsedFiles.isEmpty else { return ([], []) }
		
		return await withTaskGroup(of: (FileChanges?, DiffProcessingFailure?).self) { group in
			for parsedFile in parsedFiles {
				group.addTask {
					// Check for cancellation right away
					if Task.isCancelled { return (nil, nil) }
					
					let delegateItem = delegateEditItems.first { $0.filePath == parsedFile.fileName }
					
					// Safely process the file with detailed error reporting
					return await processFileDetailed(
						parsedFile: parsedFile,
						fileManager: fileManager,
						delegateEditItem: delegateItem,
						overrideContent: overrideContent,
						precision: diffPrecision
					)
				}
			}
			
			// Collect results
			var good: [FileChanges] = []
			var bad: [DiffProcessingFailure] = []
			
			for await result in group {
				if let fileChanges = result.0 {
					good.append(fileChanges)
				}
				if let failure = result.1 {
					bad.append(failure)
				}
			}
			return (good, bad)
		}
	}
	
	// MARK: - Helpers
	
	/// Replaces `path="original"` with `path="corrected"` wherever it appears
	/// inside a `<file …>` tag. Case-insensitive, preserves surrounding whitespace.
	static func rewriteFilePath(in xml: String,
								 from original: String,
								 to corrected: String) -> String {
		//  1️⃣ build a pattern   …path = " ORIGINAL "
		let escaped = NSRegularExpression.escapedPattern(for: original)
		let pattern = #"(<file\s+[^>]*\bpath\s*=\s*")\#(escaped)(")"#
		
		guard let rx = try? NSRegularExpression(pattern: pattern,
												options: [.caseInsensitive])
		else { return xml }
		
		//  2️⃣ replace with        …path = " CORRECTED "
		let full = NSRange(location: 0, length: xml.utf16.count)
		return rx.stringByReplacingMatches(in: xml,
										   options: [],
										   range: full,
										   withTemplate: "$1\(corrected)$2") // <-- $2 is the closing quote
	}
	
	// MARK: - Internal per-file worker that surfaces errors
	private static nonisolated func processFileDetailed(
		parsedFile: ParsedFile,
		fileManager: RepoFileManagerViewModel,
		delegateEditItem: DelegateEditItem?,
		overrideContent: String?,
		precision: DiffPrecision
	) async -> (FileChanges?, DiffProcessingFailure?) {
		// ────────── early-exit guard ──────────
		if Task.isCancelled { return (nil, nil) }
		
		// 1️⃣  Baseline content (unchanged from before)
		let fullPath: String
		let content: String
		do {
			switch parsedFile.action {
			case .create, .delegateEdit:
				fullPath = parsedFile.fileName
				content  = overrideContent ?? ""
				
			case .delete, .modify, .rewrite:
				if Task.isCancelled { return (nil, nil) }
				guard let location = await fileManager.getFileSystemServiceForRelativePath(parsedFile.fileName) else {
					return (nil, DiffProcessingFailure(filePath: parsedFile.fileName,
														reason: "Path not found for file"))
				}
				fullPath = (location.rootPath as NSString).appendingPathComponent(location.correctedPath)
				
				if let override = overrideContent, !override.isEmpty {
					content = override
				} else {
					if Task.isCancelled { return (nil, nil) }
					// Use FileViewModel to get latest content
					if let file = await fileManager.findFile(atPath: location.correctedPath,
					                                         rootIdentifier: location.rootIdentifier) {
						let loaded = await file.latestContent
						guard let loadedContent = loaded else {
							return (nil, DiffProcessingFailure(filePath: parsedFile.fileName,
																reason: "Failed to load file content"))
						}
						content = loadedContent
					} else {
						return (nil, DiffProcessingFailure(filePath: parsedFile.fileName,
															reason: "File not found in hierarchy"))
					}
				}
			}
		} catch {
			return (nil, DiffProcessingFailure(filePath: parsedFile.fileName,
												reason: "Error loading file: \(error.localizedDescription)"))
		}
		
		// 2️⃣  Prep work (unchanged)
		var changes: [FileChange] = []
		var changeContents: [String] = []
		var changeDescriptions: [String] = []
		var firstGenerationError: Error? = nil       // <── keep only the *first* failure
		
		let (lines, _) = String.splitContentPreservingLineEndings(content)
		guard !lines.isEmpty ||
				parsedFile.action == .delete ||
				parsedFile.action == .create else {
			return (nil, DiffProcessingFailure(filePath: parsedFile.fileName,
											   reason: "No lines found in existing content"))
		}
		
		let (indentType, _) = String.detectIndentationTypeFromLines(lines)
		let encodedLines     = lines.map { String.encodeIndentationWithConversion($0, desiredIndentationType: indentType) }
		let processedLineData = encodedLines.map { DiffGenerationUtility.processLine($0, precision: precision) }
		let lineIndexMap     = DiffGenerationUtility.buildLineIndexMapHigh(content: processedLineData)
		
		// ------------------------------------------------------------------
		// 🔄 Per-block cursor map (replaces single `searchCursor`)
		// ------------------------------------------------------------------
		var cursorMap: [String: Int] = [:]     // processed search-block → next start

		// 3️⃣  Generate a diff *per-change*; failures are skipped, successes are kept
		for change in parsedFile.changes where change.isSelected {
			if Task.isCancelled { return (nil, nil) }
			guard let newContent = change.content else { continue }
			
			// Compute key + starting line
			let (searchKey, searchStartLine): (String?, Int) = {
				guard let sb = change.searchBlock, !sb.isEmpty else { return (nil, 0) }
				let processed = sb
					.map { DiffGenerationUtility.processLine($0, precision: precision).removedTagsHigh }
					.joined(separator: "\n")
				return (processed, cursorMap[processed] ?? 0)
			}()
			
			let decoded = newContent
				.map { String.decodeIndentation($0) }
				.joined(separator: "\n")
			changeContents.append(decoded)
			changeDescriptions.append(change.summary)
			
			// NEW: choose the appropriate map
			let effectiveLineIndexMap: [String: [Int]]? =
				(searchStartLine == 0) ? lineIndexMap : nil
			
			let diffChunks: [DiffChunk]
			do {
				diffChunks = try await DiffGenerationUtility.generateDiff(
					fileContent      : encodedLines,
					lineIndexMap     : effectiveLineIndexMap,
					startSelector    : parsedFile.action == .rewrite ? nil : change.startSelector,
					endSelector      : parsedFile.action == .rewrite ? nil : change.endSelector,
					searchBlock      : change.searchBlock,
					newContent       : newContent,
					action           : parsedFile.action,
					diffPrecision    : precision,
					searchStartLine  : searchStartLine
				)
			} catch let err {
				// Capture the *first* diff-generation failure but continue processing the rest
				if firstGenerationError == nil { firstGenerationError = err }
				continue
			}

			// Advance cursor *only for identical (processed) search-blocks*
			if let processedKey = searchKey,
			   let first = diffChunks.first {
				let consumed = change.searchBlock?.count ?? 0
				cursorMap[processedKey] = max(cursorMap[processedKey] ?? 0,
											  first.startLine + consumed)
			}

			for chunk in diffChunks {
				if Task.isCancelled { return (nil, nil) }
				let decodedChunk = chunk.getChunkWithDecodedIndentation()
				changes.append(
					FileChange(id: UUID(),
							startLine: decodedChunk.startLine,
							description: change.summary,
							diffChunk: decodedChunk)
				)
			}
		}
		
		// 4️⃣  Nothing succeeded → treat as full failure
		if changes.isEmpty {
			let reason = firstGenerationError?.localizedDescription ?? "No valid changes could be generated"
			return (nil, DiffProcessingFailure(filePath: parsedFile.fileName, reason: reason))
		}
		
		// 5️⃣  Build ContentItem
		let contentItem: ContentItem
		if let delegate = delegateEditItem {
			contentItem = ContentItem(
				type: .file,
				content: delegate.formattedString(),
				filePath: fullPath,
				action: parsedFile.action.rawValue,
				changes: delegate.changes.map(\.codeSnippet),
				descriptions: delegate.changes.map(\.description)
			)
		} else {
			contentItem = ContentItem(
				type: .file,
				content: content,
				filePath: fullPath,
				action: parsedFile.action.rawValue,
				changes: changeContents,
				descriptions: changeDescriptions
			)
		}
		
		// 6️⃣  Return successes plus (optional) first failure
		let failure: DiffProcessingFailure? = firstGenerationError.map {
			DiffProcessingFailure(filePath: parsedFile.fileName,
								  reason: $0.localizedDescription)
		}
		
		return (
			FileChanges(
				id: UUID(),
				relativePath: fullPath,
				changes: changes,
				action: parsedFile.action,
				contentItem: contentItem
			),
			failure
		)
	}

	
	static nonisolated func parseAIResponse(
		_ response: String,
		using parser: DiffParser
	) async throws -> [ParsedFile] {
		return try await parser.parse(response)
	}
	
	static nonisolated func createFileChanges(
		from parsedFiles: [ParsedFile],
		fileManager: RepoFileManagerViewModel,
		diffPrecision: DiffPrecision,
		delegateEditItems: [DelegateEditItem] = [],
		overrideContent: String? = nil
	) async -> [FileChanges] {
		// Early exit if no parsedFiles
		guard !parsedFiles.isEmpty else { return [] }
		
		return await withTaskGroup(of: FileChanges?.self) { group in
			for parsedFile in parsedFiles {
				group.addTask {
					// Check for cancellation right away
					if Task.isCancelled { return nil }
					
					let delegateItem = delegateEditItems.first { $0.filePath == parsedFile.fileName }
					
					// Safely process the file
					return await processFile(
						parsedFile: parsedFile,
						fileManager: fileManager,
						delegateEditItem: delegateItem,
						overrideContent: overrideContent,
						precision: diffPrecision
					)
				}
			}
			
			// Collect results
			var results: [FileChanges] = []
			for await result in group {
				// If canceled or errored, result can be nil
				if let fileChanges = result {
					results.append(fileChanges)
				}
			}
			return results
		}
	}
	
	/// The actual per-file logic, based on `parsedFile.action`.
	private static nonisolated func processFile(
		parsedFile: ParsedFile,
		fileManager: RepoFileManagerViewModel,
		delegateEditItem: DelegateEditItem?,
		overrideContent: String?,
		precision: DiffPrecision
	) async -> FileChanges? {
		// Check for cancellation right away
		if Task.isCancelled { return nil }
		
		// 1) Load or set the baseline content
		let fullPath: String
		let content: String
		
		switch parsedFile.action {
		case .create, .delegateEdit:
			// For new or delegate edits, use the fileName as full path
			fullPath = parsedFile.fileName
			content = overrideContent ?? ""
			
		case .delete, .modify, .rewrite:
			// Cancellation before disk operations
			if Task.isCancelled { return nil }
			
			guard let location = await fileManager.getFileSystemServiceForRelativePath(parsedFile.fileName) else {
				print("Error: Path not found for \(parsedFile.fileName)")
				return nil
			}
			// Construct full path from root + corrected relative
			fullPath = (location.rootPath as NSString).appendingPathComponent(location.correctedPath)
			
			if let override = overrideContent, !override.isEmpty {
				content = override
			} else {
				if Task.isCancelled { return nil }
				// Use FileViewModel to get latest content
				if let file = await fileManager.findFile(atPath: location.correctedPath,
				                                         rootIdentifier: location.rootIdentifier) {
					let loaded = await file.latestContent
					guard let loadedContent = loaded else {
						print("Error: Failed to load content for \(fullPath)")
						return nil
					}
					content = loadedContent
				} else {
					print("Error: File not found in hierarchy for \(fullPath)")
					return nil
				}
			}
		}
		
		// 2) Prepare for diff generation (unchanged logic)
		var changes: [FileChange] = []
		var changeContents: [String] = []
		var changeDescriptions: [String] = []
		let (lines, _) = String.splitContentPreservingLineEndings(content)
		guard !lines.isEmpty || parsedFile.action == .delete || parsedFile.action == .create else {
			print("Warning: no lines found in existing content for \(fullPath)")
			return FileChanges(
				id: UUID(),
				relativePath: fullPath,
				changes: [],
				action: parsedFile.action,
				contentItem: ContentItem(
					type: .file,
					content: content,
					filePath: fullPath,
					action: parsedFile.action.rawValue,
					changes: [],
					descriptions: []
				)
			)
		}
		let (indentType, _) = String.detectIndentationTypeFromLines(lines)
		let encodedLines = lines.map { String.encodeIndentationWithConversion($0, desiredIndentationType: indentType) }
		let processedLineData = encodedLines.map { DiffGenerationUtility.processLine($0, precision: precision) }
		let lineIndexMap = DiffGenerationUtility.buildLineIndexMapHigh(content: processedLineData)
		
		// ------------------------------------------------------------------
		// 🔄 Search-cursor logic
		// Instead of a single `searchCursor`, we now keep a dictionary that
		// remembers, *per unique processed search-block*, where the next search
		// should start.  Unseen (unique) blocks start at 0 → unrestricted scan.
		// ------------------------------------------------------------------
		var cursorMap: [String: Int] = [:]          // key → next start line

		// 3) Generate diffs for each selected change
		for change in parsedFile.changes where change.isSelected {
			if Task.isCancelled { return nil }
			guard let newContent = change.content else {
				//print("Warning: Skipping change with no content for \(fullPath)")
				continue
			}
			
			// ── Build a key that represents the *processed* search-block ──
			let (searchKey, searchStartLine): (String?, Int) = {
				guard let sb = change.searchBlock, !sb.isEmpty else { return (nil, 0) }

				// Process each line exactly the same way `generateDiffWithSearchBlock`
				// will later do, so that logically-identical blocks collapse to
				// the same key (indent tags already stripped via `removedTagsHigh`).
				let processed = sb
					.map { DiffGenerationUtility.processLine($0, precision: precision).removedTagsHigh }
					.joined(separator: "\n")
				let nextStart = cursorMap[processed] ?? 0
				return (processed, nextStart)
			}()
			
			let decoded = newContent.map { String.decodeIndentation($0) }.joined(separator: "\n")
			changeContents.append(decoded)
			changeDescriptions.append(change.summary)
			
			// NEW: choose the appropriate map
			let effectiveLineIndexMap: [String: [Int]]? =
				(searchStartLine == 0) ? lineIndexMap : nil
			
			// 👉 Pass the *block-specific* start position
			let diffChunks: [DiffChunk]
			do {
				diffChunks = try await DiffGenerationUtility.generateDiff(
					fileContent      : encodedLines,
					lineIndexMap     : effectiveLineIndexMap,
					startSelector    : parsedFile.action == .rewrite ? nil : change.startSelector,
					endSelector      : parsedFile.action == .rewrite ? nil : change.endSelector,
					searchBlock      : change.searchBlock,
					newContent       : newContent,
					action           : parsedFile.action,
					diffPrecision    : precision,
					searchStartLine  : searchStartLine
				)
			} catch {
				print("Error generating diff for \(fullPath): \(error)")
				continue
			}

			// After a successful diff we advance the cursor *only for this key*
			if let processedKey = searchKey,
			   let first = diffChunks.first {
				let consumed = change.searchBlock?.count ?? 0
				cursorMap[processedKey] = max(cursorMap[processedKey] ?? 0,
											  first.startLine + consumed)
			}

			for chunk in diffChunks {
				if Task.isCancelled { return nil }
				let decodedChunk = chunk.getChunkWithDecodedIndentation()
				let fileChange = FileChange(
					id: UUID(),
					startLine: decodedChunk.startLine,
					description: change.summary,
					diffChunk: decodedChunk
				)
				changes.append(fileChange)
			}
		}
		if Task.isCancelled { return nil }
		
		// 4) Build the final contentItem
		let contentItem: ContentItem
		if let delegate = delegateEditItem {
			contentItem = ContentItem(
				type: .file,
				content: delegate.formattedString(),
				filePath: fullPath,
				action: parsedFile.action.rawValue,
				changes: delegate.changes.map { $0.codeSnippet },
				descriptions: delegate.changes.map { $0.description }
			)
		} else {
			contentItem = ContentItem(
				type: .file,
				content: content,
				filePath: fullPath,
				action: parsedFile.action.rawValue,
				changes: changeContents,
				descriptions: changeDescriptions
			)
		}
		
		// 5) Final result with fullPath
		return FileChanges(
			id: UUID(),
			relativePath: fullPath,
			changes: changes,
			action: parsedFile.action,
			contentItem: contentItem
		)
	}
}
