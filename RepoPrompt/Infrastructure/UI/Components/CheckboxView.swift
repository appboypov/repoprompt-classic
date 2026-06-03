import SwiftUI

struct CheckboxView: View {
	let isChecked: CheckboxState
	let action: () -> Void
	@State private var isHovering = false
	
	// Precomputed shapes
	private let backgroundShape = RoundedRectangle(cornerRadius: 4)
		.fill(Color.secondary.opacity(0.2))
	/*
	private static let borderShape = RoundedRectangle(cornerRadius: 4)
		.stroke(Color.secondary.opacity(0.5), lineWidth: 1)
	 */
	
	var body: some View {
		Button(action: action) {
			Image(systemName: checkboxImageName)
				.foregroundColor(checkboxColor)
				.frame(width: 20, height: 20)
				.background(isHovering ? backgroundShape : nil)
				//.overlay(isHovering ? Self.borderShape : nil)
		}
		.buttonStyle(PlainButtonStyle())
		.onHover { hovering in
			isHovering = hovering
		}
	}
	
	private var checkboxImageName: String {
		switch isChecked {
		case .checked:
			return "checkmark.square"
		case .unchecked:
			return "square"
		case .mixed:
			return "minus.square"
		}
	}
	
	private var checkboxColor: Color {
		switch isChecked {
		case .checked, .mixed:
			return .accentColor
		case .unchecked:
			return isHovering ? .primary : .secondary
		}
	}
}
