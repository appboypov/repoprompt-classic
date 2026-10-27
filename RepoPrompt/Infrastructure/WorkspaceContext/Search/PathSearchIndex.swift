import Foundation

// Define size_t for C interop
typealias size_t = Int

/// High-performance path search index using C implementation for binary search
/// Optimized for >1k files with O(log n + k*m) search complexity.
/// Paths can be added and removed one batch at a time, so a large index never needs a rebuild
/// for a small change.
actor PathSearchIndex {
    // MARK: - Types
    
    struct Candidate {
        /// The position of the path in the paths the index was given, counted over every add since the
        /// last rebuild. A removed path keeps its position; no other path takes it.
        let index: Int
        let path: String
        let filename: String
        let isFolder: Bool
    }
    
    // MARK: - Private State
    
    private var cIndex: OpaquePointer? // path_search_index_t*
    /// Whether the path at each position is a folder.
    private var folderFlags: [Bool] = []
    private var liveCount = 0
    
    // MARK: - Initialization
    
    init(paths: [String], folderPaths: [String] = []) async {
        add(paths, areFolders: false)
        add(folderPaths, areFolders: true)
    }
    
    init() {
        self.cIndex = nil
    }
    
    deinit {
        if let index = cIndex {
            path_search_destroy(index)
        }
    }
    
    // MARK: - Public API
    
    /// Search for paths matching the given pattern
    /// - Parameters:
    ///   - pattern: Search pattern (supports wildcards and regex)
    ///   - limit: Maximum number of results to return
    /// - Returns: The matching candidates in path order
    func search(_ pattern: String, limit: Int = 300) async -> [Candidate] {
        guard let index = cIndex else { return [] }
        
        let result = pattern.withCString { patternCStr in
            path_search_find(index, patternCStr, limit)
        }
        
        guard let searchResult = result else { return [] }
        defer { search_result_destroy(searchResult) }
        
        let resultPtr = UnsafePointer<search_result_t>(searchResult)
        let count = Int(resultPtr.pointee.count)
        guard let indices = resultPtr.pointee.indices else { return [] }
        
        var candidates: [Candidate] = []
        candidates.reserveCapacity(count)
        for i in 0..<count {
            let slot = Int(indices[i])
            guard let path = path(at: slot) else { continue }
            candidates.append(Candidate(
                index: slot,
                path: path,
                filename: Self.filename(of: path),
                isFolder: folderFlags[slot]
            ))
        }
        return candidates
    }
    
    /// Rebuild the index with new paths
    func rebuild(paths: [String]) async {
        if let oldIndex = cIndex {
            path_search_destroy(oldIndex)
            cIndex = nil
        }
        folderFlags = []
        liveCount = 0
        add(paths, areFolders: false)
    }
    
    /// Adds the paths the index does not hold yet.
    func add(_ paths: [String], areFolders: Bool) {
        guard !paths.isEmpty else { return }
        var slots = [Int](repeating: -1, count: paths.count)
        let added = Self.withCPaths(paths) { cPaths -> Bool in
            guard let index = cIndex else {
                cIndex = path_search_create(cPaths, paths.count)
                guard cIndex != nil else { return false }
                slots = Array(0..<paths.count)
                return true
            }
            return slots.withUnsafeMutableBufferPointer { buffer in
                path_search_add(index, cPaths, paths.count, buffer.baseAddress)
            }
        }
        guard added else { return }
        // Positions are handed out in order from the end, so each new one extends the flags.
        for slot in slots where slot >= 0 {
            folderFlags.append(areFolders)
            liveCount += 1
            assert(folderFlags.count == slot + 1)
        }
    }
    
    /// Removes each path and every path under it.
    func remove(_ paths: [String]) {
        guard let index = cIndex, !paths.isEmpty else { return }
        let removed = Self.withCPaths(paths) { cPaths in
            var removedSlots: UnsafeMutablePointer<size_t>?
            let removed = path_search_remove(index, cPaths, paths.count, &removedSlots)
            path_search_free_slots(removedSlots)
            return removed
        }
        liveCount -= removed
    }
    
    /// Get path at specific index
    func path(at index: Int) -> String? {
        guard let cIndex, index >= 0, let path = path_search_path(cIndex, index) else { return nil }
        return String(cString: path)
    }
    
    /// Get filename at specific index
    func filename(at index: Int) -> String? {
        path(at: index).map(Self.filename(of:))
    }
    
    /// Get total number of indexed paths
    var count: Int {
        liveCount
    }
    
    // MARK: - Helpers
    
    private static func filename(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }
    
    private static func withCPaths<Result>(
        _ paths: [String],
        _ body: (UnsafePointer<UnsafePointer<CChar>?>?) -> Result
    ) -> Result {
        let cPaths = paths.map { strdup($0) }
        defer { cPaths.forEach { free($0) } }
        let pointers = cPaths.map { UnsafePointer<CChar>($0) }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress) }
    }
}

// MARK: - LRU Cache Actor

/// Thread-safe LRU cache implementation using actors
actor LRUCacheActor<Key: Hashable, Value> {
    private struct Entry {
        let value: Value
        var timestamp: Date
    }
    
    private var cache: [Key: Entry] = [:]
    private let capacity: Int
    
    init(capacity: Int) {
        self.capacity = capacity
    }
    
    func value(for key: Key) -> Value? {
        if var entry = cache[key] {
            entry.timestamp = Date()
            cache[key] = entry
            return entry.value
        }
        return nil
    }
    
    func set(_ value: Value, for key: Key) {
        cache[key] = Entry(value: value, timestamp: Date())
        
        // Evict oldest if over capacity
        if cache.count > capacity {
            let oldest = cache.min { $0.value.timestamp < $1.value.timestamp }
            if let oldestKey = oldest?.key {
                cache.removeValue(forKey: oldestKey)
            }
        }
    }
    
    func clear() {
        cache.removeAll()
    }
}

// MARK: - C Bridge Functions

// Import the C functions
@_silgen_name("path_search_create")
func path_search_create(_ paths: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> OpaquePointer?

@_silgen_name("path_search_destroy")
func path_search_destroy(_ index: OpaquePointer?)

@_silgen_name("path_search_add")
func path_search_add(_ index: OpaquePointer?, _ paths: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int, _ slots: UnsafeMutablePointer<size_t>?) -> Bool

@_silgen_name("path_search_remove")
func path_search_remove(_ index: OpaquePointer?, _ paths: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int, _ removedSlots: UnsafeMutablePointer<UnsafeMutablePointer<size_t>?>?) -> Int

@_silgen_name("path_search_free_slots")
func path_search_free_slots(_ slots: UnsafeMutablePointer<size_t>?)

@_silgen_name("path_search_path")
func path_search_path(_ index: OpaquePointer?, _ slot: Int) -> UnsafePointer<CChar>?

@_silgen_name("path_search_find")
func path_search_find(_ index: OpaquePointer?, _ pattern: UnsafePointer<CChar>?, _ limit: Int) -> OpaquePointer?

@_silgen_name("search_result_destroy")
func search_result_destroy(_ result: OpaquePointer?)

// C struct definitions for bridging
struct search_result_t {
    var indices: UnsafeMutablePointer<size_t>?
    var count: size_t
    var capacity: size_t
}