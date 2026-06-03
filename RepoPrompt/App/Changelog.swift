//
//  Changelog.swift
import SwiftUI
import Foundation
import AppKit

class VersionManager: ObservableObject {
	private static let transitionNoticeDismissedKey = "transitionNoticeDismissed"

	static let claimsPortalURL = URL(string: "https://repoprompt.com/claim")!
	static let transitionBlogPostURL = URL(string: "https://repoprompt.com/blog/repo-prompt-next-chapter/")!
	static let websiteChangelogURL = URL(string: "https://repoprompt.com/docs#s=changelog")!

	@Published private(set) var shouldShowTransitionNotice: Bool

	init() {
		if AppLaunchConfiguration.current.suppressesNonessentialLaunchSideEffects {
			shouldShowTransitionNotice = false
		} else {
			let dismissed = UserDefaults.standard.bool(forKey: Self.transitionNoticeDismissedKey)
			shouldShowTransitionNotice = !dismissed
		}
	}

	func dismissTransitionNotice() {
		UserDefaults.standard.set(true, forKey: Self.transitionNoticeDismissedKey)
		shouldShowTransitionNotice = false
	}

	func openWebsiteChangelog() {
		NSWorkspace.shared.open(Self.websiteChangelogURL)
	}

	func showChangelog() {
		openWebsiteChangelog()
	}
}

struct TransitionNoticeView: View {
	let onDismiss: () -> Void

	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	var body: some View {
		VStack(alignment: .leading, spacing: 18) {
			header

			ScrollView {
				VStack(alignment: .leading, spacing: 18) {
					headline
					leadParagraph
					bridgeParagraph
					claimsCard
					communityParagraph
					thanksParagraph
					secondaryLinks
				}
				.frame(maxWidth: .infinity, alignment: .leading)
				.padding(20)
			}
			.background(Color.secondary.opacity(0.06))
			.clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

			footer
		}
		.padding(20)
		.frame(
			width: fontPreset.scaledClamped(600, max: 760),
			height: fontPreset.scaledClamped(520, max: 680)
		)
		.background(Color(NSColor.windowBackgroundColor))
	}

	// MARK: - Header

	private var header: some View {
		HStack(alignment: .center, spacing: 10) {
			Image(systemName: "megaphone.fill")
				.font(.system(size: 22))
				.foregroundStyle(.blue)

			Text("An update from Repo Prompt")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 16, weight: .semibold))
				.foregroundStyle(.secondary)

			Spacer()

