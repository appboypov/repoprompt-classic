import CryptoKit
import Foundation
import Logging

/// Downloads and installs Google's Antigravity ACP server into RepoPrompt's
/// Application Support folder.
///
/// RepoPrompt pins one server release. The archive comes from Google's download
/// host, is checked against the SHA-256 the ACP registry publishes for it, and is
/// unpacked into `Antigravity/<version>/`. The server binary needs its helper
/// `localharness_external` beside it, so both stay in the version folder.
enum AntigravityServerInstaller {
	enum Architecture: String, Sendable, CaseIterable {
		case arm64
		case x86_64

		static var current: Architecture {
			#if arch(arm64)
			.arm64
			#else
			.x86_64
			#endif
		}
	}

	struct Archive: Sendable, Equatable {
		let url: URL
		let sha256: String
	}

	enum InstallError: LocalizedError, Equatable {
		case checksumMismatch(expected: String, actual: String)
		case unpackFailed(status: Int32)
		case missingServerFiles

		var errorDescription: String? {
			switch self {
			case .checksumMismatch:
				return "The Antigravity download did not match its published checksum. Try again."
			case .unpackFailed(let status):
				return "Could not unpack the Antigravity download (ditto exit \(status))."
			case .missingServerFiles:
				return "The Antigravity download is missing the server files."
			}
		}
	}

	static let version = "1.4.3"
	static let serverExecutableName = "agy_acp_server.par"
	static let harnessExecutableName = "localharness_external"
	static let homeFolderName = "home"

	private static let logger = Logger(label: "com.repoprompt.antigravity.installer")

	static func archive(for architecture: Architecture) -> Archive {
		switch architecture {
		case .arm64:
			return Archive(
				url: URL(string: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-\(version)-darwin-arm64.zip")!,
				sha256: "c57db0a9b8b712daa9c3c17cdb990a61842ea569f279e8bd79d7aa85a303b20b"
			)
		case .x86_64:
			return Archive(
				url: URL(string: "https://dl.google.com/agy-extensions/releases/macos/agy-acp-server-\(version)-darwin-x86_64.zip")!,
				sha256: "9392dbbdad7f0663dbfb5a0bf641297b0cf80d2ee9cd2d49a616bbbc7378731d"
			)
		}
	}

	/// `~/Library/Application Support/RepoPrompt/Antigravity`
	static var rootURL: URL {
		let appSupportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
		return appSupportURL
			.appendingPathComponent("RepoPrompt", isDirectory: true)
			.appendingPathComponent("Antigravity", isDirectory: true)
	}

	static var installURL: URL {
		rootURL.appendingPathComponent(version, isDirectory: true)
	}

	static var serverURL: URL {
		installURL.appendingPathComponent(serverExecutableName)
	}

	static var isInstalled: Bool {
		let fileManager = FileManager.default
		return fileManager.isExecutableFile(atPath: serverURL.path)
			&& fileManager.isExecutableFile(atPath: installURL.appendingPathComponent(harnessExecutableName).path)
	}

	/// Downloads, verifies and unpacks the pinned server release, then removes
	/// the folders of other server versions.
	static func install(architecture: Architecture = .current) async throws {
		let archive = archive(for: architecture)
		logger.info("Downloading Antigravity ACP server \(version) for \(architecture.rawValue)")
		let (downloadedURL, _) = try await URLSession.shared.download(from: archive.url)
		defer { try? FileManager.default.removeItem(at: downloadedURL) }

		try verifyChecksum(of: downloadedURL, expectedSHA256: archive.sha256)
		try unpack(archiveAt: downloadedURL)
		removeOtherVersions()
		logger.info("Installed Antigravity ACP server \(version) at \(installURL.path)")
	}

	static func verifyChecksum(of fileURL: URL, expectedSHA256: String) throws {
		let actual = try sha256Hex(of: fileURL)
		guard actual.caseInsensitiveCompare(expectedSHA256) == .orderedSame else {
			logger.error("Antigravity archive checksum mismatch expected=\(expectedSHA256) actual=\(actual)")
			throw InstallError.checksumMismatch(expected: expectedSHA256, actual: actual)
		}
	}

	private static func sha256Hex(of fileURL: URL) throws -> String {
		let handle = try FileHandle(forReadingFrom: fileURL)
		defer { try? handle.close() }
		var hasher = SHA256()
		while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
			hasher.update(data: chunk)
		}
		return hasher.finalize().map { String(format: "%02x", $0) }.joined()
	}

	private static func unpack(archiveAt archiveURL: URL) throws {
		let fileManager = FileManager.default
		try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
		let stagingURL = rootURL.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
		defer { try? fileManager.removeItem(at: stagingURL) }

		let ditto = Process()
		ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
		ditto.arguments = ["-x", "-k", archiveURL.path, stagingURL.path]
		try ditto.run()
		ditto.waitUntilExit()
		guard ditto.terminationStatus == 0 else {
			logger.error("Antigravity archive unpack failed status=\(ditto.terminationStatus)")
			throw InstallError.unpackFailed(status: ditto.terminationStatus)
		}

		guard let unpackedFolder = folderContainingServer(in: stagingURL) else {
			logger.error("Antigravity archive has no \(serverExecutableName) beside \(harnessExecutableName)")
			throw InstallError.missingServerFiles
		}
		for name in [serverExecutableName, harnessExecutableName] {
			try fileManager.setAttributes(
				[.posixPermissions: 0o755],
				ofItemAtPath: unpackedFolder.appendingPathComponent(name).path
			)
		}
		if fileManager.fileExists(atPath: installURL.path) {
			try fileManager.removeItem(at: installURL)
		}
		try fileManager.moveItem(at: unpackedFolder, to: installURL)
	}

	private static func folderContainingServer(in stagingURL: URL) -> URL? {
		let fileManager = FileManager.default
		guard let enumerator = fileManager.enumerator(at: stagingURL, includingPropertiesForKeys: nil) else {
			return nil
		}
		for case let url as URL in enumerator where url.lastPathComponent == serverExecutableName {
			let folder = url.deletingLastPathComponent()
			if fileManager.fileExists(atPath: folder.appendingPathComponent(harnessExecutableName).path) {
				return folder
			}
		}
		return nil
	}

	private static func removeOtherVersions() {
		let fileManager = FileManager.default
		guard let entries = try? fileManager.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil) else {
			return
		}
		for entry in entries where ![version, homeFolderName].contains(entry.lastPathComponent) {
			do {
				try fileManager.removeItem(at: entry)
			} catch {
				logger.warning("Could not remove old Antigravity server folder \(entry.path): \(error.localizedDescription)")
			}
		}
	}
}
