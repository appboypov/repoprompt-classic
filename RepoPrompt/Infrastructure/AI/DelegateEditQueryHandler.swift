//
//  DelegateEditHandler.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-04-26.
//

import Foundation
import Combine

// MARK: – Public façade -------------------------------------------------------

/// Lifecycle information the caller must provide.
struct DelegateEditRequest: Sendable {
	let parentMessageId  : UUID
	let currentQueryId   : UUID
	let delegateItem     : DelegateEditItem
	unowned let chatVM   : ChatViewModel          // UI layer
	
	// 🆕 optional fields (filled in by ChatViewModel when it does the prep)
	let taskId         : UUID?          // pre-registered task
	let matchedPath    : String?        // resolved path (in allowedFilePaths)
	let retryStatus    : DelegateEditTask.TaskStatus?
}

/// Convenience so any VM can depend on a protocol, not an impl.
protocol DelegateEditQueryHandling: Sendable {
	func run(_ req: DelegateEditRequest) async
}

// MARK: – Concrete implementation --------------------------------------------

actor DelegateEditQueryHandler: DelegateEditQueryHandling {
	
	// Dependencies injected once – all Sendable.
	private let promptVM        : PromptViewModel          // @MainActor inside
	private let aiQueries       : AIQueriesService
	private let diffParser      : DiffParser
	private let taskManager     : DelegateEditTaskManager  // actor
	
	private let agentRunner = DelegateEditAgentRunner()
	
	// ------------------------------------------------------------------------
	private let uiUpdateInterval: TimeInterval = 0.50   // seconds
	// ------------------------------------------------------------------------
	private var inFlight: Set<String> = []
	
	init(promptVM: PromptViewModel,
		 aiQueriesService: AIQueriesService,
		 diffParser: DiffParser,
		 taskManager: DelegateEditTaskManager)
	{
		self.promptVM   = promptVM
		self.aiQueries  = aiQueriesService
		self.diffParser = diffParser
		self.taskManager = taskManager
	}
	
	// MARK: – Driver ----------------------------------------------------------
	
	/// Entry-point called by view-models.
	func run(_ req: DelegateEditRequest) async {
		
		let useAgentMode = await MainActor.run { promptVM.proEditAgentMode }
		if useAgentMode {
			await runAgentMode(req)
			return
		}
		
		// 🔀 If the ChatViewModel already did the prep, just use it
		if let taskId      = req.taskId,
		   let matchedPath = req.matchedPath
		{
			await runCore(req,
						  prep: PrepData(taskId       : taskId,
										 matchedPath  : matchedPath,
										 parentMessage: req.chatVM.getChatMessage(withId: req.parentMessageId)!,
										 initialTask  : .init(id: taskId,
															  filePath: req.delegateItem.filePath,
															  changes: req.delegateItem.changes,
															  modelDisplayName: "",
															  status: .inProgress,
															  resolvedFilePath: matchedPath)))
			return
		}
	}
	
	private func runAgentMode(_ req: DelegateEditRequest) async {
		// Use pre-resolved path and task if provided (ChatViewModel sets these when launching)
		guard let taskId = req.taskId,
				let matchedPath = req.matchedPath else {
			return
		}
		
		// De-duplicate concurrent identical requests (same path + same change set)
		let key = DelegateEditItem.buildRequestKey(path: matchedPath, changes: req.delegateItem.changes)
		guard inFlight.insert(key).inserted else {
			EditFlowPerf.event(
				EditFlowPerf.Stage.Delegate.taskDuplicateSkip,
				EditFlowPerf.Dimensions(
					status: "handler_agent_inflight",
					editCount: req.delegateItem.changes.count,
					activeCount: inFlight.count,
					isAgentMode: true
				)
			)
			return
		}
		defer { inFlight.remove(key) }
		
		await agentRunner.runForFile(
			currentQueryId: req.currentQueryId,
			taskId: taskId,
			filePath: matchedPath,
			changes: req.delegateItem.changes,
			promptVM: promptVM,
			chatVM: req.chatVM,
			retryStatus: req.retryStatus
		)
	}
	
	/// Factored-out body that does the heavy work
	private func runCore(_ req  : DelegateEditRequest,
						 prep    : PrepData) async
	{
		let taskId = prep.taskId
		let matchedPath = prep.matchedPath
		let key = DelegateEditItem.buildRequestKey(path: matchedPath, changes: req.delegateItem.changes)
		guard inFlight.insert(key).inserted else {
			EditFlowPerf.event(
				EditFlowPerf.Stage.Delegate.taskDuplicateSkip,
				EditFlowPerf.Dimensions(
					status: "handler_core_inflight",
					editCount: req.delegateItem.changes.count,
					activeCount: inFlight.count,
					isAgentMode: false
				)
			)
			return
		}
		defer { inFlight.remove(key) }
		
		do {
			// 1️⃣ Load the file to edit -------------------------------------------------
			let (fileText, lineCount) = try await loadFile(at: matchedPath)
			
			// 2 Change grouping -------------------------------------------------------
			let userStrategy = await MainActor.run { promptVM.complexEditStrategy }
			
			let changeCount = req.delegateItem.changes.count
			
			// 3 Model & system-prompt selection --------------------------------------
			//    (approximate the number of groups before we actually split)
			let groupSize = await MainActor.run { promptVM.delegateEditGroupSizeInt }
			
			let (systemPrompt, model) = await chooseModel(
				changeCount  : changeCount,
				lineCount    : lineCount,
				maxComplexity: maxComplexity(of: req.delegateItem.changes),
				groupSize    : groupSize,
				isParallel   : userStrategy == .parallelSplit && groupSize > 1
			)
			
			let editGroups = makeChangeGroups(
				req.delegateItem.changes,
				diffCapable : model.isModelCapableOfDiff,
				strategy    : userStrategy,
				groupSize: groupSize)
			
			// 🆕  FALLBACK: if no real split happened, treat it like a single query
			let effectiveStrategy: ComplexEditStrategy =
			editGroups.count == 1 ? .single : userStrategy
			
			// -------------------------------------------------------------------------
			// Store the final model name on the task (one MainActor hop for thread-safety)
			await MainActor.run {
				if let idx = req.chatVM.delegateEditTasks[req.currentQueryId]?
					.firstIndex(where: { $0.id == prep.taskId }) {
					req.chatVM.delegateEditTasks[req.currentQueryId]![idx]
						.modelDisplayName = model.displayName
				}
			}
			
			// 4️⃣ Execute edits (parallel, sequential, or single) ----------------------
			let (finalOutput, inTok, outTok, failedGroups): (String, Int, Int, Int)
			
			if effectiveStrategy == .sequential {
				// ▸ Sequential runner (one subgroup after another, rolling state)
				(finalOutput, inTok, outTok, failedGroups) = try await runGroupsSequential(
					editGroups,
					matchedPath    : matchedPath,
					fileText       : fileText,
					systemPrompt   : systemPrompt,
					model          : model,
					taskId         : taskId,
					currentQueryId : req.currentQueryId,
					chatVM         : req.chatVM)
			} else {
				// ▸ Parallel or single-shot runner (each subgroup streamed independently)
				(finalOutput, inTok, outTok, failedGroups) = try await runGroups(
					editGroups,
					matchedPath    : matchedPath,
					fileText       : fileText,
					systemPrompt   : systemPrompt,
					model          : model,
					taskId         : taskId,
					currentQueryId : req.currentQueryId,
					chatVM         : req.chatVM)
			}
			
			// 5️⃣ Finalise UI state -----------------------------------------------------
			// Number of groups originally dispatched
			let totalGroups   = editGroups.count
			// Did the model return anything useful at all?
			let outputIsEmpty = finalOutput
				.trimmingCharacters(in: .whitespacesAndNewlines)
				.isEmpty

			let finalStatus: DelegateEditTask.TaskStatus
			if outputIsEmpty || failedGroups >= totalGroups {
				// Nothing came back **or** every subgroup failed → complete failure
				finalStatus = .failed(reason: .streamError)
			} else if failedGroups > 0 {
				// Some, but not all, sub-groups failed
				finalStatus = .partialFailed(failedCount: failedGroups)
			} else {
				// All groups succeeded with non-empty output
				finalStatus = .completed
			}
			
			await MainActor.run {
				req.chatVM.finishDelegateEditTask(
					for               : req.currentQueryId,
					taskId            : taskId,
					finalOutput       : finalOutput,   // joined, validated diff hunks
					status            : finalStatus,
					promptTokens      : inTok,
					completionTokens  : outTok)
			}
			
		} catch {
			// Handle pre-LLM failures (file load, etc.)
			await MainActor.run {
				req.chatVM.finishDelegateEditTask(
					for          : req.currentQueryId,
					taskId       : taskId,
					finalOutput  : "",
					status       : .failed(reason: .streamError))
			}
		}
	}
	
	/// Launch one streaming call per group, parse each independently,
	/// and gather only the groups that produced valid diffs.
	func runGroups(
		_ groups: [[DelegateEditItem.Change]],
		matchedPath: String,
		fileText: String,
		systemPrompt: String,
		model: AIModel,
		taskId: UUID,
		currentQueryId: UUID,
		chatVM: ChatViewModel
	) async throws -> (String, Int, Int, Int) {
		
		// Running totals for the whole delegate-edit operation
		var promptTotal     = 0
		var completionTotal = 0
		var failureTotal    = 0
		
		// The task-group itself now returns the final tuple directly,
		// so we no longer need a second “join” afterwards.
		return try await withThrowingTaskGroup(of: (String, Int, Int, Bool).self) { tg in
			// ---------------------------------------------------------------
			// 1️⃣  Spawn one streaming task per change-group
			// ---------------------------------------------------------------
			for group in groups {
				let streamId = UUID()
				
				tg.addTask { [self] in
					// Buffer must live outside the `do` so we can still return it on error
					var buffer   = ""
					do {
						// ----- build sub-prompt ----------------------------------
						let subItem  = DelegateEditItem(filePath: matchedPath, changes: group)
						let userMsg  = await self.buildUserMessageOld(
							fileText: fileText,
							subItem  : subItem,
							path     : matchedPath
							//fixMinorFormattingIssues: groups.count == 1
						)
						let aiMsg    = await AIMessage(
							systemPrompt : systemPrompt,
							userMessage  : userMsg,
							temperature  : self.promptVM.setModelTemperature ? 0 : nil
						)
						
						// ----- stream --------------------------------------------
						// Delegate edits are cancelled via Task cancellation, not stream cancellation
						let (_, stream) = try await self.aiQueries.sendPrompt(aiMsg, model: model)
						var inTokAcc = 0
						var outTokAcc = 0
						var lastUpdate = Date(timeIntervalSince1970: 0)
						
						for try await chunk in stream {
							buffer      += chunk.text
							inTokAcc    = chunk.tokens.promptTokens     ?? 0
							outTokAcc   = chunk.tokens.completionTokens ?? 0
							
							// UI refresh throttled to `uiUpdateInterval`
							if Date().timeIntervalSince(lastUpdate) >= uiUpdateInterval {
								let finalBuffer = buffer
								let estimate = Int(Double(finalBuffer.count) / 4.0)
								await MainActor.run {
									chatVM.updateDelegateEditTask(
										for: currentQueryId,
										taskId: taskId,
										output: finalBuffer,
										tokenEstimate: estimate,
										streamId: streamId
									)
								}
								lastUpdate = Date()
							}
						}
						
						// ----- final flush after stream completion ---------------
						let estimate = Int(Double(buffer.count) / 4.0)
						let finalBuffer = buffer            // immutable for clarity
						await MainActor.run {
							chatVM.updateDelegateEditTask(
								for: currentQueryId,
								taskId: taskId,
								output: finalBuffer,
								tokenEstimate: estimate,
								streamId: streamId
							)
						}
						
						// ----- subgroup self-validation --------------------------
						// ---- inside runGroups(_: ) -----------------------------------------------
						let parsedFiles: [ParsedFile]
						do {
							parsedFiles = try await diffParser.parse(finalBuffer)
						} catch {
							return (finalBuffer, inTokAcc, outTokAcc, /*failed:*/ true)
						}
						
						// Treat "nothing parsed" as a failure as well
						let subgroupFailed = parsedFiles.isEmpty
						return (finalBuffer, inTokAcc, outTokAcc, subgroupFailed)
						
						
					} catch {
						// Even on failure, return whatever we captured so far for debugging
						// Even on failure, return whatever we captured so far for debugging
						print("Delegate-edit subgroup failed: \(error)")
						return (buffer, 0, 0, /*failed:*/ true)
					}
				}
			}
			
			// ---------------------------------------------------------------
			// 2️⃣  Gather results as tasks finish
			// ---------------------------------------------------------------
			var combinedOutputs: [String] = []
			
			var outputCount = 0
			
			for try await (text, p, c, failed) in tg {
				promptTotal     += p
				completionTotal += c
				// Accumulate token counts and failures independently
				if failed { failureTotal += 1 }

				// Always keep the raw text so the UI can display what was returned,
				// even if it couldn’t be parsed into valid diffs.
				if !text.isEmpty {
					combinedOutputs.append(text)
					outputCount += 1
				}
			}
			
			// Return one tuple – no “second join” needed.
			return (
				combinedOutputs.joined(separator: "\n\n"),   // aggregated, de-duplicated diff hunks
				promptTotal,
				completionTotal,
				failureTotal
			)
		}
	}
	
	
	// MARK: – Sequential runner
	func runGroupsSequential(
		_ groups: [[DelegateEditItem.Change]],
		matchedPath: String,
		fileText originalText: String,
		systemPrompt: String,
		model: AIModel,
		taskId: UUID,
		currentQueryId: UUID,
		chatVM: ChatViewModel
	) async throws -> (String, Int, Int, Int) {
		
		var currentText     = originalText           // rolling working copy
		var promptTotal     = 0
		var completionTotal = 0
		var estTokenTotal   = 0                       // cumulative estimate
		var failureTotal    = 0
		var description = ""
		
		// Grab the file-manager once (MainActor-isolated)
		let fileManager = await MainActor.run { promptVM.fileManager }
		
		// 🔑 New: allocate a stream-specific ID so the VM can merge estimates
		let streamId = UUID()
		
		for group in groups {
			
			// 1️⃣ Build the sub-prompt for this change group
			let subItem = DelegateEditItem(filePath: matchedPath, changes: group)
			let userMsg = await buildUserMessageOld(
				fileText: currentText,
				subItem : subItem,
				path    : matchedPath
			)
			
			let aiMsg = await AIMessage(
				systemPrompt : systemPrompt,
				userMessage  : userMsg,
				temperature  : promptVM.setModelTemperature ? 0 : nil
			)
			
			// 2️⃣ Stream the model response
			// Delegate edits are cancelled via Task cancellation, not stream cancellation
			let (_, stream) = try await aiQueries.sendPrompt(aiMsg, model: model)
			var buffer      = ""
			var inTok       = 0
			var outTok      = 0
			var lastUpdate  = Date(timeIntervalSince1970: 0)
			
			for try await chunk in stream {
				buffer += chunk.text
				inTok  = chunk.tokens.promptTokens     ?? inTok    // keep latest
				outTok = chunk.tokens.completionTokens ?? outTok
				
				// ⏱ Throttle UI updates to once every `uiUpdateInterval`
				if Date().timeIntervalSince(lastUpdate) >= uiUpdateInterval {
					let liveEstimate = estTokenTotal + Int(Double(buffer.count) / 4.0)
					await MainActor.run {
						chatVM.updateDelegateEditTask(
							for: currentQueryId,
							taskId: taskId,
							output: "",              // sequential mode → no partial XML
							tokenEstimate: liveEstimate,
							streamId: streamId       // 🆕 critical for per-stream tracking
						)
					}
					lastUpdate = Date()
				}
			}
			
			let chatName = ChatContentParser.parseAndRemoveChatName(from: &buffer)
			if let chatName, !chatName.isEmpty {
				description = chatName
			}
			
			// ✅ Final flush for this subgroup
			let groupEstimate  = Int(Double(buffer.count) / 4.0)
			estTokenTotal     += groupEstimate
			let capturedEstimate = estTokenTotal
			
			await MainActor.run {
				chatVM.updateDelegateEditTask(
					for: currentQueryId,
					taskId: taskId,
					output: "",                  // sequential mode → no partial XML
					tokenEstimate: capturedEstimate,
					streamId: streamId
				)
			}
			
			promptTotal     += inTok
			completionTotal += outTok
			
			// 3️⃣ Parse and (re)-diff using shared infrastructure
			do {
				let parsedFiles = try await diffParser.parse(buffer)
				guard !parsedFiles.isEmpty else {
					failureTotal += 1
					continue
				}
				
				let generated = await DiffProcessingHelper.createFileChanges(
					from: parsedFiles,
					fileManager: fileManager,
					diffPrecision: .normal,
					overrideContent: currentText
				)
				
				guard let fileChanges = generated.first, !fileChanges.changes.isEmpty else {
					failureTotal += 1
					continue
				}
				
				// Apply those chunks to our rolling working copy
				let tmp = ChangedFile(
					relativePath: matchedPath,
					fileContent : currentText,
					changes     : fileChanges.changes,
					fileAction  : .modify
				)
				
				await tmp.applyAllPendingChanges()
				currentText = tmp.fullContent
				
			} catch {
				// Any parsing or diff exception counts as a failure
				failureTotal += 1
				continue
			}
		}
		
		// 4️⃣ Produce a single packed rewrite diff reflecting all successful edits
		let finalRewrite = DiffParserUtils.packAsXML(
			path       : matchedPath,
			description: "\(description)",
			content    : currentText
		)
		
		return (finalRewrite, promptTotal, completionTotal, failureTotal)
	}
	
	func buildUserMessage(
		fileText: String,
		subItem: DelegateEditItem,
		path: String,
		fixMinorFormattingIssues: Bool = true
	) async -> String {
		let formattingLine = """
- Correct minor formatting issues proactively (e.g., inconsistent indentation, spacing irregularities, brace alignment, extra whitespace, and missing semicolons if applicable).
"""
		
		return """
<file_to_edit="\(path)">
```

(fileText)

```
</file_to_edit>

<instructions>
Edit the file specified above with the following changes, as specified.

Ensure the resulting file compiles without errors and integrates seamlessly with the existing codebase.

While applying each change:
\(fixMinorFormattingIssues ? formattingLine : "")
- Ensure references remain accurate and resolve correctly after applying edits.
- Preserve existing coding conventions observed in the provided file.

You must strictly apply every specified change without omitting any requested modifications.

\(subItem.formattedString())
</instructions>
"""
	}
	
	func buildUserMessageOld(fileText: String,
						  subItem: DelegateEditItem,
						  path: String) async -> String {
"""
<file_contents>
File: \(path)
```
\(fileText)
```
</file_contents>

<instructions>
Edit the file specified in <file_contents> with the following changes.
Ensure that every single change specified in <changes_to_apply> is applied exactly as specified.
\(subItem.formattedString())
</instructions>
"""
	}
}

