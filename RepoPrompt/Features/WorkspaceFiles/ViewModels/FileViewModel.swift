import Foundation
import Combine
import AppKit
import Neon
import SwiftTreeSitter

// MARK: - SVG-Safe Preview Types

/// Determines how a file should be previewed based on safety and performance considerations.
enum FilePreviewMode: Sendable {
	/// Preview is disabled - file is too risky to display (e.g., extremely large SVG).
	case disabled
	/// Plain text preview without syntax highlighting - safer for large or complex files.
	case plainText
	/// Full syntax-highlighted preview - default for normal files.
	case syntaxHighlighted
}

enum FileContentFreshnessPolicy: Sendable {
	/// Trust the existing FileViewModel metadata/cache fast path.
	case cachedMetadata
	/// Validate disk metadata before trusting cached content; never return stale fallback on validation/load failure.
	case validateDiskMetadata
}

/// Snapshot of file content plus a stable in-memory revision for search cache identity.
struct FileSearchContentSnapshot: Sendable {
	let content: String?
	let contentRevision: UInt64?
	let modificationDate: Date
	let isFresh: Bool
}

/// Snapshot of preview state computed by FileViewModel for safe consumption by views.
/// This moves all preview policy decisions to the view model layer, away from SwiftUI views.
struct FilePreviewSnapshot: Sendable {
	let mode: FilePreviewMode
	let isSvg: Bool
	let wasTruncatedByLines: Bool
	let wasTruncatedByBytes: Bool
	let lineCount: Int
	let byteCount: Int
	let previewText: String
	let namedRanges: [NamedRange]?
	
	/// User-facing message explaining any preview limitations.
	var statusMessage: String? {
		if mode == .disabled {
			return "Preview disabled for this file type/size to prevent crashes."
		}
		if isSvg && mode == .plainText {
			return "SVG file - shown as plain text to avoid rendering issues."
		}
		if wasTruncatedByLines || wasTruncatedByBytes {
			return "Preview truncated for performance."
		}
		return nil
	}
}

class FileViewModel: ObservableObject, Identifiable, FileSystemItemViewModel, Equatable, Hashable {
	
	// MARK: - Identity & paths
	
	let id: UUID
	let name: String
	let nameSortKey: String
	let relativePath: String
	let uniqueRelativePath: String
	let uniqueRelativePathSortKey: String
	let fullPath: String
	let standardizedFullPath: String
	let standardizedRelativePath: String
	
	/// Precomputed file extension from the file name.
	let fileExtension: String?
	
	let rootIdentifier: UUID
	let rootFolderPath: String
	let standardizedRootFolderPath: String
	let rootFolderName: String
	
	// MARK: - Observable state (MainActor for UI updates)
	
	@Published private(set) var modificationDate: Date
	@Published private(set) var isChecked: Bool
	@Published private(set) var loadingState: LoadingState
	@Published private(set) var cachedContent: String?
	@Published private(set) var error: Error?
	
	/// Preview content, limited for performance (lines/bytes).
	@Published private(set) var previewContent: String?
	/// Syntax ranges corresponding to the preview content.
	@Published private(set) var previewNamedRanges: [NamedRange]?
	
	/// SVG-safe preview snapshot with mode, truncation info, and content.
	/// Views should use this instead of directly accessing previewContent for SVG-aware rendering.
	@Published private(set) var previewSnapshot: FilePreviewSnapshot?
	
	/// Indicates whether a CodeMap load is in progress (for UI feedback)
	@Published private(set) var isCodeMapLoading: Bool = false
	
	/// Notifies listeners whenever this file’s check state changes:
	/// (file, isChecked)
	var onCheckStateChanged: ((FileViewModel, Bool) -> Void)?
	
	/// Keeps track of ongoing CodeMap loading so we can cancel or await it.
	private var codeMapLoadingTask: Task<FileAPI?, Never>?
	
	// MARK: - Single-flight gate (atomic start-or-join)
	
	private actor ContentLoadGate {
		private var task: Task<String?, Never>?
		private var generation: UInt64 = 0
		
		/// Atomically: if a task exists, return it; otherwise create/store/return a new one.
		func joinOrStart(
			make: @escaping @Sendable (_ gen: UInt64) -> Task<String?, Never>
		) -> Task<String?, Never> {
			if let t = task { return t }
			generation &+= 1
			let gen = generation
			let t = make(gen)
			task = t
			return t
		}
		
		/// Clear the stored task iff the generation matches (prevents clearing a newer task).
		func clear(gen: UInt64) {
			if generation == gen {
				task = nil
			}
		}
		
		func get() -> Task<String?, Never>? { task }
		
		func cancel() {
			task?.cancel()
			task = nil
			generation &+= 1 // advance so any late clear() won't affect a new task
		}
	}
	private let contentLoadGate = ContentLoadGate()
	
	// MARK: - Thread-safe timestamp cache with monotonic version
	
	private actor StateCache {
		private var modificationDate: Date
		private var lastLoadedDate: Date?
		private var version: UInt64 = 0  // Incremented on each external change
		
		init(modificationDate: Date, lastLoadedDate: Date? = nil) {
			self.modificationDate = modificationDate
			self.lastLoadedDate   = lastLoadedDate
		}
		
		/// One-hop atomic update when the file changes externally:
		/// - set modification date,
		/// - clear freshness,
		/// - bump version.
		func recordExternalModification(_ newDate: Date) {
			modificationDate = newDate
			lastLoadedDate   = nil
			version         &+= 1
		}
		
		func updateLastLoadedDate(_ newValue: Date?) {
			lastLoadedDate = newValue
		}

		func clearFreshness() {
			lastLoadedDate = nil
			version &+= 1
		}
		
		func snapshot() -> (modificationDate: Date, lastLoadedDate: Date?, version: UInt64) {
			(modificationDate, lastLoadedDate, version)
		}
		
		/// Record a *successful* load: align the cached modification date
		/// to the file's disk modification date, and mark freshness.
		func recordSuccessfulLoad(modificationDate: Date) {
			self.modificationDate = modificationDate
			self.lastLoadedDate   = modificationDate
		}
	}
	private let stateCache: StateCache
	
