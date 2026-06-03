//
//  ChatViewModel+Diffs.swift
//  RepoPrompt
//
//  Created by RepoPrompt on 2025-07-03.
//

import Foundation

// MARK: - Diff generation and caching helpers
extension ChatViewModel {
	nonisolated private static let maxDiffCharactersPerFile: Int = 60_000
    
    /// Generate diff summaries from ChangedFileState objects
    /// This is called after edits are applied to capture the diffs for MCP export
    @MainActor
    func captureDiffSummaries(for messageId: UUID) async {
        guard let changedFileStates = produceChangedFileStatesForMessage(messageId) else {
            return
        }
        
        // Get the live ChangedFile objects to access detailed change information
        let changedFiles = aiResponseViewModel.getChangedFiles(forQueryId: messageId) ?? []
        
        let diffSummaries = await withTaskGroup(of: MessageDiff?.self) { group in
            for fileState in changedFileStates {
                group.addTask {
                    // Skip files with no actual changes
                    guard fileState.originalContent != fileState.finalContent else { return nil }
                    
                    // Find the corresponding ChangedFile for detailed stats
                    let matchingFile = changedFiles.first { $0.relativePath == fileState.relativePath }
                    
                    // Calculate statistics from the ChangedFile if available
                    let totalLinesChanged: Int
                    let totalChunks: Int
                    let editsApplied: Int
                    
                    if let file = matchingFile {
                        // Use actual change data from ChangedFile
                        totalLinesChanged = file.changes.reduce(0) { acc, change in
                            acc + abs(change.diffChunk.lineCountDifference())
                        }
                        totalChunks = file.changes.count
                        editsApplied = file.appliedChanges.count
                    } else {
                        // Fallback: estimate from content difference
                        let (originalLines, _) = String.splitContentPreservingLineEndings(fileState.originalContent)
                        let (finalLines, _) = String.splitContentPreservingLineEndings(fileState.finalContent)
                        totalLinesChanged = abs(originalLines.count - finalLines.count)
                        totalChunks = 1
                        editsApplied = 1
                    }
                    
                    // Generate the unified diff text
                    let diffText = await self.generateUnifiedDiff(for: fileState)
                    let limitedDiffText = Self.limitedDiffText(diffText)
                    
                    // Create edit summary data
                    let editSummary = EditSummaryData(
                        status: editsApplied > 0 ? "success" : "no_changes",
                        editsRequested: matchingFile?.proposedChangeCount ?? 1,
                        editsApplied: editsApplied,
                        totalLinesChanged: totalLinesChanged,
                        totalChunks: totalChunks
                    )
                    
                    return MessageDiff(
                        path: fileState.relativePath,
                        editSummary: editSummary,
                        diffText: limitedDiffText
                    )
                }
            }
            
            var results: [MessageDiff] = []
            for await result in group {
                if let diff = result {
                    results.append(diff)
                }
            }
            return results
        }
        
        // Store the diff summaries in the message
        updateMessage(withId: messageId) { message in
            message.setDiffSummaries(diffSummaries)
        }
    }
    
    /// Generate unified diff text from a ChangedFileState
    private func generateUnifiedDiff(for fileState: ChangedFileState) async -> String {
        let (originalLines, _) = fileState.action == "create"
            ? (nil, "\n")
            : String.splitContentPreservingLineEndings(fileState.originalContent)
        let (finalLines, _) = fileState.action == "delete"
            ? (nil, "\n")
            : String.splitContentPreservingLineEndings(fileState.finalContent)
        
        do {
            return try await UnifiedDiffGenerator.build(
                oldLines: originalLines,
                newLines: finalLines,
                filePath: fileState.relativePath
            )
        } catch {
            print("Error generating unified diff: \(error)")
            return ""
        }
    }
    
	nonisolated static func limitedDiffText(_ diff: String) -> String? {
		guard !diff.isEmpty else { return nil }
		guard diff.count > maxDiffCharactersPerFile else { return diff }
		
		let cutoffIndex = diff.index(diff.startIndex, offsetBy: maxDiffCharactersPerFile, limitedBy: diff.endIndex) ?? diff.endIndex
		let truncatedString = String(diff[..<cutoffIndex])
		return truncatedString + "\n...diff truncated due to size..."
	}
    
    /// Get diff summaries for a specific message (used by MCP tools)
    func getDiffSummaries(for messageId: UUID) -> [MessageDiff] {
        return getChatMessage(withId: messageId)?.diffSummaries ?? []
    }
}
