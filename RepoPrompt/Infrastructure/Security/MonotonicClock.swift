import Foundation

enum MonotonicClock {
	static func continuousSeconds() -> Double {
		rp_continuous_time_seconds()
	}
}
