// ChangedFile.swift
import Foundation
import SwiftUI

class ChangedFile: Identifiable, ObservableObject, Equatable {
	let id = UUID()
	@Published private(set) var relativePath: String
	@Published private(set) var changes: [FileChange]
	@Published private(set) var appliedChanges: Set<UUID> = []
	@Published private(set) var rejectedChanges: Set<UUID> = []
	@Published private(set) var proposedChangeCount: Int
	@Published private(set) var acceptedChangeCount: Int
	@Published var isSaved: Bool = false
	var lastScrollPosition: CGFloat = 0
	@Published private(set) var fileContent: [String]
	@Published private(set) var originalFileContent: String
	@Published private(set) var contentItem: ContentItem? = nil
	
	private var changeManager: ChangeManager
	private(set) var lineEnding: String
	private var _applier: ChangeApplier?
	private var applier: ChangeApplier {
		if _applier == nil {
			_applier = ChangeApplier(manager: changeManager)
		}
		return _applier!
	}
	
	@Published private(set) var fileAction: FileAction
	
	// MARK: - Preview Safety
	
	/// Whether this file is an SVG (which may require special preview handling to avoid crashes).
	var isSvg: Bool {
		let ext = (relativePath as NSString).pathExtension.lowercased()
		return ext == "svg" || ext == "svgz"
	}
	
	/// Whether this SVG file is considered high-risk for preview (large content).
	/// Shows a warning banner but content is still rendered.
	var isSvgHighRisk: Bool {
		guard isSvg else { return false }
		return contentByteCount > 512_000 // 512 KB threshold
	}
	
	/// Whether the diff view should be completely disabled for this file.
	/// Applies to any file over 5MB to prevent UI hangs.
	var isPreviewDisabled: Bool {
		return contentByteCount > 5_000_000 // 5 MB threshold
	}
	
	/// Byte count of the current file content.
	private var contentByteCount: Int {
		fileContent.joined(separator: lineEnding).utf8.count
	}
	
	init(relativePath: String, fileContent: String, changes: [FileChange], fileAction: FileAction, contentItem: ContentItem? = nil) {
		self.relativePath = relativePath
		let sortedChanges = changes.sorted(by: { $0.startLine < $1.startLine })
		self.changes = sortedChanges
		self.proposedChangeCount = changes.count
		self.acceptedChangeCount = 0
		self.fileAction = fileAction
		
		let (contentLines, lineEnding) = String.splitContentPreservingLineEndings(fileContent)
		let hadTrailingNewline = fileContent.hasSuffix(lineEnding)
		self.fileContent = contentLines
		self.originalFileContent = fileContent
		self.lineEnding = lineEnding
		self.changeManager = ChangeManager(fileContent: contentLines,
									changes: sortedChanges,
									lineEnding: lineEnding,
									fileAction: fileAction,
									hadTrailingNewline: hadTrailingNewline)
		self.contentItem = contentItem
	}
	
	// Internal initializer for async factory
	init(relativePath: String,
		 fileContent: String,
		 changes: [FileChange],
		 fileAction: FileAction,
		 contentItem: ContentItem?,
		 preparedLines: [String],
		 preparedManager: ChangeManager,
		 preparedLE: String) {
		self.relativePath = relativePath
		let sortedChanges = changes.sorted(by: { $0.startLine < $1.startLine })
		self.changes = sortedChanges
		self.proposedChangeCount = changes.count
		self.acceptedChangeCount = 0
		self.fileAction = fileAction
		self.fileContent = preparedLines
		self.originalFileContent = fileContent
		self.lineEnding = preparedLE
		self.changeManager = preparedManager
		self.contentItem = contentItem
	}
	
	var fullContent: String {
		changeManager.getUpdatedContent()
	}
	
	/*
	@available(*, deprecated, message: "Use async version instead")
	func applyChange(_ change: FileChange) {
		Task { @MainActor in
			await applyChange(change)
		}
	}
	*/
	
