import Foundation
import SwiftUI

struct ApplyEditsResultPresentation: Equatable {
	let dto: ToolResultDTOs.EditSummary?
	let displayDiff: String?
	let summary: String
	let status: ToolCardStatus
	let isExpandable: Bool
	let renderMode: AgentToolCardRenderMode

	private static let legacySummaryDiffScanByteThreshold = 24_000

	static func build(for item: AgentChatItem, resultPayload: String?) -> ApplyEditsResultPresentation {
		let source = ToolResultPayloadSource(
			itemID: item.id,
			storedPayload: resultPayload,
			rawPayload: nil
		)
		return build(for: item, payloadSource: source)
	}

	static func build(for item: AgentChatItem, payloadSource: ToolResultPayloadSource) -> ApplyEditsResultPresentation {
		let resultPayload = payloadSource.preferredPayload
		let dto = ToolJSON.decodeResult(ToolResultDTOs.EditSummary.self, from: payloadSource)
		let args = ToolJSON.decodeArgs(ToolArgsDTOs.ApplyEditsArgs.self, from: item.toolArgsJSON)
		let displayDiff = resolvedDisplayDiff(from: dto)
		let status = resolvedStatus(item: item, dto: dto, resultPayload: resultPayload)
		return ApplyEditsResultPresentation(
			dto: dto,
			displayDiff: displayDiff,
			summary: buildSummary(dto: dto, diff: displayDiff, path: args?.path),
			status: status,
			isExpandable: (displayDiff?.isEmpty == false) || (ToolJSON.payloadHasContent(resultPayload) && !ToolJSON.payloadIsSummaryOnly(resultPayload)),
			renderMode: displayDiff?.isEmpty == false ? .diffPreview : .markdownFallback
		)
	}

	func shouldAutoExpand(isMostRecentEdit: Bool, resultPayload: String?) -> Bool {
		guard isMostRecentEdit else { return false }
		if displayDiff?.isEmpty == false { return true }
		guard ToolJSON.payloadHasContent(resultPayload), !ToolJSON.payloadIsSummaryOnly(resultPayload) else { return false }
		if dto?.requiresUserApproval == true { return true }
		return status != .failure
	}

	private static func resolvedDisplayDiff(from dto: ToolResultDTOs.EditSummary?) -> String? {
		guard let dto else { return nil }
		if let diff = dto.cardUnifiedDiff, !diff.isEmpty { return diff }
		if let diff = dto.unifiedDiff, !diff.isEmpty { return diff }
		return nil
	}

	private static func buildSummary(dto: ToolResultDTOs.EditSummary?, diff: String?, path: String?) -> String {
		var parts: [String] = []
		if let path {
			parts.append(fileName(from: path))
		}
		if let dto {
			parts.append("\(dto.editsApplied)/\(dto.editsRequested) edits")
			if let lineChange = lineChangeFragment(dto: dto, diff: diff) {
				parts.append(lineChange)
			}
		}
		return parts.joined(separator: " • ")
	}

	private static func lineChangeFragment(dto: ToolResultDTOs.EditSummary, diff: String?) -> String? {
		if dto.addedLines != nil || dto.deletedLines != nil {
			let addedLines = dto.addedLines ?? 0
			let deletedLines = dto.deletedLines ?? 0
			if addedLines > 0 || deletedLines > 0 {
				return "+\(addedLines) -\(deletedLines) lines"
			}
		}
		if let diff, let counts = countDiffLinesIfCheap(diff), counts.adds > 0 || counts.dels > 0 {
			return "+\(counts.adds) -\(counts.dels) lines"
		}
		if let changed = dto.totalLinesChanged {
			return "\(changed) lines"
		}
		return nil
	}

	private static func resolvedStatus(
		item: AgentChatItem,
		dto: ToolResultDTOs.EditSummary?,
		resultPayload: String?
	) -> ToolCardStatus {
		if item.toolIsError == true { return .failure }
		if let dto {
			switch dto.status.lowercased() {
			case "success": return .success
			case "partial", "warning": return .warning
			case "failed", "error": return .failure
			default: break
			}
		}
		return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: resultPayload, fallback: .neutral)
	}

	private static func countDiffLinesIfCheap(_ diff: String) -> (adds: Int, dels: Int)? {
		guard diff.utf8.count <= legacySummaryDiffScanByteThreshold else { return nil }
		var adds = 0
		var dels = 0
		for line in diff.components(separatedBy: "\n") {
			if line.hasPrefix("+") && !line.hasPrefix("+++") {
				adds += 1
			} else if line.hasPrefix("-") && !line.hasPrefix("---") {
				dels += 1
			}
		}
		return (adds, dels)
	}
}