	/// The last time we successfully loaded content (UI-facing).
	@Published private(set) var lastLoadedDate: Date?
	
	/// Cached token count for more efficient token calculations
	@Published private(set) var cachedTokenCount: Int? = nil
	
	/// Cached line counts for quick UI access
	@Published private(set) var contentLineCount: Int? = nil
	@Published private(set) var codemapLineCount: Int? = nil
	
	/// Cached syntax tokens for highlighting (loaded on demand)
	private var cachedNamedRanges: [NamedRange]?
	
	// MARK: - Off-main content mirror (for zero MainActor hop reads)
	
	private actor ContentStore {
		private var content: String?
		private var revision: UInt64 = 0

		func get() -> String? { content }

		func set(_ newValue: String?) {
			guard content != newValue else { return }
			content = newValue
			revision &+= 1
		}

		func snapshot() -> (content: String?, revision: UInt64) {
			(content, revision)
		}
	}
	private let contentStore = ContentStore()
	
	// MARK: - Misc
	
	let chunkSize = 50_000
	let hierarchyLevel: Int
	private(set) var fileAPI: FileAPI?
	var hasAcceptedCodeMap: Bool { fileAPI != nil }
	
	// MARK: - Preview limits
	
	private static let maxPreviewLines = 5000
	private static let maxPreviewBytes = 1_000_000
	private static let disabledPreviewThresholdBytes = 5_000_000
	private static let maxSafeLineLength = 4096
	
	private struct PreviewArtifacts: Sendable {
		let snapshot: FilePreviewSnapshot
		let lineCount: Int
	}
	
	/// Reference to the file system service in charge of this file, if needed for edits/deletes.
	weak private var fileSystemService: FileSystemService?
	
	/// Parent folder pointer for bubble-up state changes.
	weak var parentFolder: FolderViewModel?
	
	// MARK: - Async convenience
	
	/// Always returns the freshest content available. Callers never need to read `loadingState`.
	var latestContent: String? {
		get async { await getLatestContent() }
	}
	
	struct CachedContentSnapshot: Sendable {
		let content: String?
		let modificationDate: Date
		let isFresh: Bool
	}
	
	/// Returns cached content and freshness without touching disk.
	func cachedContentSnapshot() async -> CachedContentSnapshot {
		let (mtime, lastLoaded, _) = await stateCache.snapshot()
		let content = await contentStore.get()
		let isFresh = (content != nil) && (lastLoaded.map { $0 >= mtime } ?? false)
		return CachedContentSnapshot(content: content, modificationDate: mtime, isFresh: isFresh)
	}

	/// Returns the same content as `latestContent`, plus a stable content revision when it is backed by the off-main store.
	func searchContentSnapshot(
		freshnessPolicy: FileContentFreshnessPolicy = .cachedMetadata
	) async -> FileSearchContentSnapshot {
		switch freshnessPolicy {
		case .cachedMetadata:
			return await cachedMetadataSearchContentSnapshot()
		case .validateDiskMetadata:
			return await diskValidatedSearchContentSnapshot()
		}
	}

	private func cachedMetadataSearchContentSnapshot() async -> FileSearchContentSnapshot {
		let (mtime, lastLoaded, _) = await stateCache.snapshot()
		let cached = await contentStore.snapshot()
		let cachedIsFresh = (cached.content != nil) && (lastLoaded.map { $0 >= mtime } ?? false)
		if cachedIsFresh {
			return FileSearchContentSnapshot(
				content: cached.content,
				contentRevision: cached.revision,
				modificationDate: mtime,
				isFresh: true
			)
		}

		let loadedContent = await latestContent
		let (resolvedMTime, resolvedLastLoaded, _) = await stateCache.snapshot()
		let resolved = await contentStore.snapshot()
		let resolvedIsFresh = (resolved.content != nil) && (resolvedLastLoaded.map { $0 >= resolvedMTime } ?? false)
		if let stored = resolved.content {
			return FileSearchContentSnapshot(
				content: stored,
				contentRevision: resolved.revision,
				modificationDate: resolvedMTime,
				isFresh: resolvedIsFresh
			)
		}

		return FileSearchContentSnapshot(
			content: loadedContent,
			contentRevision: nil,
			modificationDate: resolvedMTime,
			isFresh: false
		)
	}

	private func diskValidatedSearchContentSnapshot() async -> FileSearchContentSnapshot {
		if Task.isCancelled {
			let (mtime, _, _) = await stateCache.snapshot()
			return FileSearchContentSnapshot(content: nil, contentRevision: nil, modificationDate: mtime, isFresh: false)
		}

		let service = await MainActor.run { self.fileSystemService }
		guard let service else {
			let (mtime, _, _) = await stateCache.snapshot()
			return FileSearchContentSnapshot(content: nil, contentRevision: nil, modificationDate: mtime, isFresh: false)
		}

		guard await service.regularFileExistsOnDisk(relativePath: standardizedRelativePath) else {
			await clearContentForRemoval()
			let (mtime, _, _) = await stateCache.snapshot()
			return FileSearchContentSnapshot(content: nil, contentRevision: nil, modificationDate: mtime, isFresh: false)
		}

		let diskDate: Date
		do {
			diskDate = try await service.getFileModificationDate(atRelativePath: standardizedRelativePath)
		} catch {
			if Self.isMissingFileError(error) {
				await clearContentForRemoval(error: error)
			}
			let (mtime, _, _) = await stateCache.snapshot()
			return FileSearchContentSnapshot(content: nil, contentRevision: nil, modificationDate: mtime, isFresh: false)
		}

		let (cachedMTime, lastLoaded, _) = await stateCache.snapshot()
		let cached = await contentStore.snapshot()
		let cachedIsFresh = (cached.content != nil)
			&& (lastLoaded.map { $0 >= cachedMTime } ?? false)
			&& cachedMTime == diskDate
		if cachedIsFresh {
			return FileSearchContentSnapshot(
				content: cached.content,
				contentRevision: cached.revision,
				modificationDate: cachedMTime,
				isFresh: true
			)
		}

		if cached.content != nil || cachedMTime != diskDate {
			await setModificationDate(diskDate, forceInvalidation: true)
		}

		if Task.isCancelled {
			let (mtime, _, _) = await stateCache.snapshot()
			return FileSearchContentSnapshot(content: nil, contentRevision: nil, modificationDate: mtime, isFresh: false)
		}
		let (loadStartMTime, _, loadStartVersion) = await stateCache.snapshot()

		do {
			let (contentOpt, loadedDiskDate) = try await service.loadContentWithDate(ofRelativePath: standardizedRelativePath)
			let (currentMTime, _, currentVersion) = await stateCache.snapshot()
			guard !Task.isCancelled,
				currentVersion == loadStartVersion,
				currentMTime == loadStartMTime else {
				return FileSearchContentSnapshot(content: nil, contentRevision: nil, modificationDate: currentMTime, isFresh: false)
			}
			let content = await applyLoadedDiskContent(contentOpt, modificationDate: loadedDiskDate)
			let resolved = await contentStore.snapshot()
			return FileSearchContentSnapshot(
				content: resolved.content ?? content,
				contentRevision: resolved.revision,
				modificationDate: loadedDiskDate,
				isFresh: true
			)
		} catch {
			if Self.isMissingFileError(error) {
				await clearContentForRemoval(error: error)
			}
			let (mtime, _, _) = await stateCache.snapshot()
			return FileSearchContentSnapshot(content: nil, contentRevision: nil, modificationDate: mtime, isFresh: false)
		}
	}
	
