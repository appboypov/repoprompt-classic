import Foundation

/// Namespace for MCP Tool result DTOs.
/// Using a namespace avoids name collisions with existing private structs
/// in MCPServerViewModel during the migration phase.
internal enum ToolResultDTOs {
    // MARK: - Search
    
    internal struct PerFileCount: Codable, Equatable {
        internal let path: String
        internal let count: Int
    }
    
	internal struct SearchResultDTO: Codable, Equatable {
		internal struct ContentMatchGroup: Codable, Equatable {
			internal struct ContextLine: Codable, Equatable, Hashable {
				internal let lineNumber: Int
				internal let lineText: String

				private enum CodingKeys: String, CodingKey {
					case lineNumber = "line_number"
					case lineText   = "line_text"
				}
			}

			internal struct Line: Codable, Equatable {
				internal let lineNumber: Int
				internal let lineText: String
				internal let contextBefore: [ContextLine]?
				internal let contextAfter: [ContextLine]?

				private enum CodingKeys: String, CodingKey {
					case lineNumber    = "line_number"
					case lineText      = "line_text"
					case contextBefore = "context_before"
					case contextAfter  = "context_after"
				}
			}

			internal let path: String
			internal let lines: [Line]

			private enum CodingKeys: String, CodingKey {
				case path
				case lines
			}
		}

		internal let totalMatches: Int
		internal let totalFiles: Int
		internal let matchedFiles: Int?
		internal let searchedFiles: Int?
		internal let contentMatches: Int
		internal let pathMatches: Int
		internal let limitHit: Bool
		internal let perFileCounts: [PerFileCount]
		internal let pathMatchLines: [String]
		internal let contentMatchGroups: [ContentMatchGroup]

		// NEW (optional, default nil) — indicates size-based trimming
		internal let sizeLimitHit: Bool?
		internal let omittedTotal: Int?
		internal let omittedContentMatches: Int?
		internal let omittedPathMatches: Int?
		internal let errorMessage: String?
		internal let suggestion: String?
		internal let warning: String?
		internal let perFileTotals: [PerFileCount]?
		
		// Custom initializer to keep existing call sites source-compatible while allowing optional size-cap fields.
		internal init(totalMatches: Int,
		              totalFiles: Int,
		              matchedFiles: Int? = nil,
		              searchedFiles: Int? = nil,
		              contentMatches: Int,
		              pathMatches: Int,
		              limitHit: Bool,
		              perFileCounts: [PerFileCount],
		              pathMatchLines: [String],
		              contentMatchGroups: [ContentMatchGroup],
		              sizeLimitHit: Bool? = nil,
		              omittedTotal: Int? = nil,
		              omittedContentMatches: Int? = nil,
		              omittedPathMatches: Int? = nil,
		              errorMessage: String? = nil,
		              suggestion: String? = nil,
		              warning: String? = nil,
		              perFileTotals: [PerFileCount]? = nil) {
			self.totalMatches = totalMatches
			self.totalFiles = totalFiles
			self.matchedFiles = matchedFiles
			self.searchedFiles = searchedFiles
			self.contentMatches = contentMatches
			self.pathMatches = pathMatches
			self.limitHit = limitHit
			self.perFileCounts = perFileCounts
			self.pathMatchLines = pathMatchLines
			self.contentMatchGroups = contentMatchGroups
			self.sizeLimitHit = sizeLimitHit
			self.omittedTotal = omittedTotal
			self.omittedContentMatches = omittedContentMatches
			self.omittedPathMatches = omittedPathMatches
			self.errorMessage = errorMessage
			self.suggestion = suggestion
			self.warning = warning
			self.perFileTotals = perFileTotals
		}
		
		private enum CodingKeys: String, CodingKey {
			case totalMatches        = "total_matches"
			case totalFiles          = "total_files"
			case matchedFiles        = "matched_files"
			case searchedFiles       = "searched_files"
            case contentMatches      = "content_matches"
            case pathMatches         = "path_matches"
			case limitHit            = "limit_hit"
			case perFileCounts       = "per_file_counts"
			case pathMatchLines      = "path_match_lines"
			case contentMatchGroups  = "content_match_groups"

			// NEW keys
			case sizeLimitHit            = "size_limit_hit"
			case omittedTotal            = "omitted_total"
			case omittedContentMatches   = "omitted_content_matches"
			case omittedPathMatches      = "omitted_path_matches"
			case errorMessage            = "error"
			case suggestion
			case warning
			case perFileTotals           = "per_file_totals"
		}
	}
    
    // MARK: - File Tree
    
    internal struct FileTreeDTO: Codable, Equatable {
        internal let rootsCount: Int
        internal let usesLegend: Bool
        internal let tree: String
        internal let note: String?
        internal let wasTruncated: Bool?

        internal init(
            rootsCount: Int,
            usesLegend: Bool,
            tree: String,
            note: String? = nil,
            wasTruncated: Bool? = nil
        ) {
            self.rootsCount = rootsCount
            self.usesLegend = usesLegend
            self.tree = tree
            self.note = note
            self.wasTruncated = wasTruncated
        }
        
        private enum CodingKeys: String, CodingKey {
            case rootsCount  = "roots_count"
            case usesLegend  = "uses_legend"
            case tree
            case note
            case wasTruncated = "was_truncated"
        }
    }
    
    // MARK: - Code Structure
    
    internal struct SelectedCodeStructureDTO: Codable, Equatable {
        internal let fileCount: Int
        internal let content: String
        /// Paths (display-form) that are selected but have **no codemap** available
        internal let unmappedPaths: [String]?
        /// Number of additional files with codemaps omitted due to `max_results` cap
        internal let omittedCount: Int?
        /// Total number of codemaps omitted due to all limits
        internal let omittedTotal: Int?
        /// Number of codemaps omitted due to the response token budget
        internal let tokenBudgetOmittedCount: Int?
        /// Indicates the response token budget prevented more codemaps from being emitted
        internal let tokenBudgetHit: Bool?

		internal init(fileCount: Int,
					  content: String,
					  unmappedPaths: [String]? = nil,
					  omittedCount: Int? = nil,
					  omittedTotal: Int? = nil,
					  tokenBudgetOmittedCount: Int? = nil,
					  tokenBudgetHit: Bool? = nil) {
			self.fileCount = fileCount
			self.content = content
			self.unmappedPaths = unmappedPaths
			self.omittedCount = omittedCount
			self.omittedTotal = omittedTotal
			self.tokenBudgetOmittedCount = tokenBudgetOmittedCount
			self.tokenBudgetHit = tokenBudgetHit
		}

        private enum CodingKeys: String, CodingKey {
            case fileCount      = "file_count"
            case content
            case unmappedPaths  = "unmapped_paths"
            case omittedCount   = "codemaps_omitted"
            case omittedTotal   = "omitted_total"
            case tokenBudgetOmittedCount = "token_budget_omitted"
            case tokenBudgetHit = "token_budget_hit"
        }
    }
    
