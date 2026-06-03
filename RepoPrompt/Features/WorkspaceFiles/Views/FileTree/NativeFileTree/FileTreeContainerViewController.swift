import Cocoa
import Combine

@MainActor
final class FileTreeContainerViewController: NSViewController {
	private struct SearchStatus {
		var showSearching = false
		var showNoResults = false
	}

	private let fileTreeController = FileTreeViewController()
	private let searchController = SearchFileTreeViewController()
	private let searchStatusContainer = NSView()
	private let searchingStack = NSStackView()
	private let searchingIndicator = NSProgressIndicator()
	private let searchingLabel = NSTextField(labelWithString: "Searching...")
	private let noResultsLabel = NSTextField(labelWithString: "No results found")
	private var searchCancellables = Set<AnyCancellable>()
	private var lastSearchStatus = SearchStatus()
	private var isSearchActive = false

	var windowID: Int = 0 {
		didSet {
			fileTreeController.windowID = windowID
		}
	}

	var fileManager: RepoFileManagerViewModel? {
		didSet {
			guard oldValue !== fileManager else { return }
			if let fileManager {
				fileTreeController.fileManager = fileManager
				if fileTreeController.isViewLoaded {
					fileTreeController.setupBindings()
				}
			} else {
				fileTreeController.cleanupBindings()
			}
		}
	}

	var workspaceManager: WorkspaceManagerViewModel? {
		didSet {
			fileTreeController.workspaceManager = workspaceManager
		}
	}

	var searchViewModel: SearchFileTreeViewModel? {
		didSet {
			guard oldValue !== searchViewModel else { return }
			searchController.searchViewModel = searchViewModel
			bindSearchViewModel()
		}
	}

	override func loadView() {
		let container = NSView()
		container.wantsLayer = true
		container.layer?.backgroundColor = NSColor.clear.cgColor
		view = container

		addChild(fileTreeController)
		addChild(searchController)

		let fileTreeView = fileTreeController.view
		let searchView = searchController.view
		fileTreeView.translatesAutoresizingMaskIntoConstraints = false
		searchView.translatesAutoresizingMaskIntoConstraints = false

		container.addSubview(fileTreeView)
		container.addSubview(searchView)

		NSLayoutConstraint.activate([
			fileTreeView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			fileTreeView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			fileTreeView.topAnchor.constraint(equalTo: container.topAnchor),
			fileTreeView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
			searchView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			searchView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			searchView.topAnchor.constraint(equalTo: container.topAnchor),
			searchView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
		])

		configureSearchStatusOverlay(above: searchView, in: container)
	}

	override func viewDidLoad() {
		super.viewDidLoad()
		updateVisibleTree()
		applySearchStatus()
	}

	func cleanupBindings() {
		fileTreeController.cleanupBindings()
		searchController.cleanupBindings()
		searchCancellables.removeAll()
	}

	private func configureSearchStatusOverlay(above searchView: NSView, in container: NSView) {
		searchStatusContainer.translatesAutoresizingMaskIntoConstraints = false
		searchStatusContainer.wantsLayer = true
		searchStatusContainer.layer?.backgroundColor = NSColor.clear.cgColor

		searchingIndicator.style = .spinning
		searchingIndicator.controlSize = .regular
		searchingIndicator.isDisplayedWhenStopped = false
		searchingIndicator.startAnimation(nil)

		searchingLabel.font = .systemFont(ofSize: 14, weight: .medium)
		searchingLabel.textColor = .secondaryLabelColor
		searchingLabel.alignment = .center

		searchingStack.orientation = .vertical
		searchingStack.alignment = .centerX
		searchingStack.spacing = 8
		searchingStack.translatesAutoresizingMaskIntoConstraints = false
		searchingStack.addArrangedSubview(searchingIndicator)
		searchingStack.addArrangedSubview(searchingLabel)

		noResultsLabel.font = .systemFont(ofSize: 16, weight: .medium)
		noResultsLabel.textColor = .secondaryLabelColor
		noResultsLabel.alignment = .center
		noResultsLabel.translatesAutoresizingMaskIntoConstraints = false

		searchStatusContainer.addSubview(searchingStack)
		searchStatusContainer.addSubview(noResultsLabel)
		container.addSubview(searchStatusContainer, positioned: .above, relativeTo: searchView)

		NSLayoutConstraint.activate([
			searchStatusContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			searchStatusContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			searchStatusContainer.topAnchor.constraint(equalTo: container.topAnchor),
			searchStatusContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
			searchingStack.centerXAnchor.constraint(equalTo: searchStatusContainer.centerXAnchor),
			searchingStack.centerYAnchor.constraint(equalTo: searchStatusContainer.centerYAnchor),
			noResultsLabel.centerXAnchor.constraint(equalTo: searchStatusContainer.centerXAnchor),
			noResultsLabel.centerYAnchor.constraint(equalTo: searchStatusContainer.centerYAnchor)
		])

		searchingStack.isHidden = true
		noResultsLabel.isHidden = true
		searchStatusContainer.isHidden = true
	}

	private func bindSearchViewModel() {
		searchCancellables.removeAll()
		guard let searchViewModel else {
			lastSearchStatus = SearchStatus()
			setSearchActive(false)
			applySearchStatus()
			return
		}

		setSearchActive(!searchViewModel.searchText.isEmpty)

		searchViewModel.$searchText
			.map { !$0.isEmpty }
			.removeDuplicates()
			.receive(on: DispatchQueue.main)
			.sink { [weak self] isActive in
				self?.setSearchActive(isActive)
			}
			.store(in: &searchCancellables)

		Publishers.CombineLatest4(
			searchViewModel.$isSearching,
			searchViewModel.$rootFolders,
			searchViewModel.$noResultsFound,
			searchViewModel.$hasSearchResults
		)
		.receive(on: DispatchQueue.main)
		.sink { [weak self] isSearching, rootFolders, noResultsFound, hasSearchResults in
			self?.updateSearchStatus(
				isSearching: isSearching,
				rootCount: rootFolders.count,
				noResultsFound: noResultsFound,
				hasSearchResults: hasSearchResults
			)
		}
		.store(in: &searchCancellables)
	}

	private func updateSearchStatus(isSearching: Bool, rootCount: Int, noResultsFound: Bool, hasSearchResults: Bool) {
		lastSearchStatus = SearchStatus(
			showSearching: isSearching && rootCount == 0,
			showNoResults: noResultsFound && !hasSearchResults
		)
		applySearchStatus()
	}

	private func applySearchStatus() {
		guard isViewLoaded else { return }
		searchingStack.isHidden = !lastSearchStatus.showSearching
		noResultsLabel.isHidden = !lastSearchStatus.showNoResults
		let shouldShow = lastSearchStatus.showSearching || lastSearchStatus.showNoResults
		searchStatusContainer.isHidden = !isSearchActive || !shouldShow
	}

	private func updateVisibleTree() {
		guard isViewLoaded else { return }
		fileTreeController.view.isHidden = isSearchActive
		searchController.view.isHidden = !isSearchActive
		applySearchStatus()
	}

	private func setSearchActive(_ isActive: Bool) {
		guard isSearchActive != isActive else { return }
		isSearchActive = isActive
		updateVisibleTree()
	}
}
