import Foundation

struct BenchmarkTaskExecution: Sendable {
	let task: BenchmarkTaskSpec
	let baseline: BenchmarkMockFileSystemSnapshot
	let result: BenchmarkTaskExecResult
}

struct BenchmarkSeedExecution: Sendable {
	let seed: UInt32
	let executions: [BenchmarkTaskExecution]
}

actor AsyncSemaphore {
	private var value: Int
	private var waiters: [CheckedContinuation<Void, Never>] = []
	
	init(value: Int) {
		self.value = max(1, value)
	}
	
	func wait() async {
		if value > 0 {
			value -= 1
			return
		}
		await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
			waiters.append(continuation)
		}
	}
	
	func signal() {
		if waiters.isEmpty {
			value += 1
		} else {
			let continuation = waiters.removeFirst()
			continuation.resume()
		}
	}
}

final class BenchmarkEngine {
	private let generator: BenchmarkTaskGenerator
	private let executor: BenchmarkTaskExecutor
	private let config: BenchConfig
	private let parallelism: Int
	
	init(generator: BenchmarkTaskGenerator,
		executor: BenchmarkTaskExecutor,
		config: BenchConfig,
		parallelism: Int = 4) {
		self.generator = generator
		self.executor = executor
		self.config = config
		self.parallelism = max(1, parallelism)
	}
	
	func run(
		coreSeed: UInt32,
		subSeedCount: Int = 5,
		progress: ((BenchmarkProgressEvent) -> Void)? = nil
	) async -> [BenchmarkSeedExecution] {
		let seeds = BenchmarkSeedUtilities.deriveSubSeeds(coreSeed: coreSeed, count: subSeedCount)
		let languagePlan = Self.buildLanguagePlan(count: seeds.count)
		let progressCallback = progress
		await MainActor.run {
			progressCallback?(.started(totalSeeds: seeds.count))
		}
		let generator = self.generator
		let executor = self.executor
		let config = self.config
		let parallelism = self.parallelism
		let seedCount = seeds.count
		
		return await withTaskCancellationHandler(operation: {
			var orderedResults: [BenchmarkSeedExecution?] = Array(repeating: nil, count: seeds.count)
			
			await withTaskGroup(of: (Int, BenchmarkSeedExecution?).self) { group in
				for (index, seed) in seeds.enumerated() {
					group.addTask {
						if Task.isCancelled {
							return (index, nil)
						}
						let execution = await BenchmarkEngine.executeSeed(
							index: index,
							seed: seed,
							seedCount: seedCount,
							generator: generator,
							executor: executor,
							config: config,
							parallelism: parallelism,
							language: languagePlan.indices.contains(index) ? languagePlan[index] : nil,
							progressCallback: progressCallback
						)
						return (index, execution)
					}
				}
				
				for await (index, execution) in group {
					orderedResults[index] = execution
				}
			}
			
			let completedAllSeeds = orderedResults.allSatisfy { $0 != nil }
			if Task.isCancelled || !completedAllSeeds {
				await MainActor.run {
					progressCallback?(.cancelled)
				}
			} else {
				await MainActor.run {
					progressCallback?(.finished(totalSeeds: seeds.count))
				}
			}
			
			return orderedResults.compactMap { $0 }
		}, onCancel: {
			executor.cancelInFlight()
		})
	}
	
	private static func executeSeed(
		index: Int,
		seed: UInt32,
		seedCount: Int,
		generator: BenchmarkTaskGenerator,
		executor: BenchmarkTaskExecutor,
		config: BenchConfig,
		parallelism: Int,
		language: BenchmarkLanguage?,
		progressCallback: ((BenchmarkProgressEvent) -> Void)?
	) async -> BenchmarkSeedExecution? {
		if Task.isCancelled {
			return nil
		}
		
		let generated = generator.generateSeed(seed, config: config, language: language, subseedIndex: index)
		let taskTypes = generated.tasks.map { $0.type }
		await MainActor.run {
			progressCallback?(.seedStarted(index: index, seed: seed, totalSeeds: seedCount, taskCount: generated.tasks.count, taskTypes: taskTypes))
		}
		
		if generated.tasks.isEmpty {
			await MainActor.run {
				progressCallback?(.seedCompleted(index: index, seed: seed))
			}
			return BenchmarkSeedExecution(seed: seed, executions: [])
		}
		
		if config.tasksAreCumulative {
			return await runCumulativeSeed(
				index: index,
				seed: seed,
				generated: generated,
				executor: executor,
				progressCallback: progressCallback
			)
		} else {
			return await runIndependentSeed(
				index: index,
				seed: seed,
				generated: generated,
				executor: executor,
				parallelism: parallelism,
				progressCallback: progressCallback
			)
		}
	}
	
