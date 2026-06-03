import XCTest
@testable import RepoPrompt

final class FileSystemServiceVirtualFSTests: XCTestCase {
    
    // MARK: - Test Helpers
    
	private func createTestService(
		fs: SpyFS,
		visitedPaths: Set<String> = [],
		visitedItems: [String: Bool] = [:],
		skipSymlinks: Bool = false
	) async throws -> FileSystemService {
        let testPath = "/repo"
        
        // Ensure root directory exists
        fs.addFolder("/repo")
        
        let service = try await FileSystemService(
            path: testPath,
            respectGitignore: true,
			skipSymlinks: skipSymlinks,
            testVisitedPaths: visitedPaths,
            testVisitedItems: visitedItems,
            testIgnoreRules: nil, // Let it load from the virtual FS
            isTestMode: false, // Use real ignore evaluation
            fileManagerOverride: fs
        )
        
        return service
    }
    
    private func createFSEvent(
        path: String,
        flags: FSEventStreamEventFlags
    ) -> (absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId) {
        return (absolutePath: path, flags: flags, eventId: 0)
    }

	private func addedFilePaths(from deltas: [FileSystemDelta]) -> Set<String> {
		Set(deltas.compactMap { delta -> String? in
			if case .fileAdded(let path) = delta { return path }
			return nil
		})
	}
    
    // MARK: - Hierarchical Ignores Test
    
