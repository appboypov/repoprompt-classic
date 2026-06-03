import Foundation

/// A purely static parser to extract files, plans, and changes from raw text.
/// Optionally, pass in a `processedDelegateEditHashes` set to avoid reprocessing
/// the same delegate edits (identified by hash).
final class ChatContentParser {
	
	// MARK: - Debug Configuration
	/// Set to true to enable detailed logging for description extraction debugging
	static var enableDebugLogging: Bool = false
	
	/// Convenience method to enable/disable debug logging
	static func setDebugLogging(_ enabled: Bool) {
		enableDebugLogging = enabled
		if enabled {
			print("[ChatContentParser] 🐛 Debug logging ENABLED")
		} else {
			print("[ChatContentParser] 🐛 Debug logging DISABLED")
		}
	}
	
	// MARK: - Performance Caches
	// PERF: cache placeholder regex by comment style (HTML / C-style // / Python/SQL)
	private static let _placeholderRxCache = NSCache<NSString, NSRegularExpression>()
	
	// PERF: reuse once instead of creating a new regex per finalize
	private static let _rxTrailingSpacesTabsAtEOF = try! NSRegularExpression(pattern: #"[ \t]+$"#, options: [])
	
	// PERF: used by placeholder-key canonicalization
	private static let _rxCollapseWhitespace = try! NSRegularExpression(pattern: #"\s+"#, options: [])
	
	// PERF: fast blank-line test (avoid String.trimming allocations)
	private static let _notWhitespaceSet = CharacterSet.whitespacesAndNewlines.inverted
	
	// MARK: - Regex Helpers
	private static let fileRegex = try! NSRegularExpression(
		pattern: "<file\\s+path\\s*=\\s*\"([^\"]+)\"\\s+action\\s*=\\s*\"([^\"]+)\"[^>]*>",
		options: [.caseInsensitive, .dotMatchesLineSeparators]
	)
	
	private static let fileEndRegex = try! NSRegularExpression(
		pattern: "</file\\s*>",
		options: [.caseInsensitive]
	)
	
	private static let planRegex = try! NSRegularExpression(
		pattern: "<Plan[^>]*>",
		options: [.caseInsensitive, .dotMatchesLineSeparators]
	)
	private static let planEndRegex = try! NSRegularExpression(
		pattern: "</Plan\\s*>",
		options: [.caseInsensitive]
	)
	
	private static let changeRegex = try! NSRegularExpression(pattern: "<change\\s*>", options: [.caseInsensitive])
	private static let changeEndRegex = try! NSRegularExpression(pattern: "</change\\s*>", options: [.caseInsensitive])
	
	private static let descriptionRegex = try! NSRegularExpression(
		pattern: "<description>(.*?)</description>",
		options: [.dotMatchesLineSeparators]
	)
	private static let complexityRegex = try! NSRegularExpression(
		pattern: "<complexity>(\\d+)</complexity>",
		options: [.dotMatchesLineSeparators]
	)
	
	// If you were using this for case-insensitive detection, keep or remove as needed:
	private static let delegateEditActionRegex = try! NSRegularExpression(
		pattern: "action\\s*=\\s*\"delegate\\s+edit\"",
		options: [.caseInsensitive]
	)
	
	// Supports C-style (//), Python (#), SQL (--), and HTML (<!-- … -->) comment markers
	private static let scopeMarkerRegex = try! NSRegularExpression(
		pattern: #"(?m)^\s*(?://|#|--|<!--)\s*REPOMARK\s*:\s*SCOPE\s*:\s*\d+\s*-\s*(.+?)(?:-->)*\s*$"#,
		options: [.caseInsensitive]
	)
	
	// MARK: - Comment-style helpers
	private enum CommentPrefix: String {
		case cStyle = "//"
		case python = "#"
		case sql    = "--"
		case html   = "<!--"
	}
	
	/// Returns the most likely single-line comment prefix based on file extension.
	private static func commentPrefix(for filePath: String) -> CommentPrefix {
		let ext = (filePath as NSString).pathExtension.lowercased()
		switch ext {
		case "py":             return .python
		case "rb", "sh", "bash": return .python
		case "sql", "sqlite":   return .sql
		case "html", "htm", "xml", "xhtml": return .html
		default:               return .cStyle       // default to C-style "//"
		}
	}
	
	/// Builds a language-aware placeholder regex for `… existing code …` lines.
	private static func placeholderRegex(for filePath: String) -> NSRegularExpression {
		let prefix = commentPrefix(for: filePath)
		let cacheKey = prefix.rawValue as NSString
		if let cached = _placeholderRxCache.object(forKey: cacheKey) {
			return cached
		}
		
		let pattern: String
		switch prefix {
		case .html:
			pattern = #"(?im)^\s*<!--\s*.*\.\.\.\s*.*existing\s+code.*\s*\.\.\.\s*-->\s*$"#
		case .cStyle:
			pattern = #"(?im)^\s*(?://\s*.*\.\.\.\s*.*existing\s+code.*\s*\.\.\.\s*|/\*\s*.*\.\.\.\s*.*existing\s+code.*\s*\.\.\.\s*\*/)\s*$"#
		default:
			let escaped = NSRegularExpression.escapedPattern(for: prefix.rawValue)
			pattern = #"(?im)^\s*\#(escaped)\s*.*\.\.\.\s*.*existing\s+code.*\s*\.\.\.\s*$"#
		}
		
		if let rx = try? NSRegularExpression(pattern: pattern, options: []) {
			_placeholderRxCache.setObject(rx, forKey: cacheKey)
			return rx
		} else {
			let fallback =
			#"(?im)^\s*(?:"# +
			#"<!--.*\.\.\..*existing\s+code.*\.\.\..*-->|"# +
			#"//.*\.\.\..*existing\s+code.*\.\.\..*|"# +
			#"/\*.*\.\.\..*existing\s+code.*\.\.\..*\*/|"# +
			#"#.*\.\.\..*existing\s+code.*\.\.\..*|"# +
			#"--.*\.\.\..*existing\s+code.*\.\.\..*"# +
			#")\s*$"#
			let rx = try! NSRegularExpression(pattern: fallback, options: [])
			_placeholderRxCache.setObject(rx, forKey: cacheKey)
			return rx
		}
	}
	
	// MARK: – Delegate-edit integrity helpers
	/// A delegate-edit block is considered "complete" when every
	/// <change> opener has its matching </change> and at least one
	/// pair exists.
	private static func isDelegateEditBlockComplete(_ body: String) -> Bool {
		let open  = changeRegex .numberOfMatches(in: body,
												 range: NSRange(body.startIndex..., in: body))
		let close = changeEndRegex.numberOfMatches(in: body,
												   range: NSRange(body.startIndex..., in: body))
		return open > 0 && open == close
	}
	
	/// Main entry point for parsing content. It returns:
	/// - An array of parsed ContentItem's,
	/// - The extracted "core" text content,
	/// - And any new delegate edits (skipping those whose hash is already in `processedDelegateEditHashes`).
	///
	/// Pass `isFinal = false` for partial/streaming parses, so we skip removing incomplete file tags.
	static func parseContent(
		_ content: String,
		processedDelegateEditHashes: inout Set<Int>,
		isFinal: Bool = true
	) -> ([ContentItem], String, [DelegateEditItem]) {
		var items: [ContentItem] = []
		var coreContent = ""
		var newDelegateEditItems: [DelegateEditItem] = []
		var currentIndex = 0
		let parseState = EditFlowPerf.begin(
			EditFlowPerf.Stage.Parser.chatContentParse,
			EditFlowPerf.Dimensions(
				status: isFinal ? "final" : "streaming",
				inputBytes: content.utf8.count
			)
		)
		defer {
			EditFlowPerf.end(
				EditFlowPerf.Stage.Parser.chatContentParse,
				parseState,
				EditFlowPerf.Dimensions(
					status: isFinal ? "final" : "streaming",
					inputBytes: content.utf8.count,
					contentItemCount: items.count,
					delegateEditCount: newDelegateEditItems.count
				)
			)
		}
		
		// NEW: Keep track of an overall "itemIndex" so each new ContentItem can have a stable startIndexInStream.
		var itemIndex = 0
		
		let cDataStrippedContent = DiffParserUtils.stripCDATA(content)
		
		// Check if content contains any parseable tags
		let containsParseableTags = cDataStrippedContent.range(of: "<file", options: .caseInsensitive) != nil ||
									cDataStrippedContent.range(of: "<Plan", options: .caseInsensitive) != nil ||
									cDataStrippedContent.range(of: "<change>", options: .caseInsensitive) != nil
		
		// Only remove outer backticks if we have parseable content
		// This prevents breaking regular messages with multiple code blocks
		let cleanedContent = containsParseableTags ?
							removeOuterBackticks(from: cDataStrippedContent) :
							cDataStrippedContent
		let totalLength = cleanedContent.utf16.count
		
		while currentIndex < totalLength {
			// 1) Search for next <Plan> or <file> in the *entire cleanedContent*, but restricted to [currentIndex..end]
			let searchRange = NSRange(location: currentIndex, length: totalLength - currentIndex)
			
			let planCandidate = planRegex.firstMatch(in: cleanedContent, options: [], range: searchRange)
			let fileCandidate = fileRegex.firstMatch(in: cleanedContent, options: [], range: searchRange)
			
			// If we found neither, parse the *remaining* text as text and bail.
			guard (planCandidate != nil) || (fileCandidate != nil) else {
				if let remainingRange = Range(NSRange(location: currentIndex, length: totalLength - currentIndex), in: cleanedContent) {
					let remainingText = cleanedContent[remainingRange]
					// Pass itemIndex inout to handle partial text as well
					processAndAddTextContent(String(remainingText), &items, &coreContent, isFinal: isFinal, itemIndex: &itemIndex)
				}
				currentIndex = totalLength
				break
			}
			
			let planStart = planCandidate?.range.lowerBound ?? Int.max
			let fileStart = fileCandidate?.range.lowerBound ?? Int.max
			let nextBlockStart = min(planStart, fileStart)
			
			// 2) If there’s plain text before that block, parse it first
			if nextBlockStart > currentIndex {
				if let textRange = Range(NSRange(location: currentIndex, length: nextBlockStart - currentIndex), in: cleanedContent) {
					let textFragment = String(cleanedContent[textRange])
					processAndAddTextContent(textFragment, &items, &coreContent, isFinal: isFinal, itemIndex: &itemIndex)
				}
				currentIndex = nextBlockStart
			}
			
			// 3) Determine which block is next: <Plan> or <file>?
			if planStart < fileStart {
				// We have a <Plan> block at planStart
				guard let planMatch = planCandidate else { continue }
				guard let planOpenRange = Range(planMatch.range, in: cleanedContent) else {
					currentIndex = planMatch.range.upperBound
					continue
				}
				
				// Look for the matching </Plan>
				let afterPlanOpen = planMatch.range.upperBound
				let planSearchRange = NSRange(location: afterPlanOpen, length: totalLength - afterPlanOpen)
				guard let planEndMatch = planEndRegex.firstMatch(in: cleanedContent, options: [], range: planSearchRange) else {
					// No closing </Plan>; treat the rest as plan content
					let planText = cleanedContent[planOpenRange.upperBound...]
					
					// NEW: Use itemIndex for stable ID
					let partialPlanItem = ContentItem(
						startIndexInStream: itemIndex,
						type: .text,
						content: planText.trimmingCharacters(in: .whitespacesAndNewlines)
					)
					items.append(partialPlanItem)
					itemIndex += 1
					
					coreContent += "Plan:\n\(planText)\n\n"
					currentIndex = totalLength
					break
				}
				
				// We have <Plan>...some text...</Plan>
				let planContentStart = afterPlanOpen
				let planContentEnd = planEndMatch.range.lowerBound
				let planRange = NSRange(location: planContentStart, length: planContentEnd - planContentStart)
				if let swiftRange = Range(planRange, in: cleanedContent) {
					let planContent = cleanedContent[swiftRange].trimmingCharacters(in: .whitespacesAndNewlines)
					
					// NEW: Use itemIndex for stable ID
					let planItem = ContentItem(
						startIndexInStream: itemIndex,
						type: .text,
						content: planContent
					)
					items.append(planItem)
					itemIndex += 1
					
					coreContent += "Plan:\n\(planContent)\n\n"
				}
				
				// Advance currentIndex *beyond* the closing tag
				currentIndex = planEndMatch.range.upperBound
			}
			else {
				// We have a <file> block at fileStart
				guard let fileMatch = fileCandidate else { continue }
				
				// Extract filePath & action
				let filePathRange = fileMatch.range(at: 1)
				let actionRange   = fileMatch.range(at: 2)
				guard let swiftFilePath = Range(filePathRange, in: cleanedContent),
					  let swiftAction   = Range(actionRange,   in: cleanedContent) else {
					currentIndex = fileMatch.range.upperBound
					continue
				}
				let filePath    = String(cleanedContent[swiftFilePath])
				let actionString = String(cleanedContent[swiftAction])
				
				// Then find the closing </file>
				let fileBlockStart = fileMatch.range.upperBound
				let fileSearchRange = NSRange(location: fileBlockStart, length: totalLength - fileBlockStart)
				
				if let fileEndMatch = fileEndRegex.firstMatch(in: cleanedContent, options: [], range: fileSearchRange) {
					// We have <file>...stuff...</file>
					let fileContentEnd = fileEndMatch.range.lowerBound
					let fileRange = NSRange(location: fileBlockStart, length: fileContentEnd - fileBlockStart)
					
					if let swiftFileRange = Range(fileRange, in: cleanedContent) {
						let fileContent = String(cleanedContent[swiftFileRange])
						
						if actionString.lowercased().contains("delegate") {
							
							// ── ONLY emit when the block is truly complete ────────────────
							guard isFinal || isDelegateEditBlockComplete(fileContent) else {
								// still add the ContentItem so the UI shows the preview
								// but DO NOT create a DelegateEditItem yet
								let previewItem = ContentItem(
									startIndexInStream: itemIndex,
									type: .file,
									content: fileContent,
									filePath: filePath,
									action: actionString)
								items.append(previewItem)
								itemIndex += 1
								currentIndex = fileEndMatch.range.upperBound
								continue                                          // <-- jump out
							}
							// ──────────────────────────────────────────────────────────────
							
						let (codeChanges, changes) = parseDelegateEdit(fileContent: fileContent, isFinal, filePath: filePath)
						// prefer the descriptions embedded in the Change objects (from scope splitting);
						// fall back to the old XML-based extractor if they're all empty (legacy path).
						var descriptions = changes.map(\.description)
						if descriptions.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
							descriptions = extractChangeDescriptions(from: fileContent)
						}
							
							// NEW: Use itemIndex for stable ID
							let newFileItem = ContentItem(
								startIndexInStream: itemIndex,
								type: .file,
								content: fileContent,
								filePath: filePath,
								action: actionString,
								changes: codeChanges,
								descriptions: descriptions
							)
							items.append(newFileItem)
							itemIndex += 1
							
						let delegateEditItem = DelegateEditItem(filePath: filePath, changes: changes)
						let hash = hashDelegateEditItem(delegateEditItem)
						if !processedDelegateEditHashes.contains(hash) {
							processedDelegateEditHashes.insert(hash)
							newDelegateEditItems.append(delegateEditItem)
						}
							
							coreContent += "File: \(filePath)\n"
							coreContent += "Changes:\n"
							for (index, snippet) in codeChanges.enumerated() {
								let snippetDescription = index < descriptions.count ? descriptions[index] : ""
								coreContent += "Change #\(index + 1):\n"
								if !snippetDescription.isEmpty {
									coreContent += "Description: \(snippetDescription)\n"
								}
								coreContent += "Content:\n\(snippet)\n\n"
							}
							coreContent += "\n"
						}
						else {
							// Non-delegate edits
							let changes = extractMultipleChanges(from: fileContent, isFinal)
							let descriptions = extractChangeDescriptions(from: fileContent)
							
							// NEW: Use itemIndex for stable ID
							let newFileItem = ContentItem(
								startIndexInStream: itemIndex,
								type: .file,
								content: fileContent,
								filePath: filePath,
								action: actionString,
								changes: changes,
								descriptions: descriptions
							)
							items.append(newFileItem)
							itemIndex += 1
							
							coreContent += "File: \(filePath)\n"
							coreContent += "Changes:\n"
							for (index, snippet) in changes.enumerated() {
								let snippetDescription = index < descriptions.count ? descriptions[index] : ""
								coreContent += "Change #\(index + 1):\n"
								if !snippetDescription.isEmpty {
									coreContent += "Description: \(snippetDescription)\n"
								}
								coreContent += "Content:\n\(snippet)\n\n"
							}
							coreContent += "\n"
						}
					}
					// Move currentIndex past </file>
					currentIndex = fileEndMatch.range.upperBound
				}
				else {
					// No </file> => treat rest as file content
					if let fileRange = Range(NSRange(location: fileBlockStart, length: totalLength - fileBlockStart), in: cleanedContent) {
						let fileContent = cleanedContent[fileRange]
						let changes = extractMultipleChanges(from: String(fileContent), isFinal)
						let descriptions = extractChangeDescriptions(from: String(fileContent))
						
						// NEW: Use itemIndex for stable ID
						let partialFileItem = ContentItem(
							startIndexInStream: itemIndex,
							type: .file,
							content: String(fileContent),
							filePath: filePath,
							action: actionString,
							changes: changes,
							descriptions: descriptions
						)
						items.append(partialFileItem)
						itemIndex += 1
						
						coreContent += "File: \(filePath) (Action: \(actionString))\n"
						coreContent += descriptions.joined(separator: "\n") + "\n\n"
					}
					currentIndex = totalLength
					break
				}
			}
		}
		
		return (
			items,
			coreContent.trimmingCharacters(in: .whitespacesAndNewlines),
			newDelegateEditItems
		)
	}
	// MARK: - Private Helpers
	
	private static func processPlanMatch(
		_ remainingContent: String,
		planMatch: NSTextCheckingResult,
		planEndMatch: NSTextCheckingResult,
		items: inout [ContentItem],
		coreContent: inout String,
		currentIndex: inout Int,
		// NEW: Pass `itemIndex` by inout
		itemIndex: inout Int
	) {
		// Process text before <Plan> if any
		if planMatch.range.lowerBound > 0 {
			let nsRangeBeforePlan = NSRange(location: 0, length: planMatch.range.lowerBound)
			if let swiftRangeBeforePlan = Range(nsRangeBeforePlan, in: remainingContent) {
				let textContent = String(remainingContent[swiftRangeBeforePlan])
				// Pass itemIndex here
				processAndAddTextContent(
					textContent,
					&items,
					&coreContent,
					isFinal: true,
					itemIndex: &itemIndex
				)
			}
		}
		
		// Process the <Plan> block body
		let planStart = planMatch.range.upperBound
		let planEnd = planEndMatch.range.lowerBound
		let nsRangePlan = NSRange(location: planStart, length: planEnd - planStart)
		
		if let swiftRangePlan = Range(nsRangePlan, in: remainingContent) {
			let planContent = String(remainingContent[swiftRangePlan])
			let trimmedPlanContent = planContent.trimmingCharacters(in: .whitespacesAndNewlines)
			
			// NEW: Use itemIndex for stable ID
			let planItem = ContentItem(
				startIndexInStream: itemIndex,
				type: .text,
				content: trimmedPlanContent
			)
			items.append(planItem)
			itemIndex += 1
			
			coreContent += "Plan:\n\(trimmedPlanContent)\n\n"
			
			// Update currentIndex to the end of the </Plan> tag
			currentIndex = planEndMatch.range.upperBound
		} else {
			// Fallback: if conversion fails, advance currentIndex past the opening <Plan> tag
			currentIndex = planMatch.range.upperBound
		}
	}
	
	private static func processAndAddTextContent(
		_ content: String,
		_ items: inout [ContentItem],
		_ coreContent: inout String,
		isFinal: Bool,
		// NEW: Pass `itemIndex` by inout
		itemIndex: inout Int
	) {
		// 1. Extract chat name if present
		var contentMutable = content
		_ = parseAndRemoveChatName(from: &contentMutable) // ignoring extracted name here
		
		// 2. Clean it up (remove partial tags, incomplete tags, etc.)
		//    But skip removing incomplete <file> tags if not final
		let cleanedTextContent = cleanupTextContent(contentMutable, isFinal: isFinal)
		
		// 3. Turn it into ContentItem(s): text + code blocks
		//    Pass `itemIndex` inout to track line offsets across multiple items
		let processedItems = processTextContent(cleanedTextContent, isFinal: isFinal, baseIndex: &itemIndex)
		items.append(contentsOf: processedItems)
		
		// 4. Add text to coreContent (code blocks are now embedded in text)
		for item in processedItems {
			switch item.type {
			case .text:
				let trimmedContent = item.content.trimmingCharacters(in: .whitespacesAndNewlines)
				if !trimmedContent.isEmpty {
					coreContent += "\(trimmedContent)\n\n"
				}
			case .code:
				// Code blocks are no longer split out, so this case shouldn't happen
				// But keep it for safety
				coreContent += "```\n\(item.content)\n```\n\n"
			default:
				break
			}
		}
	}
	
	// MARK: - parseDelegateEdit (updated) ───────────────────────────────────────────
	private static func parseDelegateEdit(
		fileContent: String,
		_ isFinal: Bool,
		filePath: String = ""
	) -> ([String], [DelegateEditItem.Change]) {
		
		var codeChanges: [String] = []
		var changes: [DelegateEditItem.Change] = []
		var currentIndex = 0
		var scopeCount: Int?
		let fileUTF16Count = fileContent.utf16.count
		let parseState = EditFlowPerf.begin(
			EditFlowPerf.Stage.Parser.chatDelegateEditParse,
			EditFlowPerf.Dimensions(
				status: isFinal ? "final" : "streaming",
				inputBytes: fileContent.utf8.count
			)
		)
		defer {
			EditFlowPerf.end(
				EditFlowPerf.Stage.Parser.chatDelegateEditParse,
				parseState,
				EditFlowPerf.Dimensions(
					status: isFinal ? "final" : "streaming",
					inputBytes: fileContent.utf8.count,
					changeCount: changes.count,
					scopeCount: scopeCount
				)
			)
		}
		
		// Detect single‑block (scope‑based) delegate edit
		let changeMatches = changeRegex.matches(in: fileContent,
												options: [],
												range: NSRange(location: 0, length: fileUTF16Count))
		
		if changeMatches.count == 1 {
			// ────────── NEW‑FORMAT (single <change> with REPOMARK scopes) ──────────
			guard
				let open    = changeMatches.first,
				let close   = changeEndRegex.firstMatch(in: fileContent,
														options: [],
														range: NSRange(location: open.range.upperBound,
																	   length: fileUTF16Count - open.range.upperBound))
			else { return (codeChanges, changes) }
			
			let bodyRange   = NSRange(location: open.range.upperBound,
									  length: close.range.lowerBound - open.range.upperBound)
			guard let swiftRange = Range(bodyRange, in: fileContent) else { return (codeChanges, changes) }
			let changeBody  = String(fileContent[swiftRange])
			
			let xmlDesc     = extractDescription(from: changeBody)
			let codeSnippet = extractCodeContent(from: changeBody, isFinal)
			let complexity  = extractComplexity(from: changeBody) ?? 3
			
			if enableDebugLogging {
				print("[ChatContentParser.parseDelegateEdit] Processing single delegate edit block")
				print("[ChatContentParser.parseDelegateEdit] File path: \(filePath)")
				print("[ChatContentParser.parseDelegateEdit] XML description: \"\(xmlDesc)\"")
				print("[ChatContentParser.parseDelegateEdit] Code snippet length: \(codeSnippet.count)")
			}
			
			// NEW: cut the snippet into scopes using REPOMARK comments
			let scopes = splitIntoScopes(codeSnippet, filePath: filePath)
			scopeCount = scopes.count
			
			if !scopes.isEmpty {
				if enableDebugLogging {
					print("[ChatContentParser.parseDelegateEdit] ✅ Found \(scopes.count) scopes, processing each...")
				}
				
				for (index, scope) in scopes.enumerated() {
					// Prefer the description from the marker; fall back to xml / heuristic
					var desc = scope.description.trimmingCharacters(in: .whitespacesAndNewlines)
					let originalDesc = desc
					
					if desc.isEmpty { desc = xmlDesc }
					if desc.isEmpty { desc = extractScopeDescription(from: scope.content) }
					
					if enableDebugLogging {
						print("[ChatContentParser.parseDelegateEdit] Processing scope \(index + 1):")
						print("  Original scope description: \"\(originalDesc)\"")
						print("  Final description: \"\(desc)\"")
						print("  Content length: \(scope.content.count)")
						print("  Content preview: \"\(String(scope.content.prefix(100)))\"")
					}
					
					codeChanges.append(scope.content)
					changes.append(
						DelegateEditItem.Change(
							description: desc,
							codeSnippet: scope.content,
							complexity: complexity
						)
					)
				}
			} else {
				if enableDebugLogging {
					print("[ChatContentParser.parseDelegateEdit] ⚠️ No scopes found, treating as single change")
				}
				
				// Fallback: no scope markers found – treat whole snippet as one change
				var desc = xmlDesc.trimmingCharacters(in: .whitespacesAndNewlines)
				if desc.isEmpty { desc = extractScopeDescription(from: codeSnippet) }
				
				if enableDebugLogging {
					print("[ChatContentParser.parseDelegateEdit] Single change description: \"\(desc)\"")
				}
				
				codeChanges.append(codeSnippet)
				changes.append(
					DelegateEditItem.Change(
						description: desc,
						codeSnippet: codeSnippet,
						complexity: complexity
					)
				)
			}
			
		} else {
			// ────────── LEGACY (multiple <change> blocks) ──────────
			while currentIndex < fileUTF16Count {
				guard
					let open = changeRegex.firstMatch(in: fileContent,
													  options: [],
													  range: NSRange(location: currentIndex,
																	 length: fileUTF16Count - currentIndex))
				else { break }
				
				let bodyStart = open.range.upperBound
				guard
					let close = changeEndRegex.firstMatch(in: fileContent,
														  options: [],
														  range: NSRange(location: bodyStart,
																		 length: fileUTF16Count - bodyStart))
				else { break }
				
				let bodyRange = NSRange(location: bodyStart,
										length: close.range.lowerBound - bodyStart)
				guard let swiftRange = Range(bodyRange, in: fileContent) else { break }
				let changeBody  = String(fileContent[swiftRange])
				
				var desc        = extractDescription(from: changeBody)
				let snippet     = extractCodeContent(from: changeBody, isFinal)
				let complexity  = extractComplexity(from: changeBody) ?? 1
				
				if desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
					desc = extractScopeDescription(from: snippet)
				}
				
				codeChanges.append(snippet)
				changes.append(
					DelegateEditItem.Change(description: desc,
											codeSnippet: snippet,
											complexity: complexity)
				)
				currentIndex = close.range.upperBound
			}
		}
		
		return (codeChanges, changes)
	}
	
