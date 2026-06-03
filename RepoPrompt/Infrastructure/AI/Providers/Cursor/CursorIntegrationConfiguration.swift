import Foundation

/// Cursor-specific MCP integration helpers.
///
/// Cursor ACP does not reliably honor ACP `session/new` MCP injection. RepoPrompt-launched
/// Cursor ACP runs therefore write a project-local `.cursor/mcp.json` lease before launch and
/// restore/remove it on normal shutdown. If RepoPrompt crashes, the generated file may remain;
/// cleanup is intentionally best effort and never overwrites user changes made during a run.
enum CursorIntegrationConfiguration {
	static let cleanupArtifactKind = "cursorProjectMCPConfig"
	private static let cursorDirectoryName = ".cursor"
	private static let mcpConfigFileName = "mcp.json"
	private static let fileLock = NSLock()
	private static let leaseStore = CursorProjectMCPConfigLeaseStore()

	struct ProjectMCPConfigLease: Sendable, Equatable {
		let id: UUID
		let configURL: URL
		let directoryURL: URL
		let previousData: Data?
		let writtenData: Data
		let createdDirectory: Bool
	}

	static func cursorDirectoryURL(workingDirectory: String) -> URL {
		standardizedWorkingDirectoryURL(workingDirectory)
			.appendingPathComponent(cursorDirectoryName, isDirectory: true)
	}

	static func projectMCPConfigURL(workingDirectory: String) -> URL {
		cursorDirectoryURL(workingDirectory: workingDirectory)
			.appendingPathComponent(mcpConfigFileName)
	}

	@discardableResult
	static func prepareProjectMCPConfig(
		workingDirectory: String,
		repoPromptMCPConfiguration: RepoPromptMCPServerConfiguration = .repoPrompt
	) throws -> ACPLaunchCleanupArtifact {
		fileLock.lock()
		defer { fileLock.unlock() }

		let fm = FileManager.default
		let directoryURL = cursorDirectoryURL(workingDirectory: workingDirectory)
		let configURL = directoryURL.appendingPathComponent(mcpConfigFileName)

		var isDirectory: ObjCBool = false
		let directoryExists = fm.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory)
		if directoryExists, !isDirectory.boolValue {
			throw AIProviderError.invalidConfiguration(detail: "Unable to prepare Cursor MCP config: \(directoryURL.path) exists but is not a directory.")
		}
		let createdDirectory = !directoryExists
		try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)

		let previousData: Data?
		if fm.fileExists(atPath: configURL.path) {
			do {
				previousData = try Data(contentsOf: configURL)
			} catch {
				throw AIProviderError.invalidConfiguration(detail: "Unable to read Cursor MCP config at \(configURL.path): \(error.localizedDescription)")
			}
		} else {
			previousData = nil
		}

		var root = try existingRootObject(from: previousData, configURL: configURL)
		var servers = try existingMCPServers(from: root, configURL: configURL)
		servers[repoPromptMCPConfiguration.name] = repoPromptMCPConfiguration.settingsJSONObject
		root["mcpServers"] = servers

		let writtenData = try JSONSerialization.data(
			withJSONObject: root,
			options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
		)
		try writtenData.write(to: configURL, options: .atomic)

		let lease = ProjectMCPConfigLease(
			id: UUID(),
			configURL: configURL,
			directoryURL: directoryURL,
			previousData: previousData,
			writtenData: writtenData,
			createdDirectory: createdDirectory
		)
		leaseStore.register(lease)
		return ACPLaunchCleanupArtifact(
			providerID: .cursor,
			id: lease.id,
			kind: cleanupArtifactKind
		)
	}

	static func cleanupProjectMCPConfig(leaseID: UUID) {
		fileLock.lock()
		defer { fileLock.unlock() }

		let fm = FileManager.default
		switch leaseStore.cleanupDisposition(for: leaseID) {
		case .none, .deferred:
			return
		case .final(let state):
			do {
				let currentData: Data?
				if fm.fileExists(atPath: state.configURL.path) {
					do {
						currentData = try Data(contentsOf: state.configURL)
					} catch {
						#if DEBUG
						print("[CursorIntegrationConfiguration] Cleanup read failed for \(state.configURL.path): \(error.localizedDescription)")
						#endif
						return
					}
				} else {
					currentData = nil
				}

				guard currentData == state.latestWrittenData else {
					leaseStore.completeFinalCleanup(leaseID: leaseID)
					return
				}

				if let previousData = state.originalPreviousData {
					try previousData.write(to: state.configURL, options: .atomic)
				} else if fm.fileExists(atPath: state.configURL.path) {
					try fm.removeItem(at: state.configURL)
				}

				if state.originalCreatedDirectory,
					let contents = try? fm.contentsOfDirectory(atPath: state.directoryURL.path),
					contents.isEmpty {
					try? fm.removeItem(at: state.directoryURL)
				}
				leaseStore.completeFinalCleanup(leaseID: leaseID)
			} catch {
				#if DEBUG
				print("[CursorIntegrationConfiguration] Cleanup failed for \(state.configURL.path): \(error.localizedDescription)")
				#endif
			}
		}
	}

	private static func existingRootObject(from data: Data?, configURL: URL) throws -> [String: Any] {
		guard let data else { return [:] }
		do {
			guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
				throw AIProviderError.invalidConfiguration(detail: "Unable to merge Cursor MCP config at \(configURL.path): expected a JSON object.")
			}
			return root
		} catch let error as AIProviderError {
			throw error
		} catch {
			throw AIProviderError.invalidConfiguration(detail: "Unable to merge Cursor MCP config at \(configURL.path): invalid JSON.")
		}
	}

	private static func existingMCPServers(from root: [String: Any], configURL: URL) throws -> [String: Any] {
		guard let existing = root["mcpServers"] else { return [:] }
		guard let servers = existing as? [String: Any] else {
			throw AIProviderError.invalidConfiguration(detail: "Unable to merge Cursor MCP config at \(configURL.path): `mcpServers` must be an object.")
		}
		return servers
	}

	private static func standardizedWorkingDirectoryURL(_ workingDirectory: String) -> URL {
		let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
		let path = trimmed.isEmpty ? FileManager.default.temporaryDirectory.path : trimmed
		return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
	}
}