	func revertChange(_ change: FileChange) {
		guard appliedChanges.contains(change.id) else { return }
		
		// Capture the currently applied changes before removing the current change
		let appliedChangeIds = appliedChanges
		
		// Remove the change from appliedChanges
		appliedChanges.remove(change.id)
		acceptedChangeCount -= 1 // Decrement the accepted change count
		isSaved = false
		
		// Reset fileContent to original content and re-initialize changeManager
		resetFileContentToOriginal()
		
		// Reapply all other applied changes in order
		let appliedChangesInOrder = changes.filter { appliedChangeIds.contains($0.id) && $0.id != change.id }
		for changeToApply in appliedChangesInOrder {
			let result = changeManager.applyChange(changeToApply)
			if let error = result.error {
				print("Error reapplying change: \(error)")
				// Handle error appropriately
				return
			}
			fileContent = result.updatedContent
			appliedChanges.insert(changeToApply.id)
		}
		
		// Update acceptedChangeCount to match the number of applied changes
		acceptedChangeCount = appliedChanges.count
		
		// Update changes with adjusted positions
		self.changes = changeManager.getChanges()
		
		objectWillChange.send()
	}
	
	private func resetFileContentToOriginal() {
		let (originalLines, originalLineEnding) = String.splitContentPreservingLineEndings(originalFileContent)
		fileContent = originalLines
		lineEnding = originalLineEnding
		let hadTrailingNewline = originalFileContent.hasSuffix(originalLineEnding)
		
		// Reset each FileChange object to use the original startLine from its DiffChunk
		self.changes = self.changes.map { change in
			FileChange(
				id: change.id,
				startLine: change.diffChunk.startLine,  // Use the original startLine from DiffChunk
				description: change.description,
				diffChunk: change.diffChunk
			)
		}
		
		// Re-initialize ChangeManager with reset changes
		self.changeManager = ChangeManager(
			fileContent: self.fileContent,
			changes: self.changes,
			lineEnding: self.lineEnding,
			fileAction: self.fileAction,
			hadTrailingNewline: hadTrailingNewline
		)
		
		// Reset the applier to use the new changeManager
		_applier = nil
		
		appliedChanges.removeAll()
		rejectedChanges.removeAll()
		acceptedChangeCount = 0
		isSaved = false
		
		// Update changes with adjusted positions
		self.changes = changeManager.getChanges()
	}
	
	func rejectChange(_ change: FileChange) {
		guard !rejectedChanges.contains(change.id) else { return }
		
		rejectedChanges.insert(change.id)
		appliedChanges.remove(change.id)  // In case it was previously applied
		acceptedChangeCount = appliedChanges.count
	}
	
	func undoRejectChange(_ change: FileChange) {
		rejectedChanges.remove(change.id)
	}
	
	func markAsSaved() {
		isSaved = true
	}
	
	func updateContent(_ newContent: String) {
		let (newContentLines, newLineEnding) = String.splitContentPreservingLineEndings(newContent)
		let hadTrailingNewline = newContent.hasSuffix(newLineEnding)
		fileContent = newContentLines
		lineEnding = newLineEnding
		
		// Re-initialize ChangeManager with new content
		changeManager = ChangeManager(fileContent: newContentLines,
								changes: changes,
								lineEnding: newLineEnding,
								fileAction: fileAction,
								hadTrailingNewline: hadTrailingNewline)
		appliedChanges.removeAll()
		rejectedChanges.removeAll()
		acceptedChangeCount = 0
		isSaved = false
		
		// Update changes with adjusted positions
		self.changes = changeManager.getChanges()
		
		objectWillChange.send()
	}
	
	// MARK: - Async change application methods
	
	@MainActor
	func applyChange(_ change: FileChange) async {
		guard !appliedChanges.contains(change.id) else { return }
		
		let result = await applier.apply(change)
		if let e = result.err { 
			print("Error applying change: \(e)")
			return 
		}
		
		// Single UI update
		fileContent = result.updated
		appliedChanges.formUnion(result.applied)
		rejectedChanges.remove(change.id)
		acceptedChangeCount = appliedChanges.count
		changes = changeManager.getChanges()
		isSaved = false
	}
	