	// MARK: - Scope‑splitting helper
	private static func splitIntoScopes(
		_ codeSnippet: String,
		filePath: String,
		contextLineWindow: Int = 2
	) -> [(description: String, content: String)] {
		// Heuristic: long placeholder runs (≥ threshold) belong to the *previous* scope
		let placeholderBackfillThreshold = 4

		var scopes: [(description: String, content: String)] = []
		let (lines, lineEnding) = String.splitContentPreservingLineEndings(codeSnippet)
		let placeholderRx = placeholderRegex(for: filePath)

		// State
		var currentDesc: String?
		var committed: [String] = []
		var trailing: [String] = []
		var preMarkerLookBehind: [String] = []
		var carryPlaceholders: [String] = []
		var carryPlaceholderKeys: Set<String> = []
		var committedPlaceholderKeys: Set<String> = []
		var placeholderRunCount = 0
		var seedsForCurrentScope: [String] = []
		var postMarkerNonWhitespaceCount = 0

		// PERF: small reservations
		committed.reserveCapacity(min(lines.count, 128))
		trailing.reserveCapacity(max(2, contextLineWindow))
		carryPlaceholders.reserveCapacity(4)

		@inline(__always)
		func canonicalizePlaceholderKey(_ line: String) -> String {
			var s = line.lowercased()
			for t in ["/*", "*/", "<!--", "-->", "//", "#", "--"] { s = s.replacingOccurrences(of: t, with: " ") }
			let ns = s as NSString
			let range = NSRange(location: 0, length: ns.length)
			s = ChatContentParser._rxCollapseWhitespace.stringByReplacingMatches(
				in: s, options: [], range: range, withTemplate: " "
			)
			return s.trimmingCharacters(in: .whitespacesAndNewlines)
		}

		@inline(__always)
		func addPlaceholderToCommitted(_ line: String) {
			let key = canonicalizePlaceholderKey(line)
			if !committedPlaceholderKeys.contains(key) {
				committedPlaceholderKeys.insert(key)
				committed.append(line)
			}
		}

		@inline(__always)
		func commitRegularLine(_ line: String) {
			trailing.append(line)
			if trailing.count > contextLineWindow {
				committed.append(trailing.removeFirst())
			}
		}

		@inline(__always)
		func isBlank(_ s: String) -> Bool {
			return s.rangeOfCharacter(from: ChatContentParser._notWhitespaceSet) == nil
		}

		/// Trim leading/trailing blank lines and collapse blank runs to one.
		@inline(__always)
		func normalizeBlankRuns(_ body: [String]) -> [String] {
			if body.isEmpty { return body }
			var start = 0, end = body.count
			while start < end && isBlank(body[start]) { start += 1 }
			while end > start && isBlank(body[end - 1]) { end -= 1 }
			if start >= end { return [] }

			var out: [String] = []
			out.reserveCapacity(end - start)
			var prevBlank = false
			for i in start..<end {
				let line = body[i]
				let blank = isBlank(line)
				if blank {
					if !prevBlank {
						out.append("") // keep a single blank
						prevBlank = true
					}
				} else {
					out.append(line)
					prevBlank = false
				}
			}
			return out
		}

		/// Finalize and append a scope with whitespace normalization and no trailing newline.
		@inline(__always)
		func finalizeScope(description d: String, body raw: [String]) {
			let normalized = normalizeBlankRuns(raw)
			var joined = normalized.joined(separator: lineEnding)
			// Strip terminal line terminators
			while joined.hasSuffix("\r\n") || joined.hasSuffix("\n") || joined.hasSuffix("\r") {
				if joined.hasSuffix("\r\n") { joined.removeLast(2) } else { joined.removeLast(1) }
			}
			// Strip trailing spaces/tabs at EOF
			if !joined.isEmpty {
				let ns = NSRange(joined.startIndex..., in: joined)
				joined = ChatContentParser._rxTrailingSpacesTabsAtEOF
					.stringByReplacingMatches(in: joined, options: [], range: ns, withTemplate: "")
			}
			scopes.append((d, joined))
		}

		/// Flush current scope, optionally dropping its trailing window (for zero overlap).
		@inline(__always)
		func flushCurrentScope(dropTrailing: Bool) {
			guard let d = currentDesc else { return }
			var body: [String] = committed
			if !dropTrailing {
				body.append(contentsOf: trailing)
			}
			// avoid empty snippet if everything landed in trailing
			if dropTrailing, body.isEmpty, !trailing.isEmpty {
				if let nonBlank = trailing.last(where: { !isBlank($0) }) {
					body.append(nonBlank)
				} else if let last = trailing.last {
					body.append(last)
				}
			}
			// if no post-marker content, strip any seeded pre-context
			if !dropTrailing, postMarkerNonWhitespaceCount == 0, !seedsForCurrentScope.isEmpty {
				if body.count >= seedsForCurrentScope.count {
					body.removeFirst(seedsForCurrentScope.count)
				}
			}

			finalizeScope(description: d, body: body)

			// reset for next scope
			currentDesc = nil
			committed.removeAll(keepingCapacity: true)
			trailing.removeAll(keepingCapacity: true)
			committedPlaceholderKeys.removeAll(keepingCapacity: true)
			seedsForCurrentScope.removeAll(keepingCapacity: true)
			postMarkerNonWhitespaceCount = 0
		}

		@inline(__always)
		func likelyMarker(_ line: String) -> Bool {
			return line.range(of: "repomark", options: .caseInsensitive) != nil
		}
		@inline(__always)
		func likelyPlaceholder(_ line: String) -> Bool {
			return line.range(of: "existing code", options: .caseInsensitive) != nil
				&& line.contains("...")
		}

		/// NEW: Look ahead from a marker to see if the *next scope* begins with placeholders.
		/// If so, treat that as a hard boundary (no trailing seeding across scopes).
		@inline(__always)
		func hasBoundaryPlaceholderAhead(from markerIndex: Int) -> Bool {
			var j = markerIndex + 1
			while j < lines.count {
				let nxt = lines[j]
				if likelyPlaceholder(nxt) {
					let ns = NSRange(location: 0, length: nxt.utf16.count)
					if placeholderRx.firstMatch(in: nxt, options: [], range: ns) != nil {
						return true
					}
					// if the pre-filter said "likely" but regex says no, keep scanning
				} else if !isBlank(nxt) {
					// first non-blank non-placeholder → no boundary placeholders ahead
					return false
				}
				j += 1
			}
			return false
		}

		for (idx, line) in lines.enumerated() {
			// 1) REPOMARK boundary
			if likelyMarker(line) {
				let ns = NSRange(location: 0, length: line.utf16.count)
				if let m = scopeMarkerRegex.firstMatch(in: line, options: [], range: ns),
					let r = Range(m.range(at: 1), in: line) {

					// Snapshot trailing BEFORE we mutate anything.
					let prevTrailing = trailing

					// Compute boundary BEFORE any backfill-clearing.
					let hadCarryBoundary = !carryPlaceholders.isEmpty
					let boundaryAhead = hasBoundaryPlaceholderAhead(from: idx)

					// Backfill only when the run *before* the marker is long enough.
					if currentDesc != nil, hadCarryBoundary, placeholderRunCount >= placeholderBackfillThreshold {
						for pl in carryPlaceholders { addPlaceholderToCommitted(pl) }
						carryPlaceholders.removeAll(keepingCapacity: true)
						carryPlaceholderKeys.removeAll(keepingCapacity: true)
					}

					// Use the pre-clearing boundary info to decide overlap at the flush.
					let hasBoundaryPlaceholder = hadCarryBoundary || boundaryAhead
					flushCurrentScope(dropTrailing: !hasBoundaryPlaceholder)

					// Start new scope
					let desc = String(line[r]).trimmingCharacters(in: .whitespacesAndNewlines)
					currentDesc = desc

					// Seeding (only when NO boundary placeholder existed at the split)
					if scopes.isEmpty {
						if !preMarkerLookBehind.isEmpty { committed.append(contentsOf: preMarkerLookBehind) }
						seedsForCurrentScope.removeAll(keepingCapacity: true)
					} else {
						if hasBoundaryPlaceholder {
							seedsForCurrentScope.removeAll(keepingCapacity: true)
						} else if prevTrailing.count == contextLineWindow {
							// Seed from the SNAPSHOT, not from `trailing` (which is cleared by flush).
							committed.append(contentsOf: prevTrailing)
							seedsForCurrentScope = prevTrailing
						} else {
							seedsForCurrentScope.removeAll(keepingCapacity: true)
						}
					}

					// Carry-forward placeholders (only if we still have them)
					if !carryPlaceholders.isEmpty {
						for pl in carryPlaceholders { addPlaceholderToCommitted(pl) }
						carryPlaceholders.removeAll(keepingCapacity: true)
						carryPlaceholderKeys.removeAll(keepingCapacity: true)
					}

					trailing.removeAll(keepingCapacity: true)
					placeholderRunCount = 0
					continue
				}
			}

			// 2) Placeholder line (with pre-filter)
			if likelyPlaceholder(line) {
				let ns = NSRange(location: 0, length: line.utf16.count)
				if placeholderRx.firstMatch(in: line, options: [], range: ns) != nil {
					let key = canonicalizePlaceholderKey(line)
					if !carryPlaceholderKeys.contains(key) {
						carryPlaceholderKeys.insert(key)
						carryPlaceholders.append(line)
					}
					placeholderRunCount += 1
					continue
				}
			}

			// 3) Regular content
			if currentDesc == nil {
				if contextLineWindow > 0 {
					preMarkerLookBehind.append(line)
					if preMarkerLookBehind.count > contextLineWindow {
						preMarkerLookBehind.removeFirst()
					}
				}
				// Discard staged placeholders that weren't adjacent to a scope start
				if !carryPlaceholders.isEmpty {
					carryPlaceholders.removeAll(keepingCapacity: true)
					carryPlaceholderKeys.removeAll(keepingCapacity: true)
				}
				continue
			} else {
				if !carryPlaceholders.isEmpty {
					if isBlank(line) {
						commitRegularLine(line)
					} else {
						for pl in carryPlaceholders { addPlaceholderToCommitted(pl) }
						carryPlaceholders.removeAll(keepingCapacity: true)
						carryPlaceholderKeys.removeAll(keepingCapacity: true)
						commitRegularLine(line)
						postMarkerNonWhitespaceCount += 1
					}
				} else {
					commitRegularLine(line)
					if !isBlank(line) { postMarkerNonWhitespaceCount += 1 }
				}
				if !isBlank(line) { placeholderRunCount = 0 }
			}
		}

		// Finalize last scope (include trailing); include any staged placeholders
		if currentDesc != nil {
			if !carryPlaceholders.isEmpty {
				for pl in carryPlaceholders { addPlaceholderToCommitted(pl) }
			}
			var body: [String] = committed
			body.append(contentsOf: trailing)

			if postMarkerNonWhitespaceCount == 0, !seedsForCurrentScope.isEmpty {
				if body.count >= seedsForCurrentScope.count {
					body.removeFirst(seedsForCurrentScope.count)
				}
			}
			if postMarkerNonWhitespaceCount == 0 {
				let onlyBlanks = body.allSatisfy { isBlank($0) }
				if onlyBlanks { body.removeAll() }
			}

			finalizeScope(description: currentDesc!, body: body)
		}

		return scopes
	}

	
	private static func extractMultipleChanges(from content: String, _ isFinal: Bool) -> [String] {
		var changes: [String] = []
		var currentIndex = 0
		
		// If there are no <change> tags, see if there's a single <content> tag
		if !content.contains("<change>") {
			if let contentMatch = extractContent(from: content, tag: "content", isFinal) {
				changes.append(trimContent(contentMatch))
			} else {
				changes.append(trimContent(content))
			}
			return changes
		}
		
		// Otherwise, gather multiple <change> blocks
		let contentUTF16Count = content.utf16.count
		while currentIndex < contentUTF16Count {
			if let changeMatch = changeRegex.firstMatch(
				in: content,
				options: [],
				range: NSRange(location: currentIndex, length: contentUTF16Count - currentIndex)
			) {
				let changeStart = changeMatch.range.upperBound
				if let changeEndMatch = changeEndRegex.firstMatch(
					in: content,
					options: [],
					range: NSRange(location: changeStart, length: contentUTF16Count - changeStart)
				) {
					let nsRange = NSRange(location: changeStart, length: changeEndMatch.range.lowerBound - changeStart)
					if let changeRange = Range(nsRange, in: content) {
						let changeContent = String(content[changeRange])
						changes.append(extractCodeContent(from: changeContent, isFinal))
					}
					currentIndex = changeEndMatch.range.upperBound
				} else {
					if let remainderRange = Range(NSRange(location: changeStart, length: contentUTF16Count - changeStart), in: content) {
						let changeContent = String(content[remainderRange])
						changes.append(extractCodeContent(from: changeContent, isFinal))
					}
					break
				}
			} else {
				break
			}
		}
		
		return changes
	}
	