	/// Getter that returns valid named ranges. If they’re not cached yet, it loads them.
	var latestNamedRanges: [NamedRange]? {
		get async {
			await loadSyntaxHighlighting()
			return await MainActor.run { self.cachedNamedRanges }
		}
	}
	
	// ─────────────────────────────────────────────────────────────
	// MARK: - DEBUG aid: fallback-return telemetry (lightweight)
	// ─────────────────────────────────────────────────────────────
	#if DEBUG
	private static let enableFallbackLogging = false
	#endif
	private func logFallback(_ reason: String) {
		#if DEBUG
		if Self.enableFallbackLogging {
			print("⚠️ FileViewModel(\(self.relativePath)): returning fallback content (\(reason))")
		}
		#endif
	}

	// MARK: - Init
	
	struct PrecomputedPathMetadata {
		let fullPath: String
		let standardizedFullPath: String
		let relativePath: String
		let standardizedRelativePath: String
		let standardizedRootFolderPath: String
		let rootFolderName: String

		static func preparedReplay(
			standardizedAbsolutePath: String,
			standardizedRelativePath: String,
			standardizedRootFolderPath: String
		) -> PrecomputedPathMetadata {
			PrecomputedPathMetadata(
				fullPath: standardizedAbsolutePath,
				standardizedFullPath: standardizedAbsolutePath,
				relativePath: standardizedRelativePath,
				standardizedRelativePath: standardizedRelativePath,
				standardizedRootFolderPath: standardizedRootFolderPath,
				rootFolderName: (standardizedRootFolderPath as NSString).lastPathComponent
			)
		}
	}

	init(
		file: File,
		rootPath: String,
		hierarchyLevel: Int = 0,
		rootIdentifier: UUID,
		rootFolderPath: String,
		fileSystemService: FileSystemService,
		parentFolder: FolderViewModel? = nil,
		relativePathOverride: String? = nil
	) {
		self.parentFolder      = parentFolder
		self.id                = file.id
		self.name              = file.name
		self.nameSortKey       = file.name.lowercased()
		self.fullPath          = file.path
		let stdFull = StandardizedPath.absolute(file.path)
		self.standardizedFullPath = stdFull
		let stdRoot = StandardizedPath.absolute(rootPath)
		self.relativePath = relativePathOverride.map(StandardizedPath.relative)
			?? RelativePath.fromStandardized(
				standardizedAbsolutePath: stdFull,
				standardizedRootPath: stdRoot
			)
		self.standardizedRelativePath = StandardizedPath.relative(self.relativePath)
		self.modificationDate  = file.modificationDate
		self.isChecked         = false
		self.loadingState      = .notLoaded
		self.cachedContent     = nil
		self.cachedNamedRanges = nil
		self.hierarchyLevel    = hierarchyLevel
		self.fileSystemService = fileSystemService
		
		// Preview
		self.previewContent     = nil
		self.previewNamedRanges = nil
		
		// Extension
		let ext = (file.name as NSString).pathExtension
		self.fileExtension   = ext.isEmpty ? nil : ext
		self.rootIdentifier  = rootIdentifier
		self.rootFolderPath  = rootFolderPath
		self.standardizedRootFolderPath = StandardizedPath.absolute(rootFolderPath)
		self.rootFolderName  = (self.standardizedRootFolderPath as NSString).lastPathComponent
		self.uniqueRelativePath = rootFolderName.isEmpty
			? self.relativePath
			: "\(rootFolderName)/\(self.relativePath)"
		self.uniqueRelativePathSortKey = self.uniqueRelativePath.lowercased()
		
		// Thread-safe timestamp cache
		self.stateCache = StateCache(modificationDate: file.modificationDate)
	}
	
	init(
		file: File,
		hierarchyLevel: Int = 0,
		rootIdentifier: UUID,
		rootFolderPath: String,
		fileSystemService: FileSystemService,
		parentFolder: FolderViewModel? = nil,
		precomputedPathMetadata: PrecomputedPathMetadata
	) {
		self.parentFolder      = parentFolder
		self.id                = file.id
		self.name              = file.name
		self.nameSortKey       = file.name.lowercased()
		self.fullPath          = precomputedPathMetadata.fullPath
		self.standardizedFullPath = precomputedPathMetadata.standardizedFullPath
		self.relativePath = precomputedPathMetadata.relativePath
		self.standardizedRelativePath = precomputedPathMetadata.standardizedRelativePath
		self.modificationDate  = file.modificationDate
		self.isChecked         = false
		self.loadingState      = .notLoaded
		self.cachedContent     = nil
		self.cachedNamedRanges = nil
		self.hierarchyLevel    = hierarchyLevel
		self.fileSystemService = fileSystemService

		// Preview
		self.previewContent     = nil
		self.previewNamedRanges = nil

		// Extension
		let ext = (file.name as NSString).pathExtension
		self.fileExtension   = ext.isEmpty ? nil : ext
		self.rootIdentifier  = rootIdentifier
		self.rootFolderPath  = rootFolderPath
		self.standardizedRootFolderPath = precomputedPathMetadata.standardizedRootFolderPath
		self.rootFolderName  = precomputedPathMetadata.rootFolderName
		self.uniqueRelativePath = rootFolderName.isEmpty
			? self.relativePath
			: "\(rootFolderName)/\(self.relativePath)"
		self.uniqueRelativePathSortKey = self.uniqueRelativePath.lowercased()

		// Thread-safe timestamp cache
		self.stateCache = StateCache(modificationDate: file.modificationDate)
	}