// MARK: – Private helpers (inside the actor) ---------------------------------

	private extension DelegateEditQueryHandler {
		
		// Data captured during the single MainActor "prep” hop
		struct PrepData {
			let taskId: UUID
			let matchedPath: String
			let parentMessage: AIChatMessage
			let initialTask: DelegateEditTask
		}
		
		private func loadFile(at relPath: String) async throws -> (String, Int) {
			guard let fileVM = await promptVM.fileManager.findFile(atPath: relPath),
				  let fileContent = await fileVM.latestContent else {
				throw FileSystemError.fileNotFound
			}
		
		let lineCnt = String.splitContentPreservingAllLineEndings(fileContent).count
		return (fileContent, lineCnt)
	}
	
	func maxComplexity(of changes: [DelegateEditItem.Change]) -> Int {
		changes.map(\.complexity).max() ?? 0
	}
	
	/// Decide how to break a large edit into balanced, contiguous groups.
	///
	/// * Splits only when:
	///   * `strategy` is `.parallelSplit` or `.sequential`;
	///   * the selected model is diff-capable;
	///   * `changes.count` exceeds `groupSize`, and `groupSize` > 0.
	/// * Keeps the original ordering completely (each group is a contiguous slice).
	/// * Group sizes differ by **at most 1** and never exceed `groupSize`.
	/// * Returns an empty array when `changes` is empty.
	private func makeChangeGroups(
		_ changes: [DelegateEditItem.Change],
		diffCapable: Bool,
		strategy: ComplexEditStrategy,
		groupSize: Int
	) -> [[DelegateEditItem.Change]] {
		
		// ── Fast-exit guards ────────────────────────────────────────────────────
		guard !changes.isEmpty else { return [] }
		guard strategy != .single else { return [changes] }
		guard diffCapable,
			  groupSize > 0,
			  changes.count > groupSize
		else { return [changes] }
		
		// ── Balanced contiguous split ───────────────────────────────────────────
		let total      = changes.count
		let numGroups  = Int(ceil(Double(total) / Double(groupSize)))  // ≤ total
		let baseSize   = total / numGroups     // minimum elements per group
		let remainder  = total % numGroups     // first `remainder` groups get +1
		
		var result: [[DelegateEditItem.Change]] = []
		result.reserveCapacity(numGroups)
		
		var cursor = 0
		for i in 0..<numGroups {
			let thisSize = baseSize + (i < remainder ? 1 : 0)
			let next     = cursor + thisSize
			result.append(Array(changes[cursor..<next]))
			cursor = next                                   // advance slice start
		}
		
		return result                                       // sizes differ ≤ 1
	}
	
	/// Determine edit difficulty.
	///
	/// Escalate to `.high` when either:
	/// • an individual change is very complex (`maxComplexity > 5`), **or**
	/// • the _smallest_ load-balanced group will still apply ≥ 7 edits —
	///   which implies **every** group in `makeChangeGroups` will do at least 7.
	///
	/// This mirrors `makeChangeGroups`:
	///   - `numGroups = ceil(total / groupSize)`
	///   - group sizes differ by at most 1
	///   - the lower bound on group size is `total / numGroups` (integer division)
	///
	/// All other situations default to `.medium`.
	func evaluateDifficulty(changeCount  : Int,
							maxComplexity: Int,
							groupSize    : Int) -> EditDifficulty
	{
		// 1️⃣ Bail out early for a single highly complex change.
		if maxComplexity > 5 { return .high }
		
		// 2️⃣ If grouping is disabled or unnecessary, treat whole set as one group.
		guard groupSize > 0, changeCount > groupSize else {
			return changeCount >= 7 ? .high : .medium
		}
		
		// 3️⃣ Predict the *minimum* edits any group will receive after balancing.
		let numGroups          = Int(ceil(Double(changeCount) / Double(groupSize)))
		let minEditsPerGroup   = changeCount / numGroups      // integer div ⇒ floor
		return minEditsPerGroup >= 7 ? .high : .medium
	}
	
	/// Decide which LLM & system-prompt to use.
	/// Parallel jobs remain **diff-only**.
	func chooseModel(changeCount  : Int,
					 lineCount    : Int,
					 maxComplexity: Int,
					 groupSize    : Int,
					 isParallel   : Bool) async
	-> (systemPrompt: String, model: AIModel)
	{
		let difficulty = evaluateDifficulty(changeCount  : changeCount,
											maxComplexity: maxComplexity,
											groupSize    : groupSize)
		
		print("Edit difficulty: \(difficulty)")
		
		let (model, systemPrompt) = await MainActor.run {
			promptVM.getAppropriateEditSettings(
				fileSize      : lineCount,
				difficulty    : difficulty,
				forceDiffOnly : true,
				isParallel    : isParallel)
		}
		return (systemPrompt, model)
	}
}
