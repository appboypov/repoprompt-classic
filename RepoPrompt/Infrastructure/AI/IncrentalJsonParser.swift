import Foundation
import SwiftyJSON

class IncrementalJSONParser {
	private var buffer: String = ""
	private let decoder = JSONDecoder()
	private let parserQueue = DispatchQueue(label: "com.repoprompt.jsonparser")
	
	private let startDelimiter = "###JSON_START###"
	private let endDelimiter = "###JSON_END###"
	
	private let maxBufferSize = 100_000_000 // 100 MB, adjust as needed
	private var partialJSON: String?
	
	private var processedFilePaths: Set<String> = []
	private var lastProcessedIndex: String.Index?
	
	func parse(_ chunk: String) -> (responses: [FileChanges]?, summary: String?) {
		print("DEBUG: Parsing chunk: \(chunk)")
		var result: (responses: [FileChanges]?, summary: String?)
		
		parserQueue.sync {
			self.buffer += chunk
			if self.buffer.count > self.maxBufferSize {
				print("WARNING: Buffer exceeded maximum size. Truncating.")
				self.buffer = String(self.buffer.suffix(self.maxBufferSize))
				self.lastProcessedIndex = nil // Reset last processed index if we truncate
			}
			
			let jsonObjects = self.extractJSONObjects()
			print("DEBUG: Extracted \(jsonObjects.count) JSON objects")
			
			var fileChanges: [FileChanges] = []
			var summary: String?
			
			for jsonString in jsonObjects {
				print("DEBUG: Processing JSON object: \(jsonString)")
				if let fileChange = self.parseFileChangeObject(jsonString) {
					print("DEBUG: Parsed file change object")
					if !processedFilePaths.contains(fileChange.path) {
						fileChanges.append(fileChange)
						processedFilePaths.insert(fileChange.path)
					}
				} else if let overallSummary = self.parseOverallSummaryObject(jsonString) {
					print("DEBUG: Parsed overall summary object")
					summary = overallSummary
				} else {
					print("DEBUG: Failed to parse JSON object")
				}
			}
			
			result = (responses: fileChanges.isEmpty ? nil : fileChanges, summary: summary)
		}
		
		print("DEBUG: Parse result - responses: \(result.responses?.count ?? 0), summary: \(result.summary != nil)")
		return result
	}
	
	func parseCompleteDiff(_ completeOutput: String) -> FileChanges? {
		print("DEBUG: Parsing complete diff output")
		
		// Extract JSON content between delimiters
		guard let jsonStartIndex = completeOutput.range(of: "###JSON_START###")?.upperBound,
			  let jsonEndIndex = completeOutput.range(of: "###JSON_END###")?.lowerBound,
			  jsonStartIndex < jsonEndIndex else {
			print("ERROR: JSON delimiters not found or in incorrect order")
			return nil
		}
		
		var jsonString = String(completeOutput[jsonStartIndex..<jsonEndIndex])
		print("DEBUG: Original JSON string: \(jsonString)")
		
		// Use the robust line ending splitter
		let (lines, _) = String.splitContentPreservingLineEndings(jsonString)
		jsonString = lines.joined(separator: "\n")
		
		// Aggressively trim leading and trailing whitespace
		jsonString = jsonString.trimmingCharacters(in: .whitespacesAndNewlines)
		
		// Remove any potential BOM (Byte Order Mark) characters
		if jsonString.hasPrefix("\u{FEFF}") {
			jsonString = String(jsonString.dropFirst())
		}
		
		print("DEBUG: Processed JSON string: \(jsonString)")
		
		// Attempt to parse with SwiftyJSON
		if let fileChanges = parseJSONWithSwiftyJSON(jsonString) {
			return fileChanges
		}
		
		// If SwiftyJSON fails, try with JSONSerialization
		print("DEBUG: SwiftyJSON parsing failed. Attempting with JSONSerialization...")
		if let fileChanges = parseJSONWithJSONSerialization(jsonString) {
			return fileChanges
		}
		
		// If both methods fail, try cleaning the JSON
		print("DEBUG: Attempting to clean and parse JSON...")
		let cleanedJsonString = cleanJsonString(jsonString)
		print("DEBUG: Cleaned JSON string: \(cleanedJsonString)")
		
		// Try SwiftyJSON again with cleaned JSON
		if let fileChanges = parseJSONWithSwiftyJSON(cleanedJsonString) {
			return fileChanges
		}
		
		// Finally, try JSONSerialization with cleaned JSON
		if let fileChanges = parseJSONWithJSONSerialization(cleanedJsonString) {
			return fileChanges
		}
		
		print("ERROR: All parsing attempts failed")
		return nil
	}
	