    // MARK: - Selected Files Content (bulk read)
    // (Removed) SelectedFilesContentDTO — superseded by workspace_context `file_blocks`
    
    // MARK: - Prompt State (legacy)
    
    internal struct PromptStateReply: Codable, Equatable {
        internal let prompt: String
        internal let selectedPaths: [String]
        /// Optional line-range slices for selected files.
        /// Only includes paths with actual slices; full-file selections are represented only in `selectedPaths`.
        internal let fileSlices: [FileSliceDTO]?
        
        private enum CodingKeys: String, CodingKey {
            case prompt
            case selectedPaths = "selected_paths"
            case fileSlices = "file_slices"
        }
    }
    
    // MARK: - Selection (list and mutations)
    
	internal struct LineRangeDTO: Codable, Equatable {
		internal let startLine: Int
		internal let endLine: Int
		/// Optional description explaining what this slice contains and why it's relevant
		internal let description: String?

		internal init(startLine: Int, endLine: Int, description: String? = nil) {
			self.startLine = startLine
			self.endLine = endLine
			self.description = description
		}

		internal init(range: LineRange) {
			self.init(startLine: range.start, endLine: range.end, description: range.description)
		}

		private enum CodingKeys: String, CodingKey {
			case startLine = "start_line"
			case endLine   = "end_line"
			case description
		}
	}
	
	internal struct FileSliceDTO: Codable, Equatable {
		internal let path: String
		internal let ranges: [LineRangeDTO]
		/// Absolute workspace/root path for markdown grouping. `path` remains the requested display path.
		internal let rootPath: String?
		/// File path relative to `rootPath`, used for markdown tree rendering.
		internal let pathWithinRoot: String?

		internal init(
			path: String,
			ranges: [LineRangeDTO],
			rootPath: String? = nil,
			pathWithinRoot: String? = nil
		) {
			self.path = path
			self.ranges = ranges
			self.rootPath = rootPath
			self.pathWithinRoot = pathWithinRoot
		}
		
		private enum CodingKeys: String, CodingKey {
			case path
			case ranges
			case rootPath = "root_path"
			case pathWithinRoot = "path_within_root"
		}
	}
	
    internal struct SelectedFileInfo: Codable, Equatable {
		/// How a file would render under the user's copy preset (when different from auto view)
		internal struct CopyPresetProjection: Codable, Equatable {
			internal let tokens: Int
			internal let renderMode: String              // "full" | "slice" | "codemap" | "hidden"
			internal let ranges: [LineRangeDTO]?         // for slice
			internal let codemapOrigin: String?          // if codemap: "selected_mode", etc.

			private enum CodingKeys: String, CodingKey {
				case tokens
				case renderMode = "render_mode"
				case ranges
				case codemapOrigin = "codemap_origin"
			}
		}

        internal let path: String
        internal let tokens: Int
		internal let renderMode: String
		internal let ranges: [LineRangeDTO]?
		internal let isAuto: Bool
		/// Why this file is rendered as a codemap: "auto", "manual", or "selected_mode". Nil for non-codemap files.
		internal let codemapOrigin: String?
		/// How this file would render under the user's copy preset (only set when it differs from auto view)
		internal let copyPreset: CopyPresetProjection?
		/// Absolute workspace/root path for markdown grouping. `path` remains the requested display path.
		internal let rootPath: String?
		/// File path relative to `rootPath`, used for markdown tree rendering.
		internal let pathWithinRoot: String?

		internal init(
			path: String,
			tokens: Int,
			renderMode: String,
			ranges: [LineRangeDTO]?,
			isAuto: Bool,
			codemapOrigin: String?,
			copyPreset: CopyPresetProjection?,
			rootPath: String? = nil,
			pathWithinRoot: String? = nil
		) {
			self.path = path
			self.tokens = tokens
			self.renderMode = renderMode
			self.ranges = ranges
			self.isAuto = isAuto
			self.codemapOrigin = codemapOrigin
			self.copyPreset = copyPreset
			self.rootPath = rootPath
			self.pathWithinRoot = pathWithinRoot
		}

		private enum CodingKeys: String, CodingKey {
			case path
			case tokens
			case renderMode = "render_mode"
			case ranges
			case isAuto = "is_auto"
			case codemapOrigin = "codemap_origin"
			case copyPreset = "copy_preset"
			case rootPath = "root_path"
			case pathWithinRoot = "path_within_root"
		}
    }
    
	internal struct SelectionSummary: Codable, Equatable {
		internal let fullCount: Int
		internal let sliceCount: Int
		internal let codemapCount: Int
		internal let fullTokens: Int
		internal let sliceTokens: Int
		internal let codemapTokens: Int

		private enum CodingKeys: String, CodingKey {
			case fullCount = "full_count"
			case sliceCount = "slice_count"
			case codemapCount = "codemap_count"
			case fullTokens = "full_tokens"
			case sliceTokens = "slice_tokens"
			case codemapTokens = "codemap_tokens"
		}
	}

    internal struct SelectedFilesReply: Codable, Equatable {
        internal let files: [SelectedFileInfo]
        internal let totalTokens: Int
		internal let fileSlices: [FileSliceDTO]?
		internal let summary: SelectionSummary?
		/// The active codemap usage mode: "auto", "complete", "selected", or "none"
		internal var codeMapUsage: String? = nil

		// MARK: - User Preset State Indicators (for virtual contexts)
		/// User's copy preset codemap mode (so builder knows user's actual view)
		internal var userCopyCodeMapUsage: String? = nil
		/// User's chat preset codemap mode
		internal var userChatCodeMapUsage: String? = nil
		/// Token count under user's copy preset settings
		internal var userCopyTokens: Int? = nil
		/// Token count under user's chat preset settings
		internal var userChatTokens: Int? = nil
		/// What this reply uses (e.g. "auto" for virtual contexts, nil if live)
		internal var normalizedCodeMapUsage: String? = nil
		/// Summary of how selection would render under the effective copy preset (when it differs from auto)
		internal var copyPresetProjection: CopyPresetProjectionSummaryDTO? = nil
		/// Content tokens (full + slice) under user's copy preset settings
		internal var userCopyContentTokens: Int? = nil
		/// Codemap tokens under user's copy preset settings (0 when codemaps disabled)
		internal var userCopyCodemapTokens: Int? = nil

        private enum CodingKeys: String, CodingKey {
            case files
            case totalTokens = "total_tokens"
			case fileSlices  = "file_slices"
			case summary
			case codeMapUsage = "code_map_usage"
			case userCopyCodeMapUsage = "user_copy_codemap_usage"
			case userChatCodeMapUsage = "user_chat_codemap_usage"
			case userCopyTokens = "user_copy_tokens"
			case userChatTokens = "user_chat_tokens"
			case normalizedCodeMapUsage = "normalized_codemap_usage"
			case copyPresetProjection = "copy_preset_projection"
			case userCopyContentTokens = "user_copy_content_tokens"
			case userCopyCodemapTokens = "user_copy_codemap_tokens"
        }
    }
    