	/// Adjusted to skip removing incomplete <file> tags unless `isFinal` is true
	private static func cleanupTextContent(_ content: String, isFinal: Bool) -> String {
		return content
		/*
		 var temp = content
		 // Remove partial or incomplete tags
		 temp = removeContentFromTag(temp, tag: "start_selector")
		 temp = removeContentFromTag(temp, tag: "end_selector")
		 temp = removeContentFromTag(temp, tag: "search")
		 
		 temp = removeContentBetweenMalformedTags(temp, tag: "start_selector")
		 temp = removeContentBetweenMalformedTags(temp, tag: "end_selector")
		 temp = removeContentBetweenMalformedTags(temp, tag: "search")
		 temp = removeContentBetweenMalformedTags(temp, tag: "plan")
		 
		 // Only remove incomplete file tags if this is the final parse
		 if false && isFinal {
		 temp = removeIncompleteFileTags(temp)
		 }
		 
		 // Also remove properly formed tags
		 if let startSel = DiffParserUtils.extractContent(from: temp, tag: "start_selector") {
		 temp = temp.replacingOccurrences(
		 of: "<start_selector>\(startSel)</start_selector>",
		 with: ""
		 )
		 }
		 if let endSel = DiffParserUtils.extractContent(from: temp, tag: "end_selector") {
		 temp = temp.replacingOccurrences(
		 of: "<end_selector>\(endSel)</end_selector>",
		 with: ""
		 )
		 }
		 if let search = DiffParserUtils.extractContent(from: temp, tag: "search") {
		 temp = temp.replacingOccurrences(
		 of: "<search>\(search)</search>",
		 with: ""
		 )
		 }
		 
		 return temp
		 */
	}
	