struct ApplyPatchResultPresentation: Equatable {
	let dto: ToolResultDTOs.ApplyPatchSummary?
	let summary: String
	let status: ToolCardStatus
	let isExpandable: Bool
	let renderMode: AgentToolCardRenderMode

	static func build(for item: AgentChatItem, resultPayload: String?) -> ApplyPatchResultPresentation {
		let source = ToolResultPayloadSource(
			itemID: item.id,
			storedPayload: resultPayload,
			rawPayload: nil
		)
		return build(for: item, payloadSource: source)
	}

	static func build(for item: AgentChatItem, payloadSource: ToolResultPayloadSource) -> ApplyPatchResultPresentation {
		let resultPayload = payloadSource.preferredPayload
		let dto = ToolJSON.decodeResult(ToolResultDTOs.ApplyPatchSummary.self, from: payloadSource)
		let args = ToolJSON.decodeArgs(ToolArgsDTOs.ApplyPatchArgs.self, from: item.toolArgsJSON)
		let changeCount = resolvedChangeCount(dto: dto, args: args)
		let isSummaryOnly = ToolJSON.payloadIsSummaryOnly(resultPayload)
		let renderMode = isSummaryOnly ? .markdownFallback : resolvedRenderMode(dto: dto)
		let hasDisplayableDTO = dto.map {
			guard !isSummaryOnly else { return false }
			return !$0.changes.isEmpty || ($0.output?.isEmpty == false)
		} ?? false
		let hasExpandablePayload = ToolJSON.payloadHasContent(resultPayload) && !isSummaryOnly
		return ApplyPatchResultPresentation(
			dto: dto,
			summary: buildSummary(dto: dto, args: args, changeCount: changeCount),
			status: resolvedStatus(item: item, dto: dto, resultPayload: resultPayload),
			isExpandable: hasDisplayableDTO || hasExpandablePayload,
			renderMode: renderMode
		)
	}

	func shouldAutoExpand(isMostRecentEdit: Bool, resultPayload: String?) -> Bool {
		guard isMostRecentEdit,
			ToolJSON.payloadHasContent(resultPayload),
			!ToolJSON.payloadIsSummaryOnly(resultPayload),
			let dto
		else { return false }
		return !dto.changes.isEmpty
	}

	static func isUnifiedDiff(_ diff: String, kind: String) -> Bool {
		let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		if normalizedKind != "update" {
			return false
		}
		let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.contains("@@") || trimmed.contains("--- ") || trimmed.contains("+++ ")
	}

	private static func resolvedRenderMode(dto: ToolResultDTOs.ApplyPatchSummary?) -> AgentToolCardRenderMode {
		guard let dto else { return .markdownFallback }
		if dto.changes.contains(where: { isUnifiedDiff($0.diff, kind: $0.kind) }) {
			return .diffPreview
		}
		if dto.changes.isEmpty {
			if let output = dto.output, !output.isEmpty {
				return .toolSpecificNoDiff
			}
			return .markdownFallback
		}
		return .toolSpecificNoDiff
	}

	private static func resolvedChangeCount(dto: ToolResultDTOs.ApplyPatchSummary?, args: ToolArgsDTOs.ApplyPatchArgs?) -> Int {
		if let dto {
			return max(dto.changeCount, dto.changes.count)
		}
		if let count = args?.changeCount {
			return count
		}
		return 0
	}

	private static func buildSummary(dto: ToolResultDTOs.ApplyPatchSummary?, args: ToolArgsDTOs.ApplyPatchArgs?, changeCount: Int) -> String {
		if let dto, let firstChange = dto.changes.first {
			let totalChanges = max(dto.changeCount, dto.changes.count)
			if totalChanges == 1 {
				return "\(fileName(from: firstChange.path)) • patch"
			}
			return "\(totalChanges) files • patch"
		}
		if let args {
			if let path = args.path, !path.isEmpty {
				return "\(fileName(from: path)) • patch"
			}
			if let paths = args.paths, !paths.isEmpty {
				if paths.count == 1 {
					return "\(fileName(from: paths[0])) • patch"
				}
				return "\(paths.count) files • patch"
			}
			if let changeCount = args.changeCount, changeCount > 0 {
				return "\(changeCount) file\(changeCount == 1 ? "" : "s") • patch"
			}
		}
		if changeCount > 0 {
			return "\(changeCount) file\(changeCount == 1 ? "" : "s") • patch"
		}
		return "Patch"
	}

