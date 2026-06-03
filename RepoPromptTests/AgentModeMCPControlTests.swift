import Foundation
import XCTest
import MCP
@testable import RepoPrompt

@MainActor
final class AgentModeMCPControlTests: XCTestCase {
	private enum PreservedSecurePayload {
		case absent
		case value(String)
		case unavailable
	}

	func testAskUserQuestionCardActivityExtendsTimeout() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.ensureSession(for: tabID)

		let responseTask = Task { @MainActor in
			try await vm.askUserQuestion(
				tabID: tabID,
				question: "Need input",
				timeoutSeconds: 0.3
			)
		}
		let pendingAskUser = try await waitForPendingAskUser(in: vm, tabID: tabID)

		try await Task.sleep(nanoseconds: 180_000_000)
		vm.noteAskUserCardActivity(tabID: tabID, interactionID: pendingAskUser.id)
		try await Task.sleep(nanoseconds: 180_000_000)

		XCTAssertNotNil(vm.sessions[tabID]?.pendingAskUser, "Activity should keep the question pending past the original deadline")
		let response = try await responseTask.value
		XCTAssertTrue(response.timedOut)
		XCTAssertNil(vm.sessions[tabID]?.pendingAskUser)
	}

	func testAskUserQuestionCardActivityWithStaleIDDoesNotExtendTimeout() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)

		let responseTask = Task { @MainActor in
			try await vm.askUserQuestion(
				tabID: tabID,
				question: "Need input",
				timeoutSeconds: 0.25
			)
		}
		_ = try await waitForPendingAskUser(in: vm, tabID: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let timeoutStartedAtBefore = session.pendingAskUser?.timeoutStartedAt
		let generationBefore = session.pendingAskUserTimeoutGeneration

		try await Task.sleep(nanoseconds: 100_000_000)
		vm.noteAskUserCardActivity(tabID: tabID, interactionID: UUID())

		XCTAssertEqual(session.pendingAskUser?.timeoutStartedAt, timeoutStartedAtBefore)
		XCTAssertEqual(session.pendingAskUserTimeoutGeneration, generationBefore)
		let response = try await responseTask.value
		XCTAssertTrue(response.timedOut)
		XCTAssertNil(vm.sessions[tabID]?.pendingAskUser)
	}

	func testSubmittingAfterQuestionCardActivityCancelsResetTimeout() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)

		let responseTask = Task { @MainActor in
			try await vm.askUserQuestion(
				tabID: tabID,
				question: "Need input",
				timeoutSeconds: 0.25
			)
		}
		let pendingAskUser = try await waitForPendingAskUser(in: vm, tabID: tabID)

		vm.noteAskUserCardActivity(tabID: tabID, interactionID: pendingAskUser.id)
		vm.submitQuestionResponse(tabID: tabID, response: "answer")

		let response = try await responseTask.value
		XCTAssertEqual(response.text, "answer")
		XCTAssertFalse(response.timedOut)
		XCTAssertFalse(response.skipped)

		try await Task.sleep(nanoseconds: 300_000_000)
		XCTAssertNil(vm.sessions[tabID]?.pendingAskUser)
		XCTAssertNil(vm.sessions[tabID]?.askUserTimeoutTask)
	}

	func testStartPendingSnapshotStaysRunningForSessionWithExistingHistory() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let seedSession = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(seedSession.activeAgentSessionID)
		let session = await vm.ensureSessionReady(tabID: tabID)
		session.appendItem(AgentChatItem.user("Previous turn", sequenceIndex: session.nextSequenceIndex))

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			startPending: true
		)
		await Task.yield()

		let storedStatus = await waitForSnapshotStatus(sessionID: sessionID)
		XCTAssertEqual(vm.mcpSnapshot(sessionID: sessionID)?.status, AgentRunMCPSnapshot.Status.running)
		XCTAssertEqual(storedStatus, AgentRunMCPSnapshot.Status.running)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testActivatingSameMCPControlSessionClearsPriorTabMapping() async throws {
		let vm = makeViewModel()
		let firstTabID = UUID()
		let secondTabID = UUID()
		vm.ensureSession(for: firstTabID)
		vm.ensureSession(for: secondTabID)
		let sessionID = try XCTUnwrap(vm.sessions[firstTabID]?.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: firstTabID)
		_ = await vm.ensureSessionReady(tabID: secondTabID)

		await vm.mcpActivateControlContext(
			forTabID: firstTabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)
		XCTAssertEqual(vm.mcpControlledSession(sessionID: sessionID)?.tabID, firstTabID)
		XCTAssertTrue(vm.isMCPControlled(tabID: firstTabID))

		await vm.mcpActivateControlContext(
			forTabID: secondTabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		XCTAssertNil(vm.sessions[firstTabID]?.mcpControlContext)
		XCTAssertFalse(vm.isMCPControlled(tabID: firstTabID))
		XCTAssertEqual(vm.sessions[secondTabID]?.mcpControlContext?.sessionID, sessionID)
		XCTAssertEqual(vm.mcpControlledSession(sessionID: sessionID)?.tabID, secondTabID)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testClosingTabCleansUpExternalControlWaiters() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			startPending: true
		)

		let waiter = Task {
			await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID)
		}
		await vm.test_handleComposeTabsWillClose(Set([tabID]))

		let disposition = await waiter.value
		let storedSnapshot = await AgentRunSessionStore.snapshot(for: sessionID)
		XCTAssertEqual(disposition, .expired)
		XCTAssertNil(storedSnapshot)
	}

	func testMCPControlledSessionCannotSpawnNestedAgentRuns() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)
		vm.test_applySpawnParentSessionID(UUID(), tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		do {
			try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: tabID)
			XCTFail("Expected MCP-controlled session spawn guard to reject nested agent runs")
		} catch let error as MCPError {
			guard case .invalidParams(let message) = error else {
				return XCTFail("Unexpected MCPError: \(error)")
			}
			XCTAssertTrue((message ?? "").contains("Sub-agents cannot start additional agent runs"))
		} catch {
			XCTFail("Unexpected error: \(error)")
		}
	}

	func testNonExploreSubagentCanSpawnExploreOnlyChild() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)
		vm.test_applySpawnParentSessionID(UUID(), tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			taskLabelKind: .engineer
		)

		XCTAssertNoThrow(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: tabID, isExploreOnly: true))
		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testExploreSubagentCannotSpawnExploreOnlyChild() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)
		vm.test_applySpawnParentSessionID(UUID(), tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			taskLabelKind: .explore
		)

		await XCTAssertThrowsErrorAsync(try await MainActor.run {
			try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: tabID, isExploreOnly: true)
		}) { error in
			guard case MCPError.invalidParams(let message) = error else {
				return XCTFail("Expected invalidParams error, got \(error)")
			}
			XCTAssertEqual(message, "Explore agents cannot start additional explore agents.")
		}
		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testTopLevelSessionCanSpawnAgentRuns() async {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		_ = await vm.ensureSessionReady(tabID: tabID)

		XCTAssertNoThrow(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: tabID))
		XCTAssertNoThrow(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: nil))
	}

	func testTopLevelMCPControlledSessionCanSpawnSubAgents() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		XCTAssertNoThrow(try vm.mcpValidateAgentRunSpawnAllowed(sourceTabID: tabID))
	}

	func testComposerPropsRefreshWhenMCPControlledTabSetChanges() {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		vm.ensureSession(for: tabID)
		vm.syncComposerUIState()

		XCTAssertFalse(vm.ui.composer.props.isCurrentTabMCPControlled)
		XCTAssertFalse(vm.ui.composer.props.areModelControlsDisabled)
		let revisionBeforeMCPControl = vm.ui.composer.revision

		vm.test_setMCPControlledTabIDs([tabID])

		XCTAssertTrue(vm.ui.composer.props.isCurrentTabMCPControlled)
		XCTAssertTrue(vm.ui.composer.props.areModelControlsDisabled)
		XCTAssertGreaterThan(vm.ui.composer.revision, revisionBeforeMCPControl)
		let revisionBeforeMCPRelease = vm.ui.composer.revision

		vm.test_setMCPControlledTabIDs([])

		XCTAssertFalse(vm.ui.composer.props.isCurrentTabMCPControlled)
		XCTAssertFalse(vm.ui.composer.props.areModelControlsDisabled)
		XCTAssertGreaterThan(vm.ui.composer.revision, revisionBeforeMCPRelease)
	}

	func testApplyingSessionBindingsUsesTargetTabForComposerMCPFlagWhenCurrentTabLags() {
		let vm = makeViewModel()
		let mcpTabID = UUID()
		let nonMcpTabID = UUID()
		vm.test_setCurrentTabIDOverride(mcpTabID)
		defer { vm.test_setCurrentTabIDOverride(nil) }
		let mcpSession = vm.session(for: mcpTabID)
		mcpSession.hasSentFirstMessage = true
		let nonMcpSession = vm.session(for: nonMcpTabID)
		vm.test_setMCPControlledTabIDs([mcpSession.tabID])
		XCTAssertTrue(vm.ui.composer.props.isCurrentTabMCPControlled)
		XCTAssertTrue(vm.ui.composer.props.isProviderPickerLockedForCurrentTab)

		// Simulate the `@Published activeComposeTabID` willSet window: `onTabChanged`
		// is applying the destination session while `currentTabID` can still read the
		// old MCP-controlled tab.
		vm.applySessionToBindings(nonMcpSession)

		XCTAssertEqual(vm.ui.composer.props.currentTabID, nonMcpTabID)
		XCTAssertFalse(vm.ui.composer.props.isCurrentTabMCPControlled)
		XCTAssertFalse(vm.ui.composer.props.areModelControlsDisabled)
		XCTAssertFalse(vm.ui.composer.props.isProviderPickerLockedForCurrentTab)
		XCTAssertNil(vm.ui.composer.props.lockedAgentSelectionMessage)
	}

	func testSubagentMCPActivationUsesSafePermissionsByDefault() async throws {
		let restorePreference = preserveForceSafeSubagentPermissionsPreference()
		defer { restorePreference() }
		// Force the secure production path to the Safe Managed default; the legacy
		// UserDefaults mirrors are safe-shadowed and no longer source production reads.
		AgentModePermissionPreferences.setSubagentPermissionPolicy(.safeManaged)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)
		vm.test_applySpawnParentSessionID(UUID(), tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		XCTAssertEqual(session.permissionProfile, .mcpSafeDefaults)
		XCTAssertEqual(vm.activePermissionChromeState.permissionProfile, .mcpSafeDefaults)
		XCTAssertTrue(vm.activePermissionChromeState.isSubagent)
		XCTAssertNotNil(vm.activePermissionChromeState.externallyManagedReason)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testSubagentMCPActivationCanUseUserConfiguredPermissionsWhenOverrideDisabled() async throws {
		let restorePreference = preserveForceSafeSubagentPermissionsPreference()
		defer { restorePreference() }
		AgentModePermissionPreferences.setForceSafeSubagentPermissions(false)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)
		vm.test_applySpawnParentSessionID(UUID(), tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		XCTAssertEqual(session.permissionProfile, .userConfigured)
		XCTAssertEqual(vm.activePermissionChromeState.permissionProfile, .userConfigured)
		XCTAssertTrue(vm.activePermissionChromeState.isSubagent)
		XCTAssertNotNil(vm.activePermissionChromeState.externallyManagedReason)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testTopLevelMCPActivationForOpenCodeUsesSubagentSafeManagedDefault() async throws {
		let restoreForceSafePreference = preserveForceSafeSubagentPermissionsPreference()
		let restoreOpenCodePreference = preserveOpenCodePermissionPreference()
		defer {
			restoreForceSafePreference()
			restoreOpenCodePreference()
		}
		AgentModePermissionPreferences.setSubagentPermissionPolicy(.safeManaged)
		OpenCodeAgentToolPreferences.setPermissionLevel(.fullAccess)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.selectedAgent = .openCode
		_ = await vm.ensureSessionReady(tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		XCTAssertEqual(session.permissionProfile, .mcpSafeDefaults)
		XCTAssertEqual(session.permissionProfile.openCodePermissionLevel(userConfigured: .fullAccess), .managedDefault)
		XCTAssertEqual(session.permissionProfile.acpSessionModeID(for: .openCode), OpenCodeAgentConfig.managedSessionModeID)
		XCTAssertEqual(vm.activePermissionChromeState.permissionProfile, .mcpSafeDefaults)
		XCTAssertTrue(vm.activePermissionChromeState.isSubagent)
		XCTAssertNotNil(vm.activePermissionChromeState.externallyManagedReason)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testSubagentMCPActivationForOpenCodeCanInheritUserFullAccessWhenOverrideDisabled() async throws {
		let restoreForceSafePreference = preserveForceSafeSubagentPermissionsPreference()
		let restoreOpenCodePreference = preserveOpenCodePermissionPreference()
		defer {
			restoreForceSafePreference()
			restoreOpenCodePreference()
		}
		AgentModePermissionPreferences.setForceSafeSubagentPermissions(false)
		OpenCodeAgentToolPreferences.setPermissionLevel(.fullAccess)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.selectedAgent = .openCode
		_ = await vm.ensureSessionReady(tabID: tabID)
		vm.test_applySpawnParentSessionID(UUID(), tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		XCTAssertEqual(session.permissionProfile, .userConfigured)
		XCTAssertEqual(session.permissionProfile.openCodePermissionLevel(userConfigured: .fullAccess), .fullAccess)
		XCTAssertEqual(session.permissionProfile.acpSessionModeID(for: .openCode), OpenCodeAgentConfig.managedFullAccessSessionModeID)
		XCTAssertEqual(vm.activePermissionChromeState.permissionProfile, .userConfigured)
		XCTAssertTrue(vm.activePermissionChromeState.isSubagent)
		XCTAssertNotNil(vm.activePermissionChromeState.externallyManagedReason)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testSubagentMCPActivationUsesSecureCustomPerProviderOverride() async throws {
		let restorePreference = preserveForceSafeSubagentPermissionsPreference()
		defer { restorePreference() }
		AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom)
		AgentModePermissionPreferences.setProviderSubagentPermissionLevel(.claude(.autoApproveEdits), for: .claude)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.selectedAgent = .claudeCode
		_ = await vm.ensureSessionReady(tabID: tabID)
		vm.test_applySpawnParentSessionID(UUID(), tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		XCTAssertEqual(session.permissionProfile, .providerOverride(.claude(.autoApproveEdits)))
		XCTAssertEqual(vm.activePermissionChromeState.permissionProfile, .providerOverride(.claude(.autoApproveEdits)))
		XCTAssertTrue(vm.activePermissionChromeState.isSubagent)
		XCTAssertNotNil(vm.activePermissionChromeState.externallyManagedReason)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testTopLevelMCPActivationUsesSubagentInheritPolicyWhenOverrideDisabled() async throws {
		let restorePreference = preserveForceSafeSubagentPermissionsPreference()
		defer { restorePreference() }
		AgentModePermissionPreferences.setForceSafeSubagentPermissions(false)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		XCTAssertEqual(session.permissionProfile, .userConfigured)
		XCTAssertEqual(vm.activePermissionChromeState.permissionProfile, .userConfigured)
		XCTAssertTrue(vm.activePermissionChromeState.isSubagent)
		XCTAssertNotNil(vm.activePermissionChromeState.externallyManagedReason)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testTopLevelMCPActivationUsesSubagentCustomPerProviderOverride() async throws {
		let restorePreference = preserveForceSafeSubagentPermissionsPreference()
		let restoreOpenCodePreference = preserveOpenCodePermissionPreference()
		defer {
			restorePreference()
			restoreOpenCodePreference()
		}
		AgentModePermissionPreferences.setSubagentPermissionPolicy(.custom)
		AgentModePermissionPreferences.setProviderSubagentPermissionLevel(.openCode(.fullAccess), for: .openCode)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.selectedAgent = .openCode
		_ = await vm.ensureSessionReady(tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		XCTAssertEqual(session.permissionProfile, .providerOverride(.openCode(.fullAccess)))
		XCTAssertEqual(session.permissionProfile.openCodePermissionLevel(userConfigured: .managedDefault), .fullAccess)
		XCTAssertEqual(vm.activePermissionChromeState.permissionProfile, .providerOverride(.openCode(.fullAccess)))
		XCTAssertTrue(vm.activePermissionChromeState.isSubagent)
		XCTAssertNotNil(vm.activePermissionChromeState.externallyManagedReason)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testAssigningParentAfterMCPActivationKeepsSubagentPermissions() async throws {
		let restorePreference = preserveForceSafeSubagentPermissionsPreference()
		defer { restorePreference() }
		AgentModePermissionPreferences.setForceSafeSubagentPermissions(false)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)
		XCTAssertEqual(session.permissionProfile, .userConfigured)
		XCTAssertTrue(vm.activePermissionChromeState.isSubagent)

		vm.test_applySpawnParentSessionID(UUID(), tabID: tabID)

		XCTAssertEqual(session.permissionProfile, .userConfigured)
		XCTAssertEqual(vm.activePermissionChromeState.permissionProfile, .userConfigured)
		XCTAssertTrue(vm.activePermissionChromeState.isSubagent)
		XCTAssertNotNil(vm.activePermissionChromeState.externallyManagedReason)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testTerminalSnapshotWinsIfSessionImmediatelyTransitionsBackToIdle() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let seedSession = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(seedSession.activeAgentSessionID)
		let session = await vm.ensureSessionReady(tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		session.runState = .completed
		session.runState = .idle
		await Task.yield()
		try? await Task.sleep(nanoseconds: 20_000_000)

		let storedStatus = await waitForSnapshotStatus(sessionID: sessionID)
		XCTAssertEqual(storedStatus, AgentRunMCPSnapshot.Status.completed)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		let storedAfterDeactivation = await AgentRunSessionStore.snapshot(for: sessionID)?.status
		XCTAssertEqual(storedAfterDeactivation, AgentRunMCPSnapshot.Status.completed)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testTerminalSnapshotOverridesNewerNonTerminalSnapshotWhenDeliveredLate() async {
		let sessionID = UUID()
		let tabID = UUID()
		let laterRunning = AgentRunMCPSnapshot(
			sessionID: sessionID,
			tabID: tabID,
			sessionName: "Child",
			agentRaw: "codexExec",
			agentDisplayName: "Codex",
			modelRaw: "gpt-5.4",
			reasoningEffortRaw: nil,
			status: .running,
			statusText: "Running",
			latestAssistantPreview: nil,
			interaction: nil,
			transcriptItemCount: 3,
			updatedAt: Date(timeIntervalSince1970: 200),
			parentSessionID: nil,
			failureReason: nil
		)
		let earlierCompleted = AgentRunMCPSnapshot(
			sessionID: sessionID,
			tabID: tabID,
			sessionName: "Child",
			agentRaw: "codexExec",
			agentDisplayName: "Codex",
			modelRaw: "gpt-5.4",
			reasoningEffortRaw: nil,
			status: .completed,
			statusText: "Completed",
			latestAssistantPreview: nil,
			interaction: nil,
			transcriptItemCount: 4,
			updatedAt: Date(timeIntervalSince1970: 100),
			parentSessionID: nil,
			failureReason: nil
		)

		await AgentRunSessionStore.register(sessionID: sessionID)
		await AgentRunSessionStore.noteSnapshot(laterRunning)
		await AgentRunSessionStore.noteSnapshot(earlierCompleted)

		let stored = await AgentRunSessionStore.snapshot(for: sessionID)
		XCTAssertEqual(stored?.status, AgentRunMCPSnapshot.Status.completed)
		XCTAssertEqual(stored?.transcriptItemCount, 4)

		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testReactivatingSameSessionIgnoresStaleTerminalCleanupTask() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			startPending: true
		)
		session.runState = .completed

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			startPending: true
		)
		await Task.yield()
		try? await Task.sleep(nanoseconds: 20_000_000)

		XCTAssertEqual(vm.mcpSnapshot(sessionID: sessionID)?.status, AgentRunMCPSnapshot.Status.running)
		let storedStatus = await waitForSnapshotStatus(sessionID: sessionID)
		XCTAssertEqual(storedStatus, AgentRunMCPSnapshot.Status.running)

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testTerminalSnapshotKeepsMCPControlAliveForFollowUpSteering() async throws {
		let restorePreference = preserveForceSafeSubagentPermissionsPreference()
		defer { restorePreference() }
		AgentModePermissionPreferences.setSubagentPermissionPolicy(.safeManaged)

		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)

		// Activate MCP control without startPending — simulate state after
		// the run has already started (mcpFollowUpRunPending cleared by dispatch).
		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)
		XCTAssertEqual(session.permissionProfile, .mcpSafeDefaults)

		// Simulate run completing (terminal state).
		session.runState = .completed
		session.runState = .idle
		await Task.yield()
		try? await Task.sleep(nanoseconds: 20_000_000)

		// Terminal snapshot should be signaled to waiters.
		let storedStatus = await waitForSnapshotStatus(sessionID: sessionID)
		XCTAssertEqual(storedStatus, .completed)

		// MCP control must stay alive: permission profile stays .mcpSafeDefaults
		// and the session remains MCP-controlled so follow-up steering works
		// without triggering a Codex reconnect via permission-profile-change.
		XCTAssertEqual(session.permissionProfile, .mcpSafeDefaults)
		XCTAssertNotNil(session.mcpControlContext)
		XCTAssertTrue(vm.isMCPControlled(tabID: tabID))

		// Follow-up re-activation (as steer would do) should work cleanly.
		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			startPending: true
		)
		XCTAssertEqual(session.permissionProfile, .mcpSafeDefaults)
		XCTAssertTrue(vm.isMCPControlled(tabID: tabID))

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testReactivatingSameSessionPreservesAutoEditBaseline() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.autoEditEnabled = false
		_ = await vm.ensureSessionReady(tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			startPending: true
		)
		XCTAssertTrue(session.autoEditEnabled)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil,
			startPending: true
		)
		await vm.mcpDeactivateControlContext(sessionID: sessionID)

		XCTAssertFalse(session.autoEditEnabled)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPControlledInteractionsRemainVisibleInUI() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)
		session.pendingApproval = AgentApprovalRequest(
			requestID: .codex(.string("req-visible")),
			method: "item/commandExecution/requestApproval",
			kind: .commandExecution,
			threadID: "thread-1",
			turnID: "turn-1",
			itemID: "call-1",
			command: "pwd"
		)

		XCTAssertTrue(session.shouldSurfaceInteractionsInUI)
		XCTAssertEqual(session.uiPendingApproval?.requestID, .codex(.string("req-visible")))

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPDispatchInstructionWakesBlockedWaiterAfterQueuedFollowUp() async throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .gemini
		session.runState = .running

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		let waiter = Task {
			await AgentRunSessionStore.waitUntilInteresting(sessionID: sessionID, timeoutSeconds: 5)
		}
		try? await Task.sleep(nanoseconds: 50_000_000)

		let delivery = try await vm.mcpDispatchInstruction(
			sessionID: sessionID,
			text: "please steer the active run",
			allowStartingRun: true
		)

		let disposition = await waiter.value
		XCTAssertEqual(delivery, .queuedFollowUp)
		if case .noteworthySnapshot(let snap, let reason) = disposition {
			XCTAssertEqual(snap.status, .running)
			XCTAssertEqual(reason, .steeringRequested)
		} else {
			XCTFail("Expected steering-requested noteworthy snapshot, got \(disposition)")
		}
		XCTAssertEqual(session.pendingInstructions, ["please steer the active run"])

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testMCPActiveClaudeSteerReturnsQueuedDeliveryWithoutFalseQueueError() async throws {
		let controller = MCPControlTestClaudeController()
		let vm = makeViewModel(claudeController: controller)
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		_ = await vm.ensureSessionReady(tabID: tabID)
		session.selectedAgent = .claudeCode
		session.runState = .running
		session.runID = UUID()
		session.activeHeadlessRunAttemptID = UUID()
		let originalTurnID = UUID()
		session.claudeExpectedTurnIDs = [originalTurnID]
		session.claudeController = controller

		await vm.mcpActivateControlContext(
			forTabID: tabID,
			sessionID: sessionID,
			originatingConnectionID: nil
		)

		do {
			let delivery = try await vm.mcpDispatchInstruction(
				sessionID: sessionID,
				text: "steer active Claude",
				allowStartingRun: true
			)
			let snapshot = await waitForClaudeSend(controller, expectedCount: 1)

			XCTAssertEqual(delivery, .queuedClaudeInterrupt)
			XCTAssertEqual(snapshot.sendUserMessageCallCount, 1)
			XCTAssertEqual(snapshot.interruptTurnCallCount, 1)
			XCTAssertTrue(snapshot.sentMessages.last?.contains("steer active Claude") == true)
			XCTAssertTrue(session.pendingClaudeSteeringInstructions.isEmpty)
			XCTAssertTrue(session.claudeSupersedingProtectedTurnIDs.contains(originalTurnID))
			let storedSnapshot = await AgentRunSessionStore.snapshot(for: sessionID)
			XCTAssertNil(storedSnapshot?.failureReason)
		} catch {
			await vm.mcpDeactivateControlContext(sessionID: sessionID)
			await AgentRunSessionStore.cleanup(sessionID: sessionID)
			throw error
		}

		await vm.mcpDeactivateControlContext(sessionID: sessionID)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	func testCodexFastVariantSelectionStaysOrdinaryModelState() throws {
		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)

		vm.selectedAgent = .claudeCode
		vm.selectedAgent = .codexExec
		vm.selectModel(rawModel: "gpt-5.4-fast")

		XCTAssertEqual(vm.activeProviderControlsBinding?.providerID, .codex)
		XCTAssertEqual(vm.selectedModelRaw, "gpt-5.4-fast")
		XCTAssertEqual(vm.session(for: tabID).selectedModelRaw, "gpt-5.4-fast")
	}

	func testMCPConfigureSessionRecordsExplicitCodexReasoningEffortPerModel() async throws {
		let restoreDefaults = preserveUserDefaults(keys: [
			"agentMode.lastUsedAgent",
			"agentMode.lastUsedModelsByAgent",
			"codexAgent.reasoning.lastUsedEffort",
			"agentMode.codex.lastUsedReasoningEffort",
			"codexAgent.reasoning.lastUsedEffortByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: "agentMode.lastUsedAgent")
		defaults.removeObject(forKey: "agentMode.lastUsedModelsByAgent")
		defaults.removeObject(forKey: "codexAgent.reasoning.lastUsedEffort")
		defaults.removeObject(forKey: "agentMode.codex.lastUsedReasoningEffort")
		defaults.removeObject(forKey: "codexAgent.reasoning.lastUsedEffortByModelSlug")

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)

		try await vm.mcpConfigureSession(
			tabID: tabID,
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: "gpt-5.4",
			reasoningEffortRaw: CodexReasoningEffort.high.rawValue
		)

		let session = vm.session(for: tabID)
		XCTAssertEqual(session.selectedAgent, .codexExec)
		XCTAssertEqual(session.selectedModelRaw, "gpt-5.4")
		XCTAssertEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.high.rawValue)
		XCTAssertEqual(
			CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug(defaults: defaults)["gpt-5.4"],
			.high
		)
		XCTAssertEqual(CodexAgentToolPreferences.lastUsedReasoningEffort(defaults: defaults), .high)
		XCTAssertEqual(vm.test_codexCoordinator.lastUsedReasoningEffortByModelSlug["gpt-5.4"], .high)
	}

	func testMCPConfigureSessionDoesNotPersistUnsupportedExplicitCodexReasoningEffort() async throws {
		let restoreDefaults = preserveUserDefaults(keys: [
			"agentMode.lastUsedAgent",
			"agentMode.lastUsedModelsByAgent",
			"codexAgent.reasoning.lastUsedEffort",
			"agentMode.codex.lastUsedReasoningEffort",
			"codexAgent.reasoning.lastUsedEffortByModelSlug"
		])
		defer { restoreDefaults() }
		let defaults = UserDefaults.standard
		defaults.removeObject(forKey: "agentMode.lastUsedAgent")
		defaults.removeObject(forKey: "agentMode.lastUsedModelsByAgent")
		defaults.removeObject(forKey: "codexAgent.reasoning.lastUsedEffort")
		defaults.removeObject(forKey: "agentMode.codex.lastUsedReasoningEffort")
		defaults.removeObject(forKey: "codexAgent.reasoning.lastUsedEffortByModelSlug")

		let vm = makeViewModel()
		let tabID = UUID()
		vm.test_setCurrentTabIDOverride(tabID)
		vm.ensureSession(for: tabID)

		try await vm.mcpConfigureSession(
			tabID: tabID,
			agentRaw: DiscoverAgentKind.codexExec.rawValue,
			modelRaw: "gpt-5.4",
			reasoningEffortRaw: CodexReasoningEffort.minimal.rawValue
		)

		let session = vm.session(for: tabID)
		XCTAssertEqual(session.selectedAgent, .codexExec)
		XCTAssertEqual(session.selectedModelRaw, "gpt-5.4")
		XCTAssertNotEqual(session.selectedReasoningEffortRaw, CodexReasoningEffort.minimal.rawValue)
		XCTAssertNil(CodexAgentToolPreferences.lastUsedReasoningEffortsByModelSlug(defaults: defaults)["gpt-5.4"])
		XCTAssertNil(CodexAgentToolPreferences.lastUsedReasoningEffort(defaults: defaults))
		XCTAssertNil(vm.test_codexCoordinator.lastUsedReasoningEffortByModelSlug["gpt-5.4"])
	}

	func testExternalMCPStartActivatesBeforeConfigureHydratesActiveCodexSession() async throws {
		let restorePreference = preserveForceSafeSubagentPermissionsPreference()
		defer { restorePreference() }
		AgentModePermissionPreferences.setSubagentPermissionPolicy(.safeManaged)

		var capturedProfiles: [AgentModeViewModel.AgentPermissionProfile] = []
		let vm = AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, permissionProfile, _ in
			capturedProfiles.append(permissionProfile)
			return NoOpCodexController()
		}
		let tabID = UUID()
		vm.ensureSession(for: tabID)
		let session = try XCTUnwrap(vm.sessions[tabID])
		let sessionID = try XCTUnwrap(session.activeAgentSessionID)
		session.selectedAgent = .codexExec
		session.runState = .running
		let target = AgentModeViewModel.MCPSessionTarget(tabID: tabID, sessionID: sessionID, origin: .existingSession)
		let metadata = MCPServerViewModel.RequestMetadata(connectionID: UUID(), clientName: "test", windowID: 1)

		do {
			_ = try await AgentExternalMCPRunStarter.start(
				target: target,
				message: "",
				metadata: metadata,
				bindCurrentRequestToTab: { _, _ in },
				agentModeVM: vm,
				agentRaw: nil,
				modelRaw: nil,
				reasoningEffortRaw: nil
			)
			XCTFail("Expected empty MCP instruction to fail after session configuration")
		} catch {
			// Expected: the empty message forces the helper through configure, then into cleanup.
		}

		XCTAssertEqual(capturedProfiles.first, .mcpSafeDefaults)
		XCTAssertNil(session.mcpControlContext)
		XCTAssertEqual(session.permissionProfile, .userConfigured)
		await AgentRunSessionStore.cleanup(sessionID: sessionID)
	}

	private func preserveUserDefaults(keys: [String]) -> () -> Void {
		let defaults = UserDefaults.standard
		let previousValues = keys.reduce(into: [String: Any]()) { result, key in
			if let value = defaults.object(forKey: key) {
				result[key] = value
			}
		}
		return {
			for key in keys {
				if let previousValue = previousValues[key] {
					defaults.set(previousValue, forKey: key)
				} else {
					defaults.removeObject(forKey: key)
				}
			}
		}
	}

	private func preserveForceSafeSubagentPermissionsPreference() -> () -> Void {
		let defaults = UserDefaults.standard
		let legacyKey = AgentModePermissionPreferences.forceSafeSubagentPermissionsKey
		let policyKey = AgentModePermissionPreferences.subagentPermissionPolicyKey
		let hadLegacy = defaults.object(forKey: legacyKey) != nil
		let previousLegacy = defaults.bool(forKey: legacyKey)
		let previousPolicy = defaults.string(forKey: policyKey)
		let secureKeys = SecureKeysService()
		let secureKey = AgentPermissionSecureDomain.subagent.storageKey
		let previousSecurePayload: PreservedSecurePayload
		do {
			if let payload = try secureKeys.getIntegrityProtectedValue(for: secureKey) {
				previousSecurePayload = .value(payload)
			} else {
				previousSecurePayload = .absent
			}
		} catch {
			previousSecurePayload = .unavailable
		}
		let store = AgentPermissionSecureStore.shared
		store.clearCachedDocuments()
		return {
			switch previousSecurePayload {
			case .value(let payload):
				try? secureKeys.saveIntegrityProtectedValue(payload, for: secureKey)
			case .absent:
				try? secureKeys.deleteIntegrityProtectedValue(for: secureKey)
			case .unavailable:
				break
			}
			store.clearCachedDocuments()
			if hadLegacy {
				defaults.set(previousLegacy, forKey: legacyKey)
			} else {
				defaults.removeObject(forKey: legacyKey)
			}
			if let previousPolicy {
				defaults.set(previousPolicy, forKey: policyKey)
			} else {
				defaults.removeObject(forKey: policyKey)
			}
		}
	}

	private func preserveOpenCodePermissionPreference() -> () -> Void {
		let previousMode = OpenCodeAgentToolPreferences.sessionModeID()
		return {
			OpenCodeAgentToolPreferences.setSessionModeID(previousMode)
		}
	}

	private func waitForSnapshotStatus(sessionID: UUID) async -> AgentRunMCPSnapshot.Status? {
		for _ in 0..<20 {
			if let status = await AgentRunSessionStore.snapshot(for: sessionID)?.status {
				return status
			}
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		return await AgentRunSessionStore.snapshot(for: sessionID)?.status
	}

	private func waitForClaudeSend(
		_ controller: MCPControlTestClaudeController,
		expectedCount: Int
	) async -> MCPControlTestClaudeController.Snapshot {
		for _ in 0..<50 {
			let snapshot = await controller.snapshot()
			if snapshot.sendUserMessageCallCount == expectedCount {
				return snapshot
			}
			try? await Task.sleep(nanoseconds: 10_000_000)
		}
		return await controller.snapshot()
	}

	private func waitForPendingAskUser(
		in vm: AgentModeViewModel,
		tabID: UUID,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws -> AgentAskUserPendingState {
		for _ in 0..<100 {
			if let pendingAskUser = vm.sessions[tabID]?.pendingAskUser {
				return pendingAskUser
			}
			try await Task.sleep(nanoseconds: 5_000_000)
		}
		XCTFail("Timed out waiting for pending ask_user question", file: file, line: line)
		throw CancellationError()
	}

	private func makeViewModel() -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath
		) { _, _, _, _, _, _ in
			NoOpCodexController()
		}
	}

	private func makeViewModel(claudeController: any ClaudeSessionControlling) -> AgentModeViewModel {
		AgentModeViewModel(
			testWindowID: 1,
			testWorkspacePath: FileManager.default.currentDirectoryPath,
			codexControllerFactory: { _, _, _, _, _, _ in
				NoOpCodexController()
			},
			claudeControllerFactory: { _, _, _, _, _, _, _ in
				claudeController
			}
		)
	}
}

private actor MCPControlTestClaudeController: ClaudeSessionControlling {
	struct Snapshot {
		let sendUserMessageCallCount: Int
		let interruptTurnCallCount: Int
		let sentMessages: [String]
	}

	private let stream: AsyncStream<ClaudeNativeProcessSessionController.Event>
	private var continuation: AsyncStream<ClaudeNativeProcessSessionController.Event>.Continuation?
	private var activeSession = true
	private var turnInFlight = true
	private var currentSessionID: String? = "mcp-control-test-session"
	private var sendUserMessageCallCount = 0
	private var interruptTurnCallCount = 0
	private var sentMessages: [String] = []

	var hasActiveSession: Bool { activeSession }
	var hasTurnInFlight: Bool { turnInFlight }

	nonisolated var events: AsyncStream<ClaudeNativeProcessSessionController.Event> {
		stream
	}

	init() {
		var continuationRef: AsyncStream<ClaudeNativeProcessSessionController.Event>.Continuation?
		self.stream = AsyncStream { continuation in
			continuationRef = continuation
		}
		self.continuation = continuationRef
	}

	func ensureEventsStreamReady() {}
	func resetEventsStreamForNewRun() {}

	func startOrResume(
		existingSessionID: String?,
		model _: String?,
		effortLevel _: ClaudeCodeEffortLevel?,
		systemPromptOverride _: String?
	) async throws -> ClaudeNativeProcessSessionController.SessionRef {
		activeSession = true
		currentSessionID = existingSessionID ?? currentSessionID
		return ClaudeNativeProcessSessionController.SessionRef(sessionID: currentSessionID)
	}

	func currentSessionRef() async -> ClaudeNativeProcessSessionController.SessionRef {
		ClaudeNativeProcessSessionController.SessionRef(sessionID: currentSessionID)
	}

	func applyModelAndEffort(model _: String?, effortLevel _: ClaudeCodeEffortLevel?) async throws {}

	@discardableResult
	func sendUserMessage(_ text: String) async throws -> UUID {
		sendUserMessageCallCount += 1
		sentMessages.append(text)
		turnInFlight = true
		return UUID()
	}

	func interruptTurn(reason _: String) async -> ClaudeNativeProcessSessionController.InterruptOutcome {
		interruptTurnCallCount += 1
		guard turnInFlight else { return .noTurnInFlight }
		turnInFlight = false
		return .acknowledged
	}

	func shutdown() async {
		activeSession = false
		turnInFlight = false
	}

	func respondToPermissionRequest(id _: String, decision _: AgentApprovalDecision) async {}

	func snapshot() -> Snapshot {
		Snapshot(
			sendUserMessageCallCount: sendUserMessageCallCount,
			interruptTurnCallCount: interruptTurnCallCount,
			sentMessages: sentMessages
		)
	}
}

private final class NoOpCodexController: CodexSessionControlling {
	var hasActiveThread: Bool { false }
	var events: AsyncStream<CodexNativeSessionController.Event> {
		AsyncStream { continuation in
			continuation.finish()
		}
	}

	func ensureEventsStreamReady() {}

	func startOrResume(
		existing: CodexNativeSessionController.SessionRef?,
		baseInstructions: String
	) async throws -> CodexNativeSessionController.SessionRef {
		CodexNativeSessionController.SessionRef(
			conversationID: existing?.conversationID ?? "noop",
			rolloutPath: existing?.rolloutPath,
			model: existing?.model,
			reasoningEffort: existing?.reasoningEffort
		)
	}

	func sendUserMessage(_ text: String) async throws {}
	func sendUserTurn(text: String, images: [AgentImageAttachment]) async throws {}
	func cancelCurrentTurn() async {}
	func shutdown() async {}
	func respondToServerRequest(id: CodexAppServerRequestID, result: [String : Any]) async {}
}