	private static func runCumulativeSeed(
		index: Int,
		seed: UInt32,
		generated: BenchmarkGeneratedSeed,
		executor: BenchmarkTaskExecutor,
		progressCallback: ((BenchmarkProgressEvent) -> Void)?
	) async -> BenchmarkSeedExecution? {
		var workingFileSystem = generated.fileSystem
		var executions: [BenchmarkTaskExecution] = []
		
		for (taskIndex, task) in generated.tasks.enumerated() {
			if Task.isCancelled {
				return nil
			}
			
			var taskFileSystem = workingFileSystem
			let baseline = workingFileSystem.snapshot()
			let result = await executor.runTask(task, fileSystem: &taskFileSystem, baseline: baseline)
			
			if Task.isCancelled {
				return nil
			}
			
			executions.append(BenchmarkTaskExecution(task: task, baseline: baseline, result: result))
			workingFileSystem = taskFileSystem
			
			await MainActor.run {
				progressCallback?(.taskCompleted(seed: seed, completed: taskIndex + 1, total: generated.tasks.count))
			}
		}
		
		await MainActor.run {
			progressCallback?(.seedCompleted(index: index, seed: seed))
		}
		
		return BenchmarkSeedExecution(seed: seed, executions: executions)
	}
	
	private static func runIndependentSeed(
		index: Int,
		seed: UInt32,
		generated: BenchmarkGeneratedSeed,
		executor: BenchmarkTaskExecutor,
		parallelism: Int,
		progressCallback: ((BenchmarkProgressEvent) -> Void)?
	) async -> BenchmarkSeedExecution? {
		let semaphore = AsyncSemaphore(value: parallelism)
		var executions: [BenchmarkTaskExecution?] = Array(repeating: nil, count: generated.tasks.count)
		var completed = 0
		var cancelled = false
		
		await withTaskGroup(of: (Int, BenchmarkTaskExecution?).self) { taskGroup in
			for (taskIndex, task) in generated.tasks.enumerated() {
				taskGroup.addTask {
					if Task.isCancelled {
						return (taskIndex, nil)
					}
					
					await semaphore.wait()
					if Task.isCancelled {
						await semaphore.signal()
						return (taskIndex, nil)
					}
					defer {
						Task {
							await semaphore.signal()
						}
					}
					
					var taskFileSystem = generated.fileSystem.clone()
					let baseline = generated.baseline
					let result = await executor.runTask(task, fileSystem: &taskFileSystem, baseline: baseline)
					
					if Task.isCancelled {
						return (taskIndex, nil)
					}
					
					return (taskIndex, BenchmarkTaskExecution(task: task, baseline: baseline, result: result))
				}
			}
			
			for await (taskIndex, execution) in taskGroup {
				completed += 1
				let currentCompleted = completed
				if let execution {
					executions[taskIndex] = execution
				} else {
					cancelled = true
				}
				
				await MainActor.run {
					progressCallback?(.taskCompleted(seed: seed, completed: currentCompleted, total: generated.tasks.count))
				}
			}
		}
		
		if cancelled || executions.contains(where: { $0 == nil }) {
			return nil
		}
		
		await MainActor.run {
			progressCallback?(.seedCompleted(index: index, seed: seed))
		}
		
		return BenchmarkSeedExecution(seed: seed, executions: executions.compactMap { $0 })
	}
	
	private static func buildLanguagePlan(count: Int) -> [BenchmarkLanguage] {
		guard count > 0 else { return [] }
		let cycle: [BenchmarkLanguage] = [.ts, .go, .swift, .ts, .go]
		var plan: [BenchmarkLanguage] = []
		while plan.count < count {
			let remaining = count - plan.count
			plan.append(contentsOf: cycle.prefix(remaining))
		}
		return plan
	}
}
