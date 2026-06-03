import SwiftUI

// MARK: - File Tree Inline Section (reuses existing popover content)
struct FileTreeInlineSection: View {
    @ObservedObject var promptVM: PromptViewModel
    let fontPreset: FontScalePreset
	var context: SettingsContext = .copy
    
    var body: some View {
        FileTreePopoverContent(
            promptManager: promptVM,
			context: context,
            fontPreset: fontPreset
        )
		
    }
}

// MARK: - Git Inline Section (reuses existing popover content)
struct GitInlineSection: View {
    @ObservedObject var gitViewModel: GitViewModel
	@ObservedObject var promptVM: PromptViewModel
    let fontPreset: FontScalePreset
	var context: SettingsContext = .copy
    
    var body: some View {
        GitPopoverContent(
            gitViewModel: gitViewModel,
			promptManager: promptVM,
			gitModeBinding: Binding(
				get: {
					switch context {
					case .copy: return promptVM.gitDiffInclusionModeForCopy
					case .chat: return promptVM.gitDiffInclusionModeForChat
					}
				},
				set: { newValue in
					switch context {
					case .copy:
						promptVM.updateGitInclusion(newValue)
					case .chat:
						promptVM.updateGitInclusionForChat(newValue)
					}
				}
			),
            fontPreset: fontPreset
        )
        .onAppear {
            // Ensure list loads when shown inline (popover did this previously)
            gitViewModel.isPopoverVisible = true
            Task {
                await gitViewModel.fetchUnstagedFiles(showLoading: false)
            }
        }
        .onDisappear {
            gitViewModel.isPopoverVisible = false
        }
		
    }
}

// MARK: - Code Map Inline Section (extracted from ScanPrefTag)
struct CodeMapInlineSection: View {
    @ObservedObject var fileManager: RepoFileManagerViewModel
    @ObservedObject var promptVM: PromptViewModel
    var context: SettingsContext = .copy
    let fontPreset: FontScalePreset
    let isChatContext: Bool
	@State private var didRequestScanCancel: Bool = false
    
