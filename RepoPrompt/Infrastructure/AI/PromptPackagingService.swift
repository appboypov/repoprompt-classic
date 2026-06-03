import Foundation

struct MetaInstruction {
	let title: String
	let content: String
}

struct PromptPackagingService {
	/// Returns the opening ``` fence, suffixed with the file extension (\"swift\", \"js\", …).
	@inline(__always)
	static func codeFenceStart(for fileName: String) -> String {
		let ext = URL(fileURLWithPath: fileName).pathExtension        // "swift", "m", ""
		return ext.isEmpty ? "```" : "```\(ext)"
	}

	// NEW: Helpers for title snippet
	private static func isGenericTabTitle(_ title: String) -> Bool {
		let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.range(of: #"^T\d+$"#, options: .regularExpression) != nil
	}

	private static func escapeXML(_ text: String) -> String {
		var escaped = text.replacingOccurrences(of: "&", with: "&amp;")
		escaped = escaped.replacingOccurrences(of: "<", with: "&lt;")
		escaped = escaped.replacingOccurrences(of: ">", with: "&gt;")
		escaped = escaped.replacingOccurrences(of: "\"", with: "&quot;")
		escaped = escaped.replacingOccurrences(of: "'", with: "&apos;")
		return escaped
	}

	private static func titleSnippet(for tabTitle: String?) -> String? {
		guard let raw = tabTitle?.trimmingCharacters(in: .whitespacesAndNewlines), raw.isEmpty == false else {
			return nil
		}
		guard isGenericTabTitle(raw) == false else { return nil }
		let escaped = escapeXML(raw)
		return """
<title>
\(escaped)
</title>

"""
	}

	private enum GitDiffArtifact {
		static let rootFolderName = "_git_data"

		static func isDiffArtifactPath(_ fullPath: String) -> Bool {
			guard fullPath.contains("/\(rootFolderName)/") else { return false }
			let lower = fullPath.lowercased()
			guard lower.hasSuffix(".diff") || lower.hasSuffix(".patch") else { return false }
			return lower.contains("/diff/") || lower.contains("/diffs/")
		}
	}

	static func partitionPromptEntriesForGitDiff(
		_ entries: [PromptFileEntry]
	) -> (diffEntries: [PromptFileEntry], codeEntries: [PromptFileEntry]) {
		guard !entries.isEmpty else { return ([], []) }
		var diffEntries: [PromptFileEntry] = []
		var codeEntries: [PromptFileEntry] = []
		diffEntries.reserveCapacity(entries.count)
		codeEntries.reserveCapacity(entries.count)

		for entry in entries {
			if GitDiffArtifact.isDiffArtifactPath(entry.file.fullPath) {
				diffEntries.append(entry)
			} else {
				codeEntries.append(entry)
			}
		}
		return (diffEntries, codeEntries)
	}
	
	static func selectedGitDiffText(
		fromDiffEntries diffEntries: [PromptFileEntry]
	) async -> String? {
		guard !diffEntries.isEmpty else { return nil }
		let rawParts = await generateRawFileTexts(diffEntries)
		return rawParts.isEmpty ? nil : rawParts.joined(separator: "\n\n")
	}
	
	static func selectedGitDiffText(
		from entries: [PromptFileEntry]
	) async -> String? {
		let (diffEntries, _) = partitionPromptEntriesForGitDiff(entries)
		return await selectedGitDiffText(fromDiffEntries: diffEntries)
	}
	
	static func resolveGitDiff(
		fromDiffEntries diffEntries: [PromptFileEntry],
		fallback: @Sendable () async -> String?
	) async -> String? {
		if let selected = await selectedGitDiffText(fromDiffEntries: diffEntries) {
			return selected
		}
		return await fallback()
	}
	
	static func resolveGitDiff(
		from entries: [PromptFileEntry],
		fallback: @Sendable () async -> String?
	) async -> String? {
		if let selected = await selectedGitDiffText(from: entries) {
			return selected
		}
		return await fallback()
	}

	static func generateRawFileTexts(
		_ entries: [PromptFileEntry]
	) async -> [String] {
		guard !entries.isEmpty else { return [] }
		var blocks: [String] = []
		blocks.reserveCapacity(entries.count)

		for entry in entries {
			let file = entry.file

			if let ranges = entry.ranges,
				!ranges.isEmpty,
				let assembly = await file.assembleContent(for: ranges) {
				if assembly.isFullFile {
					if !assembly.combinedText.isEmpty {
						blocks.append(assembly.combinedText)
					}
				} else {
					let text = assembly.segments.map(\.text).joined(separator: "\n")
					if !text.isEmpty {
						blocks.append(text)
					}
				}
				continue
			}

			if let content = await file.latestContent, !content.isEmpty {
				blocks.append(content)
			}
		}

		return blocks
	}
	
	/// Build an AIMessage that includes:
	/// - system prompt
	/// - meta prompts
	/// - file tree & blocks
	/// - an entire conversation array in chronological order
	static func buildAIMessage(
		systemPrompt: String,
		metaInstructions: [MetaInstruction],
		fileTree: String,
		fileContents: [String],
		gitDiff: String? = nil,
		conversation: [ConversationEntry],
		addWarning: Bool,
		temperature: Double?,
		promptSectionsOrder: [PromptSection],
		disabledPromptSections: Set<PromptSection>,
		duplicateUserInstructionsAtTop: Bool = false
	) -> AIMessage {
		
		// 1️⃣  Turn meta-instructions into prompt strings
		let metaPrompts: [String] = metaInstructions.map { meta in
			"""
			<meta prompt "\(meta.title)">
			\(meta.content)
			</meta prompt>
			"""
		}
		
		// 2️⃣  Copy conversation and rebuild the final user entry once
		var updatedConversation = conversation
		if let lastUserIndex = updatedConversation.lastIndex(where: { $0.role == .user }) {
			let lastUserEntry = updatedConversation[lastUserIndex]
			var newContent = lastUserEntry.content
			
			// Optionally append the warning
			if addWarning && !fileContents.isEmpty {
				newContent += """
				
				
				**IMPORTANT** IF MAKING FILE CHANGES, YOU MUST USE THE AVAILABLE XML FORMATTING CAPABILITIES PROVIDED ABOVE – IT IS THE ONLY WAY FOR YOUR CHANGES TO BE APPLIED.
				"""
			}
			
			// Wrap in <user_instructions> … </user_instructions> if not already wrapped
			if !newContent.contains("<user_instructions>") {
				newContent = """
				<user_instructions>
				\(newContent)
				</user_instructions>
				"""
			}
			
			// Replace the immutable entry with a new one
			updatedConversation[lastUserIndex] =
				ConversationEntry(role: lastUserEntry.role, content: newContent)
		}
		
		// 3️⃣  Package everything into AIMessage
		return AIMessage(
			systemPrompt: systemPrompt,
			metaPrompts: metaPrompts,
			fileTree: fileTree,
			fileBlocks: fileContents,
			gitDiff: gitDiff,
			conversationMessages: updatedConversation,
			temperature: temperature,
			promptSectionsOrder: promptSectionsOrder,
			disabledPromptSections: disabledPromptSections,
			duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop
		)
	}

	/// Produce file contents as an array of strings, each with the file path + raw content
	static func generateFileContents(
		_ files: [PromptFileEntry],
		filePathDisplay: FilePathDisplay = .full
	) async -> [String] {
		let (_, contentBlocks) = await generatePartitionedFileBlocks(files, filePathDisplay: filePathDisplay)
		return contentBlocks
	}

	/// Partitions file blocks into codemap blocks and content blocks
	static func generatePartitionedFileBlocks(
		_ files: [PromptFileEntry],
		filePathDisplay: FilePathDisplay
	) async -> (codemapBlocks: [String], contentBlocks: [String]) {
		let (_, codeEntries) = partitionPromptEntriesForGitDiff(files)
		let detailed = await generateFileBlocksDetailed(files: codeEntries, filePathDisplay: filePathDisplay)
		var codemapBlocks: [String] = []
		var contentBlocks: [String] = []

		for (_, text, isCodemap) in detailed {
			if text.isEmpty { continue }
			if isCodemap {
				codemapBlocks.append(text)
			} else {
				contentBlocks.append(text)
			}
		}

		return (codemapBlocks, contentBlocks)
	}

	static func generateFileBlocksDetailed(
		files: [PromptFileEntry],
		filePathDisplay: FilePathDisplay
	) async -> [(file: FileViewModel, text: String, isCodemap: Bool)] {
		var blocks: [(FileViewModel, String, Bool)] = []
		guard !files.isEmpty else { return blocks }

		let hasMultipleRoots = Set(files.map { $0.file.rootFolderPath }).count > 1

		for entry in files {
			let file = entry.file
			let selectedPath: String = {
				if filePathDisplay == .relative {
					return hasMultipleRoots ? file.uniqueRelativePath : file.relativePath
				} else {
					return file.fullPath
				}
			}()

			if entry.isCodemap {
				// Fallback: If codemap not available, fall through to full content
				if let api = file.fileAPI {
					let description = api.getFullAPIDescription(displayPath: selectedPath)
					blocks.append((file, description, true))
					continue
				}
				// No codemap available, fall through to treat as full content entry
			}

			let startFence = codeFenceStart(for: file.name)
			let endFence = "```"

			if let ranges = entry.ranges,
				!ranges.isEmpty,
				let assembly = await file.assembleContent(for: ranges) {
				if assembly.isFullFile {
					let text =
						"""
						File: \(selectedPath)
						\(startFence)
						\(assembly.combinedText)
						\(endFence)
						"""
					blocks.append((file, text, false))
				} else {
					var sliceLines: [String] = ["File: \(selectedPath)"]
					let segments = assembly.segments
					for (index, segment) in segments.enumerated() {
						let label = formatRange(segment.range)
						if let desc = segment.range.description, !desc.isEmpty {
							sliceLines.append("(lines \(label): \(desc))")
						} else {
							sliceLines.append("(lines \(label))")
						}
						sliceLines.append(startFence)
						sliceLines.append(segment.text)
						sliceLines.append(endFence)
						if index != segments.count - 1 {
							sliceLines.append("")
						}
					}
					blocks.append((file, sliceLines.joined(separator: "\n"), false))
				}
				continue
			}

			guard let content = await file.latestContent else { continue }
			let text =
				"""
				File: \(selectedPath)
				\(startFence)
				\(content)
				\(endFence)
				"""
			blocks.append((file, text, false))
		}

		return blocks
	}

	static func generatePrompt(
		systemPrompt: String,
		metaInstructions: [MetaInstruction],
		userInstructions: String,
		files: [PromptFileEntry],
		filePathDisplay: FilePathDisplay,
		fileTreeContent: String?, // NEW simplified parameter for the file tree
		gitDiff: String? = nil,
		includeDatetimeInUserInstructions: Bool = false,
		mcpMetadata: String? = nil,
		// Add parameters needed by PromptAssemblyBuilder
		promptSectionsOrder: [PromptSection],
		disabledPromptSections: Set<PromptSection>,
		duplicateUserInstructionsAtTop: Bool
	) async -> AIMessage {
		// --- Generate Snippets ---
		var snippets: [PromptSection: String] = [:]

		let (diffEntries, codeEntries) = partitionPromptEntriesForGitDiff(files)
		let (codemapBlocks, contentBlocks) = await generatePartitionedFileBlocks(codeEntries, filePathDisplay: filePathDisplay)

		// File Map Snippet - CRITICAL: Check for codemaps OR tree
		let codemapJoined = codemapBlocks.joined(separator: "\n\n")
		let hasTree = fileTreeContent != nil && !fileTreeContent!.isEmpty
		let hasCodemaps = !codemapJoined.isEmpty

		if hasTree || hasCodemaps {
			let combinedMap = [fileTreeContent ?? "", codemapJoined]
				.filter { !$0.isEmpty }
				.joined(separator: "\n\n")
			snippets[.fileMap] = """
			<file_map>
			\(combinedMap)
			</file_map>

			"""
		}

		// File Contents Snippet - only content blocks
		if !contentBlocks.isEmpty {
			let snippet = """
			<file_contents>
			\(contentBlocks.joined(separator: "\n\n"))
			</file_contents>

			"""
			snippets[.fileContents] = snippet
		}

		// Meta Prompts Snippet
		if let metaSnippet = buildMetaPromptsSnippet(metaInstructions) {
			snippets[.metaPrompts] = metaSnippet
		}

		let effectiveGitDiff = await resolveGitDiff(
			fromDiffEntries: diffEntries
		) {
			gitDiff
		}

		// Git Diff Snippet
		if let diff = effectiveGitDiff, !diff.isEmpty {
			let snippet = """
			<git_diff>
			\(diff)
			</git_diff>

			"""
			snippets[.gitDiff] = snippet
		}
		
		// User Instructions Snippet
		let trimmedMetadata = mcpMetadata?.trimmingCharacters(in: .whitespacesAndNewlines)
		var userBodySegments: [String] = []
		if let metadata = trimmedMetadata, !metadata.isEmpty {
			userBodySegments.append(metadata)
		}
		if !userInstructions.isEmpty {
			userBodySegments.append(userInstructions)
		}
		if !userBodySegments.isEmpty {
			let body = userBodySegments.joined(separator: "\n\n")
			var snippet = ""
			if includeDatetimeInUserInstructions {
				let dateFormatter = DateFormatter()
				dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
				let dateString = dateFormatter.string(from: Date())
				snippet += """
<user_instructions date="\(dateString)">
\(body)
</user_instructions>

"""
			} else {
				snippet += """
<user_instructions>
\(body)
</user_instructions>

"""
			}
			snippets[.userInstructions] = snippet
		}

		// --- Build Final User Message ---
		let userMessage = PromptAssemblyBuilder.build(
			order: promptSectionsOrder,
			disabled: disabledPromptSections,
			duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
			snippets: snippets
		)

		// --- Return AIMessage ---
		return AIMessage(
			systemPrompt: systemPrompt,
			userMessage: userMessage
		)
	}
	
	static func generateClipboardContent(
		metaInstructions: [MetaInstruction],
		userInstructions: String,
		files: [PromptFileEntry],
		fileTreeContent: String?, // NEW simplified parameter for the file tree
		gitDiff: String? = nil,
		includeDiffFormatting: Bool,
		includeSavedPrompts: Bool,
		includeFiles: Bool,
		includeUserPrompt: Bool,
		filePathDisplay: FilePathDisplay,
		selectedXMLFormat: DiffViewModel.PromptFormat = .whole,
		includeDatetimeInUserInstructions: Bool = false,
		mcpMetadata: String? = nil,
		promptSectionsOrder: [PromptSection],
		disabledPromptSections: Set<PromptSection>,
		duplicateUserInstructionsAtTop: Bool,
		tabTitle: String? = nil
	) async -> String {
		// --- Generate Snippets ---
		var snippets: [PromptSection: String] = [:]

		let (diffEntries, codeEntries) = partitionPromptEntriesForGitDiff(files)
		let (codemapBlocks, contentBlocks) = await generatePartitionedFileBlocks(codeEntries, filePathDisplay: filePathDisplay)

		// File Map Snippet - CRITICAL: Check for codemaps OR tree
		let codemapJoined = codemapBlocks.joined(separator: "\n\n")
		let hasTree = fileTreeContent != nil && !fileTreeContent!.isEmpty
		let hasCodemaps = !codemapJoined.isEmpty

		if hasTree || hasCodemaps {
			let combinedMap = [fileTreeContent ?? "", codemapJoined]
				.filter { !$0.isEmpty }
				.joined(separator: "\n\n")
			snippets[.fileMap] = """
			<file_map>
			\(combinedMap)
			</file_map>

			"""
		}

		// File Contents Snippet - only content blocks
		if includeFiles && !contentBlocks.isEmpty {
			let snippet = """
			<file_contents>
			\(contentBlocks.joined(separator: "\n\n"))
			</file_contents>

			"""
			snippets[.fileContents] = snippet
		}

		// Meta Prompts Snippet
		if includeSavedPrompts, let metaSnippet = buildMetaPromptsSnippet(metaInstructions) {
			snippets[.metaPrompts] = metaSnippet
		}

		let effectiveGitDiff = await resolveGitDiff(
			fromDiffEntries: diffEntries
		) {
			gitDiff
		}

		// Git Diff Snippet
		if let diff = effectiveGitDiff, !diff.isEmpty {
			let snippet = """
			<git_diff>
			\(diff)
			</git_diff>

			"""
			snippets[.gitDiff] = snippet
		}
		
		// Diff Formatting Snippet
		if includeDiffFormatting {
			let language = SystemPromptService.predominantLanguage(from: files.map(\.file))
			let instructions = SystemPromptService.getApplyInstructions(format: selectedXMLFormat, language: language)
			let snippet = """
			<xml_formatting_instructions>
			\(instructions)
			</xml_formatting_instructions>

			"""
			snippets[.diffFormatting] = snippet
		}

		// User Instructions Snippet
		if includeUserPrompt {
			let trimmedMetadata = mcpMetadata?.trimmingCharacters(in: .whitespacesAndNewlines)
			var bodySegments: [String] = []
			if let metadata = trimmedMetadata, !metadata.isEmpty {
				bodySegments.append(metadata)
			}
			if !userInstructions.isEmpty {
				bodySegments.append(userInstructions)
			}
			if !bodySegments.isEmpty {
				let body = bodySegments.joined(separator: "\n\n")
				var snippet = ""
				if includeDatetimeInUserInstructions {
					let dateFormatter = DateFormatter()
					dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
					let dateString = dateFormatter.string(from: Date())
					snippet += """
<user_instructions date="\(dateString)">
\(body)
</user_instructions>

"""
				} else {
					snippet += """
<user_instructions>
\(body)
</user_instructions>

"""
				}
				snippets[.userInstructions] = snippet
			}
		}

		// --- Build Final String ---
		let clipboardContent = PromptAssemblyBuilder.build(
			order: promptSectionsOrder,
			disabled: disabledPromptSections,
			duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
			snippets: snippets
		)

		// NEW: Prepend title block if provided and not generic
		let prefix = Self.titleSnippet(for: tabTitle) ?? ""
		return prefix + clipboardContent
	}
	
	static func generateDiffClipboardContent(
		instructions: String,
		files: [PromptFileEntry],
		format: ApplyPromptFormat,
		includeFiles: Bool = true,
		filePathDisplay: FilePathDisplay = .full,
		allowDiffRewrite: Bool = true,
		fileTreeContent: String?, // NEW simplified parameter for the file tree
		gitDiff: String? = nil,
		includeDatetimeInUserInstructions: Bool = false,
		mcpMetadata: String? = nil,
		promptSectionsOrder: [PromptSection],
		disabledPromptSections: Set<PromptSection>,
		duplicateUserInstructionsAtTop: Bool,
		includeMetaPrompts: Bool = false,
		metaInstructions: [MetaInstruction] = [],
		tabTitle: String? = nil
	) async -> String {
		// --- Generate Snippets ---
		var snippets: [PromptSection: String] = [:]

		let (diffEntries, codeEntries) = partitionPromptEntriesForGitDiff(files)
		let (codemapBlocks, contentBlocks) = await generatePartitionedFileBlocks(codeEntries, filePathDisplay: filePathDisplay)

		// File Map Snippet - CRITICAL: Check for codemaps OR tree
		let codemapJoined = codemapBlocks.joined(separator: "\n\n")
		let hasTree = fileTreeContent != nil && !fileTreeContent!.isEmpty
		let hasCodemaps = !codemapJoined.isEmpty

		if hasTree || hasCodemaps {
			let combinedMap = [fileTreeContent ?? "", codemapJoined]
				.filter { !$0.isEmpty }
				.joined(separator: "\n\n")
			snippets[.fileMap] = """
			<file_map>
			\(combinedMap)
			</file_map>

			"""
		}

		// File Contents Snippet - only content blocks
		if includeFiles && !contentBlocks.isEmpty {
			let snippet = """
			<file_contents>
			\(contentBlocks.joined(separator: "\n\n"))
			</file_contents>

			"""
			snippets[.fileContents] = snippet
		} else {
			snippets[.fileContents] = ""
		}

		let effectiveGitDiff = await resolveGitDiff(
			fromDiffEntries: diffEntries
		) {
			gitDiff
		}

		// Git Diff Snippet
		if let diff = effectiveGitDiff, !diff.isEmpty {
			let snippet = """
			<git_diff>
			\(diff)
			</git_diff>

			"""
			snippets[.gitDiff] = snippet
		}
		
		// Diff Formatting Snippet
		let language = SystemPromptService.predominantLanguage(from: files.map(\.file))
		let diffSnippet = """
		<xml_formatting_instructions>
		\(SystemPromptService.applyPrompt(for: format, allowRewrite: allowDiffRewrite, language: language))
		</xml_formatting_instructions>

		"""
		snippets[.diffFormatting] = diffSnippet

		// User Instructions Snippet
		let trimmedMetadata = mcpMetadata?.trimmingCharacters(in: .whitespacesAndNewlines)
		var instructionSegments: [String] = []
		if let metadata = trimmedMetadata, !metadata.isEmpty {
			instructionSegments.append(metadata)
		}
		if !instructions.isEmpty {
			instructionSegments.append(instructions)
		}
		if !instructionSegments.isEmpty {
			let body = instructionSegments.joined(separator: "\n\n") + "\n**IMPORTANT** IF MAKING FILE CHANGES, YOU MUST USE THE AVAILABLE XML FORMATTING CAPABILITIES PROVIDED ABOVE – IT IS THE ONLY WAY FOR YOUR CHANGES TO BE APPLIED."
			var userSnippet = ""
			if includeDatetimeInUserInstructions {
				let dateFormatter = DateFormatter()
				dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
				let dateString = dateFormatter.string(from: Date())
				userSnippet += """
<user_instructions date="\(dateString)">
\(body)
</user_instructions>
"""
			} else {
				userSnippet += """
<user_instructions>
\(body)
</user_instructions>
"""
			}
			snippets[.userInstructions] = userSnippet
		}

		// Meta Prompts Snippet (conditionally include)
		if includeMetaPrompts, let metaSnippet = buildMetaPromptsSnippet(metaInstructions) {
			snippets[.metaPrompts] = metaSnippet
		}

		// --- Build Final String ---
		let content = PromptAssemblyBuilder.build(
			order: promptSectionsOrder,
			disabled: disabledPromptSections,
			duplicateUserInstructionsAtTop: duplicateUserInstructionsAtTop,
			snippets: snippets
		)

		// NEW: Prepend title block if provided and not generic
		let prefix = Self.titleSnippet(for: tabTitle) ?? ""
		return prefix + content
	}

	private static func escapeString(_ input: String) -> String {
		return input.escapedString()
	}
	
	private static func formatRange(_ range: LineRange) -> String {
		range.start == range.end ? "\(range.start)" : "\(range.start)-\(range.end)"
	}

	// MARK: - Shared builder for <meta prompt> blocks
	/// Builds a formatted string containing all meta prompts in XML format
	/// Returns nil if the meta instructions array is empty
	private static func buildMetaPromptsSnippet(_ metas: [MetaInstruction]) -> String? {
		guard !metas.isEmpty else { return nil }
		var snippet = ""
		for (index, meta) in metas.enumerated() {
			snippet += """
			<meta prompt \(index + 1) = "\(meta.title)">
			\(meta.content)
			</meta prompt \(index + 1)>

			"""
		}
		return snippet
	}
}
