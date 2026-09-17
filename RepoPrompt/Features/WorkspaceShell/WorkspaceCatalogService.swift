import Foundation

/// Sequences every catalog mutation under the shell: flush all runtimes, run one writer, reload the others.
/// Holds no documents; each manager keeps its own copy and disk stays canonical.
@MainActor
final class WorkspaceCatalogService {
	private let hostRuntime: WindowState

	init(hostRuntime: WindowState) {
		self.hostRuntime = hostRuntime
	}

	/// Non-system entries in index order, hidden included.
	func loadEntries() -> [WorkspaceIndexEntry] {
		WorkspaceManagerViewModel.loadWorkspaceIndex(from: hostRuntime.workspaceManager.workspaceIndexFileURL)
			.filter { !$0.isSystemWorkspace }
	}

	/// Writes every runtime's in-memory state to disk so a wholesale reload reverts nothing.
	func flushAll(runtimes: [WindowState]) async {
		await hostRuntime.workspaceManager.pollAndSaveStateAsync()
		for runtime in runtimes {
			await runtime.workspaceManager.pollAndSaveStateAsync()
		}
	}

	func rename(id: UUID, name: String, runtime: WindowState, runtimes: [WindowState]) async throws {
		await flushAll(runtimes: runtimes)
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw WorkspaceShellError.emptyName }
		let entries = loadEntries()
		guard let model = runtime.workspaceManager.workspaces.first(where: { $0.id == id }) else {
			throw WorkspaceShellError.unknownWorkspace(id)
		}
		if entries.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
			throw WorkspaceShellError.duplicateName(trimmed)
		}
		await runtime.workspaceManager.renameWorkspaceAsync(model, newName: trimmed)
		await reloadOthers(except: runtime, runtimes: runtimes)
	}

	func reorder(ids: [UUID], runtimes: [WindowState]) async throws {
		await flushAll(runtimes: runtimes)
		let catalogIDs = loadEntries().map(\.id)
		guard WorkspaceOrdering.isPermutation(ids, of: catalogIDs) else {
			throw WorkspaceShellError.invalidOrder("expected a permutation of \(catalogIDs.count) workspace ids")
		}
		await hostRuntime.workspaceManager.reorderWorkspaces(ids: ids)
		await reloadOthers(except: hostRuntime, runtimes: runtimes)
	}

	/// Creates the document on `runtime` (a fresh shell runtime with no active workspace) and switches it there.
	func create(name: String, folderPath: String?, runtime: WindowState, runtimes: [WindowState]) async throws -> WorkspaceModel {
		await flushAll(runtimes: runtimes)
		let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { throw WorkspaceShellError.emptyName }
		if loadEntries().contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
			throw WorkspaceShellError.duplicateName(trimmed)
		}
		let repoPaths = folderPath.map { [($0 as NSString).expandingTildeInPath] } ?? []
		let created = await runtime.workspaceManager.createWorkspaceAsync(name: trimmed, repoPaths: repoPaths)
		_ = await runtime.workspaceManager.requestWorkspaceSwitch(to: created, saveState: false, reason: "shellPreparation", origin: .shell)
		await reloadOthers(except: runtime, runtimes: runtimes)
		return created
	}

	/// Deletes the catalog entry and document folder through the runtime that holds the freshest copy.
	func remove(id: UUID, runtime: WindowState, runtimes: [WindowState]) async throws {
		await flushAll(runtimes: runtimes)
		guard let model = runtime.workspaceManager.workspaces.first(where: { $0.id == id }) else {
			throw WorkspaceShellError.unknownWorkspace(id)
		}
		await runtime.workspaceManager.deleteWorkspaceAsync(model)
		await reloadOthers(except: runtime, runtimes: runtimes)
	}

	func reloadOthers(except writer: WindowState, runtimes: [WindowState]) async {
		if hostRuntime !== writer {
			await hostRuntime.workspaceManager.reloadWorkspacesFromDiskAsync()
		}
		for runtime in runtimes where runtime !== writer {
			await runtime.workspaceManager.reloadWorkspacesFromDiskAsync()
		}
	}
}