    // Local computed props mirroring ScanPrefTag logic
    private var isComplete: Bool {
        fileManager.remainingScanCount == 0 || fileManager.totalFilesSeen == 0
    }
    private var progressFraction: Double {
        let total = max(1, fileManager.totalFilesSeen)
        let done = total - fileManager.remainingScanCount
        return Double(done) / Double(total)
    }
    private var currentCodeMapUsage: CodeMapUsage {
        switch context {
        case .copy: return promptVM.codeMapUsage
        case .chat: return promptVM.codeMapUsageForChat
        }
    }
    private var isGloballyDisabled: Bool {
        promptVM.codeMapsGloballyDisabled
    }
    private var effectiveCodeMapUsage: CodeMapUsage {
        isGloballyDisabled ? .none : currentCodeMapUsage
    }
    private var codeMapUsageBinding: Binding<CodeMapUsage> {
        Binding(
            get: { currentCodeMapUsage },
            set: { newValue in
                switch context {
                case .copy:
                    promptVM.updateCodeMapUsage(newValue)
                case .chat:
                    promptVM.updateCodeMapUsageForChat(newValue)
                }
            }
        )
    }
    private var isWarningState: Bool {
        !isGloballyDisabled && isChatContext && currentCodeMapUsage == .selected && promptVM.planActMode == .edit
    }
    private var scannedLanguages: Set<LanguageType> {
        promptVM.scannedLanguages
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10 * fontPreset.scaleFactor) {
            // Warning banner at the very top
            if isGloballyDisabled {
                globalDisabledBanner
            } else if isWarningState {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.yellow)
                    Text("Using \"Selected\" code-map mode while in Edit mode will prevent file edits from being applied because full file contents are replaced with code-maps. Switch to Auto, None or Complete mode, or exit Edit mode, if you intend to modify files.")
                        .font(fontPreset.captionFont)
                }
                .padding()
                .background(Color.yellow.opacity(0.2))
                .cornerRadius(8)
            }
            
            // Controls
            codeMapControls
            
            // Languages legend (scanned)
            if !scannedLanguages.isEmpty {
                VStack(alignment: .leading, spacing: 4 * fontPreset.scaleFactor) {
                    Text("Scanned Supported Languages")
                        .font(fontPreset.headlineFont)
                    languagesLegend
                }
            }
            
            // Progress / completion
            if !isComplete || fileManager.remainingScanCount > 0 {
                progressSection
            } else if isGloballyDisabled {
                Text("Code Maps disabled globally")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            } else {
                Text("\(promptVM.cachedFileAPIs.count) supported files scanned")
                    .font(fontPreset.captionFont)
            }
        }
        .onChange(of: fileManager.remainingScanCount) { _, remaining in
            if remaining == 0 {
                didRequestScanCancel = false
            }
        }
		
    }
    
    private var globalDisabledBanner: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "slash.circle")
                .foregroundColor(.orange)
            Text("Code Maps are globally disabled in Advanced Settings. Saved copy/chat modes are preserved; effective mode is None.")
                .font(fontPreset.captionFont)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .background(Color.orange.opacity(0.1))
        .cornerRadius(8)
    }

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 6 * fontPreset.scaleFactor) {
            ProgressView(value: progressFraction)
                .scaleEffect(fontPreset.scaleFactor)
            HStack {
                Text("Remaining: \(fileManager.remainingScanCount) of \(fileManager.totalFilesSeen)")
                    .font(fontPreset.captionFont)
                Spacer()
                if fileManager.remainingScanCount > 0 {
                    Button(didRequestScanCancel ? "Cancelling…" : "Cancel Scan") {
                        didRequestScanCancel = true
                        Task { await promptVM.cancelCodeMapScans() }
                    }
                    .font(fontPreset.captionFont)
                    .buttonStyle(.borderless)
                    .disabled(didRequestScanCancel)
                }
            }
        }
    }

    // MARK: - Controls matching ScanPrefTag
    private var codeMapControls: some View {
        VStack(alignment: .leading, spacing: 4 * fontPreset.scaleFactor) {
            HStack {
                Text("Code Map Usage")
                    .font(fontPreset.headlineFont)
                Spacer()
                Button(action: {
                    Task { await promptVM.resetCodeMapCache() }
                }) {
                    HStack(spacing: 2) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10 * fontPreset.scaleFactor))
                        Text("Reset Cache")
                            .font(.system(size: 10 * fontPreset.scaleFactor))
                    }
                    .foregroundColor(.secondary)
                }
                .buttonStyle(PlainButtonStyle())
                .disabled(isGloballyDisabled)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
                .help("Clear all cached code maps and rescan files")
            }
            Picker("", selection: codeMapUsageBinding) {
                ForEach(CodeMapUsage.allCases, id: \.self) { usage in
                    Text(usage.rawValue.capitalized)
                        .font(fontPreset.font)
                        .tag(usage)
                }
            }
            .labelsHidden()
            .pickerStyle(SegmentedPickerStyle())
			.disabled(isGloballyDisabled)
            
			if isGloballyDisabled {
                Text("Effective mode: None (global override). Saved mode: \(currentCodeMapUsage.rawValue.capitalized).")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            } else {
                Text(effectiveCodeMapUsage.caption)
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            }
        }
    }
    
    // MARK: - Languages legend
    private var languagesLegend: some View {
        let itemsPerRow = 4
        let sortedLanguages = Array(scannedLanguages).sorted(by: { $0.rawValue < $1.rawValue })
        let rows = stride(from: 0, to: sortedLanguages.count, by: itemsPerRow).map {
            Array(sortedLanguages[$0..<min($0 + itemsPerRow, sortedLanguages.count)])
        }
        
        return VStack(alignment: .leading, spacing: 4 * fontPreset.scaleFactor) {
            if scannedLanguages.isEmpty {
                Text("No supported languages detected")
                    .font(fontPreset.captionFont)
                    .foregroundColor(.secondary)
            } else {
                ForEach(0..<rows.count, id: \.self) { idx in
                    HStack(spacing: 4 * fontPreset.scaleFactor) {
                        ForEach(rows[idx], id: \.self) { lang in
                            Text(lang.displayName)
                                .font(.system(size: 10 * fontPreset.scaleFactor, weight: .medium))
                                .padding(.horizontal, 8 * fontPreset.scaleFactor)
                                .padding(.vertical, 4 * fontPreset.scaleFactor)
                                .background(languageColor(for: lang))
                                .foregroundColor(.primary.opacity(0.8))
                                .cornerRadius(4)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
    
    private func languageColor(for language: LanguageType) -> Color {
        switch language {
        case .swift: return Color.orange.opacity(0.6)
        case .js, .ts, .tsx: return Color.yellow.opacity(0.5)
        case .python: return Color.blue.opacity(0.5)
        case .rust: return Color.red.opacity(0.5)
        case .go: return Color.cyan.opacity(0.5)
        case .java: return Color.purple.opacity(0.5)
        case .c, .cpp: return Color.green.opacity(0.5)
        case .c_sharp: return Color.indigo.opacity(0.5)
        case .dart: return Color.teal.opacity(0.5)
        case .ruby: return Color.red.opacity(0.4)
        case .php: return Color.pink.opacity(0.5)
        }
    }
}
