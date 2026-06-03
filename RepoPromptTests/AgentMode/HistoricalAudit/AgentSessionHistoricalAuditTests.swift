import XCTest
@testable import RepoPrompt

final class AgentSessionHistoricalAuditTests: XCTestCase {
	func testAgentControlTerminalFallbackMarksMissingWaitInterrupted() throws {
		let invocationID = UUID()
		let childSessionID = UUID()
		var items: [AgentChatItem] = [
			.user("wait for child", sequenceIndex: 0),
			.toolCall(
				name: "mcp__RepoPrompt__agent_run",
				invocationID: invocationID,
				argsJSON: "{\"op\":\"wait\",\"session_id\":\"\(childSessionID.uuidString)\"}",
				sequenceIndex: 1
			)
		]

		let finalizedCount = AgentTranscriptIO.finalizePendingToolCalls(
			in: &items,
			terminalState: .completed,
			includeExplicitRepoPromptToolCalls: true,
			nonToolBoundary: 3
		)

		XCTAssertEqual(finalizedCount, 1)
		let result = try XCTUnwrap(items.last)
		XCTAssertEqual(result.kind, .toolResult)
		XCTAssertEqual(result.toolInvocationID, invocationID)
		XCTAssertEqual(result.toolIsError, false)
		let object = try XCTUnwrap(AgentTranscriptToolNormalizer.jsonObject(from: result.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "cancelled")
		XCTAssertEqual(object["reason"] as? String, "wait_interrupted")
		XCTAssertEqual(object["op"] as? String, "wait")
	}

	func testAgentControlTerminalFallbackMarksMissingSteerAccepted() throws {
		let invocationID = UUID()
		let childSessionID = UUID()
		var items: [AgentChatItem] = [
			.user("steer child", sequenceIndex: 0),
			.toolCall(
				name: "mcp__RepoPrompt__agent_run",
				invocationID: invocationID,
				argsJSON: "{\"op\":\"steer\",\"session_id\":\"\(childSessionID.uuidString)\",\"message\":\"ask for Toronto weather\"}",
				sequenceIndex: 1
			)
		]

		let finalizedCount = AgentTranscriptIO.finalizePendingToolCalls(
			in: &items,
			terminalState: .completed,
			includeExplicitRepoPromptToolCalls: true,
			nonToolBoundary: 3
		)

		XCTAssertEqual(finalizedCount, 1)
		let result = try XCTUnwrap(items.last)
		XCTAssertEqual(result.kind, .toolResult)
		XCTAssertEqual(result.toolInvocationID, invocationID)
		XCTAssertEqual(result.toolIsError, false)
		let object = try XCTUnwrap(AgentTranscriptToolNormalizer.jsonObject(from: result.toolResultJSON))
		XCTAssertEqual(object["status"] as? String, "completed")
		XCTAssertEqual(object["reason"] as? String, "result_missing_after_turn_completed")
		XCTAssertEqual(object["op"] as? String, "steer")
	}

	func testManifestLoadsFromSourceRelativeFixtureRoot() throws {
		let root = try HistoricalAuditFixtureLoader.fixtureRoot()
		let manifestURL = root.appendingPathComponent(HistoricalAuditFixtureLoader.manifestFileName)

		XCTAssertTrue(
			FileManager.default.fileExists(atPath: manifestURL.path),
			"HistoricalAudit manifest should be discoverable from #filePath/source-relative lookup"
		)
		XCTAssertTrue(
			root.path.hasSuffix(HistoricalAuditFixtureLoader.relativeFixtureRoot),
			"Fixture root should resolve to the checked-in HistoricalAudit v1 corpus"
		)

		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		XCTAssertEqual(manifest.version, 1)
		XCTAssertEqual(manifest.cases.count, 11)
		XCTAssertEqual(manifest.globalPolicies.maxPersistedToolSummaryBytes, AgentToolResultPersistencePolicy.maxPersistedToolSummaryBytes)
		XCTAssertFalse(manifest.globalPolicies.rawToolPayloadsCommitted)
	}

	func testManifestFixturesDecode() throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		XCTAssertEqual(manifest.cases.count, 11)

		for auditCase in manifest.cases {
			try XCTContext.runActivity(named: auditCase.caseID) { _ in
				let url = try HistoricalAuditFixtureLoader.fixtureURL(for: auditCase)
				XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

				let session = try HistoricalAuditFixtureLoader.loadSession(for: auditCase)
				XCTAssertEqual(session.name, auditCase.caseID)
				XCTAssertEqual(session.agentKind, auditCase.agentKind)
				XCTAssertNotNil(session.transcript ?? (session.items.isEmpty ? nil : AgentTranscript.empty))
			}
		}
	}