	private static func calculateRelativePath(fullPath: String, rootPath: String) -> String {
		RelativePath.from(absolutePath: fullPath, rootPath: rootPath)
	}
	
	enum LoadingState {
		case notLoaded
		case loading
		case loaded
		case error
	}
	
	// MARK: - Public update methods (MainActor)
	
	/// Sets a new modification date, invalidates caches, and cancels any in-flight loads.
	/// Ensures cancelled tasks cannot apply stale results.
	@MainActor
	func setModificationDate(_ newDate: Date, forceInvalidation: Bool = false) async {
		guard forceInvalidation || modificationDate != newDate else { return }
		modificationDate = newDate
		
		// Invalidate UI-visible caches (but keep cachedContent as a fallback)
		cachedNamedRanges  = nil
		cachedTokenCount   = nil
		fileAPI            = nil
		lastLoadedDate     = nil
		loadingState       = .notLoaded
		error              = nil
		previewContent     = nil
		previewNamedRanges = nil
		contentLineCount   = nil  // ensure line count refreshes after next load
		
		// Cancel ongoing work
		await contentLoadGate.cancel()
		codeMapLoadingTask?.cancel()
		codeMapLoadingTask = nil
		isCodeMapLoading   = false
		
		// One-hop atomic snapshot update (bump version & clear freshness)
		await stateCache.recordExternalModification(newDate)
		
		// Reposition in parent if sorted by modification date.
		parentFolder?.childDidUpdateModificationDate(self)
	}
	
	func acceptsCodeMap(_ codeMap: FileAPI) -> Bool {
		acceptsCodeMap(standardizedAPIPath: StandardizedPath.absolute(codeMap.filePath))
	}

	private func acceptsCodeMap(standardizedAPIPath: String) -> Bool {
		standardizedAPIPath == standardizedFullPath
	}

	@MainActor
	func setCodeMap(_ newCodeMap: FileAPI?) {
		guard let newCodeMap else {
			fileAPI = nil
			codemapLineCount = nil
			return
		}

		let standardizedAPIPath = StandardizedPath.absolute(newCodeMap.filePath)
		guard acceptsCodeMap(standardizedAPIPath: standardizedAPIPath) else {
			fileAPI = nil
			codemapLineCount = nil
			return
		}

		fileAPI = newCodeMap
		// Count lines using line-ending-aware utility (handles LF/CRLF/CR uniformly)
		codemapLineCount = String.splitContentPreservingAllLineEndings(newCodeMap.apiDescription).count
	}
	
	/// Set whether this file is currently checked; calls the optional callback.
	@MainActor
	func setIsChecked(_ newValue: Bool) {
		guard isChecked != newValue else { return }
		let oldValue = isChecked
		isChecked = newValue
		parentFolder?.childFileCheckboxDidChange(from: oldValue, to: newValue)
		onCheckStateChanged?(self, newValue)
	}
	
	/// Toggle the file’s checked state, then bubble that up to the parent folder.
	@MainActor
	func toggleIsChecked() {
		let newValue = !isChecked
		setIsChecked(newValue)
	}
	
	@MainActor
	func setLoadingState(_ newState: LoadingState, content: String? = nil) {
		loadingState = newState
	}
	
	@MainActor
	func setError(_ newError: Error?) {
		error = newError
	}
	
	@MainActor
	func setFileSystemService(_ service: FileSystemService?) {
		fileSystemService = service
	}
	
	// MARK: - Primary content API (single-flight, retry-on-stale)
	
	/// Always returns the freshest content available.
	/// - No external code needs to read `loadingState`.
	/// - Callers rendezvous on one in-flight task.
	/// - If the file changes mid-read, we retry (bounded).
	func getLatestContent() async -> String? {
		// Join existing in-flight task if any
		if let running = await contentLoadGate.get() {
			return await running.value
		}
		
		// Fast path: fresh & present content from off-main mirror
		do {
			let (mtime, lastLoaded, _) = await stateCache.snapshot()
			let fresh = lastLoaded.map { $0 >= mtime } ?? false
			let content = await contentStore.get()
			if fresh, let content { return content }
		}
		
		// Atomically start or join the loader
		let task = await contentLoadGate.joinOrStart { [weak self] gen in
			Task<String?, Never> {
				// If `self` is already gone, skip any attempt to clear.
				guard let self = self else { return nil }
				let result = await self._performLoadLoop(maxAttempts: 3)
				await self.contentLoadGate.clear(gen: gen)
				return result
			}
		}
		
		return await task.value
	}
	
	/// Backwards-compat shim: some call sites may still call loadContent().
	@available(*, deprecated, message: "Use `await latestContent` instead; it returns the content.")
	func loadContent(_ checkShouldReload: Bool = true) async {
		_ = await getLatestContent()
	}
	
	/// The actual load loop. Retries if we detect staleness during the read.
	@MainActor
	private func getCachedContentFallback() -> String? {
		return cachedContent
	}
	
