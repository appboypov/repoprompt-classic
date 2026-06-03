import Foundation
import Combine

@MainActor
class AIResponseViewModel: ObservableObject {
	@Published var selectedFileId: UUID?
	@Published var selectedChangeId: UUID?
	@Published var rawOutput: String = ""
	@Published var overallSummary: String?
	@Published private(set) var isFinalized: Bool = false
	@Published var queryIdentifier: UUID?
	@Published private(set) var objectWillChangeCount = 0
	@Published private(set) var isParsingInProgress = false
	
	let didExitAIQuery = PassthroughSubject<Void, Never>()
	let changeCountDidUpdate = PassthroughSubject<UUID, Never>() // Sends messageId when change count updates
	
	private var changedFileHistory: [UUID: [ChangedFile]] = [:]
	
	// Removed the old private serial dispatch queue
	// private let queue = DispatchQueue(label: "com.repoprompt.airesponseviewmodel")
	
	// Keep track of local file changes before they turn into ChangedFile objects
	private var fileChangesBuffer: [String: FileChanges] = [:]
	
	// We no longer keep an explicit updateTask for bridging concurrency
	// private var updateTask: Task<Void, Never>?
	
	@Published private(set) var responses: [ChangedFile] = []
	
	let fileManager: RepoFileManagerViewModel
	
	init(fileManager: RepoFileManagerViewModel) {
		self.fileManager = fileManager
	}
	
	var selectedResponse: ChangedFile? {
		responses.first { $0.id == selectedFileId }
	}
	
	// MARK: - Public updating methods
	
	func updateRawOutput(_ newOutput: String) {
		rawOutput = newOutput
	}
	
	func updateResponses(_ newResponses: [ChangedFile]) {
		self.responses = newResponses
		self.selectFirstFileIfNeeded()
	}
	
	func updateOverallSummary(_ summary: String?) {
		overallSummary = summary
	}
	
	// MARK: - Checking for changed files
	
	func hasChangedFiles(for messageId: UUID) -> Bool {
		guard let list = changedFileHistory[messageId] else { return false }
		return !list.isEmpty
	}
	
	func getChangedFiles(forQueryId queryId: UUID) -> [ChangedFile]? {
		changedFileHistory[queryId]
	}
	
	func setFinalized() {
		isFinalized = true
	}
	
	// MARK: - Input monitoring logic
	private var inputMonitor: InputMonitor?
	
	func initializeInputMonitor() {
		guard inputMonitor == nil else { return }
		inputMonitor = InputMonitor(
			onMouseDown: { _, _ in },
			onMouseDragged: { _ in },
			onDoubleClick: {},
			onMouseUp: {}
		)
		inputMonitor?.startMonitoring()
	}
	
	func updateInputHandlers(
		viewId: UUID,
		onMouseDown: @escaping (NSPoint, Int) -> Void,
		onMouseDragged: @escaping (NSPoint) -> Void,
		onDoubleClick: @escaping () -> Void,
		onMouseUp: @escaping () -> Void
	) {
		inputMonitor?.updateHandlers(
			viewId: viewId,
			onMouseDown: onMouseDown,
			onMouseDragged: onMouseDragged,
			onDoubleClick: onDoubleClick,
			onMouseUp: onMouseUp
		)
	}
	
	func clearInputHandlers(for viewId: UUID) {
		inputMonitor?.clearHandlers(for: viewId)
	}
	
	func stopInputMonitoring() {
		inputMonitor?.stopMonitoring()
		inputMonitor = nil
	}
	
	// MARK: - Processing file changes
	