    internal struct SelectionReply: Codable, Equatable {
        internal let files: [SelectedFileInfo]?
        internal let totalTokens: Int?
        internal let status: String
        internal let invalidPaths: [String]?
        /// When `manage_selection` action=`list` and `include_content=true`
        internal let blocks: [String]?
        /// Compact code-map summary for the current selection (no large content)
        internal let codeStructure: SelectedCodeStructureDTO?
		internal let fileSlices: [FileSliceDTO]?
		internal let codemapAutoEnabled: Bool?
		internal let summary: SelectionSummary?
		/// The active codemap usage mode: "auto", "complete", "selected", or "none"
		internal let codeMapUsage: String?

		// MARK: - User Preset State Indicators (for virtual contexts)
		/// User's copy preset codemap mode (so builder knows user's actual view)
		internal let userCopyCodeMapUsage: String?
		/// User's chat preset codemap mode
		internal let userChatCodeMapUsage: String?
		/// Token count under user's copy preset settings
		internal let userCopyTokens: Int?
		/// Token count under user's chat preset settings
		internal let userChatTokens: Int?
		/// What this reply uses (e.g. "auto" for virtual contexts, nil if live)
		internal let normalizedCodeMapUsage: String?
		/// Workspace token breakdown (total includes prompt, file tree, meta, git, etc.)
		internal let tokenStats: TokenStats?
		/// Summary of how selection would render under the effective copy preset (when it differs from auto)
		internal let copyPresetProjection: CopyPresetProjectionSummaryDTO?

		// Explicit initializer with tokenStats defaulting to nil for source compatibility
		internal init(
			files: [SelectedFileInfo]?,
			totalTokens: Int?,
			status: String,
			invalidPaths: [String]? = nil,
			blocks: [String]? = nil,
			codeStructure: SelectedCodeStructureDTO? = nil,
			fileSlices: [FileSliceDTO]? = nil,
			codemapAutoEnabled: Bool? = nil,
			summary: SelectionSummary? = nil,
			codeMapUsage: String? = nil,
			userCopyCodeMapUsage: String? = nil,
			userChatCodeMapUsage: String? = nil,
			userCopyTokens: Int? = nil,
			userChatTokens: Int? = nil,
			normalizedCodeMapUsage: String? = nil,
			tokenStats: TokenStats? = nil,
			copyPresetProjection: CopyPresetProjectionSummaryDTO? = nil
		) {
			self.files = files
			self.totalTokens = totalTokens
			self.status = status
			self.invalidPaths = invalidPaths
			self.blocks = blocks
			self.codeStructure = codeStructure
			self.fileSlices = fileSlices
			self.codemapAutoEnabled = codemapAutoEnabled
			self.summary = summary
			self.codeMapUsage = codeMapUsage
			self.userCopyCodeMapUsage = userCopyCodeMapUsage
			self.userChatCodeMapUsage = userChatCodeMapUsage
			self.userCopyTokens = userCopyTokens
			self.userChatTokens = userChatTokens
			self.normalizedCodeMapUsage = normalizedCodeMapUsage
			self.tokenStats = tokenStats
			self.copyPresetProjection = copyPresetProjection
		}

        private enum CodingKeys: String, CodingKey {
            case files
            case totalTokens   = "total_tokens"
            case status
            case invalidPaths  = "invalid_paths"
            case blocks
            case codeStructure = "code_structure"
			case fileSlices    = "file_slices"
			case codemapAutoEnabled = "codemap_auto_enabled"
			case summary
			case codeMapUsage = "code_map_usage"
			case userCopyCodeMapUsage = "user_copy_codemap_usage"
			case userChatCodeMapUsage = "user_chat_codemap_usage"
			case userCopyTokens = "user_copy_tokens"
			case userChatTokens = "user_chat_tokens"
			case normalizedCodeMapUsage = "normalized_codemap_usage"
			case tokenStats = "token_stats"
			case copyPresetProjection = "copy_preset_projection"
        }
    }
    
    // MARK: - Read File
    
    /// Reply structure for read_file tool, carrying slice metadata
    internal struct ReadFileReply: Codable, Equatable {
        internal let content: String
        internal let totalLines: Int
        internal let firstLine: Int
        internal let lastLine: Int
        internal let message: String?
        internal let displayPath: String?
        
        private enum CodingKeys: String, CodingKey {
            case content
            case totalLines = "total_lines"
            case firstLine  = "first_line"
            case lastLine   = "last_line"
            case message
            case displayPath = "display_path"
        }
    }
    
    // MARK: - Apply Edits
    
    /// Compact summary returned by edit tools.
    ///
    /// Fields:
    /// - totalLinesChanged – sum of absolute line deltas across all committed chunks.
    /// - totalChunks       – number of diff chunks applied.
    internal struct EditSummary: Codable, Equatable {
        internal let status: String                  // "success", "partial", "failed"
        internal let editsRequested: Int
        internal let editsApplied: Int
        internal let addedLines: Int?
        internal let deletedLines: Int?
        internal let totalLinesChanged: Int?
        internal let totalChunks: Int?
        internal let results: [EditOutcome]?         // Provided by diff generator utilities
        internal let unifiedDiff: String?
        internal let cardUnifiedDiff: String?
        // Extra context – used for friendlier UI and fallback reporting
        internal let note: String?
        internal let fileCreated: Bool?
        internal let fileOverwritten: Bool?
        internal let reviewStatus: String?
        internal let rejectionReason: String?
        internal let requiresUserApproval: Bool?
        
        private enum CodingKeys: String, CodingKey {
            case status
            case editsRequested    = "edits_requested"
            case editsApplied      = "edits_applied"
            case addedLines        = "added_lines"
            case deletedLines      = "deleted_lines"
            case totalLinesChanged = "total_lines_changed"
            case totalChunks       = "total_chunks"
            case results
            case unifiedDiff       = "unified_diff"
            case cardUnifiedDiff   = "card_unified_diff"
            case note
            case fileCreated       = "file_created"
            case fileOverwritten   = "file_overwritten"
            case reviewStatus      = "review_status"
            case rejectionReason   = "rejection_reason"
            case requiresUserApproval = "requires_user_approval"
        }
    }

	internal struct ApplyPatchSummary: Codable, Equatable {
		internal struct Change: Codable, Equatable {
			internal let path: String
			internal let kind: String
			internal let movePath: String?
			internal let diff: String

			private enum CodingKeys: String, CodingKey {
				case path
				case kind
				case movePath = "move_path"
				case diff
			}
		}

		internal let status: String
		internal let changes: [Change]
		internal let output: String?
		internal let changeCount: Int
		internal let summaryOnly: Bool?

		private enum CodingKeys: String, CodingKey {
			case status
			case changes
			case output
			case changeCount = "change_count"
			case summaryOnly = "summary_only"
		}
	}

	// MARK: - Cursor Native Edit