	@MainActor
	func applyAllPendingChanges() async {
		// Reset to original state first
		resetToOriginalState()
		
		// Apply all changes in order
		let r = await applier.apply(changes)
		fileContent = r.updated
		appliedChanges = r.newlyApplied
		acceptedChangeCount = appliedChanges.count
		changes = changeManager.getChanges()
		isSaved = false
		
		// Log any failures
		if !r.failedIDs.isEmpty {
			print("Failed to apply changes: \(r.failedIDs)")
		}
	}
	
	@MainActor
	func revertChange(_ change: FileChange) async {
		guard appliedChanges.contains(change.id) else { return }
		
		let result = await applier.revert(change)
		if let e = result.err {
			print("Error reverting change: \(e)")
			return
		}
		
		fileContent = result.updated
		appliedChanges = result.applied
		acceptedChangeCount = appliedChanges.count
		changes = changeManager.getChanges()
		isSaved = false
	}
	
	func getChangeGroups() -> [ChangeGroup] {
		return changeManager.getChangeGroups()
	}
	
	func updateScrollPosition(_ position: CGFloat) {
		lastScrollPosition = position
	}
	
	func updateRelativePath(_ newPath: String) {
		relativePath = newPath
	}
	
	func getFirstPendingOrOverallChangeIndex() -> Int? {
		let pendingChange = changes.firstIndex { change in
			!appliedChanges.contains(change.id) && !rejectedChanges.contains(change.id)
		}
		return pendingChange ?? changes.first.map { _ in 0 }
	}
	
    func getContentForSaving() -> String {
        // Only return content when changes are actually applied
        if appliedChanges.isEmpty {
            return originalFileContent // Return original content if no changes applied
        }
        
        switch fileAction {
        case .create:
            return changeManager.getUpdatedContent()
        case .delete:
            return "" // Return empty string for delete action
        case .modify, .rewrite, .delegateEdit:
            return changeManager.getUpdatedContent()
        }
    }

	func makeStateSnapshot() -> ChangedFileState {
		let accepted = Array(appliedChanges)
		let rejected = Array(rejectedChanges)
		
		let acceptedContentKeys = changes
			.filter { appliedChanges.contains($0.id) }
			.map(\.contentKey)
		
		let rejectedContentKeys = changes
			.filter { rejectedChanges.contains($0.id) }
			.map(\.contentKey)
		
		return ChangedFileState(
			id: id,
			relativePath: relativePath,
			originalContent: originalFileContent,
			finalContent: getContentForSaving(),
			action: fileAction.rawValue,
			acceptedChanges: accepted,
			rejectedChanges: rejected,
			acceptedContentKeys: acceptedContentKeys,
			rejectedContentKeys: rejectedContentKeys
		)
	}
	
	/// Restores the file to a previously-persisted `ChangedFileState`, shielding
	/// callers from every compatibility quirk we've accumulated along the way.
	///
	/// The order of preference is:
	/// 1. New content-key strategy  (100 % reliable, today's default)
	/// 2. Legacy UUID strategy      (works so long as the in-memory IDs match)
	/// 3. *Heuristic* diff scan     (best-effort for very old sessions)
	@MainActor
	func applySavedState(_ state: ChangedFileState) async {
		//----------------------------------------------------------------------
		// 1) New – content-key matching (fast, unambiguous)
		//----------------------------------------------------------------------
		if !state.acceptedContentKeys.isEmpty || !state.rejectedContentKeys.isEmpty {
			resetToOriginalState()

			for change in changes {
				let key = change.contentKey
				if state.acceptedContentKeys.contains(key) {
					await applyChange(change)
				} else if state.rejectedContentKeys.contains(key) {
					rejectChange(change)
				}
			}
			isSaved = true
			objectWillChange.send()
			return
		}

		/*
		//----------------------------------------------------------------------
		// 2) Legacy – UUID lists (worked until we stopped persisting IDs)
		//----------------------------------------------------------------------
		let legacyAccepted = Set(state.acceptedChanges)
		let legacyRejected = Set(state.rejectedChanges)
		if !legacyAccepted.isEmpty || !legacyRejected.isEmpty {
			resetToOriginalState()

			for change in changes {
				if legacyAccepted.contains(change.id) {
					applyChange(change)
				} else if legacyRejected.contains(change.id) {
					rejectChange(change)
				}
			}

			// If at least one UUID matched we're done.
			if !appliedChanges.isEmpty || !rejectedChanges.isEmpty {
				isSaved = true
				return
			}
		}

		//----------------------------------------------------------------------
		// 3) Fallback – heuristic content scan (very old sessions)
		//
		//    We compare the *final* content that was stored on disk to the
		//    pristine original.  Any diff-chunk whose added lines already
		//    appear in the final file is treated as "accepted".
		//----------------------------------------------------------------------
		resetToOriginalState()

		let finalLines = state
			.finalContent
			.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
			.map(String.init)

		for change in changes {
			if Self.changeAppears(in: finalLines, change: change) {
				applyChange(change)
			} else {
				rejectChange(change)
			}
		}
		isSaved = true
		*/
	}

