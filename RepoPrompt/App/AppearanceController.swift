import AppKit
import Foundation

@MainActor
final class AppearanceController: ObservableObject {
	static let shared = AppearanceController()

	private var lastAppliedMode: AppearanceMode?

	func applyFromUserDefaults() {
		let rawValue = UserDefaults.standard.string(forKey: "appearanceMode") ?? AppearanceMode.system.rawValue
		apply(modeRawValue: rawValue)
	}

	func apply(modeRawValue: AppearanceMode.RawValue) {
		let mode = AppearanceMode(rawValue: modeRawValue) ?? .system
		apply(mode: mode)
	}

	func apply(mode: AppearanceMode) {
		let desiredAppearance = appearance(for: mode)
		if lastAppliedMode == mode, isAppearanceApplied(desiredAppearance) {
			return
		}

		lastAppliedMode = mode
		if !isAppearanceApplied(desiredAppearance) {
			NSApplication.shared.appearance = desiredAppearance
		}
	}

	private func appearance(for mode: AppearanceMode) -> NSAppearance? {
		switch mode {
		case .light:
			return NSAppearance(named: .aqua)
		case .dark:
			return NSAppearance(named: .darkAqua)
		case .system:
			return nil
		}
	}

	private func isAppearanceApplied(_ desiredAppearance: NSAppearance?) -> Bool {
		let currentAppearance = NSApplication.shared.appearance
		switch (desiredAppearance, currentAppearance) {
		case (nil, nil):
			return true
		case (let desired?, let current?):
			return desired.name == current.name
		default:
			return false
		}
	}
}
