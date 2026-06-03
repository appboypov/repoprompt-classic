import Foundation

/// Project layout capturing canonical task targets and decoy pools for a seed.
struct BenchmarkProjectLayout {
	let language: BenchmarkLanguage
	let workPath: String
	let auxWorkPaths: [String]
	let exporterPath: String?
	let importerPaths: [String]
	let appsIndexPaths: [String]
	let packageIndexPaths: [String]
	let fullDecoyPaths: [String]
	let decoyPool: [String]
}

/// Scaffolds a believable project structure for benchmark tasks.
enum BenchmarkProjectScaffolder {
	static func scaffoldProject(
		language: BenchmarkLanguage,
		rng: inout Mulberry32,
		config: BenchConfig,
		noise: Int,
		into fs: inout BenchmarkMockFileSystem
	) -> BenchmarkProjectLayout {
		switch language {
		case .ts:   return scaffoldTs(rng: &rng, config: config, noise: noise, fs: &fs)
		case .go:   return scaffoldGo(rng: &rng, config: config, noise: noise, fs: &fs)
		case .swift: return scaffoldSwift(rng: &rng, config: config, noise: noise, fs: &fs)
		}
	}

	// MARK: - TypeScript

	private static func scaffoldTs(
		rng: inout Mulberry32,
		config: BenchConfig,
		noise: Int,
		fs: inout BenchmarkMockFileSystem
	) -> BenchmarkProjectLayout {
		let workPath = "src/ts/work/Work.ts"
		let auxWorkPaths = ["src/ts/work/WorkA.ts", "src/ts/work/WorkB.ts"]
		let exporterPath = "src/ts/lib/exporter.ts"
		let importerPaths = [
			"apps/appA/src/useX_1.ts",
			"apps/appB/src/useX_2.ts",
			"apps/appC/src/useX_3.ts"
		]

		// Create work files with minimal bootstrapping
		fs.setFile(workPath, content: bootstrapTsWork(rng: &rng, name: "Work", noise: noise))
		for auxPath in auxWorkPaths {
			let name = auxPath.split(separator: "/").last?.replacingOccurrences(of: ".ts", with: "") ?? "WorkAux"
			fs.setFile(auxPath, content: bootstrapTsWork(rng: &rng, name: name, noise: noise))
		}

		// Create exporter and importers for rename tasks
		fs.setFile(exporterPath, content: "export function utilityX(n: number): number {\n    return n * 2;\n}\n")

		for importerPath in importerPaths {
			let appName = importerPath.split(separator: "/")[1]
			fs.setFile(importerPath, content: "import { utilityX } from '../../lib/exporter';\n\nexport function use\(appName)() {\n    return utilityX(42);\n}\n")
		}

		// Create apps and packages for index-only tasks
		let appNames = ["appA", "appB", "appC"]
		var appsIndexPaths: [String] = []
		for app in appNames {
			let indexPath = "apps/\(app)/src/index.ts"
			appsIndexPaths.append(indexPath)
			fs.setFile(indexPath, content: "console.log('App \(app) starting...');\nexport const VERSION = '1.0.0';\n")
		}

		let pkgNames = ["pkg1", "pkg2", "pkg3"]
		var packageIndexPaths: [String] = []
		for pkg in pkgNames {
			let indexPath = "packages/\(pkg)/src/index.ts"
			packageIndexPaths.append(indexPath)
			fs.setFile(indexPath, content: "export const \(pkg.uppercased())_VERSION = '1.0.0';\nexport function \(pkg)Main() {}\n")
		}

		// Create utility libraries with varying sizes
		let libNames = ["util1", "util2", "util3"]
		var decoyPool: [String] = []
		for libName in libNames {
			let libPath = "src/ts/lib/\(libName).ts"
			let multiplier = [0.6, 1.0, 1.4][rng.nextInt(upperBound: 3)]
			let approxLines = Int(Double(noise) * multiplier)
			fs.setFile(libPath, content: BelievableCodeFactory.tsUtilityModule(
				rng: &rng,
				module: libName.capitalized,
				approxLines: approxLines
			))
			decoyPool.append(libPath)
		}

		// Create full decoys near work files
		let fullDecoyPaths = ["src/ts/work/WorkShadow.ts", "src/ts/work/WorkClone.ts"]
		for decoyPath in fullDecoyPaths {
			let name = decoyPath.split(separator: "/").last?.replacingOccurrences(of: ".ts", with: "") ?? "Decoy"
			fs.setFile(decoyPath, content: bootstrapTsWork(rng: &rng, name: name, noise: Int(Double(noise) * 0.8)))
		}

		// Add more generic decoys
		for i in 0..<3 {
			let (path, content) = BelievableCodeFactory.tsDecoyFile(rng: &rng, name: "D\(i)")
			fs.setFile(path, content: content)
			decoyPool.append(path)
		}

		return BenchmarkProjectLayout(
			language: .ts,
			workPath: workPath,
			auxWorkPaths: auxWorkPaths,
			exporterPath: exporterPath,
			importerPaths: importerPaths,
			appsIndexPaths: appsIndexPaths,
			packageIndexPaths: packageIndexPaths,
			fullDecoyPaths: fullDecoyPaths,
			decoyPool: decoyPool
		)
	}