	private func resolveOverride(
		for fileChange: FileChanges,
		from dict: [String: String]?
	) -> String? {
		guard let raw = dict?[fileChange.path] else { return nil }
		
		// If it’s only whitespace/newlines, treat as “no match”.
		if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return nil
		}
		return raw      // return the untouched value
	}
	
	private func processFileChanges(
		_ changes: [(String, FileChanges)],
		overrideContents: [String: String]? = nil
	) async throws -> [ChangedFile] {
		try await withThrowingTaskGroup(of: ChangedFile?.self) { group in
			for (_, fc) in changes {
				group.addTask {
					await self.createChangedFile(
						from: fc,
						overrideContent: self.resolveOverride(for: fc, from: overrideContents)
					)
				}
			}
			var result: [ChangedFile] = []
			for try await item in group.compactMap({ $0 }) {
				result.append(item)
			}
			return result
		}
	}
	
	/// This function replaces the old `updateResponses(_ newFileChanges: [FileChanges])` that used
	/// a serial queue + `withCheckedContinuation`. Now it simply runs on the MainActor, modifies
	/// `fileChangesBuffer`, and calls `processFileChanges(...)` with Swift concurrency.
	func updateResponses(
		_ newFileChanges: [FileChanges],
		overrideContents: [String: String]? = nil
	) async {
		var newEntries: [(String, FileChanges)] = []
		
		for fc in newFileChanges where fileChangesBuffer[fc.path] == nil {
			fileChangesBuffer[fc.path] = fc
			newEntries.append((fc.path, fc))
		}
		guard !newEntries.isEmpty else { return }
		
		do {
			let newResponses = try await processFileChanges(
				newEntries,
				overrideContents: overrideContents        // ⬅️ pass through
			)
			responses.append(contentsOf: newResponses)
			selectFirstFileIfNeeded()
		} catch {
			print("Error processing file changes: \(error)")
		}
	}
	
	/// Called once we're sure no more file changes are incoming and we want
	/// to finalize everything (e.g. build a final UI, etc).
	func finalizeResponses() async {
		// If you still need to guard for concurrency collisions, keep a flag:
		guard !isParsingInProgress else {
			print("Finalize called while another finalize is in progress; skipping.")
			return
		}
		isParsingInProgress = true
		
		// Mark as finalized
		isFinalized = true
		
		do {
			// Figure out which changes in `fileChangesBuffer` never got turned into a `ChangedFile`
			let missingChanges = fileChangesBuffer.filter { relativePath, _ in
				!responses.contains { $0.relativePath == relativePath }
			}
			let missingResponses = try await self.processFileChanges(Array(missingChanges))
			responses.append(contentsOf: missingResponses)
			selectFirstFileIfNeeded()
		} catch {
			print("Error finalizing responses: \(error)")
		}
		
		isParsingInProgress = false
	}
	
	func addResponses(
		_ fileChanges: [FileChanges],
		forQueryId queryId: UUID,
		overrideContents: [String: String]? = nil
	) async {
		// Pre-resolve all overrides outside the task group to avoid self capture
		var preResolvedOverrides: [UUID: String] = [:]
		for fc in fileChanges {
			if let override = self.resolveOverride(for: fc, from: overrideContents),
			!override.isEmpty {
				preResolvedOverrides[fc.id] = override
			}
		}
		
		let newChangedFiles: [ChangedFile] = await withTaskGroup(of: ChangedFile?.self) { group in
			for fc in fileChanges {
				let overrideContent = preResolvedOverrides[fc.id]
				group.addTask {
					await self.createChangedFile(
						from: fc,
						overrideContent: overrideContent
					)
				}
			}
			var result: [ChangedFile] = []
			for await item in group.compactMap({ $0 }) {
				result.append(item)
			}
			return result
		}
		changedFileHistory[queryId] = newChangedFiles
	}
	
	func setActiveChangedFiles(forQueryId queryId: UUID, resetState: Bool = false) {
		if let changedFiles = self.changedFileHistory[queryId] {
			if resetState {
				// Revert all changes and reset the state
				for file in changedFiles {
					file.revertAllChanges()
				}
			}
			self.responses = changedFiles
			self.selectFirstFileIfNeeded()
		}
	}
	
	/// In a purely `@MainActor` world, we can just return `fileChangesBuffer`.
	func getFileChangesBuffer() -> [String: FileChanges] {
		fileChangesBuffer
	}
	
	// MARK: - Creating ChangedFile objects
	
	/// Unified function to handle both normal creation and optional override content
	private func createChangedFile(
		from fileChanges: FileChanges,
		overrideContent: String? = nil
	) async -> ChangedFile? {
		do {
			let content: String
			let fullPath: String
			
			let useOverride = overrideContent?.isEmpty == false
			
			if useOverride {
				content  = overrideContent!                      // ← always use the captured snapshot
				fullPath = fileChanges.path
			} else if fileChanges.action == .create || fileChanges.action == .delegateEdit {
				// New file or delegate edit: no existing content
				content = ""
				fullPath = fileChanges.path // treat this as full path
			} else {
				// For .delete, .modify, and .rewrite
				guard let resolved = await fileManager.resolveFileForAIResponse(fileChanges.path) else {
					throw FileManagerError.fileSystemServiceNotFound
				}
				fullPath = resolved.fullPath
				content = resolved.content
				
				return await ChangedFile.build(
					relativePath: fullPath,
					originalText: content,
					changes: fileChanges.changes,
					action: fileChanges.action,
					contentItem: fileChanges.contentItem
				)
			}
			
			// For .create/.delegateEdit or override:
			return await ChangedFile.build(
				relativePath: fullPath,
				originalText: content,
				changes: fileChanges.changes,
				action: fileChanges.action,
				contentItem: fileChanges.contentItem
			)
			
		} catch {
			print("Error processing file changes for \(fileChanges.path): \(error.localizedDescription)")
			return nil
		}
	}
	
	// MARK: - produceChangedFileStates()
	
	func produceChangedFileStates() -> [ChangedFileState] {
		responses.map { $0.makeStateSnapshot() }
	}
	
	// MARK: – Persisted-state restore
	@MainActor
	func applyChangedFileStates(_ states: [ChangedFileState], forQueryId qid: UUID) async {
		guard let changed = getChangedFiles(forQueryId: qid) else { return }

		for state in states {
			if let cf = changed.first(where: { $0.id == state.id }) ??
						changed.first(where: { $0.relativePath == state.relativePath }) {
				// The file object now owns the whole reconciliation process
				await cf.applySavedState(state)
			}
		}
	}
	
	// MARK: - Selection and navigation
	
	func selectFirstFileIfNeeded() {
		guard let firstFile = responses.first else { return }
		self.selectFileAndNavigateToFirstChange(firstFile.id)
	}
	
	func selectFileAndNavigateToFirstChange(_ fileId: UUID) {
		if selectedFileId != fileId {
			selectedFileId = fileId
		}

		guard let selectedFile = responses.first(where: { $0.id == fileId }) else {
			return
		}

		let nextChangeId: UUID? = {
			if let firstChangeIndex = selectedFile.getFirstPendingOrOverallChangeIndex() {
				return selectedFile.changes[firstChangeIndex].id
			} else {
				return nil
			}
		}()

		if selectedChangeId != nextChangeId {
			selectedChangeId = nextChangeId
		}
	}
	
	// MARK: - Accept/reject/undo changes
	
	private(set) var changeHistory: [(UUID, UUID, Bool)] = [] // (fileId, changeId, wasAccepted)
	private(set) var redoStack: [(UUID, UUID, Bool)] = []
	
	func acceptChange(_ change: FileChange, in response: ChangedFile) async {
		guard !response.appliedChanges.contains(change.id) else { return }
		await response.applyChange(change)
		changeHistory.append((response.id, change.id, true))
		redoStack.removeAll()
		selectedChangeId = change.id
		objectWillChangeCount += 1
		
		// Notify about change count update
		if let queryId = queryIdentifier {
			changeCountDidUpdate.send(queryId)
		}
	}
	
	func rejectChange(_ change: FileChange, in response: ChangedFile) {
		response.rejectChange(change)
		changeHistory.append((response.id, change.id, false))
		redoStack.removeAll()
		selectedChangeId = change.id
		objectWillChangeCount += 1
		
		// Notify about change count update
		if let queryId = queryIdentifier {
			changeCountDidUpdate.send(queryId)
		}
	}
	
	func undoRejectChange(_ change: FileChange, in response: ChangedFile) {
		response.undoRejectChange(change)
		objectWillChangeCount += 1
		
		// Notify about change count update
		if let queryId = queryIdentifier {
			changeCountDidUpdate.send(queryId)
		}
	}
	
	// MARK: - Dedicated accept/reject + save methods for UI
	
	@MainActor
	func acceptChangeAndSave(_ change: FileChange, in response: ChangedFile) async {
		await acceptChange(change, in: response)
		do {
			try await saveChanges(for: response)
		} catch {
			print("Error saving after accepting change: \(error)")
		}
	}
	
	@MainActor
	func rejectChangeAndSave(_ change: FileChange, in response: ChangedFile) async {
		rejectChange(change, in: response)
		do {
			try await saveChanges(for: response)
		} catch {
			print("Error saving after rejecting change: \(error)")
		}
	}
	
	@MainActor
	func undoRejectChangeAndSave(_ change: FileChange, in response: ChangedFile) async {
		undoRejectChange(change, in: response)
		do {
			try await saveChanges(for: response)
		} catch {
			print("Error saving after undoing reject: \(error)")
		}
	}
	
	@MainActor
	func acceptAllChangesAndSave(for response: ChangedFile) async {
		await response.applyAllPendingChanges()
		do {
			try await saveChanges(for: response)
		} catch {
			print("Error saving after accepting all changes: \(error)")
		}
		objectWillChangeCount += 1
		
		// Notify about change count update
		if let queryId = queryIdentifier {
			changeCountDidUpdate.send(queryId)
		}
	}
	
	@MainActor
	func rejectAllChangesAndSave(for response: ChangedFile) async {
		for change in response.changes {
			response.rejectChange(change)
		}
		do {
			try await saveChanges(for: response)
		} catch {
			print("Error saving after rejecting all changes: \(error)")
		}
		objectWillChangeCount += 1
		
		// Notify about change count update
		if let queryId = queryIdentifier {
			changeCountDidUpdate.send(queryId)
		}
	}
	
	@MainActor
	func undoLastChangeAndSave() async {
		guard let (fileId, changeId, wasAccepted) = changeHistory.popLast(),
			  let file = responses.first(where: { $0.id == fileId }),
			  let change = file.changes.first(where: { $0.id == changeId })
		else { return }
		
		if wasAccepted {
			await file.revertChange(change)
		} else {
			file.undoRejectChange(change)
		}
		
		redoStack.append((fileId, changeId, wasAccepted))
		selectedChangeId = changeId
		objectWillChangeCount += 1
		
		do {
			try await saveChanges(for: file)
		} catch {
			print("Error saving after undo: \(error)")
		}
	}
	
	@MainActor
	func redoLastChangeAndSave() async {
		guard let (fileId, changeId, wasAccepted) = redoStack.popLast(),
			  let file = responses.first(where: { $0.id == fileId }),
			  let change = file.changes.first(where: { $0.id == changeId })
		else { return }
		
		if wasAccepted {
			await file.applyChange(change)
		} else {
			file.rejectChange(change)
		}
		
		changeHistory.append((fileId, changeId, wasAccepted))
		selectedChangeId = changeId
		objectWillChangeCount += 1
		
		do {
			try await saveChanges(for: file)
		} catch {
			print("Error saving after redo: \(error)")
		}
	}
	
	func undoChange(_ change: FileChange, in response: ChangedFile) {
		if response.appliedChanges.contains(change.id) {
			response.revertChange(change)
		} else if response.rejectedChanges.contains(change.id) {
			response.undoRejectChange(change)
		}
		
		if let lastChange = changeHistory.last, lastChange.0 == response.id && lastChange.1 == change.id {
			let (fileId, changeId, wasAccepted) = changeHistory.removeLast()
			redoStack.append((fileId, changeId, wasAccepted))
		}
		selectedChangeId = nil
		objectWillChangeCount += 1
		
		// Notify about change count update
		if let queryId = queryIdentifier {
			changeCountDidUpdate.send(queryId)
		}
	}
	
	func undoLastChange() {
		guard let (fileId, changeId, wasAccepted) = changeHistory.popLast(),
			  let file = responses.first(where: { $0.id == fileId }),
			  let change = file.changes.first(where: { $0.id == changeId })
		else { return }
		
		if wasAccepted {
			file.revertChange(change)
		} else {
			file.undoRejectChange(change)
		}
		
		redoStack.append((fileId, changeId, wasAccepted))
		selectedChangeId = changeId
		objectWillChangeCount += 1
	}
	
	func redoLastChange() async {
		guard let (fileId, changeId, wasAccepted) = redoStack.popLast(),
			  let file = responses.first(where: { $0.id == fileId }),
			  let change = file.changes.first(where: { $0.id == changeId })
		else { return }
		
		if wasAccepted {
			await file.applyChange(change)
		} else {
			file.rejectChange(change)
		}
		
		changeHistory.append((fileId, changeId, wasAccepted))
		selectedChangeId = changeId
		objectWillChangeCount += 1
	}