	private static func resolvedStatus(
		item: AgentChatItem,
		dto: ToolResultDTOs.ApplyPatchSummary?,
		resultPayload: String?
	) -> ToolCardStatus {
		if item.toolIsError == true { return .failure }
		guard let dto else {
			return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: resultPayload, fallback: .neutral)
		}
		switch dto.status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
		case "running", "in_progress", "inprogress", "pending":
			return .neutral
		case "completed", "success", "succeeded", "ok":
			return .success
		case "declined", "rejected":
			return .warning
		case "failed", "failure", "error":
			return .failure
		default:
			return ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: resultPayload, fallback: .neutral)
		}
	}
}

struct ApplyEditsResultCard: View {
	let item: AgentChatItem
	let isMostRecentEdit: Bool
	@Environment(\.agentRawToolResultPayloadResolver) private var rawToolResultPayloadResolver
	@Environment(\.agentRawToolResultPayloadRenderRevision) private var rawPayloadRenderRevision
	@State private var isExpanded: Bool
	@State private var cachedPresentation: ApplyEditsResultPresentation?

	init(item: AgentChatItem, isMostRecentEdit: Bool = true) {
		self.item = item
		self.isMostRecentEdit = isMostRecentEdit
		self._isExpanded = State(initialValue: Self.shouldAutoExpandInitially(item: item, isMostRecentEdit: isMostRecentEdit))
		self._cachedPresentation = State(initialValue: nil)
	}

	private static func shouldAutoExpandInitially(item: AgentChatItem, isMostRecentEdit: Bool) -> Bool {
		let payloadSource = ToolJSON.resultPayloadSource(for: item, rawPayload: nil)
		let presentation = ApplyEditsResultPresentation.build(for: item, payloadSource: payloadSource)
		return presentation.shouldAutoExpand(isMostRecentEdit: isMostRecentEdit, resultPayload: payloadSource.preferredPayload)
	}

	private struct PresentationCacheKey: Equatable {
		let toolResultJSON: String?
		let toolArgsJSON: String?
		let toolIsError: Bool?
		let rawPayloadRenderRevision: Int
		let hasRawPayload: Bool
	}

	private var payloadSource: ToolResultPayloadSource {
		ToolJSON.resultPayloadSource(
			for: item,
			rawPayload: rawToolResultPayloadResolver?(item.id)
		)
	}

	private var presentationCacheKey: PresentationCacheKey {
		let source = payloadSource
		return PresentationCacheKey(
			toolResultJSON: item.toolResultJSON,
			toolArgsJSON: item.toolArgsJSON,
			toolIsError: item.toolIsError,
			rawPayloadRenderRevision: rawPayloadRenderRevision,
			hasRawPayload: source.hasRawPayload
		)
	}

	private func buildPresentation(payloadSource: ToolResultPayloadSource? = nil) -> ApplyEditsResultPresentation {
		ApplyEditsResultPresentation.build(for: item, payloadSource: payloadSource ?? self.payloadSource)
	}

	private func refreshPresentationAndReconcileExpansion() {
		let source = payloadSource
		let presentation = buildPresentation(payloadSource: source)
		cachedPresentation = presentation
		reconcileExpansion(presentation: presentation, resultPayload: source.preferredPayload)
	}

	private func reconcileExpansion(presentation: ApplyEditsResultPresentation, resultPayload: String?) {
		guard isMostRecentEdit else {
			if isExpanded {
				performAgentToolCardExpansionStateUpdateWithoutAnimation {
					isExpanded = false
				}
			}
			return
		}
		guard presentation.shouldAutoExpand(isMostRecentEdit: true, resultPayload: resultPayload), !isExpanded else {
			return
		}
		performAgentToolCardExpansionStateUpdateWithoutAnimation {
			isExpanded = true
		}
	}