	private func parseJSONWithSwiftyJSON(_ jsonString: String) -> FileChanges? {
		guard let jsonData = jsonString.data(using: .utf8) else {
			print("ERROR: Failed to convert JSON string to data")
			return nil
		}
		
		do {
			let json = try JSON(data: jsonData)
			
			guard let filePath = json["file_path"].string else {
				print("ERROR: Missing or invalid file_path in JSON")
				return nil
			}
			
			let changes = json["changes"].arrayValue.compactMap { changeJson -> FileChange? in
				guard let description = changeJson["description"].string,
					  let startLine = changeJson["start_line"].int else {
					print("WARNING: Skipping invalid change object")
					return nil
				}
				
				let chunkLines = changeJson["chunk"].arrayValue.map { self.processLine($0.stringValue) }
				let diffChunk = DiffChunk(lines: chunkLines.map { DiffLine(content: $0) }, startLine: startLine)
				
				return FileChange(
					startLine: startLine,
					description: description,
					diffChunk: diffChunk
				)
			}
			
			if changes.isEmpty {
				print("WARNING: No valid changes found for file: \(filePath)")
			}
			
			return FileChanges(relativePath: filePath, changes: changes, action: .modify)
		} catch {
			print("ERROR: Failed to parse JSON with SwiftyJSON: \(error)")
			return nil
		}
	}
	
	private func parseJSONWithJSONSerialization(_ jsonString: String) -> FileChanges? {
		guard let jsonData = jsonString.data(using: .utf8) else {
			print("ERROR: Failed to convert JSON string to data")
			return nil
		}
		
		do {
			if let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: []) as? [String: Any],
			   let filePath = jsonObject["file_path"] as? String,
			   let changes = jsonObject["changes"] as? [[String: Any]] {
				
				let fileChanges = changes.compactMap { change -> FileChange? in
					guard let description = change["description"] as? String,
						  let startLine = change["start_line"] as? Int,
						  let chunk = change["chunk"] as? [String] else {
						return nil
					}
					
					let diffChunk = DiffChunk(lines: chunk.map { DiffLine(content: processLine($0)) }, startLine: startLine)
					return FileChange(startLine: startLine, description: description, diffChunk: diffChunk)
				}
				
				return FileChanges(relativePath: filePath, changes: fileChanges, action: .modify)
			}
		} catch {
			print("ERROR: Failed to parse JSON with JSONSerialization: \(error)")
		}
		