	private func _performLoadLoop(maxAttempts: Int) async -> String? {
		await MainActor.run { self.setLoadingState(.loading) }
		
		var attempt = 0
		while !Task.isCancelled && attempt < maxAttempts {
			attempt += 1
			
			// Capture state at start of I/O
			let (startMTime, _, startVersion) = await stateCache.snapshot()
			
			// Resolve service off-main
			let service = await MainActor.run { self.fileSystemService }
			guard let service else {
				await MainActor.run {
					self.loadingState  = .error
					self.cachedContent = "[Error loading file]"
					self.error         = NSError(
						domain: "FileViewModel",
						code: 1,
						userInfo: [NSLocalizedDescriptionKey: "FileSystemService unavailable"]
					)
				}
				// Keep lastLoadedDate nil so next call will try again
				await stateCache.updateLastLoadedDate(nil)
				// Return whatever we have (avoid leaking `nil`)
				if let stored = await contentStore.get() {
					logFallback("service unavailable → ContentStore")
					return stored
				}
				let fallback = await getCachedContentFallback()
				if fallback != nil { logFallback("service unavailable → cachedContent") }
				return fallback
			}
			
			do {
				let (contentOpt, diskDate) = try await service.loadContentWithDate(ofRelativePath: self.relativePath)
				if Task.isCancelled { return await contentStore.get() }
				
				// Detect staleness during read
				let (currentMTime, _, currentVersion) = await stateCache.snapshot()
				// We consider the read stale only if state changed while reading.
				// Comparing diskDate to our synthetic UI time causes false positives.
				let stale = (currentVersion != startVersion) || (startMTime != currentMTime)
				if stale {
					// Try again against the new version
					continue
				}
				
				// Apply to UI state *before* letting the gate clear (no visible gap)
				return await self.applyLoadedDiskContent(contentOpt, modificationDate: diskDate)
				
			} catch is CancellationError {
				// Fall back to whatever we have (prevents leaking `nil`)
				if let stored = await contentStore.get() {
					logFallback("cancellation → ContentStore")
					return stored
				}
				let fallback = await getCachedContentFallback()
				if fallback != nil { logFallback("cancellation → cachedContent") }
				return fallback
			} catch {
				if Self.isMissingFileError(error) {
					await clearContentForRemoval(error: error)
					return nil
				}

				// Surface the error to UI and allow retry on next call
				await MainActor.run {
					self.loadingState  = .error
					self.cachedContent = "[Error loading file]"
					self.error         = error
				}
				await stateCache.updateLastLoadedDate(nil)
				if let stored = await contentStore.get() {
					logFallback("error → ContentStore")
					return stored
				}
				let fallback = await getCachedContentFallback()
				if fallback != nil { logFallback("error → cachedContent") }
				return fallback
			}
		}
		
		// Exceeded retries or cancelled: return whatever we currently have.
		if let stored = await contentStore.get() {
			return stored
		}
		return await getCachedContentFallback()
	}
	
	// MARK: - Syntax Highlighting (off-main safe)
	
	/// Asynchronously loads the syntax highlighting tokens on demand,
	/// caching the result in the view model. Also updates preview ranges.
	func loadSyntaxHighlighting() async {
		guard let ext = fileExtension else { return }
		
		// Only compute if not cached
		let alreadyCached = await MainActor.run { self.cachedNamedRanges != nil }
		if alreadyCached { return }
		
		// Read content off-main to avoid MainActor hops
		guard let content = await contentStore.get() else { return }
		
		do {
			let tokens = try SyntaxManager.shared.highlight(
				content: content,
				fileExtension: ext,
				origin: .previewFull(relativePath: self.relativePath)
			)
			await MainActor.run {
				self.cachedNamedRanges = tokens
				let preview = self.previewContent
				self.previewNamedRanges = self.filterRangesForContent(tokens, content: preview)
				
				// Update previewSnapshot with the new syntax ranges
				// so FilePreviewPopover gets highlighting.
				// Skip SVGs entirely - they use plainText/disabled modes for safety.
				if let snapshot = self.previewSnapshot,
					snapshot.mode == .syntaxHighlighted,
					!snapshot.isSvg {
					self.previewSnapshot = FilePreviewSnapshot(
						mode: snapshot.mode,
						isSvg: snapshot.isSvg,
						wasTruncatedByLines: snapshot.wasTruncatedByLines,
						wasTruncatedByBytes: snapshot.wasTruncatedByBytes,
						lineCount: snapshot.lineCount,
						byteCount: snapshot.byteCount,
						previewText: snapshot.previewText,
						namedRanges: self.previewNamedRanges
					)
				}
			}
		} catch {
			print("Error parsing content for syntax tokens: \(error)")
			await MainActor.run {
				self.previewNamedRanges = nil
			}
		}
	}
	
	// MARK: - Internal content updates (MainActor)

	@discardableResult
	func applyLoadedDiskContent(
		_ content: String?,
		modificationDate: Date
	) async -> String {
		let resolvedContent = content ?? "[Binary file]"
		let tokenCount = TokenCalculationService.estimateTokens(for: resolvedContent)
		let byteCount = resolvedContent.utf8.count

		// Precompute preview artifacts off MainActor to avoid UI hitches.
		let lineCount = Self.countLinesCapped(resolvedContent, cap: Self.maxPreviewLines + 1)
		let truncation = Self.truncateForPreview(
			resolvedContent,
			maxLines: Self.maxPreviewLines,
			maxBytes: Self.maxPreviewBytes
		)
		let snapshot = Self.computePreviewSnapshot(
			relativePath: self.relativePath,
			previewText: truncation.text,
			byteSize: byteCount,
			lineCount: lineCount,
			maxPreviewLines: Self.maxPreviewLines,
			wasTruncatedByBytes: truncation.wasTruncatedByBytes,
			namedRanges: nil
		)
		let previewArtifacts = PreviewArtifacts(snapshot: snapshot, lineCount: lineCount)

		await updateContentInternal(
			resolvedContent,
			modificationDate,
			tokens: nil,
			tokenCount: tokenCount,
			previewArtifacts: previewArtifacts
		)
		return resolvedContent
	}
	
