import Foundation

/// Best-effort cleanup for app state owned by removed external-service capabilities.
/// This runs on every launch so transient filesystem or Keychain failures retry safely.
enum RemovedExternalServiceStateCleanup {
	private static let exactDefaultsKeys = [
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
		"SULastProfileSubmissionDate",
		"SUSkippedVersion",
		"SUSkippedMinorVersion",
		"SUSkippedMajorVersion",
		"SUSkippedMajorSubreleaseVersion"
	]

	/// Prefix for the app's obsolete XOR-obfuscated UserDefaults API-key store.
	private static let defaultsKeyPrefixes = [
		"com.repoprompt.securekey."
	]

	private static let keychainAccounts = [
		"GitHubToken"
	]

	/// Bundle identifiers that previously hosted PostHog state and app-scoped Sentry caches.
	private static let appOwnedBundleIdentifiers = [
		"com.pvncher.repoprompt",
		"debug.pvncher.repoprompt"
	]

	private static let postHogStorageItemPrefix = "posthog."

	/// SHA-1 path component Sentry 8.58.2 derived from the removed RepoPrompt DSN.
	/// This names one audited child below the shared `io.sentry` parent without
	/// restoring the removed DSN credential.
	private static let sentryPayloadCacheDirectoryNames = [
		"19202fa554ff21bdb1deec230b48f84782c5ca19"
	]

	private static let sentryCrashBundleNames = [
		"Repo Prompt",
		"RepoPrompt"
	]

	static func perform() {
		perform(
			defaults: .standard,
			applicationSupportDirectory: FileManager.default.urls(
				for: .applicationSupportDirectory,
				in: .userDomainMask
			).first,
			cachesDirectory: FileManager.default.urls(
				for: .cachesDirectory,
				in: .userDomainMask
			).first,
			shouldDeleteHistoricalKeychainAccounts: SecureKeyValueStorageFactory.usesPersistentKeychain,
			deleteKeychainAccount: { account in
				try? KeychainService.shared.delete(for: account)
			}
		)
	}

	/// Internal seam for deterministic tests. Cleanup is idempotent and
	/// deliberately ignores failures so a later launch can retry.
	static func perform(
		defaults: UserDefaults,
		applicationSupportDirectory: URL?,
		cachesDirectory: URL? = nil,
		fileManager: FileManager = .default,
		shouldDeleteHistoricalKeychainAccounts: Bool = true,
		deleteKeychainAccount: (String) -> Void
	) {
		for key in exactDefaultsKeys {
			defaults.removeObject(forKey: key)
		}

		for key in defaults.dictionaryRepresentation().keys
			where defaultsKeyPrefixes.contains(where: key.hasPrefix) {
			defaults.removeObject(forKey: key)
		}

		if shouldDeleteHistoricalKeychainAccounts {
			for account in keychainAccounts {
				deleteKeychainAccount(account)
			}
		}

		if let applicationSupportDirectory {
			let deviceIDURL = applicationSupportDirectory
				.appendingPathComponent("com.repoprompt", isDirectory: true)
				.appendingPathComponent("device-id", isDirectory: false)
			try? fileManager.removeItem(at: deviceIDURL)

			removeAuditedPostHogResidue(
				applicationSupportDirectory: applicationSupportDirectory,
				fileManager: fileManager
			)
		}

		if let cachesDirectory {
			removeAuditedSentryResidue(cachesDirectory: cachesDirectory, fileManager: fileManager)
		}
	}

	/// PostHog 3.37.2 stores files and queue folders named `posthog.*` below
	/// Application Support/<bundle identifier>/<project key>. Older versions may
	/// leave the same names directly below the bundle root. Inspect only those two
	/// audited depths, reject symlink directories, and prune only project-key
	/// directories emptied by this cleanup.
	private static func removeAuditedPostHogResidue(
		applicationSupportDirectory: URL,
		fileManager: FileManager
	) {
		for bundleIdentifier in appOwnedBundleIdentifiers {
			let bundleDirectory = applicationSupportDirectory
				.appendingPathComponent(bundleIdentifier, isDirectory: true)
			guard isTraversableDirectory(bundleDirectory, fileManager: fileManager) else {
				continue
			}

			_ = removeImmediatePostHogResidue(under: bundleDirectory, fileManager: fileManager)

			guard let projectDirectories = try? fileManager.contentsOfDirectory(
				at: bundleDirectory,
				includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
				options: [.skipsHiddenFiles]
			) else {
				continue
			}

			for projectDirectory in projectDirectories
				where isTraversableDirectory(projectDirectory, fileManager: fileManager) {
				let removedResidue = removeImmediatePostHogResidue(
					under: projectDirectory,
					fileManager: fileManager
				)
				if removedResidue {
					removeDirectoryIfEmpty(projectDirectory, fileManager: fileManager)
				}
			}
		}
	}

	@discardableResult
	private static func removeImmediatePostHogResidue(
		under directory: URL,
		fileManager: FileManager
	) -> Bool {
		guard isTraversableDirectory(directory, fileManager: fileManager),
				let items = try? fileManager.contentsOfDirectory(
					at: directory,
					includingPropertiesForKeys: nil,
					options: [.skipsHiddenFiles]
				) else {
			return false
		}

		var removedResidue = false
		for item in items where item.lastPathComponent.hasPrefix(postHogStorageItemPrefix) {
			do {
				try fileManager.removeItem(at: item)
				removedResidue = true
			} catch {
				continue
			}
		}
		return removedResidue
	}

	private static func isTraversableDirectory(_ directory: URL, fileManager: FileManager) -> Bool {
		guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
			return false
		}
		return values.isDirectory == true && values.isSymbolicLink != true
	}

	/// Sentry 8.58.2 uses these app-scoped cache children in addition to shared
	/// cache parents. Preserve shared ~/Library/Caches/io.sentry and INSTALLATION.
	private static func removeAuditedSentryResidue(
		cachesDirectory: URL,
		fileManager: FileManager
	) {
		for bundleIdentifier in appOwnedBundleIdentifiers {
			let staticCacheURL = cachesDirectory
				.appendingPathComponent(bundleIdentifier, isDirectory: true)
				.appendingPathComponent("io.sentry", isDirectory: true)
			try? fileManager.removeItem(at: staticCacheURL)
		}

		for payloadCacheDirectoryName in sentryPayloadCacheDirectoryNames {
			let payloadCacheURL = cachesDirectory
				.appendingPathComponent("io.sentry", isDirectory: true)
				.appendingPathComponent(payloadCacheDirectoryName, isDirectory: true)
			try? fileManager.removeItem(at: payloadCacheURL)
		}

		for crashBundleName in sentryCrashBundleNames {
			let crashReportsURL = cachesDirectory
				.appendingPathComponent("SentryCrash", isDirectory: true)
				.appendingPathComponent(crashBundleName, isDirectory: true)
			try? fileManager.removeItem(at: crashReportsURL)
		}
	}

	private static func removeDirectoryIfEmpty(_ directory: URL, fileManager: FileManager) {
		guard let remainingItems = try? fileManager.contentsOfDirectory(atPath: directory.path),
				remainingItems.isEmpty else {
			return
		}
		try? fileManager.removeItem(at: directory)
	}
}