		return nil
	}
	
	private func extractJSONObjects() -> [String] {
		var jsonObjects: [String] = []
		var searchStartIndex = lastProcessedIndex ?? buffer.startIndex
		
		while let startRange = buffer.range(of: startDelimiter, range: searchStartIndex..<buffer.endIndex),
			  let endRange = buffer.range(of: endDelimiter, range: startRange.upperBound..<buffer.endIndex) {
			
			let jsonString = String(buffer[startRange.upperBound..<endRange.lowerBound])
			jsonObjects.append(jsonString)
			
			searchStartIndex = endRange.upperBound
		}
		
		// Handle partial JSON at the end of the buffer
		if let lastStartRange = buffer.range(of: startDelimiter, range: searchStartIndex..<buffer.endIndex) {
			partialJSON = String(buffer[lastStartRange.upperBound...])
			lastProcessedIndex = lastStartRange.lowerBound
		} else {
			partialJSON = nil
			lastProcessedIndex = buffer.endIndex
		}
		
		return jsonObjects
	}
	
	private func parseFileChangeObject(_ jsonString: String) -> FileChanges? {
		print("DEBUG: Original JSON string for file change: \(jsonString)")
		
		if let jsonData = jsonString.data(using: .utf8) {
			do {
				let json = try JSON(data: jsonData)
				
				guard json["file_path"].exists() && json["changes"].exists() else {
					return nil
				}
				
				let filePath = json["file_path"].stringValue
				let changes = json["changes"].arrayValue.map { changeJson -> FileChange in
					let description = changeJson["description"].stringValue
					let startLine = changeJson["start_line"].intValue
					let chunkLines = changeJson["chunk"].arrayValue.map { self.processLine($0.stringValue) }
					let diffChunk = DiffChunk(lines: chunkLines.map { DiffLine(content: $0) }, startLine: startLine)
					return FileChange(startLine: startLine, description: description, diffChunk: diffChunk)
				}
				
				// Discard file changes with empty arrays
				if changes.isEmpty {
					print("DEBUG: Discarding cleaned file change with empty array for file: \(filePath)")
					return nil
				}
				
				return FileChanges(relativePath: filePath, changes: changes, action: .modify)
			} catch {
				print("DEBUG: Failed to parse JSON with SwiftyJSON: \(error)")
				print("Attempting to clean and parse JSON...")
				return parseCleanedFileChangeObject(jsonString)
			}
		}
		
		print("DEBUG: Failed to convert string to data")
		return nil
	}
	
	private func parseCleanedFileChangeObject(_ jsonString: String) -> FileChanges? {
		let cleanedJsonString = cleanJsonString(jsonString)
		print("DEBUG: Cleaned JSON string for file change: \(cleanedJsonString)")
		
		if let jsonData = cleanedJsonString.data(using: .utf8) {
			do {
				let json = try JSON(data: jsonData)
				let filePath = json["file_path"].stringValue
				let changes = json["changes"].arrayValue.map { changeJson -> FileChange in
					let description = changeJson["description"].stringValue
					let startLine = changeJson["start_line"].intValue
					let chunkLines = changeJson["chunk"].arrayValue.map { self.processLine($0.stringValue) }
					let diffChunk = DiffChunk(lines: chunkLines.map { DiffLine(content: $0) }, startLine: startLine)
					return FileChange(startLine: startLine, description: description, diffChunk: diffChunk)
				}
				
				// Discard file changes with empty arrays
				if changes.isEmpty {
					print("DEBUG: Discarding cleaned file change with empty array for file: \(filePath)")
					return nil
				}
				
				return FileChanges(relativePath: filePath, changes: changes, action: .modify)
			} catch {
				print("DEBUG: Failed to parse cleaned JSON with SwiftyJSON: \(error)")
			}
		}
		
		print("DEBUG: Failed to parse JSON")
		return nil
	}
	
	private func parseOverallSummaryObject(_ jsonString: String) -> String? {
		print("DEBUG: Original JSON string for overall summary: \(jsonString)")
		
		if let jsonData = jsonString.data(using: .utf8) {
			do {
				let json = try JSON(data: jsonData)
				
				// Check if this JSON object actually contains an overall summary
				guard json["overall_summary"].exists() else {
					return nil
				}
				
				return json["overall_summary"].stringValue
			} catch {
				print("DEBUG: Failed to parse overall summary JSON: \(error)")
				print("Attempting to clean and parse JSON...")
				return parseCleanedOverallSummaryObject(jsonString)
			}
		}
		
		print("DEBUG: Failed to convert string to data")
		return nil
	}
	
	private func parseCleanedOverallSummaryObject(_ jsonString: String) -> String? {
		let cleanedJsonString = cleanJsonString(jsonString)
		print("DEBUG: Cleaned JSON string for overall summary: \(cleanedJsonString)")
		
		if let jsonData = cleanedJsonString.data(using: .utf8) {
			do {
				let json = try JSON(data: jsonData)
				return json["overall_summary"].stringValue
			} catch {
				print("ERROR: Failed to decode cleaned overall summary JSON: \(error)")
				print("Problematic JSON:\n\(cleanedJsonString)")
			}
		}
		
		return nil
	}
	
	private func processLine(_ line: String) -> String {
		// Check if the line is blank (only whitespace)
		if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
			return "" // Return an empty string for blank lines
		}
		
		// Trim leading whitespace and handle the +/- prefix
		let trimmedLine = String(line.drop(while: { $0.isWhitespace }))
		var prefix = ""
		var remainingLine = trimmedLine
		
		if trimmedLine.starts(with: "+") || trimmedLine.starts(with: "-") {
			prefix = String(trimmedLine.prefix(1))
			remainingLine = String(trimmedLine.dropFirst())
		}
		
		// Handle the line number and potential whitespace
		let components = remainingLine.split(separator: ":", maxSplits: 1)
		var contentWithIndentation: String
		
		if components.count == 2, let _ = Int(components[0].trimmingCharacters(in: .whitespaces)) {
			// Line has a number, so it's a context line
			contentWithIndentation = String(components[1].drop(while: { $0.isWhitespace }))
		} else {
			// Line doesn't have a number, treat it as is
			contentWithIndentation = String(remainingLine.drop(while: { $0.isWhitespace }))
		}
		
		// Handle the indentation
		let indentationRegex = try! NSRegularExpression(pattern: "^<([st])(\\d+)>\\s*(.*?)\\s*$", options: [])
		if let match = indentationRegex.firstMatch(in: contentWithIndentation, options: [], range: NSRange(contentWithIndentation.startIndex..., in: contentWithIndentation)) {
			let indentType = String(contentWithIndentation[Range(match.range(at: 1), in: contentWithIndentation)!])
			let indentCount = Int(contentWithIndentation[Range(match.range(at: 2), in: contentWithIndentation)!])!
			let content = String(contentWithIndentation[Range(match.range(at: 3), in: contentWithIndentation)!])
			
			let decodedIndentation: String
			if indentType == "t" {
				decodedIndentation = String(repeating: "\t", count: indentCount)
			} else {
				decodedIndentation = String(repeating: " ", count: indentCount)
			}
			
			return prefix + decodedIndentation + content
		} else {
			// If indentation encoding is not found, return the content as is
			return prefix + contentWithIndentation
		}
	}
	
	private func cleanJsonString(_ jsonString: String) -> String {
		var cleaned = jsonString.replacingOccurrences(of: startDelimiter, with: "")
		cleaned = cleaned.replacingOccurrences(of: endDelimiter, with: "")
		
		// Remove any potential JSON comments
		let commentPattern = try! NSRegularExpression(pattern: "(/\\*.*?\\*/|//.*?$)", options: [.dotMatchesLineSeparators])
		cleaned = commentPattern.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "")
		
		// Escape special characters within string values
		let pattern = "\"(?:[^\"\\\\]|\\\\.)*\""
		let regex = try! NSRegularExpression(pattern: pattern, options: [])
		
		let nsRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
		let matches = regex.matches(in: cleaned, options: [], range: nsRange)
		
		for match in matches.reversed() {
			guard let range = Range(match.range, in: cleaned) else { continue }
			var matchedString = String(cleaned[range])
			
			// Remove the surrounding quotes
			matchedString.removeFirst()
			matchedString.removeLast()
			
			// Escape special characters and control characters
			matchedString = matchedString.unicodeScalars.map { scalar in
				switch scalar {
				case "\\":  return "\\\\"
				case "\"":  return "\\\""
				case "\n":  return "\\n"
				case "\r":  return "\\r"
				case "\t":  return "\\t"
				case "\u{8}":  return "\\b"
				case "\u{C}":  return "\\f"
				default:
					if scalar.value < 32 {
						return "\\u{\(String(format: "%04x", scalar.value))}"
					}
					return String(scalar)
				}
			}.joined()
			
			// Put the quotes back
			matchedString = "\"\(matchedString)\""
			
			// Replace the original string with the escaped version
			cleaned.replaceSubrange(range, with: matchedString)
		}
		
		// Ensure all object keys are quoted
		let keyPattern = "([{,])\\s*([a-zA-Z_][a-zA-Z0-9_]*)\\s*:"
		let keyRegex = try! NSRegularExpression(pattern: keyPattern, options: [])
		cleaned = keyRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "$1\"$2\":")
		
		// Remove trailing commas in arrays and objects
		let trailingCommaPattern = ",\\s*([}\\]])"
		let trailingCommaRegex = try! NSRegularExpression(pattern: trailingCommaPattern, options: [])
		cleaned = trailingCommaRegex.stringByReplacingMatches(in: cleaned, options: [], range: NSRange(cleaned.startIndex..., in: cleaned), withTemplate: "$1")
		
		return cleaned
	}
	
	func reset() {
		buffer = ""
		partialJSON = nil
		processedFilePaths.removeAll()
		lastProcessedIndex = nil
	}
}