	private static func hashDelegateEditItem(_ item: DelegateEditItem) -> Int {
		let key = DelegateEditItem.buildRequestKey(path: item.filePath, changes: item.changes)
		return Int(truncatingIfNeeded: fnv1a64(key))
	}

	@inline(__always)
	private static func fnv1a64(_ string: String) -> UInt64 {
		var hash: UInt64 = 0xcbf29ce484222325
		let prime: UInt64 = 0x100000001b3
		for byte in string.utf8 {
			hash ^= UInt64(byte)
			hash &*= prime
		}
		return hash
	}
	
	private static func processTextContent(
		_ content: String,
		isFinal: Bool,
		// NEW: Use inout baseIndex to build stable line indices
		baseIndex: inout Int
	) -> [ContentItem] {
		var items: [ContentItem] = []
		let rawContent = content

		// SIMPLIFIED: Don't split code blocks - keep everything as text and let markdown handle it
		// This prevents structural array changes during streaming when code blocks close
		let finalText = maybeTruncateLastLineIfNeeded(
			rawContent.trimmingCharacters(in: .whitespacesAndNewlines),
			isFinal: isFinal
		)

		if !finalText.isEmpty {
			let textItem = ContentItem(
				startIndexInStream: baseIndex,
				type: .text,
				content: finalText
			)
			items.append(textItem)
			baseIndex += 1
		}

		return items
	}
	
