//
//  FilesTabSelector.swift
//  RepoPrompt
//
//  Tab selector extracted from TabbedFileSelectionView
//

import SwiftUI

// Tab options for file selection view
enum FilesTab: String, CaseIterable, Codable {
	case selected = "Selected Files"
	case context = "Context Builder"
	case apply = "Apply XML"
}

extension FilesTab {
	static var defaultTab: FilesTab { .context }
}

struct FilesTabSelector: View {
	@Binding var selectedTab: FilesTab
	let fileCount: Int
	let codemapCount: Int
	@State private var hoveringTab: FilesTab?

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	private var scaleFactor: CGFloat {
		fontPreset.scaleFactor
	}
    
	/*
    private var tabBackgroundColor: Color {
        isDarkMode() ? Color(NSColor.windowBackgroundColor) : Color(white: 0.85)
    }
	*/
    
    private var borderColor: Color {
        isDarkMode() ? Color.gray.opacity(0.5) : Color(NSColor.systemGray)
    }
    
    func isDarkMode() -> Bool {
		/*
        if (!isTransparent()) {
            return true
        }
		*/
        let appearance = NSApp.effectiveAppearance
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
    
	/*
    func isTransparent() -> Bool {
        let useTransparency = UserDefaults.standard.object(forKey: "useTransparency") as? Bool ?? true
        return useTransparency
    }
	*/
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(FilesTab.allCases.enumerated()), id: \.element) { index, tab in
                tabButton(for: tab, isFirst: index == 0)
            }
            Spacer()
        }
        .frame(height: 38)
        .zIndex(1)
    }
    
    private func tabButton(for tab: FilesTab, isFirst: Bool) -> some View {
        let isSelected = selectedTab == tab
        let tabHeight: CGFloat = 38
		let iconName = tabIconName(for: tab)
        
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedTab = tab
            }
        }) {
            HStack(spacing: 6) {
				TabLeadingView(
					tab: tab,
					isSelected: isSelected,
					fileCount: fileCount,
					codemapCount: codemapCount,
					iconName: iconName
				)
                //.frame(width: tab == .selected ? (codemapCount > 0 ? 52 : 40) : 22)
                
                Text(tab.rawValue)
                    .font(.headline)
            }
            .foregroundColor(isSelected ? .primary : .secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(height: tabHeight)
            .background(
				TabBackgroundView(isSelected: isSelected)
            )
            .overlay(
				TabOverlayView(isSelected: isSelected, borderColor: borderColor)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in
            hoveringTab = hovering ? tab : nil
        }
        .animation(.easeInOut(duration: 0.2), value: isSelected)
    }
    
    private func tabIconName(for tab: FilesTab) -> String? {
        switch tab {
        case .selected: return nil
        case .context: return "sparkles"
        case .apply: return "arrow.triangle.branch"
        }
    }
}

// MARK: - Extracted Subviews

private struct TabLeadingView: View {
	let tab: FilesTab
	let isSelected: Bool
	let fileCount: Int
	let codemapCount: Int
	let iconName: String?
	
	var body: some View {
		ZStack(alignment: .center) {
			if tab == .selected {
				HStack(spacing: 4) {
					Text("\(fileCount)")
						.font(.system(size: 12, weight: .medium))
					
					if codemapCount > 0 {
						Text("|")
							.font(.system(size: 12, weight: .light))
							.foregroundColor(.secondary.opacity(0.5))
						
						Text("\(codemapCount)")
							.font(.system(size: 12, weight: .medium))
							.foregroundColor(.blue)
					}
				}
				.minimumScaleFactor(0.8)
				.lineLimit(1)
				.frame(minWidth: codemapCount > 0 ? 48 : 36)
				.padding(.horizontal, codemapCount > 0 ? 8 : 6)
				.padding(.vertical, 1)
				.background(
					RoundedRectangle(cornerRadius: 16)
						.fill(isSelected ? Color.primary.opacity(0.2) : Color.secondary.opacity(0.15))
				)
				.overlay(
					RoundedRectangle(cornerRadius: 16)
						.stroke(isSelected ? Color.primary.opacity(0.3) : Color.secondary.opacity(0.2), lineWidth: 0.5)
				)
				.foregroundColor(isSelected ? .primary : .secondary)
			} else if let iconName = iconName {
				Image(systemName: iconName)
					.font(.system(size: 14))
			}
		}
	}
}

private struct TabBackgroundView: View {
	let isSelected: Bool
	
	var body: some View {
		ZStack(alignment: .bottom) {
			if isSelected {
				RoundedCorner(radius: 16, corners: [.topLeft, .topRight])
					.fill(.regularMaterial)
			} else {
				RoundedCorner(radius: 16, corners: [.topLeft, .topRight])
					.fill(Color.clear)
			}
			if isSelected {
				Rectangle()
					.fill(.regularMaterial)
					.frame(height: 2)
					.offset(y: 1)
			}
		}
	}
}

private struct TabOverlayView: View {
	let isSelected: Bool
	let borderColor: Color
	
	var body: some View {
		Group {
			if isSelected {
				SelectedTabBorder(corners: [.topLeft, .topRight])
					.stroke(borderColor, lineWidth: 0.5)
			} else {
				NonSelectedTabBorder(radius: 16, corners: [.topLeft, .topRight])
					.stroke(borderColor, lineWidth: 0.5)
			}
		}
	}
}
