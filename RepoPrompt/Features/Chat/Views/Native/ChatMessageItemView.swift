//
//  ChatMessageItemView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-30.
//


import AppKit
import Combine

/// Extremely lightweight visual representation of a single chat message.
/// Replace with richer markdown / code views as the redesign progresses.
final class ChatMessageItemView: NSView {

    // MARK: – Init
    
    private var bubbleView: ChatBubbleView
    let messageId: UUID
    private var msgSubscription: AnyCancellable?

    init(message: AIChatMessage, viewModel: ChatViewModel) {
        self.messageId  = message.id
        self.bubbleView = ChatBubbleView(message: message, viewModel: viewModel)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        addSubview(bubbleView)
        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor),
            bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor),
            bubbleView.topAnchor.constraint(equalTo: topAnchor),
            bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        // Subscribe to message updates so the view stays in sync.
        msgSubscription = viewModel.$messages
            .receive(on: RunLoop.main)
            .sink { [weak self, weak viewModel] msgs in
                guard let self,
                      let vm = viewModel,
                      let updated = msgs.first(where: { $0.id == self.messageId })
                else { return }
                self.refreshBubble(with: updated, viewModel: vm)
            }
    }
    
    required init?(coder: NSCoder) { nil }

    private func refreshBubble(with msg: AIChatMessage, viewModel: ChatViewModel) {
        // Cheap diff: if content unchanged skip.
        guard msg.combinedText != bubbleView.message.combinedText else { return }

        // Remove old bubble
        bubbleView.removeFromSuperview()

        // Create a new bubble and attach
        let newBubble = ChatBubbleView(message: msg, viewModel: viewModel)
        bubbleView = newBubble
        addSubview(newBubble)
        newBubble.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            newBubble.leadingAnchor.constraint(equalTo: leadingAnchor),
            newBubble.trailingAnchor.constraint(equalTo: trailingAnchor),
            newBubble.topAnchor.constraint(equalTo: topAnchor),
            newBubble.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    deinit {
        msgSubscription?.cancel()
    }
}