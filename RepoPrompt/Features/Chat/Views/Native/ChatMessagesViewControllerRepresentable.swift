//
//  ChatMessagesViewControllerRepresentable.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-05-30.
//


//  ChatMessagesViewControllerRepresentable.swift
//  RepoPrompt
//
//  Bridges the AppKit-native ChatMessagesViewController into SwiftUI.

import SwiftUI
import AppKit

struct ChatMessagesViewControllerRepresentable: NSViewControllerRepresentable {

    @ObservedObject var viewModel: ChatViewModel

    // MARK: - NSViewControllerRepresentable

    func makeNSViewController(context: Context) -> ChatMessagesViewController {
        let controller = ChatMessagesViewController()
        controller.viewModel = viewModel
        return controller
    }

    func updateNSViewController(_ nsViewController: ChatMessagesViewController,
                                context: Context) {
        nsViewController.viewModel = viewModel
    }
}