private final class CursorProjectMCPConfigLeaseStore: @unchecked Sendable {
	struct PathLeaseState {
		let configURL: URL
		let directoryURL: URL
		let originalPreviousData: Data?
		let originalCreatedDirectory: Bool
		var activeLeaseIDs: Set<UUID>
		var latestWrittenData: Data
	}

	enum CleanupDisposition {
		case deferred
		case final(PathLeaseState)
	}

	private let lock = NSLock()
	private var configPathByLeaseID: [UUID: String] = [:]
	private var stateByConfigPath: [String: PathLeaseState] = [:]

	func register(_ lease: CursorIntegrationConfiguration.ProjectMCPConfigLease) {
		lock.lock()
		defer { lock.unlock() }

		let key = lease.configURL.standardizedFileURL.path
		configPathByLeaseID[lease.id] = key
		if var state = stateByConfigPath[key] {
			state.activeLeaseIDs.insert(lease.id)
			state.latestWrittenData = lease.writtenData
			stateByConfigPath[key] = state
		} else {
			stateByConfigPath[key] = PathLeaseState(
				configURL: lease.configURL,
				directoryURL: lease.directoryURL,
				originalPreviousData: lease.previousData,
				originalCreatedDirectory: lease.createdDirectory,
				activeLeaseIDs: [lease.id],
				latestWrittenData: lease.writtenData
			)
		}
	}

	func cleanupDisposition(for leaseID: UUID) -> CleanupDisposition? {
		lock.lock()
		defer { lock.unlock() }

		guard let key = configPathByLeaseID[leaseID], var state = stateByConfigPath[key] else {
			return nil
		}
		if state.activeLeaseIDs.count > 1 {
			state.activeLeaseIDs.remove(leaseID)
			stateByConfigPath[key] = state
			configPathByLeaseID.removeValue(forKey: leaseID)
			return .deferred
		}
		return .final(state)
	}

	func completeFinalCleanup(leaseID: UUID) {
		lock.lock()
		defer { lock.unlock() }

		guard let key = configPathByLeaseID.removeValue(forKey: leaseID) else { return }
		stateByConfigPath.removeValue(forKey: key)
	}
}
