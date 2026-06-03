import SwiftUI

/// A lightweight, viewport-fixed heads-up panel for selection actions.
/// Intended to be used as an overlay in FilePreviewView, e.g.:
/// .overlay(alignment: .topTrailing) { SelectionHUDView(...) }
struct SelectionHUDView: View {
    let selectedCount: Int
    let linePreview: String?
    let onCopy: () -> Void
    let onClear: () -> Void
    @ObservedObject private var fontScale = FontScaleManager.shared
    private var fontPreset: FontScalePreset { fontScale.preset }
    
    private var selectionLabel: String {
        selectedCount == 1 ? "1 line selected" : "\(selectedCount) lines selected"
    }
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "highlighter")
                .imageScale(.medium)
                .foregroundColor(.primary)
            
            VStack(alignment: .leading, spacing: 2) {
                // Reserve width for the count label (prevents layout jump)
                ZStack(alignment: .leading) {
                    Text("999 lines selected")
                        .font(fontPreset.captionFont)
                        .monospacedDigit()
                        .foregroundColor(.clear) // occupy layout width only
                        .accessibilityHidden(true)
                    Text(selectionLabel)
                        .font(fontPreset.captionFont)
                        .monospacedDigit()
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                
                if let preview = linePreview, !preview.isEmpty {
                    Text(preview)
                        .font(fontPreset.swiftUIFont(sizeAtNormal: 11))
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            
            Divider()
                .frame(height: 14)
            
            Button(action: onCopy) {
                Label("Copy", systemImage: "doc.on.doc")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(CustomButtonStyle(verticalPadding: 3, horizontalPadding: 8, height: 24))
            .controlSize(.small)
            .keyboardShortcut("c", modifiers: .command)
            
            Button(action: onClear) {
                Label("Clear", systemImage: "xmark")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(CustomButtonStyle(verticalPadding: 3, horizontalPadding: 8, height: 24))
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .shadow(color: Color.black.opacity(0.12), radius: 6, x: 0, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selection actions")
        .accessibilityHint("Copy selected lines or clear the current selection")
    }
}

#if DEBUG
struct SelectionHUDView_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color(NSColor.windowBackgroundColor)
                .ignoresSafeArea()
            SelectionHUDView(
                selectedCount: 7,
                linePreview: "12–18, 21, 30–32",
                onCopy: {},
                onClear: {}
            )
            .padding()
        }
        .frame(width: 480, height: 240)
    }
}
#endif