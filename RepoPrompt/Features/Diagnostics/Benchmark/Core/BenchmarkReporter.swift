import Foundation

struct BenchmarkReporter {
	private let verifier: BenchmarkVerifying

	init(verifier: BenchmarkVerifying = BenchmarkVerifier()) {
		self.verifier = verifier
	}
	
	func buildReport(coreSeed: UInt32, executions: [BenchmarkSeedExecution]) -> BenchmarkFinalReport {
		var seedReports: [BenchmarkSeedReport] = []
		var allTaskReports: [BenchmarkTaskReport] = []
		
		for seedExecution in executions {
			var taskReports: [BenchmarkTaskReport] = []
			for execution in seedExecution.executions {
				let verification = verifier.verify(execution)
				let difficulty = execution.task.difficulty
				let maxPts = difficulty.maxPoints
				let awardedPts = BenchmarkPointScales.points(for: difficulty, normalizedScore: verification.score, pass: verification.pass)
				let report = BenchmarkTaskReport(
					id: execution.task.id,
					type: execution.task.type,
					pass: verification.pass,
					score: verification.score,
					reason: verification.reason,
					metrics: verification.metrics,
					errors: execution.result.errors,
					difficulty: difficulty,
					normalizedScore: verification.score,
					maxPoints: maxPts,
					awardedPoints: awardedPts
				)
				taskReports.append(report)
				allTaskReports.append(report)
			}
			let passRate = average(taskReports.map { $0.pass ? 1.0 : 0.0 })
			let averageScore = average(taskReports.map(\.score))
			let pointsEarned = taskReports.reduce(0.0) { sum, report in
				let multiplier = (report.pass && report.normalizedScore >= 1.0) ? 2.0 : 1.0
				return sum + (report.awardedPoints * multiplier)
			}
			let maxPoints = taskReports.reduce(0.0) { $0 + ($1.maxPoints * 2.0) }
			let pointsRate = maxPoints > 0 ? pointsEarned / maxPoints : 0.0
			seedReports.append(
				BenchmarkSeedReport(
					seed: seedExecution.seed,
					tasks: taskReports,
					passRate: passRate,
					averageScore: averageScore,
					pointsEarned: pointsEarned,
					maxPoints: maxPoints,
					pointsRate: pointsRate
				)
			)
		}
		
		let passRate = average(allTaskReports.map { $0.pass ? 1.0 : 0.0 })
		let averageScore = average(allTaskReports.map(\.score))
		let totalPointsEarned = allTaskReports.reduce(0.0) { sum, report in
			let multiplier = (report.pass && report.normalizedScore >= 1.0) ? 2.0 : 1.0
			return sum + (report.awardedPoints * multiplier)
		}
		let totalMaxPoints = allTaskReports.reduce(0.0) { $0 + ($1.maxPoints * 2.0) }
		let pointsRate = totalMaxPoints > 0 ? totalPointsEarned / totalMaxPoints : 0.0
		let perType = buildTypeStats(allTaskReports)
		return BenchmarkFinalReport(
			coreSeed: coreSeed,
			subSeeds: executions.map(\.seed),
			totalTasks: allTaskReports.count,
			passRate: passRate,
			averageScore: averageScore,
			perType: perType,
			perSeed: seedReports,
			totalMaxPoints: totalMaxPoints,
			totalPointsEarned: totalPointsEarned,
			pointsRate: pointsRate
		)
	}
	
	private func average(_ values: [Double]) -> Double {
		guard !values.isEmpty else { return 0.0 }
		let total = values.reduce(0, +)
		return total / Double(values.count)
	}
	
	private func buildTypeStats(_ reports: [BenchmarkTaskReport]) -> [BenchmarkCaseType: BenchmarkTypeStats] {
		var grouped: [BenchmarkCaseType: [BenchmarkTaskReport]] = [:]
		for report in reports {
			grouped[report.type, default: []].append(report)
		}
		var stats: [BenchmarkCaseType: BenchmarkTypeStats] = [:]
		for (type, items) in grouped {
			let passRate = average(items.map { $0.pass ? 1.0 : 0.0 })
			let avgScore = average(items.map(\.score))
			let pointsEarned = items.reduce(0.0) { sum, report in
				let multiplier = (report.pass && report.normalizedScore >= 1.0) ? 2.0 : 1.0
				return sum + (report.awardedPoints * multiplier)
			}
			let maxPoints = items.reduce(0.0) { $0 + ($1.maxPoints * 2.0) }
			let pointsRate = maxPoints > 0 ? pointsEarned / maxPoints : 0.0
			stats[type] = BenchmarkTypeStats(
				count: items.count,
				passRate: passRate,
				averageScore: avgScore,
				pointsEarned: pointsEarned,
				maxPoints: maxPoints,
				pointsRate: pointsRate
			)
		}
		return stats
	}
}