	var body: some View {
		let presentation = cachedPresentation ?? buildPresentation()
		ToolCardContainer(
			iconName: toolIcon(for: item.toolName),
			iconColor: ToolCardAccentResolver.color(for: item.toolName),
			title: "Edit",
			subtitle: nonEmptyToolCardSummary(presentation.summary, fallbackStatusFor: item),
			status: presentation.status,
			timestamp: item.timestamp,
			isExpandable: presentation.isExpandable,
			managesOwnExpansion: true,
			rawPayloadItemID: item.id,
			debugItemID: item.id,
			debugToolName: "apply_edits",
			debugRenderMode: presentation.renderMode,
			isExpanded: $isExpanded
		) {
			if let dto = presentation.dto {
				VStack(alignment: .leading, spacing: 6) {
					HStack(spacing: 6) {
						if dto.fileCreated == true {
							StatusBadge(text: "created", status: .success)
						}
						if dto.fileOverwritten == true {
							StatusBadge(text: "overwritten", status: .warning)
						}
					}
					if let note = dto.note, !note.isEmpty {
						Text(note)
							.font(.system(size: 11))
							.foregroundColor(.secondary)
					}
					if let diff = presentation.displayDiff {
						UnifiedDiffView(diff: diff, largeBodyMaxHeight: 560)
					} else {
						ToolMarkdownExpandedContent(item: item)
					}
				}
			} else {
				ToolMarkdownExpandedContent(item: item)
			}
		}
		.onAppear {
			refreshPresentationAndReconcileExpansion()
		}
		.onChange(of: presentationCacheKey) { _, _ in
			refreshPresentationAndReconcileExpansion()
		}
		.onChange(of: isMostRecentEdit) { _, _ in
			let source = payloadSource
			reconcileExpansion(
				presentation: cachedPresentation ?? buildPresentation(payloadSource: source),
				resultPayload: source.preferredPayload
			)
		}
	}
}

struct CursorNativeEditResultPresentation: Equatable {
	struct DisplayDiff: Equatable {
		let path: String
		let diff: String
		let isTruncated: Bool
	}

	let dto: ToolResultDTOs.CursorNativeEditSummary?
	let title: String
	let summary: String
	let diffs: [DisplayDiff]
	let status: ToolCardStatus
	let isExpandable: Bool
	let renderMode: AgentToolCardRenderMode

	static func build(for item: AgentChatItem) -> CursorNativeEditResultPresentation {
		build(for: item, resultPayload: item.toolResultJSON)
	}

	static func build(for item: AgentChatItem, resultPayload: String?) -> CursorNativeEditResultPresentation {
		let source = ToolResultPayloadSource(
			itemID: item.id,
			storedPayload: resultPayload,
			rawPayload: nil
		)
		return build(for: item, payloadSource: source)
	}

	static func build(for item: AgentChatItem, payloadSource: ToolResultPayloadSource) -> CursorNativeEditResultPresentation {
		let resultPayload = payloadSource.preferredPayload
		let dto = ToolJSON.decodeResult(ToolResultDTOs.CursorNativeEditSummary.self, from: payloadSource)
		let diffs = displayDiffs(from: dto)
		let title = displayTitle(from: dto)
		let status = resolvedStatus(item: item, dto: dto, diffs: diffs, resultPayload: resultPayload)
		return CursorNativeEditResultPresentation(
			dto: dto,
			title: title,
			summary: buildSummary(dto: dto, diffs: diffs),
			diffs: diffs,
			status: status,
			isExpandable: !diffs.isEmpty || (ToolJSON.payloadHasContent(resultPayload) && !ToolJSON.payloadIsSummaryOnly(resultPayload)),
			renderMode: diffs.isEmpty ? .markdownFallback : .diffPreview
		)
	}

	static func shouldAutoExpandInitially(item: AgentChatItem, isMostRecentEdit: Bool) -> Bool {
		guard isMostRecentEdit else { return false }
		return !displayDiffs(from: ToolJSON.decode(ToolResultDTOs.CursorNativeEditSummary.self, from: item.toolResultJSON)).isEmpty
	}

	private static func displayTitle(from dto: ToolResultDTOs.CursorNativeEditSummary?) -> String {
		let rawTitle = dto?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
		guard let rawTitle, !rawTitle.isEmpty else { return "Edit File" }
		if rawTitle.lowercased() == "edit file" {
			return "Edit File"
		}
		return rawTitle
	}

