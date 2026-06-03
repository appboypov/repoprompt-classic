import Foundation
import MCP                     // for Value

struct ChatSendReply: Codable {
    let chatId   : UUID
    let shortId  : String
    let mode     : String
    let response : String?
    let errors   : [String]?
    let diffs    : [MessageDiff]?

    func toMCPValue() -> Value {
        var obj: [String: Value] = [
            "chat_id"  : .string(shortId),  // Only expose short ID
            "mode"     : .string(mode)
        ]
        if let r = response { obj["response"] = .string(r) }
        if let e = errors   { obj["errors"]   = .array(e.map { .string($0) }) }
        if let d = diffs    { obj["diffs"]    = .array(d.map { $0.toMCPValue() }) }

        return .object(obj)
    }
}

// Extension to support MessageDiff conversion
extension MessageDiff {
    func toMCPValue() -> Value {
        var dict: [String: Value] = [
            "path": .string(path)
        ]
        
        // Build edit summary object
        var editSummaryDict: [String: Value] = [
            "status": .string(editSummary.status),
            "edits_requested": .int(editSummary.editsRequested),
            "edits_applied": .int(editSummary.editsApplied)
        ]
        
        if let totalLinesChanged = editSummary.totalLinesChanged {
            editSummaryDict["total_lines_changed"] = .int(totalLinesChanged)
        }
        
        if let totalChunks = editSummary.totalChunks {
            editSummaryDict["total_chunks"] = .int(totalChunks)
        }
        
        dict["edit_summary"] = .object(editSummaryDict)
        
        if let diffText = diffText {
            dict["diff_text"] = .string(diffText)
        }
        
        return .object(dict)
    }
}