	@MainActor
	private func updateContentInternal(
		_ newContent: String,
		_ modificationDate: Date,
		tokens: [NamedRange]?,
		tokenCount: Int,
		previewArtifacts: PreviewArtifacts
	) async {
		cachedContent     = newContent
		cachedNamedRanges = tokens // will be nil on load; re-tokenize on demand
		cachedTokenCount  = tokenCount
		loadingState      = .loaded
		lastLoadedDate    = modificationDate
		// Keep the UI-facing timestamp in sync with disk mtime so future setModificationDate(newDate)
		// can short-circuit when the mtime hasn't actually changed.
		self.modificationDate = modificationDate
		
		// Preview (use precomputed to avoid main-thread work)
		previewContent     = previewArtifacts.snapshot.previewText
		previewNamedRanges = filterRangesForContent(cachedNamedRanges, content: previewContent)
		contentLineCount   = previewArtifacts.lineCount
		previewSnapshot    = previewArtifacts.snapshot
		
		// Keep background caches in sync *synchronously* (no fire-and-forget).
		// Align the cache's modification date to the *disk* date so future staleness checks
		// do not compare against a synthetic "now" set by setModificationDate(_:)
		await stateCache.recordSuccessfulLoad(modificationDate: modificationDate)
		await contentStore.set(newContent)
	}
	
	// MARK: - SVG-Safe Preview Policy
	
	/// Computes a safe preview snapshot based on file type and size.
	/// Large files and SVGs get limited preview modes to avoid performance issues and crashes.
	private static func computePreviewSnapshot(
		relativePath: String,
		previewText: String,
		byteSize: Int,
		lineCount: Int,
		maxPreviewLines: Int,
		wasTruncatedByBytes: Bool,
		namedRanges: [NamedRange]?
	) -> FilePreviewSnapshot {
		let ext = ((relativePath as NSString).pathExtension).lowercased()
		let isSvg = ext == "svg" || ext == "svgz"
		let wasTruncatedByLines = lineCount > maxPreviewLines
		
		let hasExtremelyLongLines = Self.containsLineLongerThan(
			previewText,
			maxLength: Self.maxSafeLineLength
		)
		
		let mode: FilePreviewMode
		let finalPreviewText: String
		let finalNamedRanges: [NamedRange]?
		
		// Disable preview for any file over 5MB
		if byteSize > Self.disabledPreviewThresholdBytes {
			mode = .disabled
			finalPreviewText = "[Preview disabled - file too large (\(byteSize / 1_000_000) MB)]"
			finalNamedRanges = nil
		} else if isSvg {
			// All SVGs use plain text - no syntax highlighting to avoid CoreSVG issues
			if hasExtremelyLongLines {
				mode = .plainText
				finalPreviewText = Self.truncateLongLines(previewText, maxLength: Self.maxSafeLineLength)
				finalNamedRanges = nil
			} else {
				mode = .plainText
				finalPreviewText = previewText
				finalNamedRanges = nil
			}
		} else {
			// Non-SVG files use normal syntax highlighting
			mode = .syntaxHighlighted
			finalPreviewText = previewText
			finalNamedRanges = namedRanges
		}
		
		return FilePreviewSnapshot(
			mode: mode,
			isSvg: isSvg,
			wasTruncatedByLines: wasTruncatedByLines,
			wasTruncatedByBytes: wasTruncatedByBytes,
			lineCount: lineCount,
			byteCount: byteSize,
			previewText: finalPreviewText,
			namedRanges: finalNamedRanges
		)
	}
	
	/// Public setter used by edit flows and other callers.
	/// If `newContent == nil`, we evict the in-memory copy but do **not** reset freshness.
	/// Next read will reload from disk if needed because fast-path requires (fresh && content != nil).
	@MainActor
	func updateContent(_ newContent: String?) async {
		cachedContent = newContent
		
		if let newContent {
			// Update line count immediately when content is provided directly (LF/CRLF/CR aware)
			contentLineCount = Self.countLinesCapped(newContent, cap: Self.maxPreviewLines + 1)
		} else {
			// Evict memory-only caches
			cachedNamedRanges  = nil
			cachedTokenCount   = nil
			previewContent     = nil
			previewNamedRanges = nil
			previewSnapshot    = nil
			contentLineCount   = nil
			// Intentionally do not touch loadingState / lastLoadedDate here
		}
		
		// Keep off-main mirror in sync without spawning un-awaited tasks
		await contentStore.set(newContent)
	}
	
	@MainActor
	func clearContentForRemoval(error removalError: Error? = nil) async {
		cachedContent = nil
		cachedNamedRanges = nil
		cachedTokenCount = nil
		previewContent = nil
		previewNamedRanges = nil
		previewSnapshot = nil
		contentLineCount = nil
		fileAPI = nil
		loadingState = removalError == nil ? .notLoaded : .error
		error = removalError
		await contentStore.set(nil)
		await stateCache.clearFreshness()
	}

	@MainActor
	func updateLoadingState(_ newState: LoadingState) {
		loadingState = newState
	}

	private static func isMissingFileError(_ error: Error) -> Bool {
		if case FileSystemError.fileNotFound = error {
			return true
		}
		let nsError = error as NSError
		return nsError.domain == NSCocoaErrorDomain && [
			NSFileReadNoSuchFileError,
			NSFileNoSuchFileError
		].contains(nsError.code)
	}
	
	// MARK: - Utilities
	
	func revealInFinder() {
		Task {
			if let fileSystemService = await MainActor.run(body: { self.fileSystemService }) {
				let fullPath = await fileSystemService.getFullPath(forRelativePath: relativePath)
				let fileURL = URL(fileURLWithPath: fullPath)
				NSWorkspace.shared.activateFileViewerSelecting([fileURL])
			} else {
				print("Unable to reveal file in Finder: FileSystemService not available")
			}
		}
	}

	func openInDefaultApp() {
		let fileURL = URL(fileURLWithPath: standardizedFullPath)
		let opened = NSWorkspace.shared.open(fileURL)
		if !opened {
			print("Unable to open file: \(standardizedFullPath)")
		}
	}

	func copyContentsToPasteboard() {
		Task {
			if let content = await latestContent {
				copyToPasteboard(content)
			}
		}
	}

	func copyRelativePathToPasteboard() {
		copyToPasteboard(relativePath)
	}

	func copyFullPathToPasteboard() {
		copyToPasteboard(fullPath)
	}

	func copyAbsolutePathToPasteboard() {
		copyToPasteboard(standardizedFullPath)
	}

