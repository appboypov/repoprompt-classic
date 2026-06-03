import Foundation

// MARK: - VCS Resolved Repo

/// Represents a resolved VCS repository with its backend.
public struct VCSResolvedRepo: Sendable {
    /// The repository root URL.
    public let rootURL: URL
    
    /// The kind of VCS backend.
    public let backendKind: VCSBackendKind
    
    public init(rootURL: URL, backendKind: VCSBackendKind) {
        self.rootURL = rootURL
        self.backendKind = backendKind
    }
}

// MARK: - VCS Service

/// Central service for VCS operations that auto-detects and caches backends.
///
/// This service determines whether to use git or jj for a given repository:
/// 1. If `.jj` directory exists at the path → use Jujutsu backend
/// 2. If `.git` directory exists → use Git backend
/// 3. Otherwise, try `jj root` then `git rev-parse --show-toplevel` to find repo root
///
/// Policy: When both `.git` and `.jj` exist, prefer Jujutsu (jj colocates with git).
public actor VCSService {
    
    // MARK: - Singleton
    
    /// Shared instance of VCSService.
    public static let shared = VCSService()
    
    // MARK: - Properties
    
    /// Git backend instance (lazy-initialized).
    private var _gitBackend: GitBackend?
    
    /// Jujutsu backend instance (lazy-initialized).
    private var _jjBackend: JujutsuBackend?
    
    /// JJ command runner for availability checks.
    private let jjRunner: JJCommandRunner
    
    /// Cache of resolved repos by path.
    /// Key: standardized absolute path, Value: resolved repo info.
    private var resolvedRepoCache: [String: VCSResolvedRepo] = [:]
    
    /// Cache of backend kind per repo root.
    /// Key: repo root path, Value: backend kind.
    private var backendKindCache: [String: VCSBackendKind] = [:]
    
    /// Cache of Git repository layouts (for worktree awareness).
    /// Key: repo root path, Value: resolved layout
    /// Only populated for confirmed Git repos; absence means not yet resolved.
    private var gitLayoutCache: [String: GitRepositoryLayout] = [:]
    
    /// Whether jj is available on this system (cached after first check).
    private var _jjAvailable: Bool?
    
    // MARK: - Initialization
    
    public init(jjRunner: JJCommandRunner = JJCommandRunner()) {
        self.jjRunner = jjRunner
    }
    
    // MARK: - Backend Access
    
    /// Get the Git backend instance.
    func gitBackend() -> GitBackend {
        if let existing = _gitBackend {
            return existing
        }
        let backend = GitBackend()
        _gitBackend = backend
        return backend
    }
    
    /// Get the Jujutsu backend instance.
    public func jjBackend() -> JujutsuBackend {
        if let existing = _jjBackend {
            return existing
        }
        let backend = JujutsuBackend(runner: jjRunner)
        _jjBackend = backend
        return backend
    }
    
    /// Get a backend by kind.
    public func backend(for kind: VCSBackendKind) -> any VCSBackend {
        switch kind {
        case .git:
            return gitBackend()
        case .jujutsu:
            return jjBackend()
        }
    }
    
    // MARK: - Availability
    
    /// Check if jj is available on this system.
    public func isJJAvailable() async -> Bool {
        if let cached = _jjAvailable {
            return cached
        }
        let available = await jjRunner.isAvailable()
        _jjAvailable = available
        return available
    }
    
    /// Check if git is available on this system.
    /// Git is assumed available via /usr/bin/git on macOS.
    public func isGitAvailable() -> Bool {
        FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
    }
    
    // MARK: - Repository Resolution
    
    /// Resolve a path to its VCS repository information.
    /// Returns nil if the path is not in a VCS repository.
    ///
    /// - Parameter url: The starting path to search from.
    /// - Returns: The resolved repo info, or nil if not in a repo.
    public func resolveRepo(from url: URL) async -> VCSResolvedRepo? {
        let standardizedPath = url.standardizedFileURL.path
        
        // Check cache first
        if let cached = resolvedRepoCache[standardizedPath] {
            return cached
        }
        
        // Detect VCS type and find root
        if let result = await detectAndResolve(from: url) {
            // Cache by both the query path and the root path
            resolvedRepoCache[standardizedPath] = result
            resolvedRepoCache[result.rootURL.standardizedFileURL.path] = result
            backendKindCache[result.rootURL.standardizedFileURL.path] = result.backendKind
            return result
        }
        
        return nil
    }
    
    /// Get the backend for a known repository root.
    /// Use this when you already know the repo root from a previous resolve call.
    ///
    /// - Parameter rootURL: The repository root URL.
    /// - Returns: The appropriate backend for this repo.
    public func backend(forRepoRoot rootURL: URL) async -> any VCSBackend {
        let rootPath = rootURL.standardizedFileURL.path
        
        // Check cache first
        if let cachedKind = backendKindCache[rootPath] {
            return backend(for: cachedKind)
        }
        
        // Resolve to determine kind
        if let resolved = await resolveRepo(from: rootURL) {
            return backend(for: resolved.backendKind)
        }
        
        // Default to git if resolution fails
        return gitBackend()
    }
    
    /// Clear the resolution cache.
    /// Useful when workspace roots change.
    public func clearCache() {
        resolvedRepoCache.removeAll()
        backendKindCache.removeAll()
        gitLayoutCache.removeAll()
    }
    
    /// Remove a specific path from the cache.
    /// Also invalidates the resolved root if different from the input path.
    public func invalidateCache(for url: URL) {
        let path = url.standardizedFileURL.path
        
        // Get the resolved root path before removing (if cached)
        let rootPath = resolvedRepoCache[path]?.rootURL.standardizedFileURL.path
        
        // Remove caches for the input path
        resolvedRepoCache.removeValue(forKey: path)
        backendKindCache.removeValue(forKey: path)
        gitLayoutCache.removeValue(forKey: path)
        
        // Also remove caches for the resolved root if different
        if let rootPath, rootPath != path {
            resolvedRepoCache.removeValue(forKey: rootPath)
            backendKindCache.removeValue(forKey: rootPath)
            gitLayoutCache.removeValue(forKey: rootPath)
        }
    }
    
    // MARK: - Git Layout Access
    
    /// Get the Git repository layout for a known repo root.
    /// Returns nil for non-Git repos (including JJ colocated repos) or if layout cannot be resolved.
    ///
    /// This is useful for understanding worktree configurations:
    /// - `layout.isWorktree` indicates if this is a gitfile-based worktree
    /// - `layout.gitDir` is the actual git directory
    /// - `layout.commonDir` is the shared repo data (same as gitDir for non-worktrees)
    ///
    /// Note: For JJ colocated repos (where both .jj and .git exist), this returns nil
    /// because JJ is the preferred backend and Git layout details are not relevant.
    public func gitRepositoryLayout(forRepoRoot rootURL: URL) -> GitRepositoryLayout? {
        let rootPath = rootURL.standardizedFileURL.path
        
        // If we know this is a JJ repo, don't return Git layout
        // (JJ colocated repos have both .jj and .git, but JJ is preferred)
        if let knownKind = backendKindCache[rootPath], knownKind != .git {
            return nil
        }
        
        // Check cache first
        if let cached = gitLayoutCache[rootPath] {
            return cached
        }
        
        // Resolve layout
        guard let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: rootURL) else {
            return nil
        }
        
        // Cache and return
        gitLayoutCache[rootPath] = layout
        return layout
    }
    
    // MARK: - Detection Logic
    
    /// Detect the VCS type and find the repository root.
    private func detectAndResolve(from url: URL) async -> VCSResolvedRepo? {
        let fm = FileManager.default
        let startPath = url.standardizedFileURL.path
        
        // Walk up the directory tree looking for .jj or .git
        var currentURL = url.standardizedFileURL
        
        // Ensure we're starting from a directory
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: currentURL.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                currentURL = currentURL.deletingLastPathComponent()
            }
        }
        
        while currentURL.path != "/" && currentURL.path != "" {
            let jjPath = currentURL.appendingPathComponent(".jj").path
            let gitPath = currentURL.appendingPathComponent(".git").path
            
            let hasJJ = fm.fileExists(atPath: jjPath)
            let hasGit = fm.fileExists(atPath: gitPath)
            
            // Policy: prefer jj when both exist (jj colocates with git)
            if hasJJ {
                // Verify jj is actually available
                if await isJJAvailable() {
                    return VCSResolvedRepo(rootURL: currentURL, backendKind: .jujutsu)
                }
                // If jj not available but .jj exists, fall through to git check
            }
            
            if hasGit {
                // For .git files (worktrees/submodules), verify it's a valid gitfile
                // before treating as a Git repo. This avoids false positives from
                // arbitrary files named .git.
                var isGitDir: ObjCBool = false
                _ = fm.fileExists(atPath: gitPath, isDirectory: &isGitDir)
                
                if isGitDir.boolValue {
                    // .git is a directory - definitely a Git repo
                    let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: currentURL)
                    if let layout {
                        gitLayoutCache[currentURL.standardizedFileURL.path] = layout
                    }
                    return VCSResolvedRepo(rootURL: currentURL, backendKind: .git)
                } else {
                    // .git is a file - only treat as Git if it's a valid gitfile
                    if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: currentURL) {
                        gitLayoutCache[currentURL.standardizedFileURL.path] = layout
                        return VCSResolvedRepo(rootURL: currentURL, backendKind: .git)
                    }
                    // Invalid gitfile - continue searching up the tree
                }
            }
            
            currentURL = currentURL.deletingLastPathComponent()
        }
        
        // No .jj or .git found in directory walk
        // Try command-based detection as fallback
        
        // Try jj first if available
        if await isJJAvailable() {
            let jj = jjBackend()
            if let root = try? await jj.findRepoRoot(from: url) {
                return VCSResolvedRepo(rootURL: root, backendKind: .jujutsu)
            }
        }
        
        // Try git
        let git = gitBackend()
        if let root = try? await git.findRepoRoot(from: url) {
            // Cache the Git layout for worktree awareness
            if let layout = GitRepositoryLayoutResolver.resolve(atWorkTreeRoot: root) {
                gitLayoutCache[root.standardizedFileURL.path] = layout
            }
            return VCSResolvedRepo(rootURL: root, backendKind: .git)
        }
        
        return nil
    }
    
    // MARK: - Convenience Methods
    
    /// Check if a path is in a VCS repository.
    public func isRepository(at url: URL) async -> Bool {
        await resolveRepo(from: url) != nil
    }
    
    /// Get the repository root for a path, if any.
    public func repoRoot(from url: URL) async -> URL? {
        await resolveRepo(from: url)?.rootURL
    }
    
    /// Get the backend kind for a path.
    public func backendKind(for url: URL) async -> VCSBackendKind? {
        await resolveRepo(from: url)?.backendKind
    }
}