	private static func maybeTruncateLastLineIfNeeded(_ text: String, isFinal: Bool) -> String {
		// If final, keep everything as-is.
		// Otherwise, if there's no trailing newline, drop the last line from the text.
		guard !isFinal else { return text }
		
		// If the user typed a real newline at the end, keep it all.
		// If not, remove the last line.
		if text.hasSuffix("\n") {
			return text
		}
		
		// Split into lines
		var (lines, lineEnding) = String.splitContentPreservingLineEndings(text)
		// If there's anything in that last line, drop it
		if !lines.isEmpty {
			lines.removeLast()
		}
		
		return lines.joined(separator: lineEnding)
	}
	
	static func decodeIndentationInCodeBlock(_ codeBlock: String) -> String {
		let lines = DiffParserUtils.splitContentToLines(codeBlock, true)
		let decodedLines = lines.map { String.decodeIndentation($0) }
		return decodedLines.joined(separator: "\n")
	}
	
	// MARK: - NEW ▸ Helper ──────────────────────────────────────────────────────────
	/// Extracts a human‑readable description that follows a scope comment marker
	/// such as:
	///   `// REPOMARK:SCOPE: 1 - Add validation for empty input`
	///   `#  REPOMARK:SCOPE: 2 - Update logging`
	///   `-- REPOMARK:SCOPE: 3 - Replace legacy query`
	///
	/// Returns the text after the first "-".
	static func extractScopeDescription(from snippet: String) -> String {
		let pattern = #"(?m)^\s*(?:\/\/|#|--|<!--)\s*REPOMARK\s*:\s*SCOPE\s*:\s*\d+\s*-\s*(.+?)(?:-->)*\s*$"#
		
		if enableDebugLogging {
			print("[ChatContentParser.extractScopeDescription] Attempting to extract scope description")
			print("[ChatContentParser.extractScopeDescription] Pattern: \(pattern)")
			print("[ChatContentParser.extractScopeDescription] Snippet length: \(snippet.count)")
			print("[ChatContentParser.extractScopeDescription] Snippet preview (first 200 chars):")
			print("  \"\(String(snippet.prefix(200)))\"")
		}
		
		guard let regex = try? NSRegularExpression(pattern: pattern) else {
			if enableDebugLogging {
				print("[ChatContentParser.extractScopeDescription] ❌ Failed to create regex from pattern")
			}
			return ""
		}
		
		let nsRange = NSRange(snippet.startIndex..., in: snippet)
		let matches = regex.matches(in: snippet, options: [], range: nsRange)
		
		if enableDebugLogging {
			print("[ChatContentParser.extractScopeDescription] Found \(matches.count) matches")
		}
		
		if let match = matches.first,
		   let descRange = Range(match.range(at: 1), in: snippet) {
			let extractedDescription = snippet[descRange].trimmingCharacters(in: .whitespacesAndNewlines)
			
			if enableDebugLogging {
				print("[ChatContentParser.extractScopeDescription] ✅ Match found!")
				print("[ChatContentParser.extractScopeDescription] Full match range: \(match.range)")
				print("[ChatContentParser.extractScopeDescription] Description capture group range: \(match.range(at: 1))")
				print("[ChatContentParser.extractScopeDescription] Extracted description: \"\(extractedDescription)\"")
			}
			
			return extractedDescription
		}
		
		if enableDebugLogging {
			print("[ChatContentParser.extractScopeDescription] ❌ No matches found")
			// Let's also show each line for debugging
			let (lines, _) = String.splitContentPreservingLineEndings(snippet)
			for (index, line) in lines.enumerated() {
				print("[ChatContentParser.extractScopeDescription] Line \(index): \"\(line)\"")
			}
		}
		
		return ""
	}
	