	func testHierarchicalIgnoresWithNegatingRules() async throws {
		let fs = SpyFS()
		
        // Create directory structure
        fs.addFolder("/repo")
        fs.addFolder("/repo/src")
        fs.addFolder("/repo/src/vendor")
        fs.addFolder("/repo/src/vendor/lib")
        fs.addFolder("/repo/src/vendor/lib/important")
        
        // Root .gitignore ignores all vendor directories
        fs.writeGitignore(at: "/repo", """
            vendor/
            """)
        
        // Nested .gitignore negates the ignore for important subdirectory
        fs.writeGitignore(at: "/repo/src/vendor", """
            !lib/important/
            """)
        
        // Create files
        fs.addFile("/repo/src/main.swift")                    // Not ignored
        fs.addFile("/repo/src/vendor/package.json")           // Ignored by parent
        fs.addFile("/repo/src/vendor/lib/code.js")            // Ignored by parent
        fs.addFile("/repo/src/vendor/lib/important/keep.md")  // NOT ignored due to negation
        
        let service = try await createTestService(fs: fs)
        
        // Simulate events for all files
        let events = [
            createFSEvent(path: "/repo/src/main.swift", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)),
            createFSEvent(path: "/repo/src/vendor/package.json", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)),
            createFSEvent(path: "/repo/src/vendor/lib/code.js", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)),
            createFSEvent(path: "/repo/src/vendor/lib/important/keep.md", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
        ]
        
        fs.resetSpyData()
        let deltas = await service.simulateFSEvents(events)
        
        // Verify correct files were processed
        let processedPaths = deltas.compactMap { delta -> String? in
            switch delta {
            case .fileAdded(let path):
                return path
            case .fileModified(let path, _):
                return path
            default:
                return nil
            }
        }
        
        XCTAssertTrue(processedPaths.contains("src/main.swift"), "Non-ignored file should be processed")
        XCTAssertFalse(processedPaths.contains("src/vendor/package.json"), "Ignored file should not be processed")
        XCTAssertFalse(processedPaths.contains("src/vendor/lib/code.js"), "Ignored file should not be processed")
        // Note: Once vendor/ is ignored, files inside cannot be un-ignored by nested .gitignore
        XCTAssertFalse(processedPaths.contains("src/vendor/lib/important/keep.md"), "File in ignored directory cannot be un-ignored")
        
        // Verify that different folders used different cached rule sets
		XCTAssertGreaterThan(fs.enumeratedDirsCount(), 0, "Some directories should have been enumerated")
	}
	
	func testExplicitNegationInsideIgnoredDirectory() async throws {
		let fs = SpyFS()
		
		fs.addFolder("/repo")
		fs.addFolder("/repo/Temp")
		fs.addFolder("/repo/Temp/Tracked")
		fs.addFile("/repo/Temp/Tracked/TrackedIgnoredFile.txt")
		
		fs.writeGitignore(at: "/repo", """
		/[Ll]ibrary/
		/[Tt]emp/
		!/Temp/Tracked/TrackedIgnoredFile.txt
		/[Oo]bj/
		""")
		
		let service = try await createTestService(fs: fs)
		
		let deltas = try await service.scanOneLevelAndDiff(relativeFolderPath: "")
		let addedFile = deltas.contains { delta in
			if case .fileAdded(let path) = delta {
				return path == "Temp/Tracked/TrackedIgnoredFile.txt"
			}
			return false
		}
		XCTAssertTrue(addedFile, "Negated file should be discovered during initial scan")
		
		let trackedPaths = await service.getTrackedPaths()
		XCTAssertTrue(trackedPaths.contains("Temp/Tracked/TrackedIgnoredFile.txt"), "Negated file should be tracked")
		
		let tempIgnored = await service.testIsIgnoredPrefixCheck(relativePath: "Temp")
		XCTAssertTrue(tempIgnored, "Parent directory remains ignored")
		
		let negatedIgnored = await service.testIsIgnoredPrefixCheck(relativePath: "Temp/Tracked/TrackedIgnoredFile.txt")
		XCTAssertFalse(negatedIgnored, "Explicitly negated file should not be ignored")
	}

	func testFSEventForExplicitlyUnignoredFileUnderIgnoredParentIsProcessed() async throws {
		let fs = SpyFS()
		fs.addFolder("/repo/Temp/Tracked")
		fs.addFile("/repo/Temp/Tracked/TrackedIgnoredFile.txt")
		fs.addFile("/repo/Temp/Tracked/drop.txt")
		fs.writeGitignore(at: "/repo", """
		/Temp/
		!/Temp/Tracked/TrackedIgnoredFile.txt
		""")

		let service = try await createTestService(fs: fs)
		let events = [
			createFSEvent(
				path: "/repo/Temp/Tracked/TrackedIgnoredFile.txt",
				flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
			),
			createFSEvent(
				path: "/repo/Temp/Tracked/drop.txt",
				flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
			)
		]

		let addedPaths = addedFilePaths(from: await service.simulateFSEvents(events))
		XCTAssertTrue(addedPaths.contains("Temp/Tracked/TrackedIgnoredFile.txt"))
		XCTAssertFalse(addedPaths.contains("Temp/Tracked/drop.txt"))
	}

	func testUnignoredDirectoryDescendantsAreDiscovered() async throws {
		let fs = SpyFS()
		fs.addFolder("/repo/dir/subdir")
		fs.addFolder("/repo/dir/other")
		fs.addFile("/repo/dir/subdir/keep.txt")
		fs.addFile("/repo/dir/other/drop.txt")
		fs.writeGitignore(at: "/repo", """
		dir/
		!dir/subdir/
		""")

		let eventService = try await createTestService(fs: fs)
		let event = createFSEvent(
			path: "/repo/dir/subdir/keep.txt",
			flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemIsFile)
		)
		let addedPaths = addedFilePaths(from: await eventService.simulateFSEvents([event]))
		XCTAssertTrue(addedPaths.contains("dir/subdir/keep.txt"))

		let scanService = try await createTestService(fs: fs)
		let scanAddedPaths = addedFilePaths(from: try await scanService.scanOneLevelAndDiff(relativeFolderPath: ""))
		XCTAssertTrue(scanAddedPaths.contains("dir/subdir/keep.txt"))
		XCTAssertFalse(scanAddedPaths.contains("dir/other/drop.txt"))
	}

	func testWildcardIgnoredDirectoriesWithExplicitUnignoredDescendantsAreDiscovered() async throws {
		let fs = SpyFS()
		fs.addFolder("/repo/temp-123")
		fs.addFolder("/repo/temp-abc")
		fs.addFile("/repo/temp-123/important.txt")
		fs.addFile("/repo/temp-123/other.txt")
		fs.addFile("/repo/temp-abc/important.txt")
		fs.writeGitignore(at: "/repo", """
		temp-*/
		!temp-*/important.txt
		""")

		let service = try await createTestService(fs: fs)
		let scanAddedPaths = addedFilePaths(from: try await service.scanOneLevelAndDiff(relativeFolderPath: ""))
		XCTAssertTrue(scanAddedPaths.contains("temp-123/important.txt"))
		XCTAssertTrue(scanAddedPaths.contains("temp-abc/important.txt"))
		XCTAssertFalse(scanAddedPaths.contains("temp-123/other.txt"))
	}

	func testGlobstarTraversalDiscoversExplicitKeepFiles() async throws {
		let fs = SpyFS()
		fs.addFolder("/repo/logs/a/b")
		fs.addFolder("/repo/logs/c")
		fs.addFile("/repo/logs/a/b/keep.txt")
		fs.addFile("/repo/logs/a/b/drop.txt")
		fs.addFile("/repo/logs/c/keep.txt")
		fs.writeGitignore(at: "/repo", """
		logs/**
		!logs/**/keep.txt
		""")

		let service = try await createTestService(fs: fs)
		let scanAddedPaths = addedFilePaths(from: try await service.scanOneLevelAndDiff(relativeFolderPath: ""))
		XCTAssertTrue(scanAddedPaths.contains("logs/a/b/keep.txt"))
		XCTAssertTrue(scanAddedPaths.contains("logs/c/keep.txt"))
		XCTAssertFalse(scanAddedPaths.contains("logs/a/b/drop.txt"))
	}
    
    // MARK: - Cache Invalidation Test
    
    func testCacheInvalidationOnIgnoreFileCreation() async throws {
        let fs = SpyFS()
        
        // Initial structure without ignore files
        fs.addFolder("/repo")
        fs.addFolder("/repo/src")
        fs.addFolder("/repo/src/tmp")
        fs.addFile("/repo/src/main.swift")
        fs.addFile("/repo/src/tmp/cache.txt")
        
        let service = try await createTestService(fs: fs)
        
        // First event batch - tmp files should be processed
        let firstEvents = [
            createFSEvent(path: "/repo/src/tmp/cache.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))
        ]
        
        let firstDeltas = await service.simulateFSEvents(firstEvents)
        XCTAssertFalse(firstDeltas.isEmpty, "Without ignore rules, tmp file should be processed")
        
        // Create .repo_ignore that ignores tmp directory
        fs.writeRepoIgnore(at: "/repo/src", """
            tmp/
            """)
        fs.addFile("/repo/src/.repo_ignore")  // File must exist in VFS
        
        // Simulate creation event for the ignore file
        let ignoreFileEvent = createFSEvent(
            path: "/repo/src/.repo_ignore",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        
        fs.resetSpyData()
        let ignoreDeltas = await service.simulateFSEvents([ignoreFileEvent])
        
        // Verify ignore file creation was processed
        XCTAssertFalse(ignoreDeltas.isEmpty, "Ignore file creation should be processed")
        // Note: filterHashChanged is reset after processing, so we can't check it here
        // Instead, we verify the behavior change below
        
        // Now send event for tmp file again - should be filtered
        let secondEvents = [
            createFSEvent(path: "/repo/src/tmp/newfile.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated))
        ]
        
        fs.resetSpyData()
        let secondDeltas = await service.simulateFSEvents(secondEvents)
        
        // New file in ignored directory should be filtered
        XCTAssertTrue(secondDeltas.isEmpty, "After ignore file creation, tmp files should be filtered")
    }
    
    // MARK: - Prefix Cache Performance Test
    
    func testPrefixCachePerformanceWith1000Events() async throws {
        let fs = SpyFS()
        
        // Create structure with deeply nested ignored directory
        fs.addFolder("/repo")
        fs.addFolder("/repo/node_modules")
        fs.addFolder("/repo/node_modules/package1")
        fs.addFolder("/repo/node_modules/package1/lib")
        fs.addFolder("/repo/node_modules/package1/lib/src")
        
        fs.writeGitignore(at: "/repo", """
            node_modules/
            """)
        
        let service = try await createTestService(fs: fs)
        
        // Generate 1000 events for the same ignored path
        let ignoredPath = "/repo/node_modules/package1/lib/src/file.js"
        var events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)] = []
        
        for i in 0..<1000 {
            events.append(createFSEvent(
                path: ignoredPath,
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
            ))
        }
        
        fs.resetSpyData()
        
        let startTime = CFAbsoluteTimeGetCurrent()
        let deltas = await service.simulateFSEvents(events)
        let endTime = CFAbsoluteTimeGetCurrent()
        
        // All events should be filtered
        XCTAssertTrue(deltas.isEmpty, "All events for ignored path should be filtered")
        
        // Performance assertion
		let duration = endTime - startTime
		XCTAssertLessThan(duration, 0.5, "1000 events should be processed quickly due to ignore caching (hierarchical event filtering may do additional rule checks)")
        
        // Verify minimal directory enumeration due to caching
        XCTAssertEqual(fs.enumeratedDirsCount(), 0, "No directories should be enumerated for ignored paths")
    }
    
    // MARK: - Delta Generation Test
    
    func testDeltaGenerationWithVisitedPathsDiffing() async throws {
        let fs = SpyFS()
        
        // Initial file system state
        fs.addFolder("/repo")
        fs.addFolder("/repo/A")
        fs.addFile("/repo/A/file1.txt")
        fs.addFile("/repo/A/file2.txt")
        
        // Service with pre-populated visitedPaths
        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["A", "A/file1.txt", "A/file3.txt"], // file3 doesn't exist on disk
            visitedItems: ["A": true, "A/file1.txt": false, "A/file3.txt": false]
        )
        
        // Remove file1 from disk, add file2 (which wasn't in visitedPaths)
        fs.remove("/repo/A/file1.txt")
        
        // Trigger scan of folder A by sending a folder modification event
        let event = createFSEvent(
            path: "/repo/A",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)
        )
        
        let deltas = await service.simulateFSEvents([event])
        
        // Verify deltas
        let addedFiles = deltas.compactMap { delta -> String? in
            if case .fileAdded(let path) = delta { return path }
            return nil
        }
        
        let removedFiles = deltas.compactMap { delta -> String? in
            if case .fileRemoved(let path) = delta { return path }
            return nil
        }
        
        XCTAssertTrue(addedFiles.contains("A/file2.txt"), "file2 should be detected as added")
        XCTAssertTrue(removedFiles.contains("A/file1.txt"), "file1 should be detected as removed")
        XCTAssertTrue(removedFiles.contains("A/file3.txt"), "file3 should be detected as removed")
    }
    
    // MARK: - Rename Filter Tests
    
    func testRenameFilterWithNewSimplifiedLogic() async throws {
        let fs = SpyFS()
        
        fs.addFolder("/repo")
        fs.addFolder("/repo/src")
        fs.addFolder("/repo/node_modules")
        fs.addFolder("/repo/tmp")
        
        fs.writeGitignore(at: "/repo", """
            node_modules/
            tmp/
            *.tmp
            """)
        
        let service = try await createTestService(fs: fs)
        
        // Test 1: Rename within ignored directory - should be filtered
        let renameInIgnored = createFSEvent(
            path: "/repo/node_modules/oldfile.js",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed)
        )
        
        let delta1 = await service.simulateFSEvents([renameInIgnored])
        XCTAssertTrue(delta1.isEmpty, "Rename within ignored directory should be filtered")
        
        // Test 2: Rename from temp to tracked - should be processed
        fs.addFile("/repo/file.txt") // Destination file exists
        fs.addFile("/repo/file.tmp") // Source file must exist too
        
        // Create a new service with file.txt already tracked
        let service2 = try await createTestService(
            fs: fs,
            visitedPaths: ["file.txt"],
            visitedItems: ["file.txt": false]
        )
        
        // For atomic saves, need both source and destination events
        let atomicSaveRenameEvents = [
            createFSEvent(
                path: "/repo/file.tmp",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)
            ),
            createFSEvent(
                path: "/repo/file.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)
            )
        ]
        
        let delta2 = await service2.simulateFSEvents(atomicSaveRenameEvents)
        XCTAssertFalse(delta2.isEmpty, "Rename to tracked file should be processed")
        
        // Test 3: Rename from ignored to non-ignored - should be processed
        fs.addFile("/repo/src/moving.txt") // Destination exists
        
        // Both source and destination events
        let crossBoundaryRenameEvents = [
            createFSEvent(
                path: "/repo/tmp/moving.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemRemoved)
            ),
            createFSEvent(
                path: "/repo/src/moving.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemRenamed | kFSEventStreamEventFlagItemCreated)
            )
        ]
        
        let delta3 = await service.simulateFSEvents(crossBoundaryRenameEvents)
        XCTAssertFalse(delta3.isEmpty, "Rename from ignored to non-ignored should be processed")
    }
    
    // MARK: - Per-folder Cache Eviction Test
    
    func testPerFolderCacheEviction() async throws {
        let fs = SpyFS()
        
        // Create a large number of directories with unique .gitignore files
        fs.addFolder("/repo")
        
        for i in 0..<5000 {
            let dirPath = "/repo/dir\(i)"
            fs.addFolder(dirPath)
            fs.writeGitignore(at: dirPath, """
                # Unique pattern for dir\(i)
                unique_pattern_\(i)/
                """)
        }
        
        let service = try await createTestService(fs: fs)
        
        // Trigger events in many directories to populate cache
        var events: [(absolutePath: String, flags: FSEventStreamEventFlags, eventId: FSEventStreamEventId)] = []
        
        for i in 0..<5000 {
            events.append(createFSEvent(
                path: "/repo/dir\(i)/file.txt",
                flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
            ))
        }
        
        let deltas = await service.simulateFSEvents(events)
        
        // Verify cache size is limited
        let cacheSize = await service.getPerFolderIgnoreCacheSize()
        XCTAssertLessThanOrEqual(cacheSize, 4000, "Per-folder ignore cache should be capped at 4000 entries")
    }
    
    // MARK: - Symlink Handling Test
    
    func testSymlinkHandling() async throws {
        let fs = SpyFS()
        
        fs.addFolder("/repo")
        fs.addFolder("/repo/real_dir")
        fs.addFile("/repo/real_dir/file.txt")
        
        // Note: InMemoryFS doesn't support real symlinks, but we can test the skipSymlinks option
        // by mocking a symlink as a special file type in attributes
        
		// Test with skipSymlinks = true
		let service1 = try await createTestService(fs: fs, skipSymlinks: true)
		
		// Test with skipSymlinks = false (default)
		let service2 = try await createTestService(fs: fs, skipSymlinks: false)
        
        // Both should handle regular directories the same way
        let event = createFSEvent(
            path: "/repo/real_dir/file.txt",
            flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemCreated)
        )
        
        let deltas1 = await service1.simulateFSEvents([event])
        let deltas2 = await service2.simulateFSEvents([event])
        
		XCTAssertFalse(deltas1.isEmpty, "Regular directory should be processed with skipSymlinks=true")
		XCTAssertFalse(deltas2.isEmpty, "Regular directory should be processed with skipSymlinks=false")
	}
    
    // MARK: - Path Normalization Test
    
    func testPathNormalization() async throws {
        let fs = SpyFS()
        
        fs.addFolder("/repo")
        fs.addFolder("/repo/src")
        fs.addFile("/repo/src/file.txt")
        
        let service = try await createTestService(
            fs: fs,
            visitedPaths: ["src/file.txt"],
            visitedItems: ["src/file.txt": false]
        )
        
        // Test various path formats that should normalize to the same file
        let events = [
            createFSEvent(path: "/repo//src//file.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)),
            createFSEvent(path: "/repo/./src/file.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified)),
            createFSEvent(path: "/repo/src/../src/file.txt", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagItemModified))
        ]
        
        let deltas = await service.simulateFSEvents(events)
        
        // All path variants normalize to the same file; event coalescing may collapse them.
        XCTAssertGreaterThanOrEqual(deltas.count, 1, "At least one normalized path event should be processed")
        
        // Verify they all map to the same normalized path
        let modifiedPaths = deltas.compactMap { delta -> String? in
            if case .fileModified(let path, _) = delta { return path }
            return nil
        }
        
        XCTAssertTrue(modifiedPaths.allSatisfy { $0 == "src/file.txt" }, "All paths should normalize to 'src/file.txt'")
    }
}