// MARK: - VCS Service Extensions for Common Operations

public extension VCSService {
    
    /// Get the current HEAD ID for a repository.
    func getHeadID(at repoURL: URL) async throws -> String {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getHeadID(at: repoURL)
    }
    
    /// Get the status fingerprint for a repository.
    func getStatusFingerprint(at repoURL: URL, baseRef: String = "HEAD") async throws -> GitDiffFingerprint {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getStatusFingerprint(at: repoURL, baseRef: baseRef)
    }
    
    /// Get changed files with statistics.
    func getChangedFilesStats(
        compare: GitDiffCompareSpec,
        includeUntrackedWhenApplicable: Bool = true,
        detectRenames: Bool = false,
        at repoURL: URL
    ) async throws -> [VCSUncommittedFile] {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getChangedFilesStats(
            compare: compare,
            includeUntrackedWhenApplicable: includeUntrackedWhenApplicable,
            detectRenames: detectRenames,
            at: repoURL
        )
    }
    
    /// Get diff text for a comparison.
    func getDiffText(
        compare: GitDiffCompareSpec,
        paths: [String]? = nil,
        contextLines: Int = 3,
        detectRenames: Bool = false,
        at repoURL: URL
    ) async throws -> String {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getDiffText(
            compare: compare,
            paths: paths,
            contextLines: contextLines,
            detectRenames: detectRenames,
            at: repoURL
        )
    }
    