	private static func buildSummary(
		dto: ToolResultDTOs.CursorNativeEditSummary?,
		diffs: [DisplayDiff]
	) -> String {
		let truncationSuffix = diffs.contains { $0.isTruncated } ? " • diff truncated" : ""
		if let first = diffs.first {
			if diffs.count == 1 {
				return "\(fileName(from: first.path)) • edit\(truncationSuffix)"
			}
			return "\(diffs.count) files • edit\(truncationSuffix)"
		}
		if let changeCount = dto?.changeCount, changeCount > 0 {
			return "\(changeCount) file\(changeCount == 1 ? "" : "s") • edit"
		}
		return "Edit"
	}

	private static func displayDiffs(from dto: ToolResultDTOs.CursorNativeEditSummary?) -> [DisplayDiff] {
		guard let content = dto?.content else { return [] }
		return content.compactMap { block in
			let blockType = block.type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			guard blockType == nil || blockType == "diff",
				let rawPath = block.path?.trimmingCharacters(in: .whitespacesAndNewlines),
				!rawPath.isEmpty
			else {
				return nil
			}
			let isTruncated = block.diffTruncated == true
				|| block.oldTextTruncated == true
				|| block.newTextTruncated == true
			if let persistedDiff = block.unifiedDiff?.trimmingCharacters(in: .whitespacesAndNewlines),
				!persistedDiff.isEmpty {
				return DisplayDiff(path: rawPath, diff: persistedDiff, isTruncated: isTruncated)
			}
			guard let oldText = block.oldText,
				let newText = block.newText else { return nil }
			let diff = unifiedDiff(path: rawPath, oldText: oldText, newText: newText)
			guard !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
			return DisplayDiff(path: rawPath, diff: diff, isTruncated: isTruncated)
		}
	}

	private static func unifiedDiff(path: String, oldText: String, newText: String) -> String {
		let oldLines = String.splitContentPreservingLineEndings(oldText).0
		let newLines = String.splitContentPreservingLineEndings(newText).0
		let chunks = UnifiedDiffGenerator.diffChunks(
			oldLines: oldLines,
			newLines: newLines,
			context: 2
		)
		return UnifiedDiffGenerator.build(filePath: path, chunks: chunks, context: 2)
	}

	private static func resolvedStatus(
		item: AgentChatItem,
		dto: ToolResultDTOs.CursorNativeEditSummary?,
		diffs: [DisplayDiff],
		resultPayload: String?
	) -> ToolCardStatus {
		let primary = ToolResultStatusResolver.resolve(toolIsError: item.toolIsError, raw: resultPayload, fallback: .neutral)
		if primary == .failure || primary == .warning {
			return primary
		}
		if diffs.contains(where: { $0.isTruncated }) {
			return .warning
		}
		if let acpStatus = cursorStatusWord(dto?.acpStatus) {
			return acpStatus
		}
		if primary != .neutral {
			return primary
		}
		return cursorStatusWord(dto?.status) ?? primary
	}

	private static func cursorStatusWord(_ value: String?) -> ToolCardStatus? {
		guard let normalized = AgentTranscriptToolStatusSemantics.normalizedStatusWord(value) else { return nil }
		switch normalized {
		case "success": return .success
		case "warning": return .warning
		case "failed", "cancelled": return .failure
		case "running", "pending": return .running
		default: return nil
		}
	}
}

struct CursorNativeEditResultCard: View {
	let item: AgentChatItem
	let isMostRecentEdit: Bool
	@Environment(\.agentRawToolResultPayloadResolver) private var rawToolResultPayloadResolver
	@Environment(\.agentRawToolResultPayloadRenderRevision) private var rawPayloadRenderRevision
	@State private var isExpanded: Bool
	@State private var cachedPresentation: CursorNativeEditResultPresentation?

	init(item: AgentChatItem, isMostRecentEdit: Bool = true) {
		self.item = item
		self.isMostRecentEdit = isMostRecentEdit
		self._isExpanded = State(initialValue: CursorNativeEditResultPresentation.shouldAutoExpandInitially(
			item: item,
			isMostRecentEdit: isMostRecentEdit
		))
		self._cachedPresentation = State(initialValue: nil)
	}

	private struct PresentationCacheKey: Equatable {
		let toolName: String?
		let toolResultJSON: String?
		let toolArgsJSON: String?
		let toolIsError: Bool?
		let rawPayloadRenderRevision: Int
		let hasRawPayload: Bool
	}