	static func extractDescription(from content: String) -> String {
		// Allocate a buffer based on content size to avoid truncation
		// The description can't be longer than the content itself
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
		return String.trimCommonLeadingWhitespacePreservingLineEndings(content)
	}
	
	/// Removes the entire `<chatName=...>` snippet from the content if present.
	/// Returns the extracted name if found, otherwise nil.
	static func parseAndRemoveChatName(from content: inout String) -> String? {
		let pattern = #"<chatName\s*=\s*(?:"([^"]+)"|([^>\s]+))\s*(?:/?)>"#
		guard
			let regex = try? NSRegularExpression(pattern: pattern, options: []),
			let match = regex.firstMatch(in: content, options: [], range: NSRange(location: 0, length: content.utf16.count))
		else {
			return nil
		}
		
		let name: String
		if let quotedRange = Range(match.range(at: 1), in: content), !quotedRange.isEmpty {
			name = String(content[quotedRange])
		} else if let unquotedRange = Range(match.range(at: 2), in: content), !unquotedRange.isEmpty {
			name = String(content[unquotedRange])
		} else {
			return nil
		}
		
		if let snippetRange = Range(match.range, in: content) {
			content.removeSubrange(snippetRange)
		}
		
		return name
	}
	
	private static func removeContentFromTag(_ content: String, tag: String) -> String {
		if let range = content.range(of: "<\(tag)", options: .caseInsensitive) {
			return String(content[..<range.lowerBound])
		}
		return content
	}
	