	internal struct CursorNativeEditSummary: Decodable, Equatable {
		internal struct Content: Decodable, Equatable {
			internal let type: String?
			internal let path: String?
			internal let oldText: String?
			internal let newText: String?
			internal let unifiedDiff: String?
			internal let oldTextTruncated: Bool?
			internal let newTextTruncated: Bool?
			internal let diffTruncated: Bool?

			private enum CodingKeys: String, CodingKey {
				case type
				case path
				case oldText
				case newText
				case oldTextSnake = "old_text"
				case newTextSnake = "new_text"
				case unifiedDiff = "unified_diff"
				case cardUnifiedDiff = "card_unified_diff"
				case oldTextTruncated = "oldText_truncated"
				case newTextTruncated = "newText_truncated"
				case oldTextTruncatedSnake = "old_text_truncated"
				case newTextTruncatedSnake = "new_text_truncated"
				case oldTextTruncatedCamel = "oldTextTruncated"
				case newTextTruncatedCamel = "newTextTruncated"
				case diffTruncated = "diff_truncated"
				case diffTruncatedCamel = "diffTruncated"
			}

			internal init(from decoder: Decoder) throws {
				let container = try decoder.container(keyedBy: CodingKeys.self)
				type = try container.decodeIfPresent(String.self, forKey: .type)
				path = try container.decodeIfPresent(String.self, forKey: .path)
				oldText = try container.decodeIfPresent(String.self, forKey: .oldText)
					?? container.decodeIfPresent(String.self, forKey: .oldTextSnake)
				newText = try container.decodeIfPresent(String.self, forKey: .newText)
					?? container.decodeIfPresent(String.self, forKey: .newTextSnake)
				unifiedDiff = try container.decodeIfPresent(String.self, forKey: .unifiedDiff)
					?? container.decodeIfPresent(String.self, forKey: .cardUnifiedDiff)
				oldTextTruncated = try container.decodeIfPresent(Bool.self, forKey: .oldTextTruncated)
					?? container.decodeIfPresent(Bool.self, forKey: .oldTextTruncatedSnake)
					?? container.decodeIfPresent(Bool.self, forKey: .oldTextTruncatedCamel)
				newTextTruncated = try container.decodeIfPresent(Bool.self, forKey: .newTextTruncated)
					?? container.decodeIfPresent(Bool.self, forKey: .newTextTruncatedSnake)
					?? container.decodeIfPresent(Bool.self, forKey: .newTextTruncatedCamel)
				diffTruncated = try container.decodeIfPresent(Bool.self, forKey: .diffTruncated)
					?? container.decodeIfPresent(Bool.self, forKey: .diffTruncatedCamel)
			}
		}

		internal let status: String?
		internal let acpStatus: String?
		internal let kind: String?
		internal let title: String?
		internal let content: [Content]?
		internal let changeCount: Int?
		internal let summaryOnly: Bool?

		private enum CodingKeys: String, CodingKey {
			case status
			case acpStatus = "acp_status"
			case kind
			case title
			case content
			case changeCount = "change_count"
			case summaryOnly = "summary_only"
		}
	}

	// MARK: - Chat Send

	internal struct ChatSendDTO: Codable, Equatable {
		internal struct Diff: Codable, Equatable {
			internal let path: String
			internal let patch: String
		}

		internal let chatID: String?
		internal let mode: String?
		internal let response: String?
		internal let diffs: [Diff]?
		internal let errors: [String]?

		private enum CodingKeys: String, CodingKey {
			case chatID = "chat_id"
			case mode
			case response
			case diffs
			case patches
			case errors
		}

		internal init(chatID: String?, mode: String?, response: String?, diffs: [Diff]?, errors: [String]?) {
			self.chatID = chatID
			self.mode = mode
			self.response = response
			self.diffs = diffs
			self.errors = errors
		}

		internal init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			chatID = try container.decodeIfPresent(String.self, forKey: .chatID)
			mode = try container.decodeIfPresent(String.self, forKey: .mode)
			response = try container.decodeIfPresent(String.self, forKey: .response)
			if let decodedDiffs = try container.decodeIfPresent([Diff].self, forKey: .diffs) {
				diffs = decodedDiffs
			} else {
				diffs = try container.decodeIfPresent([Diff].self, forKey: .patches)
			}
			errors = try container.decodeIfPresent([String].self, forKey: .errors)
		}

