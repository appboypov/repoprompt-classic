//
//  ModelModeSettingsView.swift
//  RepoPrompt
//
//  Model-based delegate edit settings for Pro Edit
//

import SwiftUI

struct ModelModeSettingsView: View {
	@ObservedObject var promptViewModel: PromptViewModel
	@State private var isAdvancedSettingsExpanded: Bool = false
	@ObservedObject private var fontScale = FontScaleManager.shared
	private var fontPreset: FontScalePreset { fontScale.preset }

	var body: some View {
		VStack(alignment: .leading, spacing: 16) {
			// Moderate edit model section
			VStack(alignment: .leading, spacing: 12) {
				Text("Moderate Edit Model")
					.font(fontPreset.headlineFont)
					.foregroundColor(.primary)

				editSettingRow(title: "Small files", binding: $promptViewModel.editSettingsMediumSmall)
				Text("GPT 4.1 mini or Gemini flash 2.0 recommended.")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)

				editSettingRow(title: "Large files", binding: $promptViewModel.editSettingsMediumLarge)
				Text("Deepseek v3 (03-24) or Claude Sonnet 3.5 recommended.")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
			}
			.padding()
			.background(Color(NSColor.controlBackgroundColor))
			.cornerRadius(8)
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
			)

			// Complex edit model section
			VStack(alignment: .leading, spacing: 12) {
				Text("Complex Edit Model")
					.font(fontPreset.headlineFont)
					.foregroundColor(.primary)

				editSettingRow(title: "Small files", binding: $promptViewModel.editSettingsHighSmall)
				Text("Deepseek V3 (03-24) or Gemini Flash 3.0 Preview recommended.")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)

				editSettingRow(title: "Large files", binding: $promptViewModel.editSettingsHighLarge)
				Text("Claude Sonnet 4.5 or Gemini 3.1 Pro Preview recommended.")
					.font(fontPreset.captionFont)
					.foregroundColor(.secondary)
			}
			.padding()
			.background(Color(NSColor.controlBackgroundColor))
			.cornerRadius(8)
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
			)

			// Advanced Settings
			DisclosureGroup(
				isExpanded: $isAdvancedSettingsExpanded,
				content: {
					VStack(alignment: .leading, spacing: 16) {
						// Large File Threshold
						VStack(alignment: .leading, spacing: 8) {
							HStack {
								Text("Large File Threshold")
									.font(fontPreset.subHeadlineBoldFont)
								Spacer()
								Text("\(Int(promptViewModel.largeFileThreshold)) lines")
									.font(fontPreset.font)
									.foregroundColor(.secondary)
							}

							Slider(value: $promptViewModel.largeFileThreshold, in: 100...1000, step: 50)
							Text("Files larger than this threshold will use the 'Large files' edit model.")
								.font(fontPreset.captionFont)
								.foregroundColor(.secondary)
						}

						Divider()

						// Complex file edit strategy
						VStack(alignment: .leading, spacing: 8) {
							Text("Complex File Edit Strategy")
								.font(fontPreset.subHeadlineBoldFont)

							Picker("", selection: $promptViewModel.complexEditStrategy) {
								ForEach(ComplexEditStrategy.allCases) { strategy in
									Text(strategy.rawValue).tag(strategy)
								}
							}
							.pickerStyle(SegmentedPickerStyle())
							.labelsHidden()

							Text(promptViewModel.complexEditStrategy.caption)
								.font(fontPreset.captionFont)
								.foregroundColor(.secondary)
						}

						// Change Group Size (only shown if not using single strategy)
						if promptViewModel.complexEditStrategy != .single {
							Divider()

							VStack(alignment: .leading, spacing: 8) {
								HStack {
									Text("Change Group Size")
										.font(fontPreset.subHeadlineBoldFont)
									Spacer()
									Text("\(Int(promptViewModel.delegateEditGroupSize)) changes")
										.font(fontPreset.font)
										.foregroundColor(.secondary)
								}

								Slider(value: $promptViewModel.delegateEditGroupSize, in: 3...20, step: 1)

								Text("Maximum number of individual changes combined into a single subgroup when Pro Edit splits a large edit.")
									.font(fontPreset.captionFont)
									.foregroundColor(.secondary)
							}
						}
					}
					.padding(.top, 8)
				},
				label: {
					HStack {
						Text("Advanced Settings")
							.font(fontPreset.headlineFont)
							.foregroundColor(.primary)
						Spacer()
						Image(systemName: "chevron.right")
							.rotationEffect(.degrees(isAdvancedSettingsExpanded ? 90 : 0))
							.foregroundColor(.secondary)
					}
					.contentShape(Rectangle())
				}
			)
			.padding()
			.background(Color(NSColor.controlBackgroundColor))
			.cornerRadius(8)
			.overlay(
				RoundedRectangle(cornerRadius: 8)
					.stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
			)
		}
	}

	func editSettingRow(title: String, binding: Binding<String>) -> some View {
		HStack {
			Text(title)
				.font(fontPreset.font)
			Spacer()
			OptimizedModelPicker(
				selection: binding,
				availableModels: promptViewModel.availableProEditModels,
				font: fontPreset.subheadlineFont
			)
		}
	}
}
