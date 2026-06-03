//
//  GlassSummaryView.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2024-07-23.
//

import SwiftUI
import AppKit

struct HeightPreferenceKey: PreferenceKey {
	static var defaultValue: CGFloat = 0
	static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
		value = max(value, nextValue())
	}
}

struct GlassSummaryView: View {
	let summary: String
	@Binding var isVisible: Bool
	@State private var viewHeight: CGFloat = 0
	
	var body: some View {
		GeometryReader { geometry in
			VStack {
				Text("Change Summary")
					.font(.headline)
					.foregroundColor(.white)
					.padding(.bottom, 4)
				ScrollView {
					Text(summary)
						.font(.body)
						.foregroundColor(.white)
						.fixedSize(horizontal: false, vertical: true)
						.background(GeometryReader { textGeometry in
							Color.clear.preference(key: HeightPreferenceKey.self, value: textGeometry.size.height)
						})
				}
			}
			.padding()
			.frame(width: min(325, geometry.size.width), height: min(viewHeight + 60, 150))
			.background(
				ZStack {
					// Base layer
					Color.white.opacity(0.15)
					
					// Blurred layer
					Color.black.opacity(0.5)
						.blur(radius: 30)
					
					// Noise overlay
					Image("noise") // Make sure to add a noise texture to your assets
						.resizable()
						.aspectRatio(contentMode: .fill)
						.blendMode(.overlay)
						.opacity(0.1)
					
					// Light gradient
					LinearGradient(
						gradient: Gradient(colors: [
							Color.white.opacity(0.2),
							Color.white.opacity(0.05)
						]),
						startPoint: .topLeading,
						endPoint: .bottomTrailing
					)
				}
			)
			.clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
			.overlay(
				RoundedRectangle(cornerRadius: 20, style: .continuous)
					.stroke(Color.white.opacity(0.2), lineWidth: 1)
			)
			.overlay(
				// Inner shadow for depth
				RoundedRectangle(cornerRadius: 20, style: .continuous)
					.stroke(Color.white.opacity(0.2), lineWidth: 1)
					.blur(radius: 4)
					.offset(x: 0, y: 2)
					.mask(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(LinearGradient(gradient: Gradient(colors: [Color.black, Color.clear]), startPoint: .top, endPoint: .bottom)))
			)
			.shadow(color: Color.black.opacity(0.2), radius: 15, x: 0, y: 5)
			.frame(maxWidth: .infinity, alignment: .center) // This ensures center alignment
		}
		.frame(height: min(viewHeight + 60, 150)) // Constrain the overall height
		.onPreferenceChange(HeightPreferenceKey.self) { height in
			let scale = NSScreen.main?.backingScaleFactor ?? 2
			let epsilon = 1.0 / scale
			let clampedHeight = max(0, height)
			if abs(clampedHeight - viewHeight) > epsilon {
				viewHeight = clampedHeight
			}
		}
	}
}