// MARK: - Bulk actions per AI message
/// Accepts every pending change belonging to the specified AI response
/// and persists them to disk.
@MainActor
func acceptAllAndSave(forQueryId queryId: UUID) async {
	guard let files = changedFileHistory[queryId] else { return }
	for file in files {
		await acceptAllAndSave(for: file)
	}
	
	// Notify about change count update for all files
	changeCountDidUpdate.send(queryId)
}

/// Restores every file of the specified AI response back to its
/// original checkpoint and saves the pristine state.
@MainActor
func restoreCheckpoint(forQueryId queryId: UUID) async {
	guard let files = changedFileHistory[queryId] else { return }
	for file in files {
		await resetAllAndSave(for: file)
	}
	
	// Notify about change count update for all files
	changeCountDidUpdate.send(queryId)
}

	// MARK: - Accept/reject/undo all changes + saving
	
	func acceptAllAndSave(for response: ChangedFile) async {
		// Only accept pending + non-rejected changes
		let toAccept = response.changes.filter {
			!response.appliedChanges.contains($0.id) &&
			!response.rejectedChanges.contains($0.id)
		}
		guard !toAccept.isEmpty else { return }

		for change in toAccept {
			await acceptChange(change, in: response)
		}

		do {
			try await saveChanges(for: response)
		} catch {
			print("Error saving changes for \(response.relativePath): \(error)")
		}

		objectWillChangeCount += 1
	}
	
	func rejectAllAndSave(for response: ChangedFile) async {
		response.resetToOriginalState()
		for change in response.changes {
			rejectChange(change, in: response)
		}
		do {
			try await saveChanges(for: response)
		} catch {
			print("Error saving changes for \(response.relativePath): \(error)")
		}
		objectWillChangeCount += 1
	}
	
	func resetAllAndSave(for response: ChangedFile) async {
		do {
			// First remove file system modifications
			try await cleanupFileState(for: response)
			// Reset the response state
			response.resetToOriginalState()
			// Save the reset state
			try await saveChanges(for: response)
		} catch {
			print("Error resetting changes for \(response.relativePath): \(error)")
		}
	}
	
	func resetAllAndSave() async {
		for response in responses {
			do {
				try await cleanupFileState(for: response)
				response.resetToOriginalState()
				try await saveChanges(for: response)
			} catch {
				print("Error resetting changes for \(response.relativePath): \(error)")
			}
		}
		
		// Force-update everything
		self.responses = self.responses
		objectWillChangeCount += 1
	}
	
	func updateFileContent(for responseId: UUID, content: String) {
		if let index = responses.firstIndex(where: { $0.id == responseId }) {
			responses[index].updateContent(content)
		}
	}
	
	func updateQueryIdentifier(_ newIdentifier: UUID) {
		queryIdentifier = newIdentifier
		isFinalized = false
	}
	
	// MARK: - Clearing
	
	func clearResponses() {
		fileChangesBuffer.removeAll()
		responses.removeAll()
		changeHistory.removeAll()
		redoStack.removeAll()
		selectedFileId = nil
		selectedChangeId = nil
		rawOutput = ""
		overallSummary = nil
		isFinalized = false
		objectWillChangeCount = 0
	}
	
	func clearResponses(forQueryId queryId: UUID) {
		changedFileHistory[queryId]?.removeAll()
	}
	
	func clearHistory() {
		changedFileHistory.removeAll()
		clearResponses()
	}
	
	func resetState() {
		clearResponses()
		clearHistory()
		queryIdentifier = nil
		// No need to cancel tasks if we aren't storing them
	}
	
	func notifyExit() {
		didExitAIQuery.send(())
	}
	
	func saveChanges(for response: ChangedFile) async throws {
		let currentContent = response.getContentForSaving()
		
		if !response.appliedChanges.isEmpty {
			// If changes were actually applied, do the real action
			switch response.fileAction {
			case .delegateEdit:
				// No-op for delegated edits
				break
			case .create:
				_ = try await fileManager.createFile(
					atRelativePath: response.relativePath,
					content: currentContent
				)
			case .delete:
				try await fileManager.deleteFile(
					atRelativePath: response.relativePath
				)
			case .rewrite, .modify:
				try await fileManager.editFile(
					atRelativePath: response.relativePath,
					newContent: currentContent
				)
			}
		} else {
			// No changes applied — revert or remove
			switch response.fileAction {
			case .create:
				// For create with no applied changes, remove the file if it exists
				try? await fileManager.deleteFile(atRelativePath: response.relativePath)
				
			case .delete:
				// For delete with no applied changes, restore content if needed
				if !currentContent.isEmpty {
					_ = try await fileManager.createFile(
						atRelativePath: response.relativePath,
						content: currentContent
					)
				}
			default:
				// revert to the original
				try await fileManager.editFile(
					atRelativePath: response.relativePath,
					newContent: currentContent
				)
			}
		}
		
		response.markAsSaved()
	}
	
	func acceptAllAndSave() async {
		for response in responses {
			await acceptAllAndSave(for: response)
		}
	}
	
	func cleanupFileState(for response: ChangedFile) async throws {
		switch response.fileAction {
		case .create:
			try? await fileManager.deleteFile(atRelativePath: response.relativePath)
		case .delete:
			if !response.originalFileContent.isEmpty {
				_ = try await fileManager.createFile(
					atRelativePath: response.relativePath,
					content: response.originalFileContent
				)
			}
		default:
			break
		}
	}
}

extension Notification.Name {
	static let refreshFilePreview = Notification.Name("refreshFilePreview")
}