	private static func bootstrapTsWork(rng: inout Mulberry32, name: String, noise: Int) -> String {
		let base = BelievableCodeFactory.tsUtilityModule(rng: &rng, module: name, approxLines: max(40, noise))
		return base + "\n\n// FOOTER_MARKER\n"
	}

	// MARK: - Go

	private static func scaffoldGo(
		rng: inout Mulberry32,
		config: BenchConfig,
		noise: Int,
		fs: inout BenchmarkMockFileSystem
	) -> BenchmarkProjectLayout {
		let workPath = "src/go/work/Work.go"
		let auxWorkPaths = ["src/go/work/WorkA.go", "src/go/work/WorkB.go"]
		let exporterPath = "src/go/lib/exporter.go"
		let importerPaths = [
			"apps/appA/useX_1.go",
			"apps/appB/useX_2.go",
			"apps/appC/useX_3.go"
		]

		// Create work files
		fs.setFile(workPath, content: bootstrapGoWork(rng: &rng, name: "work", noise: noise))
		for auxPath in auxWorkPaths {
			fs.setFile(auxPath, content: bootstrapGoWork(rng: &rng, name: "work", noise: noise))
		}

		// Create exporter and importers
		fs.setFile(exporterPath, content: "package lib\n\nfunc UtilityX(n int) int {\n    return n * 2\n}\n")

		for importerPath in importerPaths {
			fs.setFile(importerPath, content: "package main\n\nimport \"project/src/go/lib\"\n\nfunc UseApp() int {\n    return lib.UtilityX(42)\n}\n")
		}

		// Create apps for index-only tasks
		let appNames = ["appA", "appB", "appC"]
		var appsIndexPaths: [String] = []
		for app in appNames {
			let mainPath = "apps/\(app)/main.go"
			appsIndexPaths.append(mainPath)
			fs.setFile(mainPath, content: "package main\n\nimport \"fmt\"\n\nfunc main() {\n    fmt.Println(\"App \(app) starting...\")\n}\n")
		}

		// Create packages
		let pkgNames = ["pkg1", "pkg2", "pkg3"]
		var packageIndexPaths: [String] = []
		for pkg in pkgNames {
			let pkgPath = "packages/\(pkg)/\(pkg).go"
			packageIndexPaths.append(pkgPath)
			fs.setFile(pkgPath, content: "package \(pkg)\n\nconst VERSION = \"1.0.0\"\n\nfunc Main() {}\n")
		}

		// Create utility libraries
		let libNames = ["util1", "util2", "util3"]
		var decoyPool: [String] = []
		for libName in libNames {
			let libPath = "src/go/lib/\(libName).go"
			let multiplier = [0.6, 1.0, 1.4][rng.nextInt(upperBound: 3)]
			let approxLines = Int(Double(noise) * multiplier)
			fs.setFile(libPath, content: BelievableCodeFactory.goUtilityModule(
				rng: &rng,
				pkg: libName,
				approxLines: approxLines
			))
			decoyPool.append(libPath)
		}

		// Create full decoys
		let fullDecoyPaths = ["src/go/work/WorkShadow.go", "src/go/work/WorkClone.go"]
		for decoyPath in fullDecoyPaths {
			fs.setFile(decoyPath, content: bootstrapGoWork(rng: &rng, name: "work", noise: Int(Double(noise) * 0.8)))
		}

		// Add more generic decoys
		for i in 0..<3 {
			let (path, content) = BelievableCodeFactory.goDecoyFile(rng: &rng, name: "D\(i)")
			fs.setFile(path, content: content)
			decoyPool.append(path)
		}

		return BenchmarkProjectLayout(
			language: .go,
			workPath: workPath,
			auxWorkPaths: auxWorkPaths,
			exporterPath: exporterPath,
			importerPaths: importerPaths,
			appsIndexPaths: appsIndexPaths,
			packageIndexPaths: packageIndexPaths,
			fullDecoyPaths: fullDecoyPaths,
			decoyPool: decoyPool
		)
	}

