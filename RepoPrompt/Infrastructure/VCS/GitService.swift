import Foundation
import Darwin
import CryptoKit

/// Async Git helper for fetching repository information
/// Based on the macOS 14+ Swift Git integration guide
actor GitService {
    
    // MARK: - Types
    
    struct GitError: LocalizedError {
        let message: String
        var errorDescription: String? { GitService.friendlyErrorDescription(for: message) }
    }
    
    // MARK: - Worktree Layout Cache
    
    /// Cached Git repository layouts to avoid repeated filesystem checks.
    /// Key: standardized repo root path
    /// Value: resolved layout (only non-nil results are cached)
    private var worktreeLayoutCache: [String: GitRepositoryLayout] = [:]
    
    /// Get the repository layout for a given repo URL, using cache when available.
    /// Only caches successful resolutions to prevent unbounded cache growth from
    /// calls with non-repo paths.
    private func getLayout(for repoURL: URL) -> GitRepositoryLayout? {
        let key = repoURL.standardizedFileURL.path
        
        if let cached = worktreeLayoutCache[key] {
            return cached
        }
        
        let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: repoURL)
        // Only cache non-nil to avoid unbounded growth from failed lookups
        if let layout {
            worktreeLayoutCache[key] = layout
        }
        return layout
    }
    
    /// Clear the worktree layout cache (e.g., when workspace changes).
    func clearLayoutCache() {
        worktreeLayoutCache.removeAll()
    }
    
    struct UncommittedFile: Equatable, Sendable {
        let path: String
        let status: String // M, A, D, R, C, U, ?, !
        let additions: Int?
        let deletions: Int?
        
        init(path: String,
             status: String,
             additions: Int? = nil,
             deletions: Int? = nil) {
            self.path       = path
            self.status     = status
            self.additions  = additions
            self.deletions  = deletions
        }
    }
    
    struct Branch: Sendable {
        let name: String
        let isCurrent: Bool
        let lastCommitDate: Date?
    }
    
    struct Tag: Sendable {
        let name: String
        let commitDate: Date?
    }

    /// Determines which reference the working tree is compared against
    enum CompareBase: Sendable {
        /// Compare working tree against HEAD (includes staged & unstaged changes)
        case head
        /// Compare working tree/current branch against the specified branch
        case branch(String)
    }
    
    // MARK: - Public API
    
    /// Find the git repository root starting from the given path
    func findGitRoot(from path: URL) async throws -> URL? {
        let (stdout, _, exitCode) = try await runGit(
            ["rev-parse", "--show-toplevel"],
            at: path
        )
        
        guard exitCode == 0 else {
            return nil // Not a git repository or not found
        }
        
        let rootPath = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return URL(fileURLWithPath: rootPath)
    }
    
    /// Check if the given path is within a git repository
    func isGitRepository(at path: URL) async -> Bool {
        do {
            let _ = try await findGitRoot(from: path)
            return true
        } catch {
            return false
        }
    }
    
    /// Get uncommitted modified files in the repository
    func getUncommittedFiles(at repoURL: URL) async throws -> [UncommittedFile] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["status", "--porcelain"],
            at: repoURL
        )
        
        guard exitCode == 0 else {
            throw GitError(message: "git status failed: \(stderr)")
        }
        
        return parseStatusOutput(stdout)
    }

	/// Get the current HEAD SHA for the repository.
	func getHeadSHA(at repoURL: URL) async throws -> String {
		let (stdout, stderr, exitCode) = try await runGit(
			["rev-parse", "HEAD"],
			at: repoURL
		)
		guard exitCode == 0 else {
			throw GitError(message: "git rev-parse HEAD failed: \(stderr)")
		}
		return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
	}
	
	/// Resolve any ref (branch, tag, commit-ish) to a SHA.
	func getRefSHA(at repoURL: URL, ref: String) async throws -> String {
		let (stdout, stderr, exitCode) = try await runGit(
			["rev-parse", ref],
			at: repoURL
		)
		guard exitCode == 0 else {
			throw GitError(message: "git rev-parse \(ref) failed: \(stderr)")
		}
		return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Get git status output in porcelain format with NUL delimiters.
	func getStatusPorcelainZ(at repoURL: URL) async throws -> Data {
		let (stdout, stderr, exitCode) = try await runGit(
			["status", "--porcelain", "-z"],
			at: repoURL
		)
		guard exitCode == 0 else {
			throw GitError(message: "git status --porcelain -z failed: \(stderr)")
		}
		return Data(stdout.utf8)
	}

	/// Get a status fingerprint for staleness detection.
	func getStatusFingerprint(at repoURL: URL, baseRef: String = "HEAD") async throws -> GitDiffFingerprint {
		let headSHA = try await getHeadSHA(at: repoURL)
		let baseRefSHA = try await getRefSHA(at: repoURL, ref: baseRef)
		let statusData = try await getStatusPorcelainZ(at: repoURL)
		var fingerprintData = Data()
		fingerprintData.append(statusData)
		fingerprintData.append(0)
		fingerprintData.append(Data(baseRefSHA.utf8))
		fingerprintData.append(0)

		// Include per-path size/mtime to invalidate cache when modified file content changes.
		let paths = changedPathsFromPorcelainZ(statusData)
		let fm = FileManager.default
		for path in Set(paths).sorted() {
			fingerprintData.append(Data(path.utf8))
			fingerprintData.append(0)
			let absPath = repoURL.appendingPathComponent(path).path
			if let attrs = try? fm.attributesOfItem(atPath: absPath) {
				let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
				let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
				fingerprintData.append(Data("\(size)\t\(mtime)".utf8))
			} else {
				fingerprintData.append(Data("missing".utf8))
			}
			fingerprintData.append(0)
		}
		let statusHash = sha256Hex(fingerprintData)
		return GitDiffFingerprint(
			headSHA: headSHA,
			baseRef: baseRef,
			statusHash: statusHash,
			generatedAt: Date()
		)
	}

	private func changedPathsFromPorcelainZ(_ data: Data) -> [String] {
		guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
			return []
		}

		let entries = text.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
		var paths: [String] = []
		var i = 0
		while i < entries.count {
			let entry = entries[i]
			guard entry.count >= 3 else {
				i += 1
				continue
			}

			let indexStatus = entry[entry.startIndex]
			let pathStart = entry.index(entry.startIndex, offsetBy: 3)
			let path1 = String(entry[pathStart...])
			guard !path1.isEmpty else {
				i += 1
				continue
			}

			// Renames/copies include a second path after NUL; prefer destination.
			if indexStatus == "R" || indexStatus == "C" {
				if i + 1 < entries.count, !entries[i + 1].isEmpty {
					paths.append(entries[i + 1])
				} else {
					paths.append(path1)
				}
				i += 2
				continue
			}

			paths.append(path1)
			i += 1
		}

		return paths
	}
    
    /// Get diff between specified branch and working tree
    func getDiff(from branch: String, at repoURL: URL) async throws -> String {
        // Compare branch to working tree to include all uncommitted changes
        let (stdout, stderr, exitCode) = try await runGit(
            ["diff", branch],
            at: repoURL
        )
        
        guard exitCode == 0 || exitCode == 1 else {
            throw GitError(message: "git diff failed: \(stderr)")
        }
        
        return stdout
    }
    
    /// Get diff between specified branch and working tree for specific files
    func getDiff(from branch: String, for files: [String], at repoURL: URL) async throws -> String {
        // Prefer normal argv for smaller file sets (compatibility),
        // use pathspec-from-file when args are large, and chunk as a fallback.
        let maxChunk = 3000
		let pathspecByteLimit = 128 * 1024
		let pathspecBytes = files.reduce(0) { $0 + $1.lengthOfBytes(using: .utf8) + 1 }
		
		if !files.isEmpty, pathspecBytes >= pathspecByteLimit {
			do {
				let stdin = makePathspecStdinData(files)
				let args = ["diff", "--pathspec-from-file=-", "--pathspec-file-nul", branch]
				let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL, stdin: stdin)
				guard exitCode == 0 || exitCode == 1 else {
					throw GitError(message: "git diff failed: \(stderr)")
				}
				return stdout
			} catch {
				if !shouldFallbackFromPathspecError(error) {
					throw error
				}
			}
		}
		
        if files.count <= maxChunk {
            var args = ["diff", branch, "--"]
            args.append(contentsOf: files)
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            return stdout
        }
        
        var combined = ""
        for chunk in files.chunked(into: maxChunk) {
            var args = ["diff", branch, "--"]
            args.append(contentsOf: chunk)
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            if !stdout.isEmpty {
                combined += stdout
                if !combined.hasSuffix("\n") { combined += "\n" }
            }
        }
        return combined
    }

	/// Split a unified diff output into per-file diff strings.
	static func splitUnifiedDiffByFile(_ diff: String) -> [String: String] {
		guard !diff.isEmpty else { return [:] }
		let endsWithNewline = diff.hasSuffix("\n")
		let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
		var result: [String: String] = [:]
		var currentBlock: [String] = []

		for line in lines {
			if line.hasPrefix("diff --git ") {
				finalizeUnifiedDiffBlock(currentBlock, endsWithNewline: endsWithNewline, into: &result)
				currentBlock = [line]
				continue
			}
			guard !currentBlock.isEmpty else { continue }
			currentBlock.append(line)
		}

		finalizeUnifiedDiffBlock(currentBlock, endsWithNewline: endsWithNewline, into: &result)
		return result
	}

	private static func finalizeUnifiedDiffBlock(
		_ block: [String],
		endsWithNewline: Bool,
		into result: inout [String: String]
	) {
		guard !block.isEmpty, let path = canonicalPath(forUnifiedDiffBlock: block) else { return }
		var text = block.joined(separator: "\n")
		if endsWithNewline, !text.hasSuffix("\n") {
			text += "\n"
		}
		result[path] = text
	}
	
	private static func canonicalPath(forUnifiedDiffBlock block: [String]) -> String? {
		var headerPaths: (oldPath: String, newPath: String)?
		var renameToPath: String?
		var copyToPath: String?
		var plusPath: String?
		var minusPath: String?

		for line in block {
			if line.hasPrefix("diff --git ") {
				headerPaths = parseDiffGitHeaderPaths(line)
				continue
			}
			if line.hasPrefix("rename to ") {
				renameToPath = parseGitPathRemainder(String(line.dropFirst("rename to ".count)))
				continue
			}
			if line.hasPrefix("copy to ") {
				copyToPath = parseGitPathRemainder(String(line.dropFirst("copy to ".count)))
				continue
			}
			if line.hasPrefix("+++ ") {
				plusPath = parseGitPathRemainder(String(line.dropFirst("+++ ".count))).flatMap(normalizePatchHeaderPath(_:))
				continue
			}
			if line.hasPrefix("--- ") {
				minusPath = parseGitPathRemainder(String(line.dropFirst("--- ".count))).flatMap(normalizePatchHeaderPath(_:))
				continue
			}
			if line.hasPrefix("@@") {
				break
			}
		}

		return renameToPath ?? copyToPath ?? plusPath ?? minusPath ?? headerPaths?.newPath ?? headerPaths?.oldPath
	}

	private static func parseDiffGitHeaderPaths(_ line: String) -> (oldPath: String, newPath: String)? {
		let prefix = "diff --git "
		guard line.hasPrefix(prefix) else { return nil }
		let remainder = String(line.dropFirst(prefix.count))
		let tokens = parseDiffGitTokens(remainder)
		guard tokens.count >= 2,
			let oldPath = normalizePatchHeaderPath(tokens[0]),
			let newPath = normalizePatchHeaderPath(tokens[1]) else {
			return nil
		}
		return (oldPath, newPath)
	}

	private static func parseGitPathRemainder(_ raw: String) -> String? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		if trimmed.first == "\"" {
			return parseDiffGitTokens(trimmed).first
		}
		return trimmed
	}

	private static func normalizePatchHeaderPath(_ rawPath: String) -> String? {
		let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, trimmed != "/dev/null" else { return nil }
		if trimmed.hasPrefix("a/") || trimmed.hasPrefix("b/") {
			return String(trimmed.dropFirst(2))
		}
		return trimmed
	}
	
	private static func parseDiffGitTokens(_ input: String) -> [String] {
		var tokens: [String] = []
		var current = ""
		var isQuoted = false
		var idx = input.startIndex
		
		while idx < input.endIndex {
			let ch = input[idx]
			if isQuoted {
				if ch == "\\" {
					let next = input.index(after: idx)
					if next >= input.endIndex { break }
					let escaped = input[next]
					if let octal = parseOctalEscape(escaped, input: input, start: next) {
						current.append(octal.character)
						idx = octal.nextIndex
						continue
					}
					current.append(unescapeGitDiffCharacter(escaped))
					idx = input.index(after: next)
					continue
				}
				if ch == "\"" {
					isQuoted = false
					idx = input.index(after: idx)
					continue
				}
				current.append(ch)
				idx = input.index(after: idx)
				continue
			}
			
			if ch == "\"" {
				isQuoted = true
				idx = input.index(after: idx)
				continue
			}
			if ch == " " {
				if !current.isEmpty {
					tokens.append(current)
					current = ""
				}
				idx = input.index(after: idx)
				continue
			}
			current.append(ch)
			idx = input.index(after: idx)
		}
		
		if !current.isEmpty {
			tokens.append(current)
		}
		return tokens
	}
	
	private static func unescapeGitDiffCharacter(_ ch: Character) -> Character {
		switch ch {
		case "n": return "\n"
		case "t": return "\t"
		case "r": return "\r"
		case "\"": return "\""
		case "\\": return "\\"
		default: return ch
		}
	}
	
	private static func parseOctalEscape(
		_ first: Character,
		input: String,
		start: String.Index
	) -> (character: Character, nextIndex: String.Index)? {
		guard ("0"..."7").contains(first) else { return nil }
		var digits = String(first)
		var nextIndex = input.index(after: start)
		while digits.count < 3, nextIndex < input.endIndex {
			let ch = input[nextIndex]
			guard ("0"..."7").contains(ch) else { break }
			digits.append(ch)
			nextIndex = input.index(after: nextIndex)
		}
		guard let scalar = UInt8(digits, radix: 8) else { return nil }
		let scalarValue = UnicodeScalar(scalar)
		return (Character(scalarValue), nextIndex)
	}
	
	/// Get diff for untracked files by comparing each file to /dev/null
	func getUntrackedDiff(for files: [String], contextLines: Int, at repoURL: URL) async throws -> String {
		guard !files.isEmpty else { return "" }
		
		var combined = ""
		for file in files {
			let args = ["diff", "--no-index", "--unified=\(contextLines)", "--no-ext-diff", "--color=never", "--", "/dev/null", file]
			// --no-index doesn't need repo context, so skip GIT_DIR/GIT_WORK_TREE injection
			let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL, requiresRepoContext: false)
			guard exitCode == 0 || exitCode == 1 else {
				throw GitError(message: "git diff --no-index failed: \(stderr)")
			}
			if !stdout.isEmpty {
				combined += stdout
				if !combined.hasSuffix("\n") { combined += "\n" }
			}
		}
		
		return combined
	}
    
    /// Get diff for specific files (all uncommitted changes - staged and unstaged)
    func getDiff(for files: [String]? = nil, at repoURL: URL) async throws -> String {
        var combined = ""
        if let files, !files.isEmpty {
            let maxChunk = 3000
            if files.count <= maxChunk {
                var args = ["diff", "--unified=3", "HEAD", "--"]
                args.append(contentsOf: files)
                let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
                guard exitCode == 0 || exitCode == 1 else {
                    throw GitError(message: "git diff failed: \(stderr)")
                }
                return stdout
            }
            for chunk in files.chunked(into: maxChunk) {
                var args = ["diff", "--unified=3", "HEAD", "--"]
                args.append(contentsOf: chunk)
                let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
                guard exitCode == 0 || exitCode == 1 else {
                    throw GitError(message: "git diff failed: \(stderr)")
                }
                if !stdout.isEmpty {
                    combined += stdout
                    if !combined.hasSuffix("\n") { combined += "\n" }
                }
            }
            return combined
        } else {
            let args = ["diff", "--unified=3", "HEAD"]
            let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
            guard exitCode == 0 || exitCode == 1 else {
                throw GitError(message: "git diff failed: \(stderr)")
            }
            return stdout
        }
    }

	private func runDiff(
		argsPrefix: [String],
		contextLines: Int?,
		detectRenames: Bool,
		refArg: String?,
		paths: [String]?,
		at repoURL: URL
	) async throws -> String {
		let maxChunk = 3000
		let pathspecByteLimit = 128 * 1024
		let cleanedPaths = (paths ?? []).filter { !$0.isEmpty }
		let pathspecBytes = cleanedPaths.reduce(0) { $0 + $1.lengthOfBytes(using: .utf8) + 1 }
		let usePathspec = !cleanedPaths.isEmpty && pathspecBytes >= pathspecByteLimit

		func baseArgs() -> [String] {
			var args = argsPrefix
			if let contextLines {
				args.append("--unified=\(contextLines)")
			}
			if detectRenames {
				args.append("-M")
			}
			args.append("--no-ext-diff")
			args.append("--color=never")
			return args
		}

		if usePathspec {
			do {
				var args = baseArgs()
				args.append(contentsOf: ["--pathspec-from-file=-", "--pathspec-file-nul"])
				if let refArg, !refArg.isEmpty {
					args.append(refArg)
				}
				let stdin = makePathspecStdinData(cleanedPaths)
				let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL, stdin: stdin)
				guard exitCode == 0 || exitCode == 1 else {
					throw GitError(message: "git diff failed: \(stderr)")
				}
				return stdout
			} catch {
				if !shouldFallbackFromPathspecError(error) {
					throw error
				}
			}
		}

		guard !cleanedPaths.isEmpty else {
			var args = baseArgs()
			if let refArg, !refArg.isEmpty {
				args.append(refArg)
			}
			let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
			guard exitCode == 0 || exitCode == 1 else {
				throw GitError(message: "git diff failed: \(stderr)")
			}
			return stdout
		}

		if cleanedPaths.count <= maxChunk {
			var args = baseArgs()
			if let refArg, !refArg.isEmpty {
				args.append(refArg)
			}
			args.append("--")
			args.append(contentsOf: cleanedPaths)
			let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
			guard exitCode == 0 || exitCode == 1 else {
				throw GitError(message: "git diff failed: \(stderr)")
			}
			return stdout
		}

		var combined = ""
		for chunk in cleanedPaths.chunked(into: maxChunk) {
			var args = baseArgs()
			if let refArg, !refArg.isEmpty {
				args.append(refArg)
			}
			args.append("--")
			args.append(contentsOf: chunk)
			let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
			guard exitCode == 0 || exitCode == 1 else {
				throw GitError(message: "git diff failed: \(stderr)")
			}
			if !stdout.isEmpty {
				combined += stdout
				if !combined.hasSuffix("\n") { combined += "\n" }
			}
		}
		return combined
	}

	func getDiffUncommitted(
		base: String,
		paths: [String]?,
		contextLines: Int,
		detectRenames: Bool,
		at repoURL: URL
	) async throws -> String {
		try await runDiff(
			argsPrefix: ["diff"],
			contextLines: contextLines,
			detectRenames: detectRenames,
			refArg: base,
			paths: paths,
			at: repoURL
		)
	}

	func getDiffUncommittedMergeBase(
		base: String,
		paths: [String]?,
		contextLines: Int,
		detectRenames: Bool,
		at repoURL: URL
	) async throws -> String {
		try await runDiff(
			argsPrefix: ["diff", "--merge-base"],
			contextLines: contextLines,
			detectRenames: detectRenames,
			refArg: base,
			paths: paths,
			at: repoURL
		)
	}

	func getDiffStaged(
		base: String,
		paths: [String]?,
		contextLines: Int,
		detectRenames: Bool,
		at repoURL: URL
	) async throws -> String {
		try await runDiff(
			argsPrefix: ["diff", "--cached"],
			contextLines: contextLines,
			detectRenames: detectRenames,
			refArg: base,
			paths: paths,
			at: repoURL
		)
	}

	func getDiffStagedMergeBase(
		base: String,
		paths: [String]?,
		contextLines: Int,
		detectRenames: Bool,
		at repoURL: URL
	) async throws -> String {
		try await runDiff(
			argsPrefix: ["diff", "--cached", "--merge-base"],
			contextLines: contextLines,
			detectRenames: detectRenames,
			refArg: base,
			paths: paths,
			at: repoURL
		)
	}

	func getDiffUnstaged(
		paths: [String]?,
		contextLines: Int,
		detectRenames: Bool,
		at repoURL: URL
	) async throws -> String {
		try await runDiff(
			argsPrefix: ["diff"],
			contextLines: contextLines,
			detectRenames: detectRenames,
			refArg: nil,
			paths: paths,
			at: repoURL
		)
	}

	func getDiffRevspec(
		_ revspec: String,
		paths: [String]?,
		contextLines: Int,
		detectRenames: Bool,
		at repoURL: URL
	) async throws -> String {
		try await runDiff(
			argsPrefix: ["diff"],
			contextLines: contextLines,
			detectRenames: detectRenames,
			refArg: revspec,
			paths: paths,
			at: repoURL
		)
	}

    /// Get diff for specific files with error handling per file
    /// Returns tuple of (combinedDiff, failedFiles)
    func getDiffWithFailures(for files: [String], at repoURL: URL) async -> (String, [String]) {
        var combinedDiff = ""
        var failedFiles: [String] = []
        
        // Try to get diff for all files at once first
        do {
            let diff = try await getDiff(for: files, at: repoURL)
            return (diff, [])
        } catch {
            // If batch diff fails, try each file individually
            for file in files {
                do {
                    let fileDiff = try await getDiff(for: [file], at: repoURL)
                    if !fileDiff.isEmpty {
                        combinedDiff += fileDiff
                        if !combinedDiff.hasSuffix("\n") {
                            combinedDiff += "\n"
                        }
                    }
                } catch {
                    failedFiles.append(file)
                }
            }
        }
        
        return (combinedDiff, failedFiles)
    }
    
    /// Get list of local branches with last commit dates
    func getLocalBranches(at repoURL: URL) async throws -> [Branch] {
        // Get branches with their last commit dates using for-each-ref
        let (stdout, stderr, exitCode) = try await runGit(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%09%(committerdate:iso8601)%09%(HEAD)", "refs/heads"],
            at: repoURL
        )
        
        guard exitCode == 0 else {
            throw GitError(message: "git for-each-ref failed: \(stderr)")
        }
        
        return parseBranchOutputWithDates(stdout)
    }
    
    /// Get list of remote branches with last commit dates, sorted by most recent
    /// Filters out symbolic HEAD refs (e.g., origin/HEAD)
    func getRemoteBranches(at repoURL: URL, limit: Int = 10) async throws -> [Branch] {
        let (stdout, stderr, exitCode) = try await runGit(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%09%(committerdate:iso8601)", "refs/remotes", "--count=\(limit + 5)"],
            at: repoURL
        )
        
        guard exitCode == 0 else {
            throw GitError(message: "git for-each-ref failed: \(stderr)")
        }
        
        // Parse and filter out HEAD symbolic refs (e.g., origin/HEAD)
        // Reuse parseBranchOutputWithDates since it handles 2-field format (name + date)
        let branches = parseBranchOutputWithDates(stdout)
            .filter { !$0.name.hasSuffix("/HEAD") }
        
        // Return only up to limit after filtering
        return Array(branches.prefix(limit))
    }
    
	/// Fetch updates from all remotes
	/// Updates local tracking refs (e.g., origin/main) to match remote state
	func fetch(at repoURL: URL) async throws {
		let (_, stderr, exitCode) = try await runGit(
			["fetch", "--all", "--prune"],
			at: repoURL
		)
        
		guard exitCode == 0 else {
			throw GitError(message: "git fetch failed: \(stderr)")
		}
	}
	
	/// Check if a given ref name exists under refs/remotes.
	func hasRemoteTrackingRef(named refName: String, at repoURL: URL) async -> Bool {
		let ref = "refs/remotes/\(refName)"
		do {
			let (_, _, exitCode) = try await runGit(
				["show-ref", "--verify", "--quiet", ref],
				at: repoURL
			)
			return exitCode == 0
		} catch {
			return false
		}
	}
    
    /// Get recent tags sorted by commit date
    func getTags(at repoURL: URL, limit: Int = 10) async throws -> [Tag] {
        // Get tags with their commit dates using for-each-ref
        let (stdout, stderr, exitCode) = try await runGit(
            ["for-each-ref", "--sort=-committerdate", "--format=%(refname:short)%09%(committerdate:iso8601)", "refs/tags", "--count=\(limit)"],
            at: repoURL
        )
        
        guard exitCode == 0 else {
            throw GitError(message: "git for-each-ref failed: \(stderr)")
        }
        
        return parseTagOutputWithDates(stdout)
    }
    
	/// Get current branch name
	func getCurrentBranch(at repoURL: URL) async throws -> String {
        // Try the symbolic-ref command first (more reliable)
        let (stdout, stderr, exitCode) = try await runGit(
            ["symbolic-ref", "--short", "HEAD"],
            at: repoURL
        )
        
        if exitCode == 0 {
            return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Fallback to branch --show-current
        let (stdout2, stderr2, exitCode2) = try await runGit(
            ["branch", "--show-current"],
            at: repoURL
        )
        
        if exitCode2 == 0 {
            return stdout2.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Final fallback to rev-parse
        let (stdout3, stderr3, exitCode3) = try await runGit(
            ["rev-parse", "--abbrev-ref", "HEAD"],
            at: repoURL
        )
        
        guard exitCode3 == 0 else {
            throw GitError(message: "All git branch commands failed. symbolic-ref: \(stderr), branch: \(stderr2), rev-parse: \(stderr3)")
        }
        
        return stdout3.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Get list of changed files with per-file additions / deletions statistics
    /// Get changed files with statistics, including untracked files
    /// - Parameters:
    ///   - base: Comparison baseline (`.head` or `.branch("main")`)
    ///   - repoURL: URL of the repository root
    /// - Returns: Array of `UncommittedFile` including tracked changes and untracked files
    func getChangedFilesStats(
        relativeTo base: CompareBase,
        at repoURL: URL
    ) async throws -> [UncommittedFile] {
        
        // Build argument lists ---------------------------------------------------
        let reference: [String] = {
            switch base {
            case .head:           return ["HEAD"]
            case .branch(let ref):return [ref]
            }
        }()
        
        let numstatArgs     = ["diff"] + reference + ["--numstat"]
        let nameStatusArgs  = ["diff"] + reference + ["--name-status"]
        
        // Run all commands in parallel -----------------------------------------
        async let numstatResult  = runGit(numstatArgs,    at: repoURL)
        async let nameStatResult = runGit(nameStatusArgs, at: repoURL)
        async let untrackedResult = runGit(["ls-files", "--others", "--exclude-standard"], at: repoURL)
        
        let (numOut, numErr, numExit)       = try await numstatResult
        guard numExit == 0 || numExit == 1 else {
            throw GitError(message: "git diff --numstat failed: \(numErr)")
        }
        
        let (nameOut, nameErr, nameExit)    = try await nameStatResult
        guard nameExit == 0 || nameExit == 1 else {
            throw GitError(message: "git diff --name-status failed: \(nameErr)")
        }
        
        let (untrackedOut, _, untrackedExit) = try await untrackedResult
        guard untrackedExit == 0 else {
            throw GitError(message: "git ls-files failed")
        }
        
        // Parse outputs ----------------------------------------------------------
        let statsMap   = parseNumstatOutput(numOut)       // path → (add,del)
        let statusMap  = parseNameStatusOutput(nameOut)   // path → "M"
        
        // Merge into unified results --------------------------------------------
        var results: [UncommittedFile] = []
        let allPaths = Set(statsMap.keys).union(statusMap.keys)
        
        for path in allPaths {
            let status     = statusMap[path] ?? "M"
            let tuple      = statsMap[path]
            let additions  = tuple?.0
            let deletions  = tuple?.1
            results.append(
                UncommittedFile(
                    path: path,
                    status: status,
                    additions: additions,
                    deletions: deletions
                )
            )
        }
        
        // Add untracked files ----------------------------------------------------
        let untrackedFiles = untrackedOut
            .split(separator: "\n")
            .map { String($0) }
            .filter { !$0.isEmpty }
        
        for path in untrackedFiles {
            // Only add if not already in the results (avoid duplicates)
            if !allPaths.contains(path) {
				let stats = untrackedLineStats(for: path, repoURL: repoURL)
                results.append(
                    UncommittedFile(
                        path: path,
                        status: "??",
                        additions: stats.additions,
                        deletions: stats.deletions
                    )
                )
            }
        }
        
        // Stable, human-friendly order
		let keyed = results.map { file in
			(lower: file.path.lowercased(), original: file.path, file: file)
		}
		return keyed.sorted { lhs, rhs in
			if lhs.lower != rhs.lower {
				return lhs.lower < rhs.lower
			}
			return lhs.original < rhs.original
		}.map(\.file)
    }
    
	private enum DiffStatKind {
		case numstat
		case nameStatus
	}

	private func diffArgs(
		for compare: GitDiffCompareSpec,
		kind: DiffStatKind
	) -> (argsPrefix: [String], refArg: String?) {
		var argsPrefix = ["diff"]
		switch compare {
		case .staged:
			argsPrefix.append("--cached")
		case .stagedMergeBase:
			argsPrefix.append("--cached")
			argsPrefix.append("--merge-base")
		case .uncommittedMergeBase:
			argsPrefix.append("--merge-base")
		default:
			break
		}
		switch kind {
		case .numstat:
			argsPrefix.append("--numstat")
		case .nameStatus:
			argsPrefix.append("--name-status")
		}

		let refArg: String?
		switch compare {
		case .uncommitted(let base):
			refArg = base
		case .uncommittedMergeBase(let base):
			refArg = base
		case .staged(let base):
			refArg = base
		case .stagedMergeBase(let base):
			refArg = base
		case .unstaged:
			refArg = nil
		case .revspec(let revspec):
			refArg = revspec
		}
		return (argsPrefix, refArg)
	}

	func getDiffNumstat(
		compare: GitDiffCompareSpec,
		detectRenames: Bool = false,
		at repoURL: URL
	) async throws -> String {
		let (argsPrefix, refArg) = diffArgs(for: compare, kind: .numstat)
		return try await runDiff(
			argsPrefix: argsPrefix,
			contextLines: nil,
			detectRenames: detectRenames,
			refArg: refArg,
			paths: nil,
			at: repoURL
		)
	}

	func getDiffNameStatus(
		compare: GitDiffCompareSpec,
		detectRenames: Bool = false,
		at repoURL: URL
	) async throws -> String {
		let (argsPrefix, refArg) = diffArgs(for: compare, kind: .nameStatus)
		return try await runDiff(
			argsPrefix: argsPrefix,
			contextLines: nil,
			detectRenames: detectRenames,
			refArg: refArg,
			paths: nil,
			at: repoURL
		)
	}

	func getChangedFilesStats(
		compare: GitDiffCompareSpec,
		includeUntrackedWhenApplicable: Bool,
		detectRenames: Bool = false,
		at repoURL: URL
	) async throws -> [UncommittedFile] {
		let numOut = try await getDiffNumstat(compare: compare, detectRenames: detectRenames, at: repoURL)
		let nameOut = try await getDiffNameStatus(compare: compare, detectRenames: detectRenames, at: repoURL)
		let statsMap = parseNumstatOutput(numOut)
		let statusMap = parseNameStatusOutput(nameOut)

		var results: [UncommittedFile] = []
		let allPaths = Set(statsMap.keys).union(statusMap.keys)

		for path in allPaths {
			let status = statusMap[path] ?? "M"
			let tuple = statsMap[path]
			let additions = tuple?.0
			let deletions = tuple?.1
			results.append(
				UncommittedFile(
					path: path,
					status: status,
					additions: additions,
					deletions: deletions
				)
			)
		}

		let includeUntracked = includeUntrackedWhenApplicable && {
			switch compare {
			case .uncommitted, .uncommittedMergeBase, .unstaged:
				return true
			case .staged, .stagedMergeBase, .revspec:
				return false
			}
		}()

		if includeUntracked {
			let (untrackedOut, _, untrackedExit) = try await runGit(["ls-files", "--others", "--exclude-standard"], at: repoURL)
			guard untrackedExit == 0 else {
				throw GitError(message: "git ls-files failed")
			}
			let untrackedFiles = untrackedOut
				.split(separator: "\n")
				.map { String($0) }
				.filter { !$0.isEmpty }

			for path in untrackedFiles {
				if !allPaths.contains(path) {
					let stats = untrackedLineStats(for: path, repoURL: repoURL)
					results.append(
						UncommittedFile(
							path: path,
							status: "??",
							additions: stats.additions,
							deletions: stats.deletions
						)
					)
				}
			}
		}

		let keyed = results.map { file in
			(lower: file.path.lowercased(), original: file.path, file: file)
		}
		return keyed.sorted { lhs, rhs in
			if lhs.lower != rhs.lower {
				return lhs.lower < rhs.lower
			}
			return lhs.original < rhs.original
		}.map(\.file)
	}

	func getCommitGraph(maxLines: Int, at repoURL: URL) async throws -> String {
		let args = ["log", "--graph", "--decorate", "--oneline", "--color=never", "-n", "\(maxLines)"]
		let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
		guard exitCode == 0 else {
			throw GitError(message: "git log failed: \(stderr)")
		}
		return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
	}

    /// Return how many commits the current HEAD is ahead/behind the given branch.
    /// Positive `ahead` means local commits not in *branch*,
    /// positive `behind` means commits present in *branch* but not in HEAD.
    func getAheadBehind(
        vs branch: String,
        at repoURL: URL
    ) async throws -> (ahead: Int, behind: Int) {
        let args = ["rev-list", "--left-right", "--count", "\(branch)...HEAD"]
        let (stdout, stderr, exit) = try await runGit(args, at: repoURL)
        guard exit == 0 else {
            throw GitError(message: "git rev-list failed: \(stderr)")
        }
        let parts = stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\t")
            .map(String.init)
        guard parts.count == 2,
              let behind = Int(parts[0]),
              let ahead  = Int(parts[1]) else {
            throw GitError(message: "Unexpected rev-list output: \(stdout)")
        }
        return (ahead: ahead, behind: behind)
    }

	// MARK: - Unified Git Tool Support

	/// Get the upstream tracking branch for the current branch.
	/// Returns nil if no upstream is set.
	func getUpstreamRef(at repoURL: URL) async throws -> String? {
		let args = ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]
		let (stdout, _, exitCode) = try await runGit(args, at: repoURL)
		guard exitCode == 0 else {
			return nil // No upstream configured
		}
		let result = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
		return result.isEmpty ? nil : result
	}

	/// Structured working directory status.
	struct WorkingStatus: Sendable {
		let staged: [String]
		let modified: [String]
		let untracked: [String]
	}

	/// Get structured working status with staged, modified, and untracked files.
	func getWorkingStatus(at repoURL: URL) async throws -> WorkingStatus {
		let args = ["status", "--porcelain", "-z"]
		let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
		guard exitCode == 0 else {
			throw GitError(message: "git status --porcelain -z failed: \(stderr)")
		}

		var staged: [String] = []
		var modified: [String] = []
		var untracked: [String] = []

		// Parse NUL-delimited entries
		// Format: XY<space>path<NUL>[origPath<NUL> for renames]
		let entries = stdout.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
		var i = 0
		while i < entries.count {
			let entry = entries[i]
			guard entry.count >= 3 else {
				i += 1
				continue
			}

			let indexStatus = entry[entry.startIndex]
			let workTreeStatus = entry[entry.index(after: entry.startIndex)]
			let pathStart = entry.index(entry.startIndex, offsetBy: 3)
			let path = String(entry[pathStart...])

			// Skip empty paths
			guard !path.isEmpty else {
				i += 1
				continue
			}

			// Untracked
			if indexStatus == "?" && workTreeStatus == "?" {
				untracked.append(path)
				i += 1
				continue
			}

			// Staged: X is not space and not ?
			if indexStatus != " " && indexStatus != "?" {
				staged.append(path)
			}

			// Modified in working tree: Y is not space and not ?
			if workTreeStatus != " " && workTreeStatus != "?" {
				modified.append(path)
			}

			// Handle renames/copies which have an additional path
			if indexStatus == "R" || indexStatus == "C" {
				i += 2 // Skip the original path
			} else {
				i += 1
			}
		}

		return WorkingStatus(
			staged: staged.sorted(),
			modified: modified.sorted(),
			untracked: untracked.sorted()
		)
	}

	/// Summary of a commit for log output.
	struct CommitSummary: Sendable {
		let sha: String
		let shortSHA: String
		let author: String
		let dateISO: String
		let message: String
		let filesChanged: Int
		let insertions: Int
		let deletions: Int
	}

	/// Get commit log summaries with stats.
	func getLogSummaries(
		count: Int,
		path: String? = nil,
		at repoURL: URL
	) async throws -> [CommitSummary] {
		// Use a custom format with a separator to parse commits
		// Format: __C__<sha>\t<short>\t<author>\t<date>\t<subject>
		// Followed by --numstat lines
		var args = [
			"log",
			"-n", "\(count)",
			"--date=iso-strict",
			"--pretty=format:__C__%H%x09%h%x09%an%x09%ad%x09%s",
			"--numstat",
			"--no-ext-diff",
			"--no-textconv",
			"--color=never"
		]
		if let path, !path.isEmpty {
			args.append("--")
			args.append(path)
		}

		let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
		guard exitCode == 0 else {
			throw GitError(message: "git log failed: \(stderr)")
		}

		return parseLogSummaries(stdout)
	}

	private func parseLogSummaries(_ output: String) -> [CommitSummary] {
		var results: [CommitSummary] = []
		let blocks = output.components(separatedBy: "__C__").filter { !$0.isEmpty }

		for block in blocks {
			let lines = block.components(separatedBy: "\n")
			guard let headerLine = lines.first else { continue }

			let headerParts = headerLine.split(separator: "\t", maxSplits: 4).map(String.init)
			guard headerParts.count >= 5 else { continue }

			let sha = headerParts[0]
			let shortSHA = headerParts[1]
			let author = headerParts[2]
			let dateISO = headerParts[3]
			let message = headerParts[4]

			// Parse numstat lines for this commit
			var filesChanged = 0
			var insertions = 0
			var deletions = 0

			for i in 1..<lines.count {
				let line = lines[i].trimmingCharacters(in: .whitespaces)
				guard !line.isEmpty else { continue }
				let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
				guard parts.count >= 2 else { continue }

				filesChanged += 1
				if let adds = Int(parts[0]) {
					insertions += adds
				}
				if let dels = Int(parts[1]) {
					deletions += dels
				}
			}

			results.append(CommitSummary(
				sha: sha,
				shortSHA: shortSHA,
				author: author,
				dateISO: dateISO,
				message: message,
				filesChanged: filesChanged,
				insertions: insertions,
				deletions: deletions
			))
		}

		return results
	}

	/// Detailed commit info for `show` operation.
	struct CommitInfo: Sendable {
		let sha: String
		let shortSHA: String
		let author: String
		let dateISO: String
		let message: String
	}

	/// Get commit info (metadata only, no diff).
	func getCommitInfo(ref: String, at repoURL: URL) async throws -> CommitInfo {
		let args = [
			"show",
			"-s",
			"--date=iso-strict",
			"--format=%H%x09%h%x09%an%x09%ad%x09%B",
			"--no-ext-diff",
			"--no-textconv",
			"--color=never",
			ref
		]
		let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
		guard exitCode == 0 else {
			throw GitError(message: "git show failed: \(stderr)")
		}

		let parts = stdout.split(separator: "\t", maxSplits: 4).map(String.init)
		guard parts.count >= 5 else {
			throw GitError(message: "Unexpected git show output format")
		}

		return CommitInfo(
			sha: parts[0],
			shortSHA: parts[1],
			author: parts[2],
			dateISO: parts[3],
			message: parts[4].trimmingCharacters(in: .whitespacesAndNewlines)
		)
	}

	/// A single line of blame output.
	struct BlameLine: Sendable {
		let line: Int
		let sha: String
		let author: String
		let dateISO: String
		let content: String
	}

	/// Get blame for a file, optionally for a specific line range.
	func blame(
		path: String,
		lineRange: ClosedRange<Int>? = nil,
		at repoURL: URL
	) async throws -> [BlameLine] {
		var args = [
			"blame",
			"--line-porcelain"
		]
		if let range = lineRange {
			args.append("-L")
			args.append("\(range.lowerBound),\(range.upperBound)")
		}
		args.append("--")
		args.append(path)

		let (stdout, stderr, exitCode) = try await runGit(args, at: repoURL)
		guard exitCode == 0 else {
			throw GitError(message: "git blame failed: \(stderr)")
		}

		return parseBlameOutput(stdout)
	}

	private func parseBlameOutput(_ output: String) -> [BlameLine] {
		var results: [BlameLine] = []
		let lines = output.components(separatedBy: "\n")

		var currentSHA: String?
		var currentAuthor: String?
		var currentAuthorTime: String?
		var currentLineNum: Int?
		var i = 0

		while i < lines.count {
			let line = lines[i]

			// First line of a block: <sha> <origLine> <finalLine> [<numLines>]
			if line.count >= 40, !line.hasPrefix("\t") {
				let parts = line.split(separator: " ", maxSplits: 3).map(String.init)
				if parts.count >= 3, parts[0].count == 40 {
					currentSHA = parts[0]
					currentLineNum = Int(parts[2])
				}
			} else if line.hasPrefix("author ") {
				currentAuthor = String(line.dropFirst("author ".count))
			} else if line.hasPrefix("author-time ") {
				// Unix timestamp
				if let timestamp = Int(line.dropFirst("author-time ".count)) {
					let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
					let formatter = ISO8601DateFormatter()
					formatter.formatOptions = [.withInternetDateTime]
					currentAuthorTime = formatter.string(from: date)
				}
			} else if line.hasPrefix("\t") {
				// Content line
				let content = String(line.dropFirst())
				if let sha = currentSHA,
				   let author = currentAuthor,
				   let time = currentAuthorTime,
				   let lineNum = currentLineNum {
					results.append(BlameLine(
						line: lineNum,
						sha: String(sha.prefix(7)),
						author: author,
						dateISO: time,
						content: content
					))
				}
			}

			i += 1
		}

		return results
	}

    // MARK: - Private Implementation
    
// Use AsyncStream to collect pipe output without locks/queues per chunk
    
	private func sha256Hex(_ data: Data) -> String {
		let digest = SHA256.hash(data: data)
		return digest.map { String(format: "%02x", $0) }.joined()
	}
	
	nonisolated static func mergedProcessEnvironment(
		baseEnvironment: [String: String],
		shellEnvironment: [String: String]
	) -> [String: String] {
		var environment = baseEnvironment
		environment.merge(shellEnvironment) { _, new in new }
		return environment
	}
	
	nonisolated static func friendlyErrorDescription(for rawMessage: String) -> String {
		let lowercased = rawMessage.lowercased()
		guard lowercased.contains("git-lfs"), lowercased.contains("command not found") else {
			return rawMessage
		}
		
		let action: String
		if lowercased.hasPrefix("git diff") {
			action = "Git diff"
		} else if lowercased.hasPrefix("git fetch") {
			action = "Git fetch"
		} else if lowercased.hasPrefix("git status") {
			action = "Git status"
		} else {
			action = "Git"
		}
		
		return "\(action) couldn’t launch git-lfs from RepoPrompt’s subprocess environment. If git-lfs is installed, restart RepoPrompt and make sure it’s available from your login shell PATH.\n\nRaw error: \(rawMessage)"
	}
	
	private func processEnvironment() async -> [String: String] {
		let baseEnvironment = ProcessInfo.processInfo.environment
		let shellEnvironment = await CLIEnvironmentCache.shared.environment(enableLogging: false)
		return Self.mergedProcessEnvironment(
			baseEnvironment: baseEnvironment,
			shellEnvironment: shellEnvironment
		)
	}

    private func runGit(
        _ args: [String],
        at repoURL: URL,
        env: [String: String] = [:],
        stdin: Data? = nil,
        requiresRepoContext: Bool = true
    ) async throws -> (String, String, Int32) {

        let process = Process()
        process.executableURL       = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments           = args
        process.currentDirectoryURL = repoURL

        var environment = await processEnvironment()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        
        // For gitfile worktrees, inject GIT_DIR and GIT_WORK_TREE to ensure
        // git commands operate in the correct context.
        // Skip for commands that don't need repo context (e.g., --no-index diffs).
        if requiresRepoContext, let layout = getLayout(for: repoURL), layout.isWorktree {
            environment["GIT_DIR"] = layout.gitDir.path
            environment["GIT_WORK_TREE"] = layout.workTreeRoot.path
        }
        
        environment.merge(env) { _, new in new }
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError  = errPipe

        var inPipe: Pipe?
        if let _ = stdin {
            let p = Pipe()
            process.standardInput = p
            inPipe = p
            // Suppress SIGPIPE on this write FD so closed readers won’t crash the app
            let fd = p.fileHandleForWriting.fileDescriptor
            _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        }

        // Build async streams for stdout/stderr and single consumer tasks to collect data
        final class SendableContinuation: @unchecked Sendable {
            private let _cont: AsyncStream<Data>.Continuation
            init(_ c: AsyncStream<Data>.Continuation) { _cont = c }
            func yield(_ d: Data) { _cont.yield(d) }
            func finish() { _cont.finish() }
        }
        var outBox: SendableContinuation!
        let outStream = AsyncStream<Data>(bufferingPolicy: .unbounded) { cont in outBox = SendableContinuation(cont) }
        var errBox: SendableContinuation!
        let errStream = AsyncStream<Data>(bufferingPolicy: .unbounded) { cont in errBox = SendableContinuation(cont) }

        // Freeze references to sendable boxes for cross-thread use
        // (avoid capturing vars in concurrently-executing closures)
        // Note: set handlers only after boxes are initialized
        let outC = outBox!
        let errC = errBox!

        let outCollector = Task(priority: .userInitiated) { () -> Data in
            var buf = Data()
            for await chunk in outStream { if !chunk.isEmpty { buf.append(chunk) } }
            return buf
        }
        let errCollector = Task(priority: .userInitiated) { () -> Data in
            var buf = Data()
            for await chunk in errStream { if !chunk.isEmpty { buf.append(chunk) } }
            return buf
        }

        return try await withTaskCancellationHandler(operation: {
            return try await withCheckedThrowingContinuation { continuation in
            // Drain stdout
            outPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { outC.yield(chunk) }
            }
            // Drain stderr
            errPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if !chunk.isEmpty { errC.yield(chunk) }
            }

            process.terminationHandler = { proc in
                // Stop handlers to break strong reference cycles
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil

                // Read any remaining bytes that arrived between the last readability
                // callback and process termination. Without this, stdout/stderr can be
                // truncated for larger outputs and parsing (e.g. --numstat) becomes empty.
                let outTail = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errTail = errPipe.fileHandleForReading.readDataToEndOfFile()

                // Send any remaining bytes, then finish streams and await collectors
                if !outTail.isEmpty { outC.yield(outTail) }
                if !errTail.isEmpty { errC.yield(errTail) }
                outC.finish()
                errC.finish()

                Task {
                    let stdoutData = await outCollector.value
                    let stderrData = await errCollector.value

                    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                    let stderr = String(data: stderrData, encoding: .utf8) ?? ""

                    continuation.resume(returning: (stdout, stderr, proc.terminationStatus))
                }
            }

            do {
                try process.run()

				// If stdin data was provided, write it after the process starts.
				// Use raw FD writes via FDWriteSupport instead of FileHandle.write()
				// because FileHandle.write() throws ObjC NSFileHandleOperationException
				// on broken pipe, which Swift do/catch cannot intercept.
				// If the write fails (e.g. child exited early or task was cancelled),
				// we still let the process terminate normally so stderr and exit code
				// are collected — this preserves fallback logic in runDiff.
                if let stdin {
                    if let inPipe {
						let fd = inPipe.fileHandleForWriting.fileDescriptor
						do {
							try FDWriteSupport.writeAll(stdin, to: fd)
						} catch {
							// Broken pipe / bad fd — child exited early or was terminated.
							// Swallow the error; the process termination handler will
							// still collect stdout, stderr, and exit code normally.
							// This preserves runDiff's pathspec fallback behavior.
						}
                        inPipe.fileHandleForWriting.closeFile()
                    }
                }
            } catch {
                // Ensure handlers are removed on failure
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
            }
            }
        }, onCancel: {
            // Stop reading, finish streams, and terminate the git process to avoid pent-up data
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            outC.finish()
            errC.finish()
            // Only terminate if the process actually started to avoid NSInvalidArgumentException
            if process.isRunning {
                process.terminate()
            }
        })
    }
    
    private func parseStatusOutput(_ output: String) -> [UncommittedFile] {
        return output
            .split(separator: "\n")
            .compactMap { raw in
                let line = String(raw)
                
                guard line.count >= 3 else { return nil }
                
                let statusCode = String(line.prefix(2))
                let status     = statusCode.trimmingCharacters(in: .whitespaces)
                
                let pathStart  = line.index(line.startIndex, offsetBy: 3)
                var path       = String(line[pathStart...])
                // Handle rename/copy lines which look like: "R  old/path -> new/path"
                if status.hasPrefix("R") || status.hasPrefix("C"),
                   let arrowRange = path.range(of: " -> ") {
                    path = String(path[arrowRange.upperBound...])
                }
                
                guard !path.hasSuffix("/") else { return nil }
                
                return UncommittedFile(path: path, status: status)
            }
    }
    
	private func makePathspecStdinData(_ files: [String]) -> Data {
		var data = Data()
		for path in files {
			if let encoded = path.data(using: .utf8) {
				data.append(encoded)
			}
			data.append(0)
		}
		return data
	}
	
	private func shouldFallbackFromPathspecError(_ error: Error) -> Bool {
		guard let gitError = error as? GitError else { return false }
		let message = gitError.message.lowercased()
		return message.contains("unknown option") || message.contains("pathspec-from-file")
	}
    
    private func parseBranchOutput(_ output: String) -> [Branch] {
        return output
            .split(separator: "\n")
            .compactMap { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { return nil }
                
                let isCurrent = trimmed.hasPrefix("*")
                let name = isCurrent ?
                    String(trimmed.dropFirst(2)) :
                    String(trimmed)
                
                return Branch(name: name, isCurrent: isCurrent, lastCommitDate: nil)
            }
    }
    
    private func parseBranchOutputWithDates(_ output: String) -> [Branch] {
        return output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count >= 2 else { return nil }
                
                let name = parts[0]
                let dateString = parts[1]
                let isCurrent = parts.count > 2 && parts[2] == "*"
                let date = parseGitDate(dateString)
                
                return Branch(name: name, isCurrent: isCurrent, lastCommitDate: date)
            }
    }
    
    private func parseTagOutputWithDates(_ output: String) -> [Tag] {
        return output
            .split(separator: "\n")
            .compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
                guard !parts.isEmpty else { return nil }
                
                let name = parts[0]
                let date = parts.count > 1 ? parseGitDate(parts[1]) : nil
                
                return Tag(name: name, commitDate: date)
            }
    }

    // Accept both Git's "yyyy-MM-dd HH:mm:ss Z" (e.g. "+0000") and RFC3339
    private static let gitDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return df
    }()
    private static let rfc3339Formatter: ISO8601DateFormatter = {
        let df = ISO8601DateFormatter()
        df.formatOptions = [.withInternetDateTime, .withSpaceBetweenDateAndTime]
        return df
    }()
    private func parseGitDate(_ s: String) -> Date? {
        if let d = Self.gitDateFormatter.date(from: s) { return d }
        return Self.rfc3339Formatter.date(from: s)
    }

	private func untrackedLineStats(for path: String, repoURL: URL) -> (additions: Int?, deletions: Int?) {
		let fileURL = repoURL.appendingPathComponent(path)
		guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
			return (nil, nil)
		}
		defer {
			try? handle.close()
		}

		let chunkSize = 64 * 1024
		var sawData = false
		var lineCount = 0
		var lastByte: UInt8?

		while true {
			guard let data = try? handle.read(upToCount: chunkSize),
				!data.isEmpty else {
				break
			}
			sawData = true
			for byte in data {
				if byte == 0 {
					return (nil, nil)
				}
				if byte == 0x0A {
					lineCount += 1
				}
				lastByte = byte
			}
		}

		if sawData {
			if let lastByte, lastByte != 0x0A {
				lineCount += 1
			}
		}

		return (lineCount, 0)
	}
    
    /// Parses `git diff --numstat` output into a map of path → (additions, deletions)
    nonisolated func parseNumstatOutput(_ output: String) -> [String: (Int?, Int?)] {
        var map: [String: (Int?, Int?)] = [:]
        
        for rawLine in output.split(separator: "\n") {
            let parts = rawLine.split(separator: "\t", maxSplits: 2).map(String.init)
            guard parts.count == 3 else { continue }
            
            let addStr = parts[0]
            let delStr = parts[1]
            let pathRaw = parts[2]
            let path = normalizeRenamedPath(pathRaw)
            
            let additions = Int(addStr)   // nil when "-"
            let deletions = Int(delStr)
            
            map[path] = (additions, deletions)
        }
        return map
    }
    
    /// Convert numstat rename formats to the final/new path so they line up with name-status.
    /// Handles:
    ///  - "old/path => new/path"
    ///  - "dir/{old => new}/file.swift"
    nonisolated func normalizeRenamedPath(_ s: String) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Brace segment renames: "a/{old => new}/b"
        if trimmed.contains("{"), trimmed.contains("}"), trimmed.contains(" => ") {
            var out = ""
            var i = trimmed.startIndex
            var handledBraceRename = false
            while i < trimmed.endIndex {
                if trimmed[i] == "{", let end = trimmed[i...].firstIndex(of: "}") {
                    let inner = trimmed[trimmed.index(after: i)..<end]
                    if let sep = inner.range(of: " => ") {
                        handledBraceRename = true
                        out += inner[sep.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                    } else {
                        out.append("{")
                        out += inner
                        out.append("}")
                    }
                    i = trimmed.index(after: end)
                } else {
                    out.append(trimmed[i])
                    i = trimmed.index(after: i)
                }
            }
            if handledBraceRename {
                return out
            }
        }
        
        // Simple "old/path => new/path" whole-path rename
        if let arrow = trimmed.range(of: " => ") {
            return String(trimmed[arrow.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        return trimmed
    }
    
    /// Parses `git diff --name-status` lines into a map of path → single-letter status
    nonisolated func parseNameStatusOutput(_ output: String) -> [String: String] {
        var map: [String: String] = [:]
        
        for rawLine in output.split(separator: "\n") {
            let parts = rawLine
                .split(separator: "\t", omittingEmptySubsequences: false)
                .map(String.init)
            guard !parts.isEmpty else { continue }
            
            let statusCode = parts[0].trimmingCharacters(in: .whitespaces)
            
            // Handle rename/copy which provide two paths
            let path: String
            if statusCode.hasPrefix("R") || statusCode.hasPrefix("C") {
                // new path is last field
                path = parts.last ?? ""
            } else {
                path = parts.count > 1 ? parts[1] : ""
            }
            
            if !path.isEmpty {
                map[path] = String(statusCode.prefix(1)) // e.g. "M"
            }
        }
        return map
    }
}

// MARK: - Shell Escaping Extension

private extension String {
    /// Returns a single-quoted string the shell treats as one token
    var shellEscaped: String {
        replacingOccurrences(of: "'", with: "'\\''").surrounding(with: "'")
    }
    
    func surrounding(with quote: String) -> String {
        quote + self + quote
    }
}

private extension Sequence where Element == String {
    func shellEscaped() -> [String] {
        map { $0.shellEscaped }
    }
}
