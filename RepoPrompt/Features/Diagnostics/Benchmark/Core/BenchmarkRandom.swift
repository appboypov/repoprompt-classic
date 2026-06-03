import Foundation

/// Deterministic PRNG implementation based on Mulberry32.
struct Mulberry32: Sendable {
	private var state: UInt32
	
	init(seed: UInt32) {
		self.state = seed
	}
	
	mutating func nextUInt32() -> UInt32 {
		state &+= 0x6D2B79F5
		var z = state
		z = (z ^ (z >> 15)) &* (z | 1)
		z ^= z &+ ((z ^ (z >> 7)) &* (z | 61))
		return z ^ (z >> 14)
	}
	
	mutating func nextDouble() -> Double {
		Double(nextUInt32()) / 4294967296.0
	}
	
	mutating func nextInt(upperBound: Int) -> Int {
		guard upperBound > 0 else { return 0 }
		let value = nextUInt32()
		return Int(value % UInt32(upperBound))
	}
}

enum BenchmarkSeedUtilities {
	/// Canonical core seed so runs start from a shared baseline.
	static let canonicalCoreSeed: UInt32 = 3_618_045_077
	
	static func deriveSubSeeds(coreSeed: UInt32, count: Int = 5) -> [UInt32] {
		var seeds: [UInt32] = []
		var rng = Mulberry32(seed: coreSeed)
		for _ in 0..<count {
			seeds.append(rng.nextUInt32())
		}
		return seeds
	}
}