			Button(action: onDismiss) {
				Image(systemName: "xmark.circle.fill")
					.font(.system(size: 20))
					.foregroundStyle(.secondary)
			}
			.buttonStyle(.plain)
			.accessibilityLabel("Dismiss transition notice")
		}
	}

	// MARK: - Body sections

	private var headline: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Repo Prompt is now free")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 26, weight: .bold))

			Text("Licensing is off, all subscriptions have been cancelled, and no subscription is required.")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 14, weight: .regular))
				.foregroundStyle(.secondary)
				.lineSpacing(3)
		}
	}

	private var leadParagraph: some View {
		Text("Eric here. For the last two years, I've been working on my own to realize my vision for what AI coding tools could be. What started as a copy-pasting utility has transformed into a multi-agent orchestration tool, and the time has come for a new chapter.")
			.lineSpacing(4)
			.fixedSize(horizontal: false, vertical: true)
	}

	private var bridgeParagraph: some View {
		Text("Before stepping into that next chapter, I wanted to make sure every Repo Prompt user was taken care of. The app you have today is yours to keep: free, unlocked, and with no subscription required.")
			.lineSpacing(4)
			.fixedSize(horizontal: false, vertical: true)
	}

	private var claimsCard: some View {
		VStack(alignment: .leading, spacing: 12) {
			HStack(alignment: .firstTextBaseline, spacing: 8) {
				Image(systemName: "envelope.badge.fill")
					.foregroundStyle(.blue)
				Text("Annual, lifetime, or supporter?")
					.font(fontPreset.swiftUIFont(sizeAtNormal: 16, weight: .semibold))
			}

			Text("As a token of my appreciation, open the claims portal so I can take care of you. The same form also lets you add your GitHub handle for Community Edition contributor access.")
				.lineSpacing(4)
				.fixedSize(horizontal: false, vertical: true)

			HStack(spacing: 10) {
				Link(destination: VersionManager.claimsPortalURL) {
					HStack(spacing: 6) {
						Image(systemName: "arrow.up.right.square.fill")
						Text("Open the claims portal")
							.fontWeight(.semibold)
					}
				}
				.buttonStyle(PrimaryClaimsButtonStyle())

				Text(VersionManager.claimsPortalURL.absoluteString)
					.font(fontPreset.swiftUIFont(sizeAtNormal: 12, weight: .regular))
					.foregroundStyle(.secondary)
					.textSelection(.enabled)
					.lineLimit(1)
					.truncationMode(.middle)
			}
		}
		.padding(16)
		.frame(maxWidth: .infinity, alignment: .leading)
		.background(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.fill(Color.blue.opacity(0.10))
		)
		.overlay(
			RoundedRectangle(cornerRadius: 12, style: .continuous)
				.stroke(Color.blue.opacity(0.35), lineWidth: 1)
		)
	}

	private var communityParagraph: some View {
		VStack(alignment: .leading, spacing: 6) {
			Text("Repo Prompt Community Edition is coming")
				.font(fontPreset.swiftUIFont(sizeAtNormal: 15, weight: .semibold))

			Text("On top of making the app free, I want to give the project to the community in open source, so Repo Prompt can keep growing well beyond what one developer can ship alone.")
				.lineSpacing(4)
				.fixedSize(horizontal: false, vertical: true)
		}
	}

	private var thanksParagraph: some View {
		Text("Never in my wildest dreams would I have expected Repo Prompt to reach as many people as it did. You were a huge part of making it possible. Thank you for making Repo Prompt possible. I hope you'll be part of its next chapter.")
			.lineSpacing(4)
			.foregroundStyle(.primary)
			.fixedSize(horizontal: false, vertical: true)
	}

	private var secondaryLinks: some View {
		HStack(spacing: 10) {
			Link(destination: VersionManager.transitionBlogPostURL) {
				Label("Read the transition post", systemImage: "doc.text")
			}
			.buttonStyle(CustomButtonStyle())

			Spacer()
		}
	}

	// MARK: - Footer

	private var footer: some View {
		HStack(spacing: 12) {
			Spacer()

			Button("Got it", action: onDismiss)
				.buttonStyle(CustomButtonStyle(verticalPadding: 6, horizontalPadding: 14))
				.keyboardShortcut(.defaultAction)
				.accessibilityLabel("Dismiss transition notice")
		}
	}
}

// MARK: - Primary claims button style
//
// SEARCH-HELPER: Transition Notice, Claims Portal, Primary Button
// Used only by `TransitionNoticeView` to keep the claims portal action the
// most prominent control in the modal. Intentionally heavier than
// `CustomButtonStyle` so users can spot it at a glance.
private struct PrimaryClaimsButtonStyle: ButtonStyle {
	@Environment(\.isEnabled) private var isEnabled

	func makeBody(configuration: Configuration) -> some View {
		let cornerRadius = ButtonScale.pillCornerRadius()
		HoverableButton(configuration: configuration) { hovering in
			configuration.label
				.lineLimit(1)
				.padding(.vertical, ButtonScale.metric(8))
				.padding(.horizontal, ButtonScale.metric(16))
				.foregroundStyle(.white)
				.background(
					RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
						.fill(background(isPressed: configuration.isPressed, isHovering: hovering))
				)
				.overlay(
					RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
						.stroke(Color.white.opacity(0.15), lineWidth: 0.5)
				)
				.scaleEffect(configuration.isPressed ? 0.98 : 1.0)
				.animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
		}
		.opacity(isEnabled ? 1.0 : 0.5)
	}

	private func background(isPressed: Bool, isHovering: Bool) -> Color {
		if isPressed {
			return Color.blue.opacity(0.85)
		} else if isHovering {
			return Color.blue.opacity(0.95)
		} else {
			return Color.blue
		}
	}
}
