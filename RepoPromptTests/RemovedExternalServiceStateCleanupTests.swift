import XCTest
@testable import RepoPrompt

final class RemovedExternalServiceStateCleanupTests: XCTestCase {
	private var suiteName: String!
	private var defaults: UserDefaults!
	private var applicationSupportDirectory: URL!
	private var cachesDirectory: URL!

	override func setUpWithError() throws {
		try super.setUpWithError()
		suiteName = "RemovedExternalServiceStateCleanupTests.\(UUID().uuidString)"
		defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
		applicationSupportDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("RemovedExternalServiceStateCleanupTests.appSupport.\(UUID().uuidString)", isDirectory: true)
		cachesDirectory = FileManager.default.temporaryDirectory
			.appendingPathComponent("RemovedExternalServiceStateCleanupTests.caches.\(UUID().uuidString)", isDirectory: true)
		try FileManager.default.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true)
		try FileManager.default.createDirectory(at: cachesDirectory, withIntermediateDirectories: true)
	}

	override func tearDownWithError() throws {
		defaults.removePersistentDomain(forName: suiteName)
		try? FileManager.default.removeItem(at: applicationSupportDirectory)
		try? FileManager.default.removeItem(at: cachesDirectory)
		defaults = nil
		suiteName = nil
		applicationSupportDirectory = nil
		cachesDirectory = nil
		try super.tearDownWithError()
	}

	func testPerformRemovesOnlyAuditedState() throws {
		let exactKeys = [
			"evt_p",
			"BenchmarkSubmissionService.uploadedIDs",
			"RepoPromptPassiveAppcastChecksEnabled",
			"SparkleLastUpdateCheck",
			"PreAuthState",
			"PHGVersionKey",
			"PHGBuildKeyV2",
			"SUHasLaunchedBefore",
			"SULastCheckTime",
			"SUEnableAutomaticChecks",
			"SUAutomaticallyUpdate",
			"SUScheduledCheckInterval",
			"SUSendProfileInfo",
			"SULastProfileSubmissionDate"
		]
		for key in exactKeys {
			defaults.set("remove", forKey: key)
		}
		defaults.set("remove", forKey: "SUSkippedVersion")
		defaults.set("remove", forKey: "SUSkippedMinorVersion")
		defaults.set("remove", forKey: "SUSkippedMajorVersion")
		defaults.set("remove", forKey: "SUSkippedMajorSubreleaseVersion")
		defaults.set("keep", forKey: "SUUnrelatedValue")
		defaults.set("remove", forKey: "com.repoprompt.securekey.GitHubToken")
		defaults.set("remove", forKey: "com.repoprompt.securekey.OpenAIAPI")

		defaults.set("keep", forKey: "appearanceMode")
		defaults.set("keep", forKey: "notSU")
		defaults.set("keep", forKey: "com.repoprompt.securekeyish.OpenAIAPI")

		let appStateDirectory = applicationSupportDirectory
			.appendingPathComponent("com.repoprompt", isDirectory: true)
		try FileManager.default.createDirectory(at: appStateDirectory, withIntermediateDirectories: true)
		let deviceIDURL = appStateDirectory.appendingPathComponent("device-id")
		try Data("device-id".utf8).write(to: deviceIDURL)
		let retainedFileURL = appStateDirectory.appendingPathComponent("keep-me")
		try Data("keep".utf8).write(to: retainedFileURL)

		let postHogProjectDirectory = applicationSupportDirectory
			.appendingPathComponent("com.pvncher.repoprompt", isDirectory: true)
			.appendingPathComponent("removed-project-key", isDirectory: true)
		let postHogQueueDirectory = postHogProjectDirectory
			.appendingPathComponent("posthog.queueFolder", isDirectory: true)
		try FileManager.default.createDirectory(at: postHogQueueDirectory, withIntermediateDirectories: true)
		try Data("queued-event".utf8).write(to: postHogQueueDirectory.appendingPathComponent("event"))
		try Data("identity".utf8).write(to: postHogProjectDirectory.appendingPathComponent("posthog.distinctId"))
		let retainedPostHogSiblingURL = postHogProjectDirectory.appendingPathComponent("keep-me")
		try Data("keep".utf8).write(to: retainedPostHogSiblingURL)
		let legacyPostHogURL = postHogProjectDirectory
			.deletingLastPathComponent()
			.appendingPathComponent("posthog.legacy")
		try Data("legacy".utf8).write(to: legacyPostHogURL)

		let nestedPostHogDirectory = postHogProjectDirectory.appendingPathComponent("nested", isDirectory: true)
		try FileManager.default.createDirectory(at: nestedPostHogDirectory, withIntermediateDirectories: true)
		let retainedNestedPostHogURL = nestedPostHogDirectory.appendingPathComponent("posthog.keep-me")
		try Data("keep".utf8).write(to: retainedNestedPostHogURL)

		let prunablePostHogProjectDirectory = applicationSupportDirectory
			.appendingPathComponent("com.pvncher.repoprompt", isDirectory: true)
			.appendingPathComponent("empty-removed-project-key", isDirectory: true)
		try FileManager.default.createDirectory(at: prunablePostHogProjectDirectory, withIntermediateDirectories: true)
		try Data("identity".utf8).write(to: prunablePostHogProjectDirectory.appendingPathComponent("posthog.distinctId"))

		let linkedProjectTargetDirectory = applicationSupportDirectory
			.appendingPathComponent("linked-posthog-project-target", isDirectory: true)
		try FileManager.default.createDirectory(at: linkedProjectTargetDirectory, withIntermediateDirectories: true)
		let retainedLinkedProjectPostHogURL = linkedProjectTargetDirectory.appendingPathComponent("posthog.keep-me")
		try Data("keep".utf8).write(to: retainedLinkedProjectPostHogURL)
		try FileManager.default.createSymbolicLink(
			at: postHogProjectDirectory.deletingLastPathComponent().appendingPathComponent("linked-project-key"),
			withDestinationURL: linkedProjectTargetDirectory
		)

		let linkedBundleTargetDirectory = applicationSupportDirectory
			.appendingPathComponent("linked-posthog-bundle-target", isDirectory: true)
		try FileManager.default.createDirectory(at: linkedBundleTargetDirectory, withIntermediateDirectories: true)
		let retainedLinkedBundlePostHogURL = linkedBundleTargetDirectory.appendingPathComponent("posthog.keep-me")
		try Data("keep".utf8).write(to: retainedLinkedBundlePostHogURL)
		try FileManager.default.createSymbolicLink(
			at: applicationSupportDirectory.appendingPathComponent("debug.pvncher.repoprompt", isDirectory: true),
			withDestinationURL: linkedBundleTargetDirectory
		)

		let sentryStaticCacheURL = cachesDirectory
			.appendingPathComponent("com.pvncher.repoprompt", isDirectory: true)
			.appendingPathComponent("io.sentry", isDirectory: true)
		try FileManager.default.createDirectory(at: sentryStaticCacheURL, withIntermediateDirectories: true)
		try Data("profile".utf8).write(to: sentryStaticCacheURL.appendingPathComponent("profileLaunch"))
		let sentryCrashURL = cachesDirectory
			.appendingPathComponent("SentryCrash", isDirectory: true)
			.appendingPathComponent("Repo Prompt", isDirectory: true)
		try FileManager.default.createDirectory(at: sentryCrashURL, withIntermediateDirectories: true)
		try Data("crash".utf8).write(to: sentryCrashURL.appendingPathComponent("report"))
		let historicalSentryCrashURL = cachesDirectory
			.appendingPathComponent("SentryCrash", isDirectory: true)
			.appendingPathComponent("RepoPrompt", isDirectory: true)
		try FileManager.default.createDirectory(at: historicalSentryCrashURL, withIntermediateDirectories: true)
		try Data("crash".utf8).write(to: historicalSentryCrashURL.appendingPathComponent("report"))
		let sentryPayloadCacheURL = cachesDirectory
			.appendingPathComponent("io.sentry", isDirectory: true)
			.appendingPathComponent("19202fa554ff21bdb1deec230b48f84782c5ca19", isDirectory: true)
		try FileManager.default.createDirectory(at: sentryPayloadCacheURL, withIntermediateDirectories: true)
		try Data("envelope".utf8).write(to: sentryPayloadCacheURL.appendingPathComponent("envelope"))

		let sharedSentryCacheURL = cachesDirectory
			.appendingPathComponent("io.sentry", isDirectory: true)
			.appendingPathComponent("another-app-hash", isDirectory: true)
		try FileManager.default.createDirectory(at: sharedSentryCacheURL, withIntermediateDirectories: true)
		try Data("keep".utf8).write(to: sharedSentryCacheURL.appendingPathComponent("envelope"))
		let sharedInstallationURL = cachesDirectory.appendingPathComponent("INSTALLATION")
		try Data("keep".utf8).write(to: sharedInstallationURL)

		var deletedKeychainAccounts: [String] = []
		RemovedExternalServiceStateCleanup.perform(
			defaults: defaults,
			applicationSupportDirectory: applicationSupportDirectory,
			cachesDirectory: cachesDirectory,
			deleteKeychainAccount: { deletedKeychainAccounts.append($0) }
		)

		for key in exactKeys {
			XCTAssertNil(defaults.object(forKey: key), "Expected cleanup of \(key)")
		}
		XCTAssertNil(defaults.object(forKey: "SUSkippedVersion"))
		XCTAssertNil(defaults.object(forKey: "SUSkippedMinorVersion"))
		XCTAssertNil(defaults.object(forKey: "SUSkippedMajorVersion"))
		XCTAssertNil(defaults.object(forKey: "SUSkippedMajorSubreleaseVersion"))
		XCTAssertNil(defaults.object(forKey: "com.repoprompt.securekey.GitHubToken"))
		XCTAssertNil(defaults.object(forKey: "com.repoprompt.securekey.OpenAIAPI"))

		XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "keep")
		XCTAssertEqual(defaults.string(forKey: "SUUnrelatedValue"), "keep")
		XCTAssertEqual(defaults.string(forKey: "notSU"), "keep")
		XCTAssertEqual(defaults.string(forKey: "com.repoprompt.securekeyish.OpenAIAPI"), "keep")
		XCTAssertEqual(deletedKeychainAccounts, ["GitHubToken"])
		XCTAssertFalse(FileManager.default.fileExists(atPath: deviceIDURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: retainedFileURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: postHogQueueDirectory.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: postHogProjectDirectory.appendingPathComponent("posthog.distinctId").path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPostHogURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: retainedPostHogSiblingURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: retainedNestedPostHogURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: prunablePostHogProjectDirectory.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: retainedLinkedProjectPostHogURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: retainedLinkedBundlePostHogURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: sentryStaticCacheURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: sentryCrashURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: historicalSentryCrashURL.path))
		XCTAssertFalse(FileManager.default.fileExists(atPath: sentryPayloadCacheURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: sharedSentryCacheURL.path))
		XCTAssertTrue(FileManager.default.fileExists(atPath: sharedInstallationURL.path))
	}

	func testPerformRemainsIdempotentAfterRemovingState() throws {
		defaults.set("remove", forKey: "evt_p")
		defaults.set("keep", forKey: "appearanceMode")

		let appStateDirectory = applicationSupportDirectory
			.appendingPathComponent("com.repoprompt", isDirectory: true)
		try FileManager.default.createDirectory(at: appStateDirectory, withIntermediateDirectories: true)
		let deviceIDURL = appStateDirectory.appendingPathComponent("device-id")
		try Data("device-id".utf8).write(to: deviceIDURL)

		var deletedKeychainAccounts: [String] = []
		for _ in 0..<2 {
			RemovedExternalServiceStateCleanup.perform(
				defaults: defaults,
				applicationSupportDirectory: applicationSupportDirectory,
				cachesDirectory: cachesDirectory,
				deleteKeychainAccount: { deletedKeychainAccounts.append($0) }
			)
		}

		XCTAssertNil(defaults.object(forKey: "evt_p"))
		XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "keep")
		XCTAssertFalse(FileManager.default.fileExists(atPath: deviceIDURL.path))
		XCTAssertEqual(deletedKeychainAccounts, ["GitHubToken", "GitHubToken"])
	}

	func testPerformSkipsHistoricalKeychainDeletionInVolatileModeButStillCleansOtherState() throws {
		defaults.set("remove", forKey: "evt_p")
		defaults.set("keep", forKey: "appearanceMode")

		let appStateDirectory = applicationSupportDirectory
			.appendingPathComponent("com.repoprompt", isDirectory: true)
		try FileManager.default.createDirectory(at: appStateDirectory, withIntermediateDirectories: true)
		let deviceIDURL = appStateDirectory.appendingPathComponent("device-id")
		try Data("device-id".utf8).write(to: deviceIDURL)

		var deletedKeychainAccounts: [String] = []
		for _ in 0..<2 {
			RemovedExternalServiceStateCleanup.perform(
				defaults: defaults,
				applicationSupportDirectory: applicationSupportDirectory,
				cachesDirectory: cachesDirectory,
				shouldDeleteHistoricalKeychainAccounts: false,
				deleteKeychainAccount: { deletedKeychainAccounts.append($0) }
			)
		}

		XCTAssertNil(defaults.object(forKey: "evt_p"))
		XCTAssertEqual(defaults.string(forKey: "appearanceMode"), "keep")
		XCTAssertFalse(FileManager.default.fileExists(atPath: deviceIDURL.path))
		XCTAssertTrue(deletedKeychainAccounts.isEmpty)
	}
}