	private func copyToPasteboard(_ value: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(value, forType: .string)
	}
	
	/// Returns the file extension (if any) based on the file's name.
	var filExtension: String? {
		let ext = (name as NSString).pathExtension
		return ext.isEmpty ? nil : ext
	}

	/// Returns true if this file's extension supports codemap extraction.
	/// Use this to filter files when adding to codemap-only selections.
	var supportsCodeMap: Bool {
		guard let ext = fileExtension?.lowercased() else { return false }
		return SyntaxManager.supportsCodeMap(fileExtension: ext)
	}

	// MARK: - Helpers
	
	private struct PreviewTruncation {
		let text: String
		let wasTruncatedByBytes: Bool
	}
	
	/// Fast truncation for previews with line and byte limits.
	/// - Preserves original line endings in the included slice.
	/// - Appends "[Preview truncated…]" when a cut occurs.
	private static func truncateForPreview(
		_ content: String,
		maxLines: Int,
		maxBytes: Int
	) -> PreviewTruncation {
		guard maxLines > 0, maxBytes > 0, !content.isEmpty else {
			return PreviewTruncation(text: content, wasTruncatedByBytes: false)
		}
		
		let utf8 = content.utf8
		var i    = utf8.startIndex
		let end  = utf8.endIndex
		
		var lineEndsFound = 0
		var cutUTF8Index: String.UTF8View.Index? = nil
		var truncatedByBytes = false
		
		var lfCount   = 0
		var crlfCount = 0
		var crCount   = 0
		var bytesScanned = 0
		
		while i < end {
			let b = utf8[i]
			var bytesToConsume = 1
			if b == 0x0D {
				let n1 = utf8.index(after: i)
				if n1 < end, utf8[n1] == 0x0A {
					bytesToConsume = 2
				}
			}
			
			if bytesScanned + bytesToConsume > maxBytes {
				truncatedByBytes = true
				cutUTF8Index = i
				break
			}
			
			if b == 0x0A { // '\n'
				lfCount += 1
				lineEndsFound += 1
				let next = utf8.index(after: i)
				bytesScanned += 1
				if lineEndsFound == maxLines, next < end {
					cutUTF8Index = next
					break
				}
				i = next
				continue
			} else if b == 0x0D { // '\r'
				let n1 = utf8.index(after: i)
				if n1 < end, utf8[n1] == 0x0A {
					crlfCount += 1
					lineEndsFound += 1
					let next = utf8.index(after: n1) // skip CRLF
					bytesScanned += 2
					if lineEndsFound == maxLines, next < end {
						cutUTF8Index = next
						break
					}
					i = next
					continue
				} else {
					crCount += 1
					lineEndsFound += 1
					let next = n1 // skip CR
					bytesScanned += 1
					if lineEndsFound == maxLines, next < end {
						cutUTF8Index = next
						break
					}
					i = next
					continue
				}
			}
			
			// Regular byte
			bytesScanned += 1
			i = utf8.index(after: i)
		}
		
		guard let cutUTF8 = cutUTF8Index else {
			return PreviewTruncation(text: content, wasTruncatedByBytes: false)
		}
		
		let cutIndex = safeStringIndex(cutUTF8, in: content)
		
		let lineEnding: String = {
			if crlfCount >= lfCount && crlfCount >= crCount && crlfCount > 0 { return "\r\n" }
			if lfCount   >= crCount && lfCount   > 0 { return "\n" }
			if crCount   > 0 { return "\r" }
			return "\n"
		}()
		
		var result = String(content[..<cutIndex])
		result.reserveCapacity(result.utf16.count + 2 * lineEnding.utf16.count + 24)
		result.append(lineEnding)
		result.append(lineEnding)
		result.append("[Preview truncated…]")
		return PreviewTruncation(text: result, wasTruncatedByBytes: truncatedByBytes)
	}
	
	private static func safeStringIndex(
		_ utf8Index: String.UTF8View.Index,
		in content: String
	) -> String.Index {
		var candidate = utf8Index
		let utf8 = content.utf8
		var steps = 0
		
		while steps <= 3 {
			if let index = String.Index(candidate, within: content) {
				return index
			}
			if candidate == utf8.startIndex {
				return content.startIndex
			}
			candidate = utf8.index(before: candidate)
			steps += 1
		}
		
		return content.startIndex
	}
	
	private static func countLinesCapped(_ content: String, cap: Int) -> Int {
		guard cap > 0, !content.isEmpty else { return 0 }
		
		let utf8 = content.utf8
		var i = utf8.startIndex
		let end = utf8.endIndex
		
		var count = 0
		var endedWithLineEnding = false
		
		while i < end {
			let b = utf8[i]
			if b == 0x0A { // '\n'
				count += 1
				if count >= cap { return cap }
				let next = utf8.index(after: i)
				endedWithLineEnding = (next == end)
				i = next
				continue
			} else if b == 0x0D { // '\r'
				let n1 = utf8.index(after: i)
				if n1 < end, utf8[n1] == 0x0A {
					count += 1
					if count >= cap { return cap }
					let next = utf8.index(after: n1)
					endedWithLineEnding = (next == end)
					i = next
					continue
				} else {
					count += 1
					if count >= cap { return cap }
					endedWithLineEnding = (n1 == end)
					i = n1
					continue
				}
			}
			i = utf8.index(after: i)
		}
		
		if !endedWithLineEnding {
			count += 1
		}
		
		return min(count, cap)
	}
	
	private static func containsLineLongerThan(_ text: String, maxLength: Int) -> Bool {
		guard maxLength > 0, !text.isEmpty else { return false }
		
		var currentLength = 0
		var previousWasCR = false
		
		for scalar in text.unicodeScalars {
			if scalar == "\n" {
				if previousWasCR {
					previousWasCR = false
					continue
				}
				currentLength = 0
				continue
			}
			
			if scalar == "\r" {
				currentLength = 0
				previousWasCR = true
				continue
			}
			
			previousWasCR = false
			currentLength += 1
			if currentLength > maxLength {
				return true
			}
		}
		
		return false
	}
	
