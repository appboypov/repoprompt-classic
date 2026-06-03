//
//  ParsingStatus.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-12-14.
//

import SwiftUI

struct ParsingStatusBox: View {
	let status: DiffViewModel.ParsingStatus
	let errorMessage: String?
	let fileLoadingWarning: String?
	@State private var isErrorPopoverVisible = false
	@State private var isWarningPopoverVisible = false
	
	var body: some View {
		HStack {
			Group {
				switch status {
				case .idle:
					Image(systemName: "circle")
						.foregroundColor(.secondary)
				case .loading:
					ProgressView()
						.scaleEffect(0.7)
				case .success:
					Image(systemName: "checkmark.circle.fill")
						.foregroundColor(.green)
				case .failure:
					Image(systemName: "xmark.circle.fill")
						.foregroundColor(.red)
						.popover(isPresented: $isErrorPopoverVisible) {
							VStack(alignment: .leading, spacing: 10) {
								Text("Parsing Error")
									.font(.headline)
								Text(errorMessage ?? "Unknown error occurred during parsing.")
									.font(.body)
							}
							.padding()
							.frame(width: 300)
						}
						.onHover { isHovering in
							isErrorPopoverVisible = isHovering
						}
				}
			}
			.frame(width: 24, height: 24)
			
			if let warning = fileLoadingWarning {
				Image(systemName: "exclamationmark.triangle.fill")
					.foregroundColor(.yellow)
					.popover(isPresented: $isWarningPopoverVisible) {
						Text(warning)
							.padding()
					}
					.onHover { isHovering in
						isWarningPopoverVisible = isHovering
					}
			}
		}
	}
}