	private var payloadSource: ToolResultPayloadSource {
		ToolJSON.resultPayloadSource(
			for: item,
			rawPayload: rawToolResultPayloadResolver?(item.id)
		)
	}

	private var presentationCacheKey: PresentationCacheKey {
		let source = payloadSource
		return PresentationCacheKey(
			toolName: item.toolName,
			toolResultJSON: item.toolResultJSON,
			toolArgsJSON: item.toolArgsJSON,
			toolIsError: item.toolIsError,
			rawPayloadRenderRevision: rawPayloadRenderRevision,
			hasRawPayload: source.hasRawPayload
		)
	}

	private func buildPresentation(payloadSource: ToolResultPayloadSource? = nil) -> CursorNativeEditResultPresentation {
		CursorNativeEditResultPresentation.build(for: item, payloadSource: payloadSource ?? self.payloadSource)
	}

	private func refreshPresentationAndReconcileExpansion() {
		let presentation = buildPresentation()
		cachedPresentation = presentation
		reconcileExpansion(presentation: presentation)
	}

	private func reconcileExpansion(presentation: CursorNativeEditResultPresentation) {
		guard isMostRecentEdit else {
			if isExpanded {
				performAgentToolCardExpansionStateUpdateWithoutAnimation {
					isExpanded = false
				}
			}
			return
		}
		guard !presentation.diffs.isEmpty, !isExpanded else { return }
		performAgentToolCardExpansionStateUpdateWithoutAnimation {
			isExpanded = true
		}
	}

	var body: some View {
		let presentation = cachedPresentation ?? buildPresentation()
		ToolCardContainer(
			iconName: toolIcon(for: item.toolName),
			iconColor: ToolCardAccentResolver.color(for: item.toolName),
			title: presentation.title,
			subtitle: nonEmptyToolCardSummary(presentation.summary, fallbackStatusFor: item),
			status: presentation.status,
			timestamp: item.timestamp,
			isExpandable: presentation.isExpandable,
			managesOwnExpansion: true,
			rawPayloadItemID: item.id,
			debugItemID: item.id,
			debugToolName: "edit",
			debugRenderMode: presentation.renderMode,
			isExpanded: $isExpanded
		) {
			if presentation.diffs.isEmpty {
				ToolMarkdownExpandedContent(item: item)
			} else {
				VStack(alignment: .leading, spacing: 10) {
					ForEach(Array(presentation.diffs.enumerated()), id: \.offset) { _, diff in
						VStack(alignment: .leading, spacing: 6) {
							Text(shortenPath(diff.path))
								.font(.system(size: 11, weight: .semibold))
								.textSelection(.enabled)
							if diff.isTruncated {
								Text("Diff truncated")
									.font(.system(size: 11))
									.foregroundColor(.secondary)
							}
							UnifiedDiffView(diff: diff.diff, largeBodyMaxHeight: 440)
						}
					}
				}
			}
		}
		.onAppear {
			refreshPresentationAndReconcileExpansion()
		}
		.onChange(of: presentationCacheKey) { _, _ in
			refreshPresentationAndReconcileExpansion()
		}
		.onChange(of: isMostRecentEdit) { _, _ in
			reconcileExpansion(presentation: cachedPresentation ?? buildPresentation())
		}
	}
}

struct ApplyPatchResultCard: View {
	let item: AgentChatItem
	let isMostRecentEdit: Bool
	@Environment(\.agentRawToolResultPayloadResolver) private var rawToolResultPayloadResolver
	@Environment(\.agentRawToolResultPayloadRenderRevision) private var rawPayloadRenderRevision
	@State private var isExpanded: Bool
	@State private var cachedPresentation: ApplyPatchResultPresentation?

	init(item: AgentChatItem, isMostRecentEdit: Bool = true) {
		self.item = item
		self.isMostRecentEdit = isMostRecentEdit
		self._isExpanded = State(initialValue: Self.shouldAutoExpandInitially(item: item, isMostRecentEdit: isMostRecentEdit))
		self._cachedPresentation = State(initialValue: nil)
	}

	private static func shouldAutoExpandInitially(item: AgentChatItem, isMostRecentEdit: Bool) -> Bool {
		let payloadSource = ToolJSON.resultPayloadSource(for: item, rawPayload: nil)
		let presentation = ApplyPatchResultPresentation.build(for: item, payloadSource: payloadSource)
		return presentation.shouldAutoExpand(isMostRecentEdit: isMostRecentEdit, resultPayload: payloadSource.preferredPayload)
	}

