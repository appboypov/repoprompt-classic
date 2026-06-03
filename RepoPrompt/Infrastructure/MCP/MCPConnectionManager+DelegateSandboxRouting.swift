import Foundation
import MCP

extension ServerNetworkManager {
	func resolveDelegateSandboxRunID(connectionID: UUID) async -> UUID? {
		guard let routedRunID = await runIDForConnection(connectionID),
			delegateSandbox(for: routedRunID) != nil else {
			return nil
		}
		return routedRunID
	}

	func isDelegateEditContext(connectionID: UUID) async -> Bool {
		if runPurpose(for: connectionID) == .delegateEditRun {
			return true
		}
		if let routedRunID = await runIDForConnection(connectionID),
			runPolicyPurpose(for: routedRunID) == .delegateEditRun {
			return true
		}
		return false
	}

	func handleDelegateSandboxToolCallIfNeeded(
		connectionID: UUID,
		toolName: String,
		args: [String: Value],
		rawJSON: Bool
	) async -> CallTool.Result? {
		guard DelegateEditToolNames.sandboxToolNames.contains(toolName) else {
			return nil
		}

		let isEditFile = toolName == DelegateEditToolNames.editFile
		let isDelegateContext = await isDelegateEditContext(connectionID: connectionID)
		guard isEditFile || isDelegateContext else {
			return nil
		}

		if let runID = await resolveDelegateSandboxRunID(connectionID: connectionID),
			let sandbox = delegateSandbox(for: runID) {
			let invocationID = UUID()
			let observerStartState = EditFlowPerf.begin(
				EditFlowPerf.Stage.MCPToolCall.observerCallbacks,
				EditFlowPerf.Dimensions(toolName: toolName)
			)
			_ = await fireToolCallObservers(runID: runID, toolName: toolName)
			_ = await fireToolCalledObservers(
				runID: runID,
				invocationID: invocationID,
				toolName: toolName,
				args: args
			)
			EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.observerCallbacks, observerStartState)

			let result: CallTool.Result
			let dispatchState = EditFlowPerf.begin(
				EditFlowPerf.Stage.MCPToolCall.dispatch,
				EditFlowPerf.Dimensions(toolName: toolName)
			)
			switch toolName {
			case DelegateEditToolNames.fileSearch:
				result = await sandbox.callFileSearch(args: args)
			case DelegateEditToolNames.readFile:
				result = await sandbox.callReadFile(args: args)
			case DelegateEditToolNames.editFile:
				result = await sandbox.callApplyEdits(args: args, surfaceToolName: toolName, argsAreNormalized: true)
			default:
				EditFlowPerf.end(
					EditFlowPerf.Stage.MCPToolCall.dispatch,
					dispatchState,
					EditFlowPerf.Dimensions(toolName: toolName, status: "unsupported")
				)
				return nil
			}
			EditFlowPerf.end(
				EditFlowPerf.Stage.MCPToolCall.dispatch,
				dispatchState,
				EditFlowPerf.Dimensions(toolName: toolName, isError: result.isError ?? false)
			)

			let resultJSON = Self.extractTextFromContentBlocks(result.content)
			let observerCompleteState = EditFlowPerf.begin(
				EditFlowPerf.Stage.MCPToolCall.observerCallbacks,
				EditFlowPerf.Dimensions(toolName: toolName, isError: result.isError ?? false)
			)
			_ = await fireToolCompletedObservers(
				runID: runID,
				invocationID: invocationID,
				toolName: toolName,
				args: args,
				resultJSON: resultJSON,
				isError: result.isError ?? false
			)
			EditFlowPerf.end(EditFlowPerf.Stage.MCPToolCall.observerCallbacks, observerCompleteState)
			return result
		}

		let shouldReturnSandboxRoutingError: Bool
		if isEditFile {
			shouldReturnSandboxRoutingError = true
		} else {
			shouldReturnSandboxRoutingError = isDelegateContext
		}
		guard shouldReturnSandboxRoutingError else {
			return nil
		}

		return Self.toolErrorResult(
			rawJSON: rawJSON,
			message: "Delegate edit tool '\(toolName)' could not resolve sandbox routing for this connection."
		)
	}
}