	private static func bootstrapGoWork(rng: inout Mulberry32, name: String, noise: Int) -> String {
		let base = BelievableCodeFactory.goUtilityModule(rng: &rng, pkg: name, approxLines: max(40, noise))
		return base + "\n\n// FOOTER_MARKER\n"
	}

	// MARK: - Swift

	private static func scaffoldSwift(
		rng: inout Mulberry32,
		config: BenchConfig,
		noise: Int,
		fs: inout BenchmarkMockFileSystem
	) -> BenchmarkProjectLayout {
		let workPath = "src/swift/work/Work.swift"
		let auxWorkPaths = ["src/swift/work/WorkA.swift", "src/swift/work/WorkB.swift"]
		let exporterPath = "src/swift/lib/Exporter.swift"
		let importerPaths = [
			"Apps/appA/UseX_1.swift",
			"Apps/appB/UseX_2.swift",
			"Apps/appC/UseX_3.swift"
		]

		// Create work files
		fs.setFile(workPath, content: bootstrapSwiftWork(rng: &rng, name: "Work", noise: noise))
		for auxPath in auxWorkPaths {
			let name = auxPath.split(separator: "/").last?.replacingOccurrences(of: ".swift", with: "") ?? "WorkAux"
			fs.setFile(auxPath, content: bootstrapSwiftWork(rng: &rng, name: name, noise: noise))
		}

		// Create exporter and importers
		fs.setFile(exporterPath, content: "public func utilityX(_ n: Int) -> Int {\n\treturn n * 2\n}\n")

		for importerPath in importerPaths {
			let appName = importerPath.split(separator: "/")[1]
			fs.setFile(importerPath, content: "import Foundation\n\nfunc use\(appName)() -> Int {\n\treturn utilityX(42)\n}\n")
		}

		// Create apps for index-only tasks
		let appNames = ["appA", "appB", "appC"]
		var appsIndexPaths: [String] = []
		for app in appNames {
			let indexPath = "Apps/\(app)/index.swift"
			appsIndexPaths.append(indexPath)
			fs.setFile(indexPath, content: "func main() {\n\tprint(\"App \(app) starting...\")\n\tlet VERSION = \"1.0.0\"\n}\n")
		}

		// Create packages
		let pkgNames = ["Pkg1", "Pkg2", "Pkg3"]
		var packageIndexPaths: [String] = []
		for pkg in pkgNames {
			let pkgPath = "Packages/\(pkg)/\(pkg).swift"
			packageIndexPaths.append(pkgPath)
			fs.setFile(pkgPath, content: "public enum \(pkg) {\n\tpublic static let VERSION = \"1.0.0\"\n\tpublic static func main() {}\n}\n")
		}

		// Create utility libraries
		let libNames = ["Utils1", "Utils2", "Utils3"]
		var decoyPool: [String] = []
		for libName in libNames {
			let libPath = "src/swift/lib/\(libName).swift"
			let multiplier = [0.6, 1.0, 1.4][rng.nextInt(upperBound: 3)]
			let approxLines = Int(Double(noise) * multiplier)
			fs.setFile(libPath, content: BelievableCodeFactory.swiftUtilityModule(
				rng: &rng,
				module: libName,
				approxLines: approxLines
			))
			decoyPool.append(libPath)
		}

		// Create full decoys
		let fullDecoyPaths = ["src/swift/work/WorkShadow.swift", "src/swift/work/WorkClone.swift"]
		for decoyPath in fullDecoyPaths {
			let name = decoyPath.split(separator: "/").last?.replacingOccurrences(of: ".swift", with: "") ?? "Decoy"
			fs.setFile(decoyPath, content: bootstrapSwiftWork(rng: &rng, name: name, noise: Int(Double(noise) * 0.8)))
		}

		// Add more generic decoys
		for i in 0..<3 {
			let (path, content) = BelievableCodeFactory.swiftDecoyFile(rng: &rng, name: "D\(i)")
			fs.setFile(path, content: content)
			decoyPool.append(path)
		}

		return BenchmarkProjectLayout(
			language: .swift,
			workPath: workPath,
			auxWorkPaths: auxWorkPaths,
			exporterPath: exporterPath,
			importerPaths: importerPaths,
			appsIndexPaths: appsIndexPaths,
			packageIndexPaths: packageIndexPaths,
			fullDecoyPaths: fullDecoyPaths,
			decoyPool: decoyPool
		)
	}

	private static func bootstrapSwiftWork(rng: inout Mulberry32, name: String, noise: Int) -> String {
		let base = BelievableCodeFactory.swiftUtilityModule(rng: &rng, module: name, approxLines: max(40, noise))
		return base + "\n\n// FOOTER_MARKER\n"
	}
}