	private struct PresentationCacheKey: Equatable {
		let toolResultJSON: String?
		let toolArgsJSON: String?
		let toolIsError: Bool?
		let rawPayloadRenderRevision: Int
		let hasRawPayload: Bool
	}

	private var payloadSource: ToolResultPayloadSource {
		ToolJSON.resultPayloadSource(
			for: item,
			rawPayload: rawToolResultPayloadResolver?(item.id)
		)
	}

	private var presentationCacheKey: PresentationCacheKey {
		let source = payloadSource
		return PresentationCacheKey(
			toolResultJSON: item.toolResultJSON,
			toolArgsJSON: item.toolArgsJSON,
			toolIsError: item.toolIsError,
			rawPayloadRenderRevision: rawPayloadRenderRevision,
			hasRawPayload: source.hasRawPayload
		)
	}

	private func buildPresentation(payloadSource: ToolResultPayloadSource? = nil) -> ApplyPatchResultPresentation {
		ApplyPatchResultPresentation.build(for: item, payloadSource: payloadSource ?? self.payloadSource)
	}

	private func refreshPresentationAndReconcileExpansion() {
		let source = payloadSource
		let presentation = buildPresentation(payloadSource: source)
		cachedPresentation = presentation
		reconcileExpansion(presentation: presentation, resultPayload: source.preferredPayload)
	}

	private func reconcileExpansion(presentation: ApplyPatchResultPresentation, resultPayload: String?) {
		guard isMostRecentEdit else {
			if isExpanded {
				performAgentToolCardExpansionStateUpdateWithoutAnimation {
					isExpanded = false
				}
			}
			return
		}
		guard presentation.shouldAutoExpand(isMostRecentEdit: true, resultPayload: resultPayload), !isExpanded else {
			return
		}
		performAgentToolCardExpansionStateUpdateWithoutAnimation {
			isExpanded = true
		}
	}

	var body: some View {
		let presentation = cachedPresentation ?? buildPresentation()
		ToolCardContainer(
			iconName: toolIcon(for: item.toolName),
			iconColor: ToolCardAccentResolver.color(for: item.toolName),
			title: "Patch",
			subtitle: nonEmptyToolCardSummary(presentation.summary, fallbackStatusFor: item),
			status: presentation.status,
			timestamp: item.timestamp,
			isExpandable: presentation.isExpandable,
			managesOwnExpansion: true,
			rawPayloadItemID: item.id,
			debugItemID: item.id,
			debugToolName: "apply_patch",
			debugRenderMode: presentation.renderMode,
			isExpanded: $isExpanded
		) {
			if let dto = presentation.dto {
				VStack(alignment: .leading, spacing: 10) {
					if dto.changes.isEmpty {
						if let output = dto.output, !output.isEmpty {
							ToolScrollableMarkdownTextView(text: output, maxHeight: 180)
						} else {
							ToolMarkdownExpandedContent(item: item)
						}
					} else {
						ForEach(Array(dto.changes.enumerated()), id: \.offset) { _, change in
							VStack(alignment: .leading, spacing: 6) {
								HStack(alignment: .firstTextBaseline, spacing: 6) {
									Text(shortenPath(change.path))
										.font(.system(size: 11, weight: .semibold))
										.textSelection(.enabled)
									if let movePath = change.movePath, !movePath.isEmpty {
										Text("→ \(shortenPath(movePath))")
											.font(.system(size: 11))
											.foregroundColor(.secondary)
									}
								}
								if ApplyPatchResultPresentation.isUnifiedDiff(change.diff, kind: change.kind) {
									UnifiedDiffView(diff: change.diff, largeBodyMaxHeight: 440)
								} else {
									ToolScrollableMarkdownTextView(text: change.diff, maxHeight: 180)
								}
							}
						}
					}
				}
			} else {
				ToolMarkdownExpandedContent(item: item)
			}
		}
		.onAppear {
			refreshPresentationAndReconcileExpansion()
		}
		.onChange(of: presentationCacheKey) { _, _ in
			refreshPresentationAndReconcileExpansion()
		}
		.onChange(of: isMostRecentEdit) { _, _ in
			let source = payloadSource
			reconcileExpansion(
				presentation: cachedPresentation ?? buildPresentation(payloadSource: source),
				resultPayload: source.preferredPayload
			)
		}
	}
}