	private static func removeContentBetweenMalformedTags(_ content: String, tag: String) -> String {
		let pattern = "<\(tag)[^>]*>.*?</[^>]*>"
		return content.replacingOccurrences(of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
	}
	
	private static func removeIncompleteFileTags(_ content: String) -> String {
		let pattern = "<file[^>]*$"
		if let range = content.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
			return String(content[..<range.lowerBound])
		}
		return content
	}
	
	/// Removes outer triple-backtick fences if present (with or without language spec).
	/// Also handles partial code blocks by removing opening backticks when no closing backticks exist.
	static func removeOuterBackticks(from content: String) -> String {
		// Allocate a buffer for the result
		let bufferSize = content.utf8.count + 1
		let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bufferSize)
		defer { buffer.deallocate() }
		
		// Call the C function
		let success = content.withCString { cString in
			repo_remove_outer_backticks(buffer, cString, bufferSize)
		}
		
		// If successful, convert back to Swift String
		if success {
			return String(cString: buffer)
		} else {
			// Buffer too small (shouldn't happen), return original
			return content
		}
	}
	
	private static func extractChangeDescriptions(from content: String) -> [String] {
		var descriptions: [String] = []
		let matches = descriptionRegex.matches(in: content, options: [], range: NSRange(content.startIndex..., in: content))
		for match in matches {
			if let range = Range(match.range(at: 1), in: content) {
				let description = content[range].trimmingCharacters(in: .whitespacesAndNewlines)
				descriptions.append(description)
			}
		}
		return descriptions
	}
}
