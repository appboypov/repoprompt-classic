import Foundation

/// A Swift wrapper for the C implementation of ChatContentParser (STAGED VERSION)
final class ChatContentParserStaged {
    
    // MARK: - Debug Configuration
    /// Set to true to enable detailed logging for description extraction debugging
    static var enableDebugLogging: Bool = false {
        didSet {
            repo_set_debug_logging(enableDebugLogging)
        }
    }
    
    /// Convenience method to enable/disable debug logging
    static func setDebugLogging(_ enabled: Bool) {
        enableDebugLogging = enabled
    }
    
    /// Main entry point for parsing content
    static func parseContent(
        _ content: String,
        processedDelegateEditHashes: inout Set<Int>,
        isFinal: Bool = true
    ) -> ([ContentItem], String, [DelegateEditItem]) {
        
        // Convert Swift Set to C array
        let hashArray = Array(processedDelegateEditHashes).map { Int64($0) }
        
        // Call C implementation
        let result = content.withCString { cString in
            if hashArray.isEmpty {
                return repo_parse_content(
                    cString,
                    nil,
                    0,
                    isFinal,
                    enableDebugLogging
                )
            } else {
                var mutableHashArray = hashArray
                return mutableHashArray.withUnsafeMutableBufferPointer { buffer in
                    repo_parse_content(
                        cString,
                        buffer.baseAddress,
                        hashArray.count,
                        isFinal,
                        enableDebugLogging
                    )
                }
            }
        }
        
        guard let parseResult = result else {
            return ([], "", [])
        }
        
        // Convert C results to Swift types
        var items: [ContentItem] = []
        var delegateEdits: [DelegateEditItem] = []
        
        // Convert ContentItems
        for i in 0..<parseResult.pointee.item_count {
            let cItem = parseResult.pointee.items[i]
            
            // Convert content type
            let type: ContentType
            switch cItem.type {
            case CONTENT_TYPE_TEXT:
                type = .text
            case CONTENT_TYPE_FILE:
                type = .file
            case CONTENT_TYPE_CODE:
                type = .code
            default:
                type = .text
            }
            
            // Convert changes and descriptions
            var changes: [String] = []
            var descriptions: [String] = []
            
            if let cChanges = cItem.changes {
                var idx = 0
                while let change = cChanges[idx] {
                    changes.append(String(cString: change))
                    idx += 1
                }
            }
            
            if let cDescriptions = cItem.descriptions {
                var idx = 0
                while let desc = cDescriptions[idx] {
                    descriptions.append(String(cString: desc))
                    idx += 1
                }
            }
            
            // Create ContentItem (line segments no longer needed)
            let item = ContentItem(
                startIndexInStream: Int(cItem.start_index_in_stream),
                type: type,
                content: String(cString: cItem.content),
                filePath: cItem.file_path.map { String(cString: $0) } ?? "",
                action: cItem.action.map { String(cString: $0) } ?? "",
                changes: changes,
                descriptions: descriptions
            )
            
            items.append(item)
        }
        
        // Convert core content
        let coreContent = String(cString: parseResult.pointee.core_content)
        
        // Convert DelegateEditItems
        for i in 0..<parseResult.pointee.delegate_edit_count {
            var changes: [DelegateEditItem.Change] = []
            for j in 0..<parseResult.pointee.delegate_edits[i].change_count {
                let cChange = parseResult.pointee.delegate_edits[i].changes[j]
                changes.append(DelegateEditItem.Change(
                    description: String(cString: cChange.description),
                    codeSnippet: String(cString: cChange.code_snippet),
                    complexity: Int(cChange.complexity)
                ))
            }
            
            let delegateEdit = DelegateEditItem(
                filePath: String(cString: parseResult.pointee.delegate_edits[i].file_path),
                changes: changes
            )
            
            delegateEdits.append(delegateEdit)
            
            // Update processed hashes
            let hash = repo_hash_delegate_edit_item(&parseResult.pointee.delegate_edits[i])
            processedDelegateEditHashes.insert(Int(hash))
        }
        
        // Free the C result
        repo_free_parse_result(result)
        
        return (items, coreContent, delegateEdits)
    }
    
    // MARK: - Helper methods that delegate to C implementations
    
    static func removeOuterBackticks(from content: String) -> String {
        let bufferSize = content.utf8.count + 1
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        
        let success = content.withCString { cString in
            repo_remove_outer_backticks(buffer, cString, bufferSize)
        }
        
        return success ? String(cString: buffer) : content
    }
    
