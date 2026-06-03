import Foundation

actor BenchmarkRunStore {
	static let shared = BenchmarkRunStore()
	
	private let storageKey = "benchmarkRunHistory"
	private let encoder: JSONEncoder
	private let decoder: JSONDecoder
	private let userDefaults: UserDefaults
	
	init(userDefaults: UserDefaults = .standard) {
		let encoder = JSONEncoder()
		encoder.dateEncodingStrategy = .iso8601
		self.encoder = encoder
		let decoder = JSONDecoder()
		decoder.dateDecodingStrategy = .iso8601
		self.decoder = decoder
		self.userDefaults = userDefaults
	}
	
	func loadRuns() -> [BenchmarkRunSummary] {
		guard let data = userDefaults.data(forKey: storageKey) else {
			return []
		}
		do {
			return try decoder.decode([BenchmarkRunSummary].self, from: data)
		} catch {
			return []
		}
	}
	
	func saveRuns(_ runs: [BenchmarkRunSummary]) {
		guard let data = try? encoder.encode(runs) else { return }
		userDefaults.set(data, forKey: storageKey)
	}
	
	@discardableResult
	func append(_ run: BenchmarkRunSummary) -> [BenchmarkRunSummary] {
		var runs = loadRuns()
		runs.append(run)
		// Keep most recent first when stored to simplify consumers
		runs.sort { $0.timestamp > $1.timestamp }
		saveRuns(runs)
		return runs
	}
	
	func clear() {
		userDefaults.removeObject(forKey: storageKey)
	}
}
