import SwiftUI
import AppKit
import SwiftTreeSitter

struct FilePreviewOverlay: View {
	@Binding var isVisible: Bool
	@Binding var selectedFile: FileViewModel?
	
	@State private var content: String = "Loading..."
	@State private var highlightRanges: [NamedRange]? = nil
	
	var body: some View {
		ZStack {
			Color.black.opacity(0.3)
				.edgesIgnoringSafeArea(.all)
				.onTapGesture {
					isVisible = false
					selectedFile = nil
				}
			
			VStack(spacing: 0) {
				HStack {
					Text(selectedFile?.name ?? "")
						.font(.headline)
					Spacer()
					Button(action: {
						isVisible = false
						selectedFile = nil
					}) {
						Image(systemName: "xmark.circle.fill")
							.foregroundColor(.secondary)
					}
					.buttonStyle(PlainButtonStyle())
				}
				.padding()
				
				if content != "Loading..." {
					FilePreviewContent(
						content: content,
						highlightRanges: highlightRanges
					)
				} else {
					ProgressView()
						.frame(maxWidth: .infinity, maxHeight: .infinity)
				}
			}
			.frame(maxWidth: .infinity, maxHeight: .infinity)
			.background(Color(NSColor.windowBackgroundColor))
			.cornerRadius(10)
			.padding(5)
			.onAppear {
				if let file = selectedFile {
					Task {
						let loadedContent = await file.latestContent ?? "Error loading file content"
						let tokens = await file.latestNamedRanges
						await MainActor.run {
							self.content = loadedContent
							self.highlightRanges = tokens
						}
					}
				}
			}
		}
	}
}

struct FilePreviewContent: View {
	let content: String
	/// Instead of exposing cached tokens, we pass the highlight tokens loaded via the async getter.
	let highlightRanges: [NamedRange]?
	
	var body: some View {
		HighlightedTextKitView(
			text: .constant(content),
			highlightRanges: highlightRanges ?? [],
			isEditable: false
		)
		.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
		.foregroundColor(.blue)
	}
}