	static func trimLeadingWhitespace(_ lines: [String]) -> [String] {
		guard !lines.isEmpty else { return lines }
		
		let decodedLines = lines.map { decodeIndentationTag($0) }
		
		var minWhitespace: Int?
		for line in decodedLines {
			if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
				continue
			}
			let count = leadingWhitespaceCount(in: line)
			minWhitespace = min(minWhitespace ?? count, count)
		}
		
		let trimCount = minWhitespace ?? 0
		guard trimCount > 0 else { return decodedLines }
		
		return decodedLines.map { line in
			if line.count <= trimCount {
				return ""
			}
			let index = line.index(line.startIndex, offsetBy: trimCount)
			return String(line[index...])
		}
	}
	
	private static func leadingWhitespaceCount(in line: String) -> Int {
		var count = 0
		for ch in line {
			if ch == " " || ch == "\t" {
				count += 1
			} else {
				break
			}
		}
		return count
	}
	
	private static func decodeIndentationTag(_ line: String) -> String {
		guard line.hasPrefix("<"), let closeIndex = line.firstIndex(of: ">") else {
			return line
		}
		
		let tagStart = line.index(after: line.startIndex)
		let tagContent = line[tagStart..<closeIndex]
		guard tagContent.count >= 2 else { return line }
		
		guard let typeChar = tagContent.first, typeChar == "s" || typeChar == "t" else {
			return line
		}
		
		let countStr = tagContent.dropFirst()
		guard !countStr.isEmpty, countStr.count < 20 else { return line }
		for ch in countStr where ch < "0" || ch > "9" {
			return line
		}
		guard let count = Int(countStr), count <= 1_000_000 else { return line }
		
		let indentChar = typeChar == "t" ? "\t" : " "
		let indent = String(repeating: String(indentChar), count: count)
		let rest = line[line.index(after: closeIndex)...]
		return indent + rest
	}
    
    static func extractDescription(from content: String) -> String {
        // Allocate a buffer based on content size to avoid truncation
        let bufferSize = content.utf8.count + 1
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        
        // Call the C function
        let success = content.withCString { cString in
            repo_extract_description(buffer, cString, bufferSize)
        }
        
        // Return the result (empty string if not found)
        return success ? String(cString: buffer) : ""
    }
    
    static func extractComplexity(from content: String) -> Int? {
        // Call the C function
        let result = content.withCString { cString in
            repo_extract_complexity(cString)
        }
        
        // Return nil if -1 (not found), otherwise return the value
        return result == -1 ? nil : Int(result)
    }
    
    static func decodeIndentationInCodeBlock(_ codeBlock: String) -> String {
        guard let decoded = codeBlock.withCString({ cString in
            repo_decode_indentation_in_code_block(cString)
        }) else {
            return codeBlock
        }
        
        let result = String(cString: decoded)
        free(decoded)
        return result
    }
    
	static func parseAndRemoveChatName(from content: inout String) -> String? {
		// Create a mutable copy
		var mutableContent = strdup(content)
		defer { free(mutableContent) }
		
		// Parse and remove chat name
		guard let chatName = repo_parse_and_remove_chat_name(&mutableContent) else {
			return nil
		}
		
		// Update the content
		content = String(cString: mutableContent!)
		
		// Return the chat name
		let name = String(cString: chatName)
		free(chatName)
		return name
	}
    
    static func extractScopeDescription(from snippet: String) -> String {
        guard let desc = snippet.withCString({ cString in
            repo_extract_scope_description(cString)
        }) else {
            return ""
        }
        
        let result = String(cString: desc)
        free(desc)
        return result
    }
    
    // MARK: - Utility functions that remain in Swift
    
    static func extractCodeContent(from content: String, _ isFinal: Bool) -> String {
        if let contentMatch = extractContent(from: content, tag: "content", isFinal) {
            return trimContent(contentMatch)
        }
        return ""
    }
    
    static func extractContent(from input: String, tag: String, _ isFinal: Bool) -> String? {
        return DiffParserUtils.extractContent(from: input, tag: tag, flexible: true)
    }
    
    static func trimContent(_ content: String) -> String {
        let lines = DiffParserUtils.splitContentToLines(content, true)
        let trimmedLines = trimLeadingWhitespace(lines)
        return trimmedLines.joined(separator: "\n")
    }
}
