//
//  ErrorView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-07-07.
//

import Foundation
import SwiftUI

struct ErrorView: View {
	let message: String
	
	var body: some View {
		Text(message)
			.foregroundColor(.red)
			.font(.caption)
	}
}