    /// Get the current branch name.
    func getCurrentBranch(at repoURL: URL) async throws -> String? {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getCurrentBranch(at: repoURL)
    }
    
    /// Get local branches.
    func getLocalBranches(at repoURL: URL, limit: Int = 50) async throws -> [VCSBranch] {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getLocalBranches(at: repoURL, limit: limit)
    }
    
    /// Get the working status.
    func getWorkingStatus(at repoURL: URL) async throws -> VCSWorkingStatus {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getWorkingStatus(at: repoURL)
    }
    
    /// Get commit log summaries.
    func getLogSummaries(
        count: Int = 10,
        path: String? = nil,
        at repoURL: URL
    ) async throws -> [VCSCommitSummary] {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getLogSummaries(count: count, path: path, at: repoURL)
    }
    
    /// Get the commit graph.
    func getCommitGraph(maxLines: Int = 20, at repoURL: URL) async throws -> String {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getCommitGraph(maxLines: maxLines, at: repoURL)
    }
    
    /// Get commit info.
    func getCommitInfo(ref: String, at repoURL: URL) async throws -> VCSCommitInfo {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.getCommitInfo(ref: ref, at: repoURL)
    }
    
    /// Get blame for a file.
    func blame(
        path: String,
        lineRange: ClosedRange<Int>? = nil,
        at repoURL: URL
    ) async throws -> [VCSBlameLine] {
        let backend = await backend(forRepoRoot: repoURL)
        return try await backend.blame(path: path, lineRange: lineRange, at: repoURL)
    }
    
    /// Fetch from remotes.
    func fetch(at repoURL: URL) async throws {
        let backend = await backend(forRepoRoot: repoURL)
        try await backend.fetch(at: repoURL)
    }
    
    /// Get the capabilities for a repository.
    func capabilities(at repoURL: URL) async -> VCSCapabilities {
        let backend = await backend(forRepoRoot: repoURL)
        return backend.capabilities
    }
    
    /// Normalize a compare spec for a repository, returning any applicable warning.
    func normalizeCompareSpec(
        _ spec: GitDiffCompareSpec,
        at repoURL: URL
    ) async -> NormalizedCompareResult {
        let backend = await backend(forRepoRoot: repoURL)
        if let withWarnings = backend as? VCSBackendWithWarnings {
            return withWarnings.normalizeCompareSpecWithWarning(spec)
        }
        return NormalizedCompareResult(spec: backend.normalizeCompareSpec(spec), warning: nil)
    }
}