	func testMetricEvaluatorReportsEveryExpectedAfterFixMetric() throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let expectedMetricNames = HistoricalAuditMetricEvaluator.expectedMetricNames(in: manifest)
		let unsupportedExpectedMetrics = expectedMetricNames.subtracting(HistoricalAuditMetricEvaluator.supportedMetricNames)
		XCTAssertTrue(
			unsupportedExpectedMetrics.isEmpty,
			"Unsupported HistoricalAudit expected-after-fix metrics: \(unsupportedExpectedMetrics.sorted())"
		)

		for auditCase in manifest.cases {
			try XCTContext.runActivity(named: auditCase.caseID) { _ in
				let data = try HistoricalAuditFixtureLoader.fixtureData(for: auditCase)
				let session = try HistoricalAuditFixtureLoader.loadSession(for: auditCase)
				let report = HistoricalAuditMetricEvaluator.report(
					caseID: auditCase.caseID,
					rawSession: session,
					persistedData: data
				)

				for metricName in (auditCase.expectedMetricsAfterFix ?? [:]).keys {
					XCTAssertTrue(
						report.reports(metricName),
						"Metric evaluator must report \(metricName) for \(auditCase.caseID) at every Batch 0 boundary"
					)
				}
			}
		}
	}

	func testMetricEvaluatorKnowsAllManifestMetricNames() throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let manifestMetricNames = HistoricalAuditMetricEvaluator.allManifestMetricNames(in: manifest)
		let unsupportedMetrics = manifestMetricNames.subtracting(HistoricalAuditMetricEvaluator.supportedMetricNames)

		XCTAssertTrue(
			unsupportedMetrics.isEmpty,
			"Add evaluator support for new HistoricalAudit manifest metrics: \(unsupportedMetrics.sorted())"
		)
	}

	func testDuplicateInvocationFixtureReportsDuplicateInvocationMetric() throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let auditCase = try XCTUnwrap(
			manifest.cases.first { $0.caseID == "gemini-duplicate-invocation-readme-25e5e3f5" }
		)
		let session = try HistoricalAuditFixtureLoader.loadSession(for: auditCase)
		let report = HistoricalAuditMetricEvaluator.report(caseID: auditCase.caseID, rawSession: session)

		XCTAssertEqual(report.rawFixture["duplicateInvocationIDGroupCount"], 1)
	}

	func testBatch1DisplaylessAssistantFixturesHaveCleanProjectionAndExportAfterNormalization() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let fixtureIDs = [
			"cursor-acp-ghost-newlines-7cf4991f",
			"codex-empty-assistant-1a5fa4e5"
		]

		for caseID in fixtureIDs {
			let report = try await normalizedReport(for: caseID, in: manifest)
			XCTAssertGreaterThan(
				report.rawFixture["sourceGhostAssistantCount"],
				0,
				"Fixture should preserve historical displayless source assistant rows for \(caseID)"
			)
			XCTAssertEqual(report.projection["projectedGhostAssistantCount"], 0, caseID)
			XCTAssertEqual(report.export["exportGhostAssistantCount"], 0, caseID)
		}
	}

	func testBatch1MicroNoiseAndConciseFixtureAnswersRemainDisplayable() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()

		let dotSession = try await normalizedSession(for: "codex-dot-assistant-dcc3d87f", in: manifest)
		let dotTranscript = try XCTUnwrap(dotSession.transcript)
		let dotProjection = AgentTranscriptProjectionBuilder.build(from: dotTranscript)
		let dotProjectionRows = dotProjection.workingRows + dotProjection.archivedRows
		XCTAssertTrue(dotProjectionRows.contains { ($0.kind == .assistant || $0.kind == .assistantInline) && $0.text == "." })
		XCTAssertFalse(dotProjectionRows.contains { ($0.kind == .assistant || $0.kind == .assistantInline) && !AgentDisplayableText.hasDisplayableBody($0.text) })

		let conciseSession = try await normalizedSession(for: "opencode-concise-final-e181fce3", in: manifest)
		let conciseTranscript = try XCTUnwrap(conciseSession.transcript)
		let conciseHistory = AgentTranscriptIO.buildConversationHistory(from: conciseTranscript)
		let conciseForkXML = AgentTranscriptIO.buildForkTranscriptXML(from: conciseTranscript)
		XCTAssertTrue(conciseHistory.contains("<assistant>resumed after stop</assistant>"))
		XCTAssertTrue(conciseForkXML.contains("<assistant>resumed after stop</assistant>"))
	}

	func testBatch2TerminalRepairPolicyIncludesClaudeNativeAndACPExplicitTools() throws {
		XCTAssertTrue(AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(context: .coldRestore(agentKindRaw: nil)))
		XCTAssertTrue(AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(context: .liveTerminal(agentKind: .claudeCode)))
		XCTAssertTrue(AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(context: .liveTerminal(agentKind: .claudeCodeGLM)))
		XCTAssertTrue(AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(context: .liveTerminal(agentKind: .gemini)))
		XCTAssertTrue(AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(context: .liveTerminal(agentKind: .openCode)))
		XCTAssertTrue(AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(context: .liveTerminal(agentKind: .cursor)))
		XCTAssertFalse(AgentTranscriptQualityRepair.shouldFinalizeExplicitRepoPromptTools(context: .liveTerminal(agentKind: .codexExec)))
	}

	func testBatch2TerminalStaleToolFixturesRepairAfterNormalization() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let fixtureIDs = [
			"claude-stale-running-conclusion-ec15d540",
			"gemini-stale-running-tool-52687d25"
		]
		let terminalToolMetrics = [
			"pendingToolAfterTerminalCount",
			"unresolvedToolCallCount",
			"staleToolCallWithoutResultCount"
		]

		for caseID in fixtureIDs {
			let report = try await normalizedReport(for: caseID, in: manifest)
			XCTAssertGreaterThan(
				report.rawFixture["pendingToolAfterTerminalCount"],
				0,
				"Fixture should preserve historical terminal stale-tool state for \(caseID)"
			)
			for metric in terminalToolMetrics {
				XCTAssertEqual(report.normalizedModel[metric], 0, "\(caseID) normalized \(metric)")
				XCTAssertEqual(report.projection[metric], 0, "\(caseID) projection \(metric)")
				XCTAssertEqual(report.export[metric], 0, "\(caseID) export \(metric)")
			}
		}
	}

	func testBatch2ClaudeStaleConclusionRepairsAfterNormalization() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let caseID = "claude-stale-running-conclusion-ec15d540"
		let report = try await normalizedReport(for: caseID, in: manifest)

		XCTAssertEqual(report.rawFixture["staleConclusionCount"], 1)
		XCTAssertEqual(report.normalizedModel["displaylessConclusionCount"], 0)
		XCTAssertEqual(report.normalizedModel["staleConclusionCount"], 0)
		XCTAssertEqual(report.projection["displaylessConclusionCount"], 0)
		XCTAssertEqual(report.projection["staleConclusionCount"], 0)
		XCTAssertEqual(report.export["displaylessConclusionCount"], 0)
		XCTAssertEqual(report.export["staleConclusionCount"], 0)
	}

	func testBatch2ActiveRunningFixtureDoesNotForceFinalizePendingTools() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let caseID = "gemini-huge-read-file-44ac4441"
		let session = try await normalizedSession(for: caseID, in: manifest)
		let transcript = try XCTUnwrap(session.transcript)
		let activities = transcript.allActivities
		let remainingToolCalls = activities.filter { $0.itemKind == .toolCall }
		let forcedFallbackResults = activities.compactMap(\.toolExecution?.resultJSON).filter { resultJSON in
			resultJSON.contains("result_missing") || resultJSON.contains("run_ended")
		}

		XCTAssertGreaterThanOrEqual(
			remainingToolCalls.count,
			3,
			"Cold restore of an originally running session must not convert pending file_search calls into terminal fallback results"
		)
		XCTAssertTrue(forcedFallbackResults.isEmpty)
	}

	func testBatch2OpenCodeConciseConclusionRemainsExportable() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let caseID = "opencode-concise-final-e181fce3"
		let session = try await normalizedSession(for: caseID, in: manifest)
		let transcript = try XCTUnwrap(session.transcript)
		let report = HistoricalAuditMetricEvaluator.report(
			caseID: caseID,
			rawSession: session,
			normalizedSession: session
		)

		XCTAssertEqual(report.normalizedModel["staleConclusionCount"], 0)
		XCTAssertEqual(report.normalizedModel["displaylessConclusionCount"], 0)
		XCTAssertTrue(AgentTranscriptIO.buildConversationHistory(from: transcript).contains("<assistant>resumed after stop</assistant>"))
		XCTAssertTrue(AgentTranscriptIO.buildForkTranscriptXML(from: transcript).contains("<assistant>resumed after stop</assistant>"))
	}

	func testBatch3PersistencePayloadQualityFixturesRewriteStorage() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let maxPersistedToolSummaryBytes = manifest.globalPolicies.maxPersistedToolSummaryBytes
		let fixtureExpectations: [(caseID: String, rawHeavyToolNames: Set<String>)] = [
			("codex-legacy-huge-no-transcript-929ef811", ["bash"]),
			("codex-v2-large-file-search-45f6783b", ["file_search"]),
			("claude-huge-read-file-c264b9ae", ["read_file"]),
			("gemini-huge-read-file-44ac4441", ["read_file"])
		]

		for expectation in fixtureExpectations {
			let auditCase = try XCTUnwrap(manifest.cases.first { $0.caseID == expectation.caseID })
			let rawSession = try HistoricalAuditFixtureLoader.loadSession(for: auditCase)
			let originalData = try HistoricalAuditFixtureLoader.fixtureData(for: auditCase)
			let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
				"RepoPrompt-HistoricalAuditTests-Batch3-\(expectation.caseID)-\(UUID().uuidString)",
				isDirectory: true
			)
			defer { try? FileManager.default.removeItem(at: tempRoot) }

			let copiedURL = try HistoricalAuditFixtureLoader.copyFixtureToTemporarySessionFile(
				for: auditCase,
				temporaryRoot: tempRoot
			)
			let normalizedSession = try await AgentSessionDataService.shared.loadAgentSession(from: copiedURL)
			let persistedData = try Data(contentsOf: copiedURL)
			let persistedSession = try JSONDecoder().decode(AgentSession.self, from: persistedData)
			let report = HistoricalAuditMetricEvaluator.report(
				caseID: auditCase.caseID,
				rawSession: rawSession,
				normalizedSession: normalizedSession,
				persistedData: persistedData,
				rawData: originalData
			)

			XCTAssertTrue(persistedSession.items.isEmpty, "Persisted sessions should not keep duplicated legacy item rows for \(expectation.caseID)")
			XCTAssertNotNil(persistedSession.transcript, "Persisted sessions should materialize sanitized transcript storage for \(expectation.caseID)")
			XCTAssertLessThanOrEqual(
				report.persistedStorage["maxPersistedToolSummaryBytes"],
				maxPersistedToolSummaryBytes,
				"\(expectation.caseID) persisted tool summary exceeded storage summary budget"
			)
			XCTAssertLessThan(
				report.persistedStorage["duplicatedTextResultJSONChars"],
				100_000,
				"\(expectation.caseID) duplicated text/result payload should stay below P1 threshold"
			)

			for (metricName, expectedValue) in auditCase.expectedMetricsAfterFix ?? [:] where metricName.hasPrefix("persistedRaw") {
				XCTAssertEqual(report.persistedStorage[metricName], expectedValue, "\(expectation.caseID) \(metricName)")
			}
			if let expectedDuplicateChars = auditCase.expectedMetricsAfterFix?["duplicatedTextResultJSONChars"] {
				XCTAssertEqual(report.persistedStorage["duplicatedTextResultJSONChars"], expectedDuplicateChars, expectation.caseID)
			}

			if expectation.caseID == "codex-legacy-huge-no-transcript-929ef811" {
				XCTAssertFalse(rawSession.items.isEmpty)
				XCTAssertNil(rawSession.transcript)
				XCTAssertEqual(report.persistedStorage["persistedRawBashOutputCount"], 0)
			}

			try assertPersistedRawHeavyToolsAreSummaryOnly(
				in: persistedSession,
				rawHeavyToolNames: expectation.rawHeavyToolNames,
				maxPersistedToolSummaryBytes: maxPersistedToolSummaryBytes
			)
		}
	}

	func testBatch4PlaceholderVisibilityAndPathLikeToolNamesAreCleanAfterNormalization() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let placeholderFixtureIDs = [
			"cursor-acp-ghost-newlines-7cf4991f",
			"codex-empty-assistant-1a5fa4e5"
		]

		for caseID in placeholderFixtureIDs {
			let report = try await normalizedReport(for: caseID, in: manifest)
			XCTAssertGreaterThan(
				report.rawFixture["placeholderVisibleBlockCount"],
				0,
				"Fixture should preserve historical summary-only placeholder tool rows for \(caseID)"
			)
			XCTAssertEqual(report.projection["placeholderVisibleBlockCount"], 0, "\(caseID) projection placeholder visibility")
			XCTAssertEqual(report.export["placeholderVisibleBlockCount"], 0, "\(caseID) export placeholder visibility")
		}

		let geminiReport = try await normalizedReport(for: "gemini-duplicate-invocation-readme-25e5e3f5", in: manifest)
		XCTAssertGreaterThan(
			geminiReport.rawFixture["pathLikeToolNameVisibleCount"],
			0,
			"Gemini fixture should preserve historical path-like visible tool name"
		)
		XCTAssertEqual(geminiReport.normalizedModel["pathLikeToolNameVisibleCount"], 0)
		XCTAssertEqual(geminiReport.projection["pathLikeToolNameVisibleCount"], 0)
		XCTAssertEqual(geminiReport.export["pathLikeToolNameVisibleCount"], 0)

		let geminiSession = try await normalizedSession(for: "gemini-duplicate-invocation-readme-25e5e3f5", in: manifest)
		let geminiExecutions = try XCTUnwrap(geminiSession.transcript).allActivities.compactMap(\.toolExecution)
		XCTAssertTrue(
			geminiExecutions.contains { execution in
				execution.toolName == "read_file" && execution.keyPaths.contains("README.md")
			},
			"Path-like historical tool names should display as read_file while preserving the original path signal"
		)
	}

	func testBatch4MeaningfulPlaceholderErrorsStillRender() {
		let invocationID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
		let items: [AgentChatItem] = [
			.user("Run the unknown tool.", sequenceIndex: 0),
			.toolResult(
				name: "other",
				invocationID: invocationID,
				resultJSON: #"{"status":"failed","error":"permission denied"}"#,
				isError: true,
				sequenceIndex: 1
			),
			.assistant("The tool failed.", sequenceIndex: 2)
		]
		let transcript = AgentTranscriptIO.importLegacyItems(items)
		let projection = AgentTranscriptProjectionBuilder.build(from: transcript)
		let rows = projection.workingRows + projection.archivedRows
		let history = AgentTranscriptIO.buildConversationHistory(from: transcript)
		let forkXML = AgentTranscriptIO.buildForkTranscriptXML(from: transcript)

		XCTAssertTrue(rows.contains { $0.kind == .toolResult && $0.toolName == "other" })
		XCTAssertTrue(history.contains(#"<tool_result name="other"/>"#))
		XCTAssertTrue(forkXML.contains("<assistant>The tool failed.</assistant>"))
	}

	func testBatch5DuplicateInvocationFixtureHasCleanCorrelationMetricsAfterNormalization() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let auditCase = try XCTUnwrap(
			manifest.cases.first { $0.caseID == "gemini-duplicate-invocation-readme-25e5e3f5" }
		)
		let report = try await normalizedReport(for: auditCase.caseID, in: manifest)
		let expectedDuplicateGroupCount = try XCTUnwrap(auditCase.expectedMetricsAfterFix?["duplicateInvocationIDGroupCount"])

		XCTAssertEqual(report.normalizedModel["duplicateInvocationIDGroupCount"], expectedDuplicateGroupCount)
		XCTAssertEqual(report.normalizedModel["resultOverwriteCorruptionCount"], 0)
		XCTAssertEqual(report.normalizedModel["orphanToolResultCount"], 0)
		XCTAssertEqual(report.normalizedModel["pathLikeToolNameVisibleCount"], 0)
		XCTAssertEqual(report.projection["resultOverwriteCorruptionCount"], 0)
		XCTAssertEqual(report.projection["orphanToolResultCount"], 0)
		XCTAssertEqual(report.projection["pathLikeToolNameVisibleCount"], 0)
		XCTAssertEqual(report.export["resultOverwriteCorruptionCount"], 0)
		XCTAssertEqual(report.export["orphanToolResultCount"], 0)
		XCTAssertEqual(report.export["pathLikeToolNameVisibleCount"], 0)
	}

	func testBatch6ExpectedAfterFixMetricsAndSeverityThresholdsPassForAllCases() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let maxPersistedToolSummaryBytes = manifest.globalPolicies.maxPersistedToolSummaryBytes

		for auditCase in manifest.cases {
			let report = try await normalizedReport(for: auditCase.caseID, in: manifest)
			let currentDiagnostic = expectedMetricsCurrentDiagnostic(for: auditCase, report: report)

			if let currentDiagnostic {
				await MainActor.run {
					XCTContext.runActivity(named: auditCase.caseID) { activity in
						let attachment = XCTAttachment(string: currentDiagnostic)
						attachment.name = "expectedMetricsCurrent diagnostics"
						activity.add(attachment)
					}
				}
			}

			assertExpectedMetricsAfterFix(
				for: auditCase,
				report: report
			)
			assertNoP0P1SeverityThresholdViolations(
				for: auditCase,
				report: report,
				maxPersistedToolSummaryBytes: maxPersistedToolSummaryBytes
			)
		}
	}

	func testBatch3PersistenceRewriteIsIdempotentForPayloadFixtures() async throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let fixtureIDs = [
			"codex-legacy-huge-no-transcript-929ef811",
			"codex-v2-large-file-search-45f6783b",
			"claude-huge-read-file-c264b9ae",
			"gemini-huge-read-file-44ac4441"
		]

		for caseID in fixtureIDs {
			let auditCase = try XCTUnwrap(manifest.cases.first { $0.caseID == caseID })
			let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
				"RepoPrompt-HistoricalAuditTests-Batch3-Idempotence-\(caseID)-\(UUID().uuidString)",
				isDirectory: true
			)
			defer { try? FileManager.default.removeItem(at: tempRoot) }

			let copiedURL = try HistoricalAuditFixtureLoader.copyFixtureToTemporarySessionFile(
				for: auditCase,
				temporaryRoot: tempRoot
			)
			_ = try await AgentSessionDataService.shared.loadAgentSession(from: copiedURL)
			let firstRewrite = try Data(contentsOf: copiedURL)
			_ = try await AgentSessionDataService.shared.loadAgentSession(from: copiedURL)
			let secondRewrite = try Data(contentsOf: copiedURL)

			XCTAssertEqual(firstRewrite, secondRewrite, "Batch 3 storage rewrite should be idempotent for \(caseID)")
		}
	}

	func testFixtureLoaderCanCopySourceFixtureToTemporarySessionFile() throws {
		let manifest = try HistoricalAuditFixtureLoader.loadManifest()
		let auditCase = try XCTUnwrap(manifest.cases.first)
		let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
			"RepoPrompt-HistoricalAuditTests-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: tempRoot) }

		let copiedURL = try HistoricalAuditFixtureLoader.copyFixtureToTemporarySessionFile(
			for: auditCase,
			temporaryRoot: tempRoot
		)
		let copiedData = try Data(contentsOf: copiedURL)
		let copiedSession = try JSONDecoder().decode(AgentSession.self, from: copiedData)

		XCTAssertTrue(copiedURL.lastPathComponent.hasPrefix("AgentSession-"))
		XCTAssertEqual(copiedSession.name, auditCase.caseID)
	}

	private func normalizedSession(
		for caseID: String,
		in manifest: HistoricalAuditManifest,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws -> AgentSession {
		let auditCase = try XCTUnwrap(
			manifest.cases.first { $0.caseID == caseID },
			"Missing HistoricalAudit fixture case \(caseID)",
			file: file,
			line: line
		)
		let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
			"RepoPrompt-HistoricalAuditTests-\(caseID)-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: tempRoot) }

		let copiedURL = try HistoricalAuditFixtureLoader.copyFixtureToTemporarySessionFile(
			for: auditCase,
			temporaryRoot: tempRoot
		)
		return try await AgentSessionDataService.shared.loadAgentSession(from: copiedURL)
	}

	private func normalizedReport(
		for caseID: String,
		in manifest: HistoricalAuditManifest,
		file: StaticString = #filePath,
		line: UInt = #line
	) async throws -> HistoricalMetricReport {
		let auditCase = try XCTUnwrap(
			manifest.cases.first { $0.caseID == caseID },
			"Missing HistoricalAudit fixture case \(caseID)",
			file: file,
			line: line
		)
		let rawSession = try HistoricalAuditFixtureLoader.loadSession(for: auditCase)
		let originalData = try HistoricalAuditFixtureLoader.fixtureData(for: auditCase)
		let tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
			"RepoPrompt-HistoricalAuditTests-\(caseID)-\(UUID().uuidString)",
			isDirectory: true
		)
		defer { try? FileManager.default.removeItem(at: tempRoot) }

		let copiedURL = try HistoricalAuditFixtureLoader.copyFixtureToTemporarySessionFile(
			for: auditCase,
			temporaryRoot: tempRoot
		)
		let normalizedSession = try await AgentSessionDataService.shared.loadAgentSession(from: copiedURL)
		let persistedData = try Data(contentsOf: copiedURL)
		return HistoricalAuditMetricEvaluator.report(
			caseID: auditCase.caseID,
			rawSession: rawSession,
			normalizedSession: normalizedSession,
			persistedData: persistedData,
			rawData: originalData
		)
	}

	private enum HistoricalMetricBoundary: String, CaseIterable {
		case normalizedModel
		case projection
		case export
		case persistedStorage
	}

	private func assertExpectedMetricsAfterFix(
		for auditCase: HistoricalAuditCase,
		report: HistoricalMetricReport,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		for (metricName, expectedValue) in (auditCase.expectedMetricsAfterFix ?? [:]).sorted(by: { $0.key < $1.key }) {
			for boundary in expectedAfterFixBoundaries(for: metricName) {
				let actualValue = snapshot(boundary, in: report)[metricName]
				if isMaximumExpectedMetric(metricName) {
					XCTAssertLessThanOrEqual(
						actualValue,
						expectedValue,
						"\(auditCase.caseID) expectedMetricsAfterFix[\(metricName)] cap at \(boundary.rawValue)",
						file: file,
						line: line
					)
				} else {
					XCTAssertEqual(
						actualValue,
						expectedValue,
						"\(auditCase.caseID) expectedMetricsAfterFix[\(metricName)] at \(boundary.rawValue)",
						file: file,
						line: line
					)
				}
			}
		}
	}

	private func assertNoP0P1SeverityThresholdViolations(
		for auditCase: HistoricalAuditCase,
		report: HistoricalMetricReport,
		maxPersistedToolSummaryBytes: Int,
		file: StaticString = #filePath,
		line: UInt = #line
	) {
		let exactAfterFixMetrics = Set((auditCase.expectedMetricsAfterFix ?? [:]).keys)

		assertZeroIfNotExpected(
			"projectedGhostAssistantCount",
			boundaries: [.projection],
			exactAfterFixMetrics: exactAfterFixMetrics,
			auditCase: auditCase,
			report: report,
			file: file,
			line: line
		)
		assertZeroIfNotExpected(
			"exportGhostAssistantCount",
			boundaries: [.export],
			exactAfterFixMetrics: exactAfterFixMetrics,
			auditCase: auditCase,
			report: report,
			file: file,
			line: line
		)
		assertZeroIfNotExpected(
			"placeholderVisibleBlockCount",
			boundaries: [.projection, .export],
			exactAfterFixMetrics: exactAfterFixMetrics,
			auditCase: auditCase,
			report: report,
			file: file,
			line: line
		)
		for metric in ["pendingToolAfterTerminalCount", "unresolvedToolCallCount", "staleToolCallWithoutResultCount"] {
			assertZeroIfNotExpected(
				metric,
				boundaries: [.normalizedModel, .projection, .export, .persistedStorage],
				exactAfterFixMetrics: exactAfterFixMetrics,
				auditCase: auditCase,
				report: report,
				file: file,
				line: line
			)
		}
		for metric in ["displaylessConclusionCount", "staleConclusionCount", "missingConclusionWithAssistantCount"] {
			assertZeroIfNotExpected(
				metric,
				boundaries: [.normalizedModel, .projection, .export, .persistedStorage],
				exactAfterFixMetrics: exactAfterFixMetrics,
				auditCase: auditCase,
				report: report,
				file: file,
				line: line
			)
		}
		for metric in ["resultOverwriteCorruptionCount", "pathLikeToolNameVisibleCount"] {
			assertZeroIfNotExpected(
				metric,
				boundaries: [.normalizedModel, .projection, .export, .persistedStorage],
				exactAfterFixMetrics: exactAfterFixMetrics,
				auditCase: auditCase,
				report: report,
				file: file,
				line: line
			)
		}
		if !auditCase.issues.contains("pendingToolInActiveRun") {
			assertZeroIfNotExpected(
				"orphanToolResultCount",
				boundaries: [.normalizedModel, .projection, .export, .persistedStorage],
				exactAfterFixMetrics: exactAfterFixMetrics,
				auditCase: auditCase,
				report: report,
				file: file,
				line: line
			)
		}
		assertZeroIfNotExpected(
			"duplicateInvocationIDGroupCount",
			boundaries: [.normalizedModel, .projection, .export, .persistedStorage],
			exactAfterFixMetrics: exactAfterFixMetrics,
			auditCase: auditCase,
			report: report,
			file: file,
			line: line
		)
		for metric in ["persistedRawReadFileCount", "persistedRawFileSearchCount", "persistedRawBashOutputCount", "persistedRawToolPayloadCount"] {
			assertZeroIfNotExpected(
				metric,
				boundaries: [.persistedStorage],
				exactAfterFixMetrics: exactAfterFixMetrics,
				auditCase: auditCase,
				report: report,
				file: file,
				line: line
			)
		}

		if !exactAfterFixMetrics.contains("maxPersistedToolSummaryBytes") {
			XCTAssertLessThanOrEqual(
				report.persistedStorage["maxPersistedToolSummaryBytes"],
				maxPersistedToolSummaryBytes,
				"\(auditCase.caseID) persisted maxPersistedToolSummaryBytes should stay within HistoricalAudit summary budget",
				file: file,
				line: line
			)
		}
		if !exactAfterFixMetrics.contains("sessionFileBytes") {
			XCTAssertLessThanOrEqual(
				report.persistedStorage["sessionFileBytes"],
				1_000_000,
				"\(auditCase.caseID) persisted sessionFileBytes crossed the P1 1 MB threshold",
				file: file,
				line: line
			)
		}
		if !exactAfterFixMetrics.contains("duplicatedTextResultJSONChars") {
			XCTAssertLessThanOrEqual(
				report.persistedStorage["duplicatedTextResultJSONChars"],
				100_000,
				"\(auditCase.caseID) persisted duplicatedTextResultJSONChars crossed the P1 threshold",
				file: file,
				line: line
			)
		}
	}

	private func assertZeroIfNotExpected(
		_ metricName: String,
		boundaries: [HistoricalMetricBoundary],
		exactAfterFixMetrics: Set<String>,
		auditCase: HistoricalAuditCase,
		report: HistoricalMetricReport,
		file: StaticString,
		line: UInt
	) {
		guard !exactAfterFixMetrics.contains(metricName) else { return }
		for boundary in boundaries {
			XCTAssertEqual(
				snapshot(boundary, in: report)[metricName],
				0,
				"\(auditCase.caseID) \(metricName) violated the HistoricalAudit P0/P1 threshold at \(boundary.rawValue)",
				file: file,
				line: line
			)
		}
	}

	private func isMaximumExpectedMetric(_ metricName: String) -> Bool {
		metricName == "maxPersistedToolSummaryBytes" || metricName == "maxToolPayloadChars" || metricName == "sessionFileBytes"
	}

	private func expectedAfterFixBoundaries(for metricName: String) -> [HistoricalMetricBoundary] {
		switch metricName {
		case "projectedGhostAssistantCount":
			return [.projection]
		case "exportGhostAssistantCount":
			return [.export]
		case "placeholderVisibleBlockCount":
			return [.projection, .export]
		case "pendingToolAfterTerminalCount", "unresolvedToolCallCount", "staleToolCallWithoutResultCount":
			return [.normalizedModel, .projection, .export, .persistedStorage]
		case "displaylessConclusionCount", "staleConclusionCount", "missingConclusionWithAssistantCount":
			return [.normalizedModel, .projection, .export, .persistedStorage]
		case "duplicateInvocationIDGroupCount":
			return [.normalizedModel, .projection, .export, .persistedStorage]
		case "resultOverwriteCorruptionCount", "orphanToolResultCount", "pathLikeToolNameVisibleCount":
			return [.normalizedModel, .projection, .export, .persistedStorage]
		case "maxPersistedToolSummaryBytes", "maxToolPayloadChars", "duplicatedTextResultJSONChars", "persistedRawReadFileCount", "persistedRawFileSearchCount", "persistedRawBashOutputCount", "persistedRawToolPayloadCount", "sessionFileBytes":
			return [.persistedStorage]
		case "assistantMicroNoiseCount":
			return [.normalizedModel, .projection]
		case "lowSubstantiveFinalAnswerCount":
			return [.normalizedModel, .export]
		default:
			return HistoricalMetricBoundary.allCases
		}
	}

	private func snapshot(_ boundary: HistoricalMetricBoundary, in report: HistoricalMetricReport) -> HistoricalMetricSnapshot {
		switch boundary {
		case .normalizedModel:
			return report.normalizedModel
		case .projection:
			return report.projection
		case .export:
			return report.export
		case .persistedStorage:
			return report.persistedStorage
		}
	}

	private func expectedMetricsCurrentDiagnostic(
		for auditCase: HistoricalAuditCase,
		report: HistoricalMetricReport
	) -> String? {
		guard let currentMetrics = auditCase.expectedMetricsCurrent, !currentMetrics.isEmpty else { return nil }
		let lines = currentMetrics.keys.sorted().map { metricName in
			let expectedCurrent = currentMetrics[metricName] ?? 0
			return "\(metricName): expectedMetricsCurrent=\(expectedCurrent), normalized=\(report.normalizedModel[metricName]), projection=\(report.projection[metricName]), export=\(report.export[metricName]), persisted=\(report.persistedStorage[metricName])"
		}
		return "expectedMetricsCurrent is diagnostic only and intentionally not asserted.\n" + lines.joined(separator: "\n")
	}

	private func assertPersistedRawHeavyToolsAreSummaryOnly(
		in session: AgentSession,
		rawHeavyToolNames: Set<String>,
		maxPersistedToolSummaryBytes: Int,
		file: StaticString = #filePath,
		line: UInt = #line
	) throws {
		let transcript = try XCTUnwrap(session.transcript, file: file, line: line)
		let matchingActivities = transcript.allActivities.filter { activity in
			guard activity.itemKind == .toolResult,
				let toolName = AgentToolResultPersistencePolicy.normalizedToolName(activity.toolExecution?.toolName)
			else {
				return false
			}
			return rawHeavyToolNames.contains(toolName)
		}
		XCTAssertFalse(matchingActivities.isEmpty, "Expected persisted raw-heavy tool coverage for \(rawHeavyToolNames)", file: file, line: line)

		for activity in matchingActivities {
			let execution = try XCTUnwrap(activity.toolExecution, file: file, line: line)
			XCTAssertTrue(execution.summaryOnly, "Persisted raw-heavy tool execution should be summary-only", file: file, line: line)
			XCTAssertNil(execution.argsJSON, "Persisted raw-heavy tool execution should drop raw args", file: file, line: line)
			XCTAssertTrue(execution.keyPaths.isEmpty, "Persisted raw-heavy tool execution should drop path/raw-detail arrays", file: file, line: line)
			XCTAssertTrue(isSummaryOnlyJSON(execution.resultJSON), "Persisted raw-heavy resultJSON should be summary-only JSON", file: file, line: line)
			XCTAssertTrue(isSummaryOnlyJSON(activity.text), "Persisted raw-heavy activity text should be summary-only JSON", file: file, line: line)

			for payload in [execution.argsJSON, execution.resultJSON, activity.text] {
				guard let payload else { continue }
				XCTAssertLessThanOrEqual(
					payload.utf8.count,
					maxPersistedToolSummaryBytes,
					"Persisted raw-heavy tool summary should obey the storage summary budget",
					file: file,
					line: line
				)
			}
		}
	}

	private func isSummaryOnlyJSON(_ value: String?) -> Bool {
		guard let value else { return false }
		let compact = value.replacingOccurrences(of: " ", with: "").lowercased()
		return compact.contains("\"summary_only\":true") || compact.contains("\"summaryonly\":true")
	}
}