		internal func encode(to encoder: Encoder) throws {
			var container = encoder.container(keyedBy: CodingKeys.self)
			try container.encodeIfPresent(chatID, forKey: .chatID)
			try container.encodeIfPresent(mode, forKey: .mode)
			try container.encodeIfPresent(response, forKey: .response)
			try container.encodeIfPresent(diffs, forKey: .diffs)
			try container.encodeIfPresent(errors, forKey: .errors)
		}
	}

	// MARK: - Context Builder

	internal struct ContextBuilderDTO: Codable, Equatable {
		internal let tabID: String?
		internal let status: String?
		internal let prompt: String?
		internal let fileCount: Int?
		internal let totalTokens: Int?
		internal let selection: String?
		internal let responseType: String?
		internal let plan: ChatSendDTO?
		internal let review: ChatSendDTO?
		internal let followUpHint: String?
		internal let message: String?
		internal let summary: String?

		private enum CodingKeys: String, CodingKey {
			case tabID = "context_id"
			case status
			case prompt
			case fileCount = "file_count"
			case totalTokens = "total_tokens"
			case selection
			case responseType = "response_type"
			case plan
			case review
			case followUpHint = "follow_up_hint"
			case message
			case summary
		}

		private enum LegacyCodingKeys: String, CodingKey {
			case tabID = "tab_id"
		}

		internal init(from decoder: Decoder) throws {
			let container = try decoder.container(keyedBy: CodingKeys.self)
			let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)

			tabID = try container.decodeIfPresent(String.self, forKey: .tabID)
				?? legacyContainer.decodeIfPresent(String.self, forKey: .tabID)
			status = try container.decodeIfPresent(String.self, forKey: .status)
			prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
			fileCount = try container.decodeIfPresent(Int.self, forKey: .fileCount)
			totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
			selection = try container.decodeIfPresent(String.self, forKey: .selection)
			responseType = try container.decodeIfPresent(String.self, forKey: .responseType)
			plan = try container.decodeIfPresent(ChatSendDTO.self, forKey: .plan)
			review = try container.decodeIfPresent(ChatSendDTO.self, forKey: .review)
			followUpHint = try container.decodeIfPresent(String.self, forKey: .followUpHint)
			message = try container.decodeIfPresent(String.self, forKey: .message)
			summary = try container.decodeIfPresent(String.self, forKey: .summary)
		}
	}
    
    // MARK: - Models
    
    internal struct SupportedModesInfo: Codable, Equatable {
        internal let chat: Bool
        internal let plan: Bool
        internal let edit: Bool
        internal let review: Bool
    }
    
    internal struct ModelInfo: Codable, Equatable {
        internal let id: String
        internal let name: String
        internal let description: String?
        internal let supportedModes: SupportedModesInfo?
        
        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case description
            case supportedModes = "supported_modes"
        }
    }
    
    internal struct ListModelsReply: Codable, Equatable {
        internal let models: [ModelInfo]
        internal let total: Int
    }
    
    // MARK: - File Actions
    
    internal struct FileActionReply: Codable, Equatable {
        internal let status: String     // "ok" or error/other statuses
        internal let action: String     // "create", "delete", "move"
        internal let path: String
        internal let newPath: String?   // present for move/rename
        
        private enum CodingKeys: String, CodingKey {
            case status
            case action
            case path
            case newPath = "new_path"
        }
    }

    // MARK: - Copy Preset DTOs

    /// Compact identifier for a copy preset
    internal struct CopyPresetDescriptorDTO: Codable, Equatable {
        internal let id: String            // UUID string
        internal let name: String
        internal let kind: String?         // CopyPresetKind.rawValue
        internal let isBuiltIn: Bool

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case kind
            case isBuiltIn = "is_built_in"
        }
    }

    /// Full preset listing with configuration details
    internal struct CopyPresetListItemDTO: Codable, Equatable {
        internal let preset: CopyPresetDescriptorDTO
        internal let description: String?
        internal let icon: String?

        // Raw preset fields (may be nil meaning "uses workspace/UI defaults")
        internal let includeFiles: Bool?
        internal let includeUserPrompt: Bool?
        internal let includeMetaPrompts: Bool?
        internal let includeFileTree: Bool?
        internal let xmlFormat: String?          // "diff"|"whole"|"architect"|nil
        internal let fileTreeMode: String?       // "auto"|"full"|"selected"|"none"|nil
        internal let codeMapUsage: String?       // "auto"|"complete"|"selected"|"none"|nil
        internal let gitInclusion: String?       // "none"|"selected"|"complete"|nil
        internal let systemPromptFlavor: String? // existing string mapping
        internal let includeMCPMetadata: Bool?

        private enum CodingKeys: String, CodingKey {
            case preset
            case description
            case icon
            case includeFiles = "include_files"
            case includeUserPrompt = "include_user_prompt"
            case includeMetaPrompts = "include_meta_prompts"
            case includeFileTree = "include_file_tree"
            case xmlFormat = "xml_format"
            case fileTreeMode = "file_tree_mode"
            case codeMapUsage = "codemap_usage"
            case gitInclusion = "git_inclusion"
            case systemPromptFlavor = "system_prompt_flavor"
            case includeMCPMetadata = "include_mcp_metadata"
        }
    }

    /// Active vs effective preset context (for override scenarios)
    internal struct CopyPresetContextDTO: Codable, Equatable {
        internal let active: CopyPresetDescriptorDTO
        internal let effective: CopyPresetDescriptorDTO   // equals active if no override
        internal let isOverridden: Bool

        private enum CodingKeys: String, CodingKey {
            case active
            case effective
            case isOverridden = "is_overridden"
        }
    }

    /// Summary of how selection would render under a copy preset
    internal struct CopyPresetProjectionSummaryDTO: Codable, Equatable {
        internal let codeMapUsage: String
        internal let includesFiles: Bool
        internal let totalTokens: Int

        private enum CodingKeys: String, CodingKey {
            case codeMapUsage = "codemap_usage"
            case includesFiles = "includes_files"
            case totalTokens = "total_tokens"
        }
    }

    // MARK: - Unified prompt + selection + context (codemaps-first)
	internal struct TokenStats: Codable, Equatable {
        internal let total: Int
        internal let files: Int
		internal let prompt: Int?
		internal let fileTree: Int?
		internal let meta: Int?
		internal let git: Int?
		internal let other: Int?
		/// Token count from full files and slices (excludes codemaps)
		internal let filesContent: Int?
		/// Token count from codemaps only
		internal let codemaps: Int?

		internal init(
			total: Int,
			files: Int,
			prompt: Int? = nil,
			fileTree: Int? = nil,
			meta: Int? = nil,
			git: Int? = nil,
			other: Int? = nil,
			filesContent: Int? = nil,
			codemaps: Int? = nil
		) {
			self.total = total
			self.files = files
			self.prompt = prompt
			self.fileTree = fileTree
			self.meta = meta
			self.git = git
			self.other = other
			self.filesContent = filesContent
			self.codemaps = codemaps
		}

		private enum CodingKeys: String, CodingKey {
			case total
			case files
			case prompt
			case fileTree = "file_tree"
			case meta
			case git
			case other
			case filesContent = "files_content"
			case codemaps
		}
    }

    // MARK: - Prompt (read/write)
    internal struct PromptReply: Codable, Equatable {
        internal let prompt: String
        internal let lines: Int
        
        // Preset information
        internal let copyPresetName: String?
        internal let chatPresetName: String?
        internal let chatMode: String?              // "chat", "plan", "edit"
        
        // Configuration breakdown (what's included in the prompt)
        internal let includesFiles: Bool?
        internal let includesFileTree: Bool?
        internal let includesCodemaps: Bool?
        internal let includesGitDiff: Bool?
        internal let includesUserPrompt: Bool?
        internal let includesMetaPrompts: Bool?
        internal let includesStoredPrompts: Bool?
        
        // Detailed settings
        internal let fileTreeMode: String?          // "auto", "full", "selected", "none"
        internal let codeMapUsage: String?          // "none", "auto", "complete", "selected"
        internal let gitInclusion: String?          // "none", "selected", "complete"
        internal let xmlFormat: String?             // "diff", "whole", "architect" or nil
        internal let systemPromptFlavor: String?    // System prompt type being used
        
        // Token counts
        internal let effectiveTokens: Int?          // Tokens for the actual prompt being sent
        internal let fullFilesTokens: Int?          // Tokens if full files were included
        
        // Codemap details (when codemaps are included)
        internal let codeMapFileCount: Int?         // Number of files with codemaps
        internal let codeMapTokens: Int?            // Tokens consumed by codemaps
        internal let codeMapFiles: [String]?        // List of file paths with codemaps
        
        private enum CodingKeys: String, CodingKey {
            case prompt
            case lines
            case copyPresetName = "copy_preset_name"
            case chatPresetName = "chat_preset_name"
            case chatMode = "chat_mode"
            case includesFiles = "includes_files"
            case includesFileTree = "includes_file_tree"
            case includesCodemaps = "includes_codemaps"
            case includesGitDiff = "includes_git_diff"
            case includesUserPrompt = "includes_user_prompt"
            case includesMetaPrompts = "includes_meta_prompts"
            case includesStoredPrompts = "includes_stored_prompts"
            case fileTreeMode = "file_tree_mode"
            case codeMapUsage = "codemap_usage"
            case gitInclusion = "git_inclusion"
            case xmlFormat = "xml_format"
            case systemPromptFlavor = "system_prompt_flavor"
            case effectiveTokens = "effective_tokens"
            case fullFilesTokens = "full_files_tokens"
            case codeMapFileCount = "codemap_file_count"
            case codeMapTokens = "codemap_tokens"
            case codeMapFiles = "codemap_files"
        }
    }

	// MARK: - Prompt Export
	internal struct PromptExportReply: Codable, Equatable {
		internal let path: String
		internal let tokens: Int
		internal let bytes: Int
		internal let files: [SelectedFileInfo]
		/// The copy preset used for this export (if overridden or for informational purposes)
		internal let copyPreset: CopyPresetDescriptorDTO?

		private enum CodingKeys: String, CodingKey {
			case path
			case tokens
			case bytes
			case files
			case copyPreset = "copy_preset"
		}
	}

	/// Reply for list_presets operation
	internal struct PresetsListReply: Codable, Equatable {
		internal let presets: [CopyPresetListItemDTO]
	}

	// MARK: - Unified Git Tool

	/// Main reply DTO for the unified `git` MCP tool.
	/// The `op` field indicates which operation was performed and which
	/// payload fields are populated.
	///
	/// Multi-root support:
	/// - When operating on a single repo, the existing flat structure is used (status, diff, log, etc.)
	/// - When operating on multiple repos, the `repos` array contains per-repo results
	/// - The `aggregate` field contains combined totals across all repos (for multi-root diff)
	internal struct GitToolReplyDTO: Codable, Equatable {
		internal let op: String

		// Multi-root support
		/// Per-repo results for multi-root operations (nil when single repo)
		internal let repos: [RepoResultDTO]?
		/// Aggregated results across all repos (for multi-root diff operations)
		internal let aggregate: AggregateDTO?

		// Status op payload (single repo)
		internal let status: StatusDTO?

		// Diff op payload (single repo)
		internal let diff: DiffDTO?

		// Log op payload (single repo)
		internal let log: LogDTO?

		// Show op payload (single repo)
		internal let show: ShowDTO?

		// Blame op payload (single repo)
		internal let blame: BlameDTO?
		
		// Worktree metadata (single repo)
		internal let worktree: WorktreeDTO?

		// Artifact info (diff with artifacts: true)
		internal let snapshotId: String?
		internal let snapshotDir: String?

		internal let artifacts: ArtifactsDTO?
		internal let primaryArtifacts: PrimaryArtifactsDTO?
		internal let summary: SummaryDTO?
		internal let oneliner: String?
		internal let inputs: DiffInputsDTO?
		internal let modeDetails: String?
		internal let inline: InlineDTO?

		// Common
		internal let warning: String?
		internal let emptyReason: String?
		internal let error: String?

		private enum CodingKeys: String, CodingKey {
			case op, repos, aggregate, status, diff, log, show, blame, worktree
			case artifacts, summary, oneliner, inputs, inline, warning, error
			case primaryArtifacts = "primary_artifacts"
			case snapshotId = "snapshot_id"
			case snapshotDir = "snapshot_dir"

			case modeDetails = "mode_details"
			case emptyReason = "empty_reason"
		}

		// Explicit initializer to allow default values for new optional fields
		internal init(
			op: String,
			repos: [RepoResultDTO]? = nil,
			aggregate: AggregateDTO? = nil,
			status: StatusDTO? = nil,
			diff: DiffDTO? = nil,
			log: LogDTO? = nil,
			show: ShowDTO? = nil,
			blame: BlameDTO? = nil,
			worktree: WorktreeDTO? = nil,
			snapshotId: String? = nil,
			snapshotDir: String? = nil,
			artifacts: ArtifactsDTO? = nil,
			primaryArtifacts: PrimaryArtifactsDTO? = nil,
			summary: SummaryDTO? = nil,
			oneliner: String? = nil,
			inputs: DiffInputsDTO? = nil,
			modeDetails: String? = nil,
			inline: InlineDTO? = nil,
			warning: String? = nil,
			emptyReason: String? = nil,
			error: String? = nil
		) {
			self.op = op
			self.repos = repos
			self.aggregate = aggregate
			self.status = status
			self.diff = diff
			self.log = log
			self.show = show
			self.blame = blame
			self.worktree = worktree
			self.snapshotId = snapshotId
			self.snapshotDir = snapshotDir
			self.artifacts = artifacts
			self.primaryArtifacts = primaryArtifacts
			self.summary = summary
			self.oneliner = oneliner
			self.inputs = inputs
			self.modeDetails = modeDetails
			self.inline = inline
			self.warning = warning
			self.emptyReason = emptyReason
			self.error = error
		}

		// MARK: - Nested DTOs
		
		// MARK: Multi-root DTOs
		
		/// Per-repo result for multi-root operations
		internal struct RepoResultDTO: Codable, Equatable {
			/// Canonical absolute path of the git repository root
			internal let repoRoot: String
			/// Stable repo key for storage/identification
			internal let repoKey: String
			/// Human-readable repo name (typically last path component)
			internal let repoName: String?
			
			// Op-specific payloads (at most one populated per repo)
			internal let status: StatusDTO?
			internal let diff: DiffDTO?
			internal let log: LogDTO?
			internal let show: ShowDTO?
			internal let blame: BlameDTO?
			
			// Worktree metadata (per repo)
			internal let worktree: WorktreeDTO?
			
			// Artifact info (for diff with artifacts)
			internal let snapshotId: String?
			internal let snapshotDir: String?
			internal let artifacts: ArtifactsDTO?
			internal let primaryArtifacts: PrimaryArtifactsDTO?
			internal let summary: SummaryDTO?
			internal let oneliner: String?
			internal let inputs: DiffInputsDTO?
			internal let modeDetails: String?
			internal let inline: InlineDTO?
			
			// Per-repo status
			internal let warning: String?
			internal let emptyReason: String?
			internal let error: String?
			
			private enum CodingKeys: String, CodingKey {
				case repoRoot = "repo_root"
				case repoKey = "repo_key"
				case repoName = "repo_name"
				case status, diff, log, show, blame, worktree
				case snapshotId = "snapshot_id"
				case snapshotDir = "snapshot_dir"
				case artifacts, summary, oneliner, inputs
				case primaryArtifacts = "primary_artifacts"
				case modeDetails = "mode_details"
				case inline
				case warning
				case emptyReason = "empty_reason"
				case error
			}
			
			internal init(
				repoRoot: String,
				repoKey: String,
				repoName: String? = nil,
				status: StatusDTO? = nil,
				diff: DiffDTO? = nil,
				log: LogDTO? = nil,
				show: ShowDTO? = nil,
				blame: BlameDTO? = nil,
				worktree: WorktreeDTO? = nil,
				snapshotId: String? = nil,
				snapshotDir: String? = nil,
				artifacts: ArtifactsDTO? = nil,
				primaryArtifacts: PrimaryArtifactsDTO? = nil,
				summary: SummaryDTO? = nil,
				oneliner: String? = nil,
				inputs: DiffInputsDTO? = nil,
				modeDetails: String? = nil,
				inline: InlineDTO? = nil,
				warning: String? = nil,
				emptyReason: String? = nil,
				error: String? = nil
			) {
				self.repoRoot = repoRoot
				self.repoKey = repoKey
				self.repoName = repoName
				self.status = status
				self.diff = diff
				self.log = log
				self.show = show
				self.blame = blame
				self.worktree = worktree
				self.snapshotId = snapshotId
				self.snapshotDir = snapshotDir
				self.artifacts = artifacts
				self.primaryArtifacts = primaryArtifacts
				self.summary = summary
				self.oneliner = oneliner
				self.inputs = inputs
				self.modeDetails = modeDetails
				self.inline = inline
				self.warning = warning
				self.emptyReason = emptyReason
				self.error = error
			}
		}
		
		/// Aggregated results across multiple repos (for multi-root diff)
		internal struct AggregateDTO: Codable, Equatable {
			/// Combined totals across all repos
			internal let totals: TotalsDTO?
			/// Combined status breakdown across all repos
			internal let byStatus: [String: Int]?
			/// Summary one-liner (e.g., "3 repos: 15 files (+200 -50)")
			internal let oneliner: String?
			/// Number of repos included in aggregation
			internal let repoCount: Int?
			
			internal init(
				totals: TotalsDTO? = nil,
				byStatus: [String: Int]? = nil,
				oneliner: String? = nil,
				repoCount: Int? = nil
			) {
				self.totals = totals
				self.byStatus = byStatus
				self.oneliner = oneliner
				self.repoCount = repoCount
			}
			
			private enum CodingKeys: String, CodingKey {
				case totals
				case byStatus = "by_status"
				case oneliner
				case repoCount = "repo_count"
			}
		}

		internal struct WorktreeDTO: Codable, Equatable {
			internal let isWorktree: Bool
			internal let worktreeName: String?
			internal let worktreeRoot: String
			internal let commonGitDir: String?
			internal let mainWorktreeRoot: String?
			internal let worktreeBranch: String?
			internal let mainBranch: String?
			internal let worktreeHead: String?
			internal let mainHead: String?

			private enum CodingKeys: String, CodingKey {
				case isWorktree = "is_worktree"
				case worktreeName = "worktree_name"
				case worktreeRoot = "worktree_root"
				case commonGitDir = "common_git_dir"
				case mainWorktreeRoot = "main_worktree_root"
				case worktreeBranch = "worktree_branch"
				case mainBranch = "main_branch"
				case worktreeHead = "worktree_head"
				case mainHead = "main_head"
			}
		}

		internal struct StatusDTO: Codable, Equatable {
			internal let branch: String?
			internal let upstream: String?
			internal let ahead: Int?
			internal let behind: Int?
			internal let staged: [String]
			internal let modified: [String]
			internal let untracked: [String]
			internal let summary: String

			private enum CodingKeys: String, CodingKey {
				case branch, upstream, ahead, behind, staged, modified, untracked, summary
			}
		}

		internal struct DiffDTO: Codable, Equatable {
			internal let compare: String
			internal let detail: String?
			internal let files: [DiffFileDTO]?
			internal let totals: TotalsDTO
			internal let byStatus: [String: Int]?
			internal let oneliner: String
			internal let truncated: Bool?
			internal let truncationNote: String?

			private enum CodingKeys: String, CodingKey {
				case compare, detail, files, totals, oneliner, truncated
				case byStatus = "by_status"
				case truncationNote = "truncation_note"
			}
		}

		internal struct DiffFileDTO: Codable, Equatable {
			internal let path: String
			internal let status: String
			internal let insertions: Int?
			internal let deletions: Int?
			internal let hunks: [DiffHunkDTO]?

			private enum CodingKeys: String, CodingKey {
				case path, status, insertions, deletions, hunks
			}
		}

		internal struct DiffHunkDTO: Codable, Equatable {
			internal let header: String
			internal let oldStart: Int
			internal let newStart: Int
			internal let patch: String

			private enum CodingKeys: String, CodingKey {
				case header, patch
				case oldStart = "old_start"
				case newStart = "new_start"
			}
		}

		internal struct TotalsDTO: Codable, Equatable {
			internal let files: Int
			internal let insertions: Int
			internal let deletions: Int
		}

		internal struct LogDTO: Codable, Equatable {
			internal let commits: [CommitSummaryDTO]
		}

		internal struct CommitSummaryDTO: Codable, Equatable {
			internal let sha: String
			internal let shortSha: String
			internal let author: String
			internal let date: String
			internal let message: String
			internal let filesChanged: Int
			internal let insertions: Int
			internal let deletions: Int

			private enum CodingKeys: String, CodingKey {
				case sha, author, date, message, insertions, deletions
				case shortSha = "short_sha"
				case filesChanged = "files_changed"
			}
		}

		internal struct ShowDTO: Codable, Equatable {
			internal let sha: String
			internal let shortSha: String
			internal let author: String
			internal let date: String
			internal let message: String
			internal let files: [DiffFileDTO]?
			internal let totals: TotalsDTO
			internal let hunks: [DiffHunkDTO]?

			private enum CodingKeys: String, CodingKey {
				case sha, author, date, message, files, totals, hunks
				case shortSha = "short_sha"
			}
		}

		internal struct BlameDTO: Codable, Equatable {
			internal let path: String
			internal let lines: [BlameLineDTO]
		}

		internal struct BlameLineDTO: Codable, Equatable {
			internal let num: Int
			internal let sha: String
			internal let author: String
			internal let date: String
			internal let content: String
		}

		internal struct SummaryDTO: Codable, Equatable {
			internal let files: Int
			internal let insertions: Int
			internal let deletions: Int
			internal let byStatus: [String: Int]?

			private enum CodingKeys: String, CodingKey {
				case files, insertions, deletions
				case byStatus = "by_status"
			}
		}

		internal struct ArtifactsDTO: Codable, Equatable {
			internal let manifest: String
			internal let map: String
			internal let filesTsv: String
			internal let changedLines: String?
			internal let tree: String
			internal let selectionPaths: String?
			internal let allPatch: String?
			internal let deepHunks: String?
			internal let deepChangedLines: String?

			private enum CodingKeys: String, CodingKey {
				case manifest, map, tree
				case filesTsv = "files_tsv"
				case changedLines = "changed_lines"
				case selectionPaths = "selection_paths"
				case allPatch = "all_patch"
				case deepHunks = "deep_hunks"
				case deepChangedLines = "deep_changed_lines"
			}
		}
		
		internal struct PrimaryArtifactsDTO: Codable, Equatable {
			internal struct PerFilePatchDTO: Codable, Equatable {
				internal let jumpIndex: Int
				internal let gitPath: String
				internal let selectionPath: String
				internal let status: String?
				internal let additions: Int?
				internal let deletions: Int?

				private enum CodingKeys: String, CodingKey {
					case status, additions, deletions
					case jumpIndex = "jump_index"
					case gitPath = "git_path"
					case selectionPath = "selection_path"
				}
			}

			internal let map: String
			internal let allPatch: String?
			internal let autoSelected: [String]?
			internal let perFilePatches: [PerFilePatchDTO]?
			
			private enum CodingKeys: String, CodingKey {
				case map
				case allPatch = "all_patch"
				case autoSelected = "auto_selected"
				case perFilePatches = "per_file_patches"
			}
		}

		internal struct InlineDTO: Codable, Equatable {
			internal let mapExcerpt: String
			internal let truncated: Bool
			internal let totalLines: Int
			internal let returnedLines: Int

			private enum CodingKeys: String, CodingKey {
				case mapExcerpt = "map_excerpt"
				case truncated
				case totalLines = "total_lines"
				case returnedLines = "returned_lines"
			}
		}

		internal struct DiffInputsDTO: Codable, Equatable {
			internal let compare: String
			internal let compareInput: String?
			internal let scope: String
			internal let requestedPathsCount: Int?
			internal let contextLines: Int
			internal let detectRenames: Bool

			private enum CodingKeys: String, CodingKey {
				case compare, scope
				case compareInput = "compare_input"
				case requestedPathsCount = "requested_paths_count"
				case contextLines = "context_lines"
				case detectRenames = "detect_renames"
			}
		}
	}

	// MARK: - Git Diff (legacy)

	internal struct GitDiffPublishReplyDTO: Codable, Equatable {
		internal let op: String
		internal let snapshotId: String?
		internal let snapshotDir: String?
		internal let artifacts: ArtifactsDTO?
		internal let summary: SummaryDTO?
		internal let oneliner: String?
		internal let inputs: InputsDTO?
		internal let modeDetails: String?
		internal let warning: String?
		internal let emptyReason: String?
		internal let inline: InlineDTO?
		internal let snapshots: [SnapshotEntryDTO]?
		internal let deleted: [String]?
		internal let notFound: [String]?

		internal struct ArtifactsDTO: Codable, Equatable {
			internal let manifest: String
			internal let map: String
			internal let filesTsv: String
			internal let changedLines: String?
			internal let tree: String
			internal let selectionPaths: String?
			internal let allPatch: String?
			internal let deepHunks: String?
			internal let deepChangedLines: String?

			private enum CodingKeys: String, CodingKey {
				case manifest
				case map
				case filesTsv = "files_tsv"
				case changedLines = "changed_lines"
				case tree
				case selectionPaths = "selection_paths"
				case allPatch = "all_patch"
				case deepHunks = "deep_hunks"
				case deepChangedLines = "deep_changed_lines"
			}
		}

		internal struct SummaryDTO: Codable, Equatable {
			internal let files: Int
			internal let insertions: Int
			internal let deletions: Int
			internal let byStatus: [String: Int]?

			private enum CodingKeys: String, CodingKey {
				case files
				case insertions
				case deletions
				case byStatus = "by_status"
			}
		}

		internal struct InputsDTO: Codable, Equatable {
			internal let compare: String
			internal let compareInput: String?
			internal let scope: String
			internal let requestedPathsCount: Int?
			internal let contextLines: Int
			internal let detectRenames: Bool

			private enum CodingKeys: String, CodingKey {
				case compare
				case compareInput = "compare_input"
				case scope
				case requestedPathsCount = "requested_paths_count"
				case contextLines = "context_lines"
				case detectRenames = "detect_renames"
			}
		}

		internal struct SnapshotEntryDTO: Codable, Equatable {
			internal let snapshotId: String
			internal let repoKey: String?
			internal let snapshotDir: String?
			internal let generatedAt: String
			internal let mode: String
			internal let compare: String
			internal let scope: String
			internal let summary: SummaryDTO
			internal let oneliner: String?
			internal let current: Bool?

			private enum CodingKeys: String, CodingKey {
				case snapshotId = "snapshot_id"
				case repoKey = "repo_key"
				case snapshotDir = "snapshot_dir"
				case generatedAt = "generated_at"
				case mode
				case compare
				case scope
				case summary
				case oneliner
				case current
			}
		}

		internal struct InlineDTO: Codable, Equatable {
			internal let mapExcerpt: String
			internal let truncated: Bool
			internal let totalLines: Int
			internal let returnedLines: Int

			private enum CodingKeys: String, CodingKey {
				case mapExcerpt = "map_excerpt"
				case truncated
				case totalLines = "total_lines"
				case returnedLines = "returned_lines"
			}
		}
	}

	/// Envelope for prompt tool results (discriminated by `op` field)
	internal struct PromptToolEnvelope: Codable, Equatable {
		internal let op: String
		internal let prompt: PromptReply?
		internal let export: PromptExportReply?
		internal let presetsList: PresetsListReply?
		internal let selectedPreset: CopyPresetDescriptorDTO?

		private enum CodingKeys: String, CodingKey {
			case op
			case prompt
			case export
			case presetsList = "presets_list"
			case selectedPreset = "selected_preset"
		}

		static func forPrompt(_ reply: PromptReply, op: String) -> PromptToolEnvelope {
			PromptToolEnvelope(op: op, prompt: reply, export: nil, presetsList: nil, selectedPreset: nil)
		}

		static func forExport(_ reply: PromptExportReply) -> PromptToolEnvelope {
			PromptToolEnvelope(op: "export", prompt: nil, export: reply, presetsList: nil, selectedPreset: nil)
		}

		static func forPresetsList(_ presets: [CopyPresetListItemDTO]) -> PromptToolEnvelope {
			PromptToolEnvelope(op: "list_presets", prompt: nil, export: nil, presetsList: PresetsListReply(presets: presets), selectedPreset: nil)
		}

		static func forSelectPreset(_ preset: CopyPresetDescriptorDTO) -> PromptToolEnvelope {
			PromptToolEnvelope(op: "select_preset", prompt: nil, export: nil, presetsList: nil, selectedPreset: preset)
		}
    }

    /// Unified prompt-context payload for `workspace_context`
    internal struct PromptContextDTO: Codable, Equatable {
        internal let prompt: String
        internal let selection: SelectedFilesReply?
        /// When requested, raw content blocks (from selected files)
        internal let fileBlocks: [String]?
        /// When requested (default), the codemap aggregation + unmapped files
        internal let codeStructure: SelectedCodeStructureDTO?
        /// Optional selected file tree
        internal let fileTree: FileTreeDTO?
        /// Optional token stats (normalized/agent view - always includes codemaps)
        internal let tokenStats: TokenStats?
        /// Token stats matching user's copy preset settings (codemaps may be disabled)
        internal let userTokenStats: TokenStats?
        /// Explains why tokenStats and userTokenStats differ (e.g., codemap settings)
        internal let tokenStatsNote: String?
        /// Active and effective copy preset information (when override is used)
        internal let copyPreset: CopyPresetContextDTO?
        /// Available copy presets (when include contains "presets")
        internal let copyPresets: [CopyPresetListItemDTO]?

        private enum CodingKeys: String, CodingKey {
            case prompt
            case selection
            case fileBlocks     = "file_blocks"
            case codeStructure  = "code_structure"
            case fileTree       = "file_tree"
            case tokenStats     = "token_stats"
            case userTokenStats = "user_token_stats"
            case tokenStatsNote = "token_stats_note"
            case copyPreset     = "copy_preset"
            case copyPresets    = "copy_presets"
        }
    }
}
