//
//  ChatMessagesViewController.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-30.
//


import AppKit
import Combine

/// Experimental App-Kit-native controller that mirrors the functionality
/// of the SwiftUI `ChatMessagesView`.  It is **not** wired into the
/// window hierarchy yet – embed it where appropriate during the redesign.
final class ChatMessagesViewController: NSViewController {

    // MARK: – Public
    
    /// The shared view-model; inject from outside.
    var viewModel: ChatViewModel! {
        didSet { bindToViewModel() }
    }

    // MARK: – Private UI

    private let scrollView  = NSScrollView()
    private let stackView   = NSStackView()

    /// Auto-scroll control (default = true while streaming)
    private var autoScrollEnabled = true
    /// Tracks whether the bottom sentinel is visible
    private var isNearBottom = false
    /// Overlay button (arrow / play / pause)
    private let bottomButton = NSButton()
    /// Debounce helper to avoid double scrolls
    private let scrollWorkGate = WorkItemGate()

    // MARK: – Combine

    private var cancellables = Set<AnyCancellable>()

    // MARK: – Life-cycle

    override func loadView() {
        // Configure root view
        view = NSView()
        view.wantsLayer = true

        // Configure scroll view
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        // Full-size constraints
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        // Configure stack view
        stackView.orientation = .vertical
        stackView.alignment   = .leading
        stackView.spacing     = 12
        stackView.translatesAutoresizingMaskIntoConstraints = false

        // Embed stack in a clip view
        let clip = NSClipView()
        clip.documentView = stackView
        clip.postsBoundsChangedNotifications = true
        scrollView.contentView = clip
        
        // Now that the contentView is final, attach the observer
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: clip)

        // --- Bottom button ---
        bottomButton.bezelStyle = .shadowlessSquare
        bottomButton.isBordered = false
        bottomButton.target = self
        bottomButton.action = #selector(handleBottomButtonClick(_:))
        bottomButton.isHidden = true
        bottomButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomButton)

        // Constraints bottom-right
        NSLayoutConstraint.activate([
            bottomButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            bottomButton.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            bottomButton.widthAnchor.constraint(equalToConstant: 30),
            bottomButton.heightAnchor.constraint(equalTo: bottomButton.widthAnchor)
        ])
    }

    // MARK: – Binding

    private func bindToViewModel() {
        // Reset old
        cancellables.removeAll()

        // Listen to message list
        viewModel.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildStack()
            }
            .store(in: &cancellables)

        viewModel.$streamingSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let inProgress = self.viewModel.isSessionStreaming(self.viewModel.currentSessionID)
                if inProgress {
                    self.autoScrollEnabled = true
                    self.scrollToBottom(animated: false)
                } else {
                    self.autoScrollEnabled = false
                }
                self.updateBottomButtonIcon()
                self.updateBottomButtonVisibility()
            }
            .store(in: &cancellables)

        viewModel.$currentSessionID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.rebuildStack(chatChanged: true)
                self.autoScrollEnabled = self.viewModel.isSessionStreaming(self.viewModel.currentSessionID)
                self.updateBottomButtonIcon()
                self.updateBottomButtonVisibility()
            }
            .store(in: &cancellables)
    }

    // MARK: – Stack maintenance

    private func rebuildStack(chatChanged: Bool = false) {
        // Map existing message views by their identifiers
        let existing = stackView.arrangedSubviews.compactMap { $0 as? ChatMessageItemView }
        var viewsById: [UUID: ChatMessageItemView] = [:]
        existing.forEach { viewsById[$0.messageId] = $0 }

        // Track which ids are still present after diffing
        var usedIds = Set<UUID>()

        // Insert or reuse views in the correct order
        for (index, msg) in viewModel.messages.enumerated() {
            let id = msg.id
            usedIds.insert(id)

            if let view = viewsById[id] {
                // Move existing view if its index changed
                if stackView.arrangedSubviews.indices.contains(index) {
                    if stackView.arrangedSubviews[index] !== view {
                        stackView.insertArrangedSubview(view, at: index)
                    }
                } else {
                    stackView.addArrangedSubview(view)
                }
            } else {
                // Create and insert a new view for the message
                let item = ChatMessageItemView(message: msg, viewModel: viewModel)
                stackView.insertArrangedSubview(item, at: index)
                // Pin to stack edges (safer than width equality with NSStackView)
                item.leadingAnchor.constraint(equalTo: stackView.leadingAnchor).isActive = true
                item.trailingAnchor.constraint(equalTo: stackView.trailingAnchor).isActive = true
            }
        }

        // Remove any views whose messages disappeared
        for view in existing where !usedIds.contains(view.messageId) {
            stackView.removeArrangedSubview(view)
            view.removeFromSuperview()
        }

        // Scroll handling
        if autoScrollEnabled || chatChanged {
            scrollToBottom(animated: !chatChanged)
        }

        updateBottomButtonVisibility()
    }

    // MARK: – Auto-scroll helpers
    private func scrollToBottom(animated: Bool) {
        guard let doc = scrollView.documentView else { return }
        let maxY = max(0, doc.bounds.height - scrollView.contentView.bounds.height)
        let target = NSPoint(x: 0, y: maxY)

        scrollWorkGate.cancel()
        let work = scrollWorkGate.makeWorkItem { [weak self] in
            self?.scrollView.contentView.scroll(to: target)
            self?.scrollView.reflectScrolledClipView(self?.scrollView.contentView ?? NSClipView())
        }
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: work)
        } else {
            work.perform()
        }
    }

    @objc private func contentViewBoundsDidChange(_ note: Notification) {
        // Detect proximity to bottom (≤ 60 pt)
        guard let doc = scrollView.documentView else { return }
        let maxY = doc.bounds.height - scrollView.contentView.bounds.height
        let delta = maxY - scrollView.contentView.bounds.origin.y
        let wasNear = isNearBottom
        isNearBottom = delta <= 60
        if wasNear != isNearBottom { updateBottomButtonVisibility() }

        // User interaction disables auto-scroll
        if !isNearBottom && autoScrollEnabled {
            autoScrollEnabled = false
            updateBottomButtonIcon()
        }
    }

    // MARK: – Bottom button
    @objc private func handleBottomButtonClick(_ sender: Any) {
        if viewModel.isSessionStreaming(viewModel.currentSessionID) {
            autoScrollEnabled.toggle()
            updateBottomButtonIcon()
        } else {
            scrollToBottom(animated: true)
        }
        updateBottomButtonVisibility()
    }

    private func updateBottomButtonVisibility() {
        let shouldShow = viewModel?.isSessionStreaming(viewModel?.currentSessionID) == true || !isNearBottom
        bottomButton.isHidden = !shouldShow
    }

    private func updateBottomButtonIcon() {
        let name: String
        if autoScrollEnabled {
            name = "pause.circle.fill"
        } else if viewModel?.isSessionStreaming(viewModel?.currentSessionID) == true {
            name = "play.circle.fill"
        } else {
            name = "arrow.down.circle.fill"
        }
        bottomButton.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