	/// Truncates lines longer than maxLength to prevent layout issues.
	private static func truncateLongLines(_ text: String, maxLength: Int) -> String {
		guard maxLength > 0, !text.isEmpty else { return text }
		
		var result = String()
		result.reserveCapacity(min(text.utf16.count, maxLength * 16) + 64)
		
		var currentLength = 0
		var previousWasCR = false
		var isTruncatingLine = false
		
		for scalar in text.unicodeScalars {
			if scalar == "\n" {
				if previousWasCR {
					previousWasCR = false
				}
				result.unicodeScalars.append(scalar)
				currentLength = 0
				isTruncatingLine = false
				continue
			}
			
			if scalar == "\r" {
				result.unicodeScalars.append(scalar)
				previousWasCR = true
				currentLength = 0
				isTruncatingLine = false
				continue
			}
			
			previousWasCR = false
			
			if isTruncatingLine {
				continue
			}
			
			currentLength += 1
			if currentLength > maxLength {
				result.append("... [line truncated]")
				isTruncatingLine = true
				continue
			}
			
			result.unicodeScalars.append(scalar)
		}
		
		return result
	}
	
	/// Helper to filter syntax ranges to only include those within the bounds of the given content length.
	private func filterRangesForContent(_ ranges: [NamedRange]?, content: String?) -> [NamedRange]? {
		guard let ranges = ranges, let content = content else { return nil }
		let contentLength = content.utf16.count // Use UTF16 count for NSRange compatibility
		return ranges.filter { range in
			let rangeEnd = range.range.location + range.range.length
			return rangeEnd <= contentLength
		}
	}
	
	// MARK: - Equatable / Hashable
	
	static func == (lhs: FileViewModel, rhs: FileViewModel) -> Bool {
		lhs.id == rhs.id
	}
	
	func hash(into hasher: inout Hasher) {
		hasher.combine(id)
	}
}

extension FileViewModel {
	struct SliceSegment {
		let range: LineRange
		let text: String
	}
	
	struct SliceAssembly {
		let segments: [SliceSegment]
		let combinedText: String
		let totalLines: Int
		let detectedLineEnding: String
		let usedRanges: [LineRange]
		let isFullFile: Bool
		
		var totalCharacters: Int { combinedText.count }
	}
	
	func assembleContent(for ranges: [LineRange]?) async -> SliceAssembly? {
		guard let content = await latestContent else { return nil }
		return Self.buildSliceAssembly(from: content, ranges: ranges)
	}
	
	internal static func buildSliceAssembly(from content: String, ranges: [LineRange]?) -> SliceAssembly {
		// 1) Preserve per-line endings for exact reconstruction of slices
		let pairs = String.splitContentPreservingAllLineEndings(content) // [(line, ending)]
		// 2) Also compute a canonical/dominant line ending (kept for callers that need it)
		let (_, detectedEnding) = String.splitContentPreservingLineEndings(content)
		let totalLines = pairs.count
		
		func fullFileAssembly() -> SliceAssembly {
			let segment: SliceSegment? = {
				if totalLines > 0 || !content.isEmpty {
					let rangeEnd = totalLines > 0 ? totalLines : 1
					return SliceSegment(range: LineRange(start: 1, end: rangeEnd), text: content)
				}
				return nil
			}()
			return SliceAssembly(
				segments: segment.map { [$0] } ?? [],
				combinedText: content,
				totalLines: totalLines,
				detectedLineEnding: detectedEnding,
				usedRanges: [],
				isFullFile: true
			)
		}
		
		guard let ranges, !ranges.isEmpty else {
			return fullFileAssembly()
		}
		
		let normalized = normalizeSlices(ranges, maxLine: totalLines)
		guard !normalized.isEmpty else {
			return fullFileAssembly()
		}
		
		var segments: [SliceSegment] = []
		segments.reserveCapacity(normalized.count)
		var combined = String()
		combined.reserveCapacity(content.count)
		
		for range in normalized {
			let startIndex = max(range.start - 1, 0)
			let endIndex = min(range.end, totalLines)
			guard startIndex < endIndex else { continue }

			// Re-apply the original per-line endings when assembling the slice
			let slicePairs = pairs[startIndex..<endIndex]
			let sliceText = slicePairs.map { $0.line + $0.ending }.joined()
			if !sliceText.isEmpty {
				combined.append(sliceText)
			}
			// Preserve the description from the original range
			let clampedRange = LineRange(start: startIndex + 1, end: endIndex, description: range.description)
			segments.append(SliceSegment(range: clampedRange, text: sliceText))
		}
		
		if segments.isEmpty {
			return fullFileAssembly()
		}
		
		return SliceAssembly(
			segments: segments,
			combinedText: combined,
			totalLines: totalLines,
			detectedLineEnding: detectedEnding,
			usedRanges: segments.map(\.range),
			isFullFile: false
		)
	}
	
	private static func normalizeSlices(_ ranges: [LineRange], maxLine: Int) -> [LineRange] {
		guard maxLine > 0 else { return [] }
		
		var cleaned: [LineRange] = []
		cleaned.reserveCapacity(ranges.count)
		
		for range in ranges {
			let start = max(1, range.start)
			let end = min(max(start, range.end), maxLine)
			if start > maxLine { continue }
			// Preserve the description from the original range
			cleaned.append(LineRange(start: start, end: end, description: range.description))
		}
		
		if cleaned.isEmpty { return [] }
		
		cleaned.sort { lhs, rhs in
			if lhs.start == rhs.start {
				return lhs.end < rhs.end
			}
			return lhs.start < rhs.start
		}
		
		var merged: [LineRange] = []
		for range in cleaned {
			if var last = merged.last, range.start <= last.end + 1 {
				// When merging ranges, prefer the first description if available
				// If both have descriptions, concatenate them
				let mergedDescription: String?
				if let lastDesc = last.description, let rangeDesc = range.description, lastDesc != rangeDesc {
					mergedDescription = lastDesc + "; " + rangeDesc
				} else {
					mergedDescription = last.description ?? range.description
				}
				last = LineRange(start: last.start, end: max(last.end, range.end), description: mergedDescription)
				merged[merged.count - 1] = last
			} else {
				merged.append(range)
			}
		}
		
		return merged
	}
}
