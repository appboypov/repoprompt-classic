//
//  MessageDiff.swift
//  RepoPrompt
//
//  Created by RepoPrompt on 2025-07-03.
//

import Foundation

/// Compact DTO that holds diff information for one file changed by a chat message
public struct MessageDiff: Codable {
    /// The file path that was modified
    public let path: String
    
    /// Summary statistics about the edit (lines changed, chunks, etc.)
    public let editSummary: EditSummaryData
    
    /// The actual unified diff text (optional to save memory)
    public let diffText: String?
    
    public init(path: String, editSummary: EditSummaryData, diffText: String?) {
        self.path = path
        self.editSummary = editSummary
        self.diffText = diffText
    }
}

/// Simplified version of EditSummary that's more suitable for storage and transmission
public struct EditSummaryData: Codable {
    public let status: String              // "success", "partial", "failed"
    public let editsRequested: Int
    public let editsApplied: Int
    public let totalLinesChanged: Int?     // present when editsApplied > 0
    public let totalChunks: Int?           // present when editsApplied > 0
    
    public init(status: String, editsRequested: Int, editsApplied: Int, 
                totalLinesChanged: Int?, totalChunks: Int?) {
        self.status = status
        self.editsRequested = editsRequested
        self.editsApplied = editsApplied
        self.totalLinesChanged = totalLinesChanged
        self.totalChunks = totalChunks
    }
    
    /// Create from the full EditSummary used by apply_edits tool
    /// Note: We can't directly reference EditSummary since it's private to MCPServerViewModel
    public static func fromEditSummary(status: String, editsRequested: Int, editsApplied: Int,
                                       totalLinesChanged: Int?, totalChunks: Int?) -> EditSummaryData {
        return EditSummaryData(
            status: status,
            editsRequested: editsRequested,
            editsApplied: editsApplied,
            totalLinesChanged: totalLinesChanged,
            totalChunks: totalChunks
        )
    }
}