	// MARK: - Heuristic helpers
	private static func changeAppears(in finalLines: [String], change: FileChange) -> Bool {
		// We only look at added lines; removals are implicit once additions land.
		let added = change.diffChunk.lines
			.filter { $0.type == .addition }
			.map { $0.content }

		guard !added.isEmpty else { return false }
		return added.allSatisfy { finalLines.contains($0) }
	}
	
	func revertAllChanges() {
		resetFileContentToOriginal()
	}
	
	func resetToOriginalState() {
		revertAllChanges()
	}
	
	static func == (lhs: ChangedFile, rhs: ChangedFile) -> Bool {
		return lhs.id == rhs.id
	}
	
	/// Restores the state of accepted and rejected changes using the provided change IDs
	@MainActor
	func applyState(applied accepted: Set<UUID>, rejected: Set<UUID>) async {
		// 1. Reset to original
		resetFileContentToOriginal()
		
		print("Applying state: accepted: \(accepted), rejected: \(rejected) | actual changes: \(changes)")
		
		// 2. Re-apply accepted changes in natural order using bulk apply
		let acceptedChanges = changes.filter { accepted.contains($0.id) }
		if !acceptedChanges.isEmpty {
			let r = await applier.apply(acceptedChanges)
			fileContent = r.updated
			appliedChanges = r.newlyApplied
			self.changes = changeManager.getChanges()
			
			if !r.failedIDs.isEmpty {
				print("Failed to apply changes during state restoration: \(r.failedIDs)")
			}
		}
		
		// 3. Mark rejected ones
		for change in changes where rejected.contains(change.id) {
			rejectChange(change)
		}
		
		// 4. Final bookkeeping
		acceptedChangeCount = appliedChanges.count
		isSaved = true
		objectWillChange.send()
	}
}

extension ChangedFile {
	/// Runs all heavy initialisation off the main thread
	static func build(
		relativePath: String,
		originalText: String,
		changes: [FileChange],
		action: FileAction,
		contentItem: ContentItem? = nil
	) async -> ChangedFile {
		// Heavy work on a background thread
		let (lines, le) = await Task.detached {
			String.splitContentPreservingLineEndings(originalText)
		}.value
		let hadNewline = originalText.hasSuffix(le)
		let sortedChanges = changes.sorted(by: { $0.startLine < $1.startLine })
		let mgr = ChangeManager(fileContent: lines,
								changes: sortedChanges,
								lineEnding: le,
								fileAction: action,
								hadTrailingNewline: hadNewline)
		// Hop back to MainActor only to publish @Published vars
		return await MainActor.run {
			ChangedFile(relativePath: relativePath,
						fileContent: originalText,
						changes: changes,
						fileAction: action,
						contentItem: contentItem,
						preparedLines: lines,
						preparedManager: mgr,
						preparedLE: le)
		}
	}
}
