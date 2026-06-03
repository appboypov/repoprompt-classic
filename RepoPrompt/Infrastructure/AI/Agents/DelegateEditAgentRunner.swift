import Foundation
import OSLog

actor DelegateEditAgentRunner {
    private let log = Logger(subsystem: "com.repoprompt.agents", category: "DelegateEditAgentRunner")

    func runForFile(
        currentQueryId: UUID,
        taskId: UUID,
        filePath: String,
        changes: [DelegateEditItem.Change],
        promptVM: PromptViewModel,
        chatVM: ChatViewModel,
        retryStatus: DelegateEditTask.TaskStatus? = nil
    ) async {
        let runID = UUID()
        let perfState = EditFlowPerf.begin(
            EditFlowPerf.Stage.Delegate.runForFile,
            EditFlowPerf.Dimensions(
                status: retryStatus == .noChangesMade ? "retry_no_changes" : "run",
                editCount: changes.count,
                isAgentMode: true
            )
        )
        defer { EditFlowPerf.end(EditFlowPerf.Stage.Delegate.runForFile, perfState) }

        // Resolve static setup state on the main actor in one hop.
        let setup = await MainActor.run {
            let windowID = promptVM.windowID
            return (
                agentKind: promptVM.proEditAgentKind,
				agentModel: promptVM.proEditAgentModelRaw,
                windowID: windowID,
                owningWindow: WindowStatesManager.shared.allWindows.first(where: { $0.windowID == windowID })
            )
        }
        let agentKind = setup.agentKind
        let agentModel = setup.agentModel
        let windowID = setup.windowID

        // Mirror discover agent behavior: ensure the MCP server is started for this window
        if let owningWindow = setup.owningWindow {
            await owningWindow.mcpServer.startServer()
            let enabled = await MainActor.run { owningWindow.mcpServer.windowToolsEnabled }
            if !enabled {
#if DEBUG
				print("[DelegateEditAgentRunner] MCP server not enabled for window \(windowID)")
#endif
                await chatVM.finishDelegateEditTask(
                    for: currentQueryId,
                    taskId: taskId,
                    finalOutput: "Failed to start MCP server. Check Local Network permission in System Settings.",
                    status: .failed(reason: .streamError),
                    promptTokens: nil,
                    completionTokens: nil
                )
                return
            }
        } else {
#if DEBUG
			print("[DelegateEditAgentRunner] No window found for delegate edit run (windowID: \(windowID))")
#endif
            await chatVM.finishDelegateEditTask(
                for: currentQueryId,
                taskId: taskId,
                finalOutput: "No active window found for delegate edit run.",
                status: .failed(reason: .streamError),
                promptTokens: nil,
                completionTokens: nil
            )
            return
        }

		// Load the resolved file content; fail fast if it cannot be read
		guard let originalContent = await loadContent(for: filePath, promptVM: promptVM) else {
#if DEBUG
			print("[DelegateEditAgentRunner] Failed to load file content for \(filePath)")
#endif
			await chatVM.finishDelegateEditTask(
				for: currentQueryId,
				taskId: taskId,
				finalOutput: "",
				status: .failed(reason: .fileLoadError),
				promptTokens: nil,
				completionTokens: nil,
				displayOutput: "Could not load '\(filePath)'.",
				delegateResultOverride: nil
			)
			return
		}

        // Mark task as in-progress (UI)
        await chatVM.updateDelegateEditTaskStatus(
            messageId: currentQueryId,
            taskId: taskId,
            status: .inProgress
        )

        // Install sandbox for this run (single-file virtual FS)
		await ServerNetworkManager.shared.installDelegateEditSandbox(
			windowID: windowID,
			runID: runID,
			allowedPath: filePath,
			originalContent: originalContent
		)

        // Register tool call observer to track tool usage
        // MCPConnectionManager now supports multiple observers per runID (won't be overwritten by AgentToolTracker)
        let queryIdCopy = currentQueryId
        let taskIdCopy = taskId

        await ServerNetworkManager.shared.registerToolCallObserver(for: runID) { toolName in
            NotificationCenter.default.post(
                name: .delegateEditToolUsed,
                object: nil,
                userInfo: [
                    "queryId": queryIdCopy,
                    "taskId": taskIdCopy,
                    "toolName": toolName
                ]
            )
        }
		#if DEBUG || EDIT_FLOW_PERF
        let registeredObserverCount = await ServerNetworkManager.shared.toolCallObserverCount(for: runID)
        EditFlowPerf.event(
            EditFlowPerf.Stage.Delegate.observerRegister,
            EditFlowPerf.Dimensions(status: "registered", activeCount: registeredObserverCount)
        )
		#endif

        func unregisterDelegateObserver() async {
            await ServerNetworkManager.shared.unregisterToolCallObserver(for: runID)
			#if DEBUG || EDIT_FLOW_PERF
            let observerCount = await ServerNetworkManager.shared.toolCallObserverCount(for: runID)
            EditFlowPerf.event(
                EditFlowPerf.Stage.Delegate.observerUnregister,
                EditFlowPerf.Dimensions(status: "unregistered", activeCount: observerCount)
            )
			#endif
        }

        // Prepare connection policy with restricted tools (same pattern as discovery)
        let spec = AgentRunSpec(
            type: .delegateEdit,
            runID: runID,
            agentKind: agentKind,
            modelString: agentModel,
            windowID: windowID,
            restrictedTools: DelegateEditMCPToolPolicy.restrictedTools,
            connectionTTL: 30
        )

        do {
            let lease = try await AgentRunCoordinator.shared.prepareAndInstallPolicy(
                spec,
                additionalTools: nil,
                reason: "delegate-edit-run",
                gateID: runID
            )

			// Build minimal AIMessage – model must read file itself via read_file
			let systemPrompt = SystemPromptService.mcpDelegateEditPrompt(
				filePath: filePath,
				changes: changes,
				retryingAfterNoChanges: retryStatus == .noChangesMade,
				agentKind: agentKind
			)
			let userMessage = "Apply the requested changes to \(filePath)."
            let agentMessage = AgentMessage(
                systemPrompt: systemPrompt,
                userMessage: userMessage
            )

            // Create provider and stream results
			let delegateWorkspacePath = URL(fileURLWithPath: filePath).deletingLastPathComponent().path
			let provider = AgentRunCoordinator.shared.makeProvider(
				agentKind: agentKind,
				modelString: agentModel,
				runType: .delegateEdit,
				workspacePath: delegateWorkspacePath
			)
            var accumulated = ""
            var meaningfulAccumulated = ""
            var promptTokens = 0
            var completionTokens = 0

            // Ensure consolidated cleanup happens exactly once on all paths (success, early return, error, cancellation)
            await AsyncScope.withCleanup({}, cleanup: {
                // Coordinator owns both policy cleanup (client connection policy) and provider.dispose() for delegate‑edit runs.
                await AgentRunCoordinator.shared.cleanup(spec, provider: provider)
                await unregisterDelegateObserver()
                await ServerNetworkManager.shared.removeDelegateEditSandbox(runID: runID)
            }) {
                func finishStreamError(_ error: Error, releaseGate: Bool) async {
#if DEBUG
                    print("[DelegateEditAgentRunner] Stream error: \(error.localizedDescription)")
#endif
                    if releaseGate {
                        // Ensure the gate is released even if streaming fails to begin
                        await lease.failAndCleanup()
                    }

                    // Stream error – fail task; consolidated cleanup handles disposal and sandbox teardown
                    await chatVM.finishDelegateEditTask(
                        for: currentQueryId,
                        taskId: taskId,
                        finalOutput: "",
                        status: .failed(reason: .streamError),
                        promptTokens: nil,
                        completionTokens: nil
                    )
                }

                do {
                    let stream = try await AgentRunCoordinator.shared.runStream(provider: provider, message: agentMessage, runID: runID)

                    // Centralized "release on routing" – releases the gate once mapping is established or on timeout
                    _ = await lease.releaseWhenRouted(timeoutMs: 10_000)

                    func appendToLog(_ snippet: String, isMeaningful: Bool) async {
                        guard !snippet.isEmpty else { return }
                        if accumulated.isEmpty {
                            accumulated = snippet
                        } else {
                            accumulated += "\n" + snippet
                        }
                        if isMeaningful {
                            if meaningfulAccumulated.isEmpty {
                                meaningfulAccumulated = snippet
                            } else {
                                meaningfulAccumulated += "\n" + snippet
                            }
                        }
                        let estimate = Int(Double(accumulated.count) / 4.0)
                        let output = accumulated
                        let tokenEstimate = estimate
                        await MainActor.run {
                            chatVM.updateDelegateEditTask(
                                for: currentQueryId,
                                taskId: taskId,
                                output: output,
                                tokenEstimate: tokenEstimate
                            )
                        }
                    }

                    do {
                        for try await chunk in stream {
                            // Map and forward to UI
                            switch chunk.type {
                            case "content":
                                if let snippet = self.chunkDisplayText(chunk) {
                                    await appendToLog(snippet, isMeaningful: true)
                                }
                            case "event":
                                if let snippet = self.chunkDisplayText(chunk) {
                                    await appendToLog(snippet, isMeaningful: false)
                                }
                            case "error":
                                let base = self.chunkDisplayText(chunk) ?? ""
                                let snippet = base.isEmpty ? "Error" : "Error: \(base)"
                                await appendToLog(snippet, isMeaningful: true)
                            case "message_stop":
                                // Capture token usage (if provided)
                                promptTokens = chunk.promptTokens ?? promptTokens
                                completionTokens = chunk.completionTokens ?? completionTokens
                            default:
                                // system/other – append if helpful
                                if let snippet = self.chunkDisplayText(chunk) {
                                    await appendToLog(snippet, isMeaningful: true)
                                }
                            }
                        }

                        // After stream completes, fetch final content from sandbox
                        let finalContent = await ServerNetworkManager.shared.delegateEditFinalContent(for: runID) ?? originalContent
                        let trimmedAgentOutput = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedMeaningfulOutput = meaningfulAccumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                        if finalContent == originalContent {
                            let displayText = trimmedAgentOutput.isEmpty ? "No changes were made." : trimmedAgentOutput
#if DEBUG
                            print("[DelegateEditAgentRunner] No changes detected for \(filePath)")
#endif
                            await chatVM.finishDelegateEditTask(
                                for: currentQueryId,
                                taskId: taskId,
                                finalOutput: "",
                                status: .noChangesMade,
                                promptTokens: promptTokens,
                                completionTokens: completionTokens,
                                displayOutput: displayText,
                                delegateResultOverride: trimmedAgentOutput.isEmpty ? nil : trimmedAgentOutput
                            )
                            return
                        }

                        // Optionally extract <chatName="..."/> from assistant chatter for description
                        var descSource = accumulated
                        let extractedName = ChatContentParser.parseAndRemoveChatName(from: &descSource)
                        let description = (extractedName?.isEmpty == false) ? extractedName! : "Agent Edit"

                        let xml = DiffParserUtils.packAsXML(
                            path: filePath,
                            description: description,
                            content: finalContent
                        )

                        let shouldFallbackToXML = trimmedMeaningfulOutput.isEmpty
                        let displayText = shouldFallbackToXML ? xml : trimmedAgentOutput
                        let storedResult = xml
                        await chatVM.finishDelegateEditTask(
                            for: currentQueryId,
                            taskId: taskId,
                            finalOutput: xml,
                            status: .completed,
                            promptTokens: promptTokens,
                            completionTokens: completionTokens,
                            displayOutput: displayText,
                            delegateResultOverride: storedResult
                        )
                    } catch {
                        await finishStreamError(error, releaseGate: false)
                    }
                } catch {
                    await finishStreamError(error, releaseGate: true)
                }

            }
        } catch {
#if DEBUG
			print("[DelegateEditAgentRunner] Policy/provider setup failed: \(error.localizedDescription)")
#endif
            // Policy/provider setup error – fail task and cleanup sandbox/observers (no provider created yet)
            await chatVM.finishDelegateEditTask(
                for: currentQueryId,
                taskId: taskId,
                finalOutput: "",
                status: .failed(reason: .streamError),
                promptTokens: nil,
                completionTokens: nil
            )
            await unregisterDelegateObserver()
            await ServerNetworkManager.shared.removeDelegateEditSandbox(runID: runID)
        }
    }
}

private extension DelegateEditAgentRunner {
	func chunkDisplayText(_ chunk: AIStreamResult, fallback: String? = nil) -> String? {
		func trimmed(_ value: String?) -> String? {
			guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
				  !value.isEmpty else { return nil }
			return value
        }

        var components: [String] = []

        if let text = trimmed(chunk.text) {
            components.append(text)
        } else if let fallback = trimmed(fallback) {
            components.append(fallback)
        }

        if let reasoning = trimmed(chunk.reasoning) {
            if components.isEmpty {
                components.append(reasoning)
            } else {
                components.append("Reasoning:\n\(reasoning)")
            }
        }

		return components.isEmpty ? nil : components.joined(separator: "\n\n")
	}

	func loadContent(for path: String, promptVM: PromptViewModel) async -> String? {
		guard let fileVM = await promptVM.fileManager.findFile(atPath: path) else {
			return nil
		}
		return await fileVM.latestContent
	}
}
