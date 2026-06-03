//
//  CodeMapPipelinePerformanceTests.swift
//  RepoPromptTests
//
//  Environment-gated codemap pipeline smoke timings for local performance work.
//

import XCTest
@testable import RepoPrompt
import Foundation

final class CodeMapPipelinePerformanceTests: XCTestCase {
	private struct BenchmarkFile {
		let fullPath: String
		let fileExtension: String
		let content: String
	}

	private struct BenchmarkWorkload {
		let name: String
		let files: [BenchmarkFile]
		let minimumGeneratedAPIs: Int
		let expectedEmptyCaptures: Bool
	}

	private struct RunSignature: Equatable, CustomStringConvertible {
		let fileCount: Int
		let captureCount: Int
		let generatedAPICount: Int
		let nilAPICount: Int

		var description: String {
			"files=\(fileCount), captures=\(captureCount), generatedAPIs=\(generatedAPICount), nilAPIs=\(nilAPICount)"
		}
	}

	private struct Measurement {
		let signature: RunSignature
		let totalMilliseconds: Double
		let parseAndQueryMilliseconds: Double
		let generatorMilliseconds: Double
	}

	func testCodemapPipelinePerformanceSmoke() throws {
		guard CodeMapPerfRuntime.shouldRunBenchmarks else {
			throw XCTSkip("Set \(CodeMapPerfRuntime.benchmarkEnvironmentKey)=1 or create \(CodeMapPerfRuntime.benchmarkMarkerPath) to run local codemap performance smoke benchmarks.")
		}

		let syntaxManagerPrimeStart = DispatchTime.now().uptimeNanoseconds
		_ = SyntaxManager.shared
		let syntaxManagerPrimeMilliseconds = Self.milliseconds(
			DispatchTime.now().uptimeNanoseconds - syntaxManagerPrimeStart
		)

		let iterations = Self.iterationCountFromEnvironment(defaultValue: 5)
		let workloads = Self.makeWorkloads()
		var reportRows: [String] = []
		reportRows.append("Codemap pipeline performance smoke")
		reportRows.append("syntaxManagerPrime=\(Self.formatMilliseconds(syntaxManagerPrimeMilliseconds)) ms, excluded from per-file parse/query timings")
		reportRows.append("iterations=\(iterations), timing=median/p90 after one reported same-process warm-up, no timing thresholds asserted")
		reportRows.append("env \(CodeMapPerfRuntime.benchmarkEnvironmentKey)=\(Self.environmentDescription(CodeMapPerfRuntime.benchmarkEnvironmentKey)), \(CodeMapPerfRuntime.benchmarkIterationsEnvironmentKey)=\(Self.environmentDescription(CodeMapPerfRuntime.benchmarkIterationsEnvironmentKey)), \(CodeMapPerfRuntime.instrumentationEnvironmentKey)=\(Self.environmentDescription(CodeMapPerfRuntime.instrumentationEnvironmentKey)), marker=\(FileManager.default.fileExists(atPath: CodeMapPerfRuntime.benchmarkMarkerPath) ? CodeMapPerfRuntime.benchmarkMarkerPath : "<absent>")")
		reportRows.append("")

		let postPrimeStats = CodeMapPerfRuntime.sharedPipelineStats?.snapshot

		for workload in workloads {
			let warmup = try measure(workload)
			reportRows.append(Self.warmupReportLine(workload: workload.name, measurement: warmup))
		}

		let measuredStatsBaseline = CodeMapPerfRuntime.sharedPipelineStats?.snapshot

		for workload in workloads {
			var measurements: [Measurement] = []
			measurements.reserveCapacity(iterations)

			for _ in 0..<iterations {
				measurements.append(try measure(workload))
			}

			guard let firstSignature = measurements.first?.signature else {
				XCTFail("No measurements recorded for \(workload.name)")
				continue
			}

			for measurement in measurements {
				XCTAssertEqual(measurement.signature, firstSignature, "\(workload.name) signature should be stable across measured iterations")
			}
			XCTAssertGreaterThanOrEqual(firstSignature.generatedAPICount, workload.minimumGeneratedAPIs, "\(workload.name) should generate representative APIs")
			if workload.expectedEmptyCaptures {
				XCTAssertEqual(firstSignature.captureCount, 0, "\(workload.name) should exercise the oversize empty-capture path")
			}

			reportRows.append(Self.reportLine(workload: workload.name, measurements: measurements))
		}

		if let stats = CodeMapPerfRuntime.sharedPipelineStats?.snapshot {
			reportRows.append("")
			reportRows.append("syntaxManager startup wallPrime=\(Self.formatMilliseconds(syntaxManagerPrimeMilliseconds)) ms, instrumentedPrime=\(Self.formatMilliseconds(stats.syntaxManagerPrimeDuration * 1_000)) ms, warmCache=\(Self.formatMilliseconds(stats.syntaxWarmCacheDuration * 1_000)) ms, warmCodeMapQueries=\(Self.formatMilliseconds(stats.syntaxWarmCodeMapQueriesDuration * 1_000)) ms")
			reportRows.append("syntaxManager languageConfig create=\(Self.formatMilliseconds(stats.syntaxLanguageConfigCreateDuration * 1_000)) ms, pointer=\(Self.formatMilliseconds(stats.syntaxLanguagePointerDuration * 1_000)) ms, eagerHighlightData=\(Self.formatMilliseconds(stats.syntaxHighlightQueryDataDuration * 1_000)) ms, eagerHighlightCompile=\(Self.formatMilliseconds(stats.syntaxHighlightQueryCompileDuration * 1_000)) ms")
			reportRows.append("syntaxManager codeMapPrecompute data=\(Self.formatMilliseconds(stats.syntaxCodeMapQueryDataDuration * 1_000)) ms, compile=\(Self.formatMilliseconds(stats.syntaxCodeMapQueryCompileDuration * 1_000)) ms")
			reportRows.append("syntaxManager startup counters warmCacheLanguages=\(stats.syntaxWarmCacheLanguageCount), configCreate=\(stats.syntaxLanguageConfigCreateCount), configSuccess=\(stats.syntaxLanguageConfigSuccessCount), configFailure=\(stats.syntaxLanguageConfigFailureCount), eagerHighlightCompileSuccess=\(stats.syntaxHighlightQueryCompileSuccessCount), eagerHighlightCompileFailure=\(stats.syntaxHighlightQueryCompileFailureCount), codeMapLanguages=\(stats.syntaxWarmCodeMapQueryLanguageCount), codeMapSuccess=\(stats.syntaxCodeMapQueryPrecomputeSuccessCount), codeMapFailure=\(stats.syntaxCodeMapQueryPrecomputeFailureCount), codeMapSkipped=\(stats.syntaxCodeMapQueryPrecomputeSkippedCount)")

			if let postPrimeStats, let measuredStatsBaseline {
				Self.appendInstrumentationReport(
					to: &reportRows,
					label: "cold warm-up instrumentation",
					stats: Self.deltaStats(measuredStatsBaseline, since: postPrimeStats)
				)
				Self.appendInstrumentationReport(
					to: &reportRows,
					label: "steady-state instrumentation",
					stats: Self.deltaStats(stats, since: measuredStatsBaseline)
				)
			} else {
				Self.appendInstrumentationReport(
					to: &reportRows,
					label: "instrumentation total",
					stats: stats
				)
			}
		}

		let report = reportRows.joined(separator: "\n")
		let reportURL = FileManager.default.temporaryDirectory.appendingPathComponent("repoprompt-codemap-pipeline-performance-smoke-report.txt")
		try? report.write(to: reportURL, atomically: true, encoding: .utf8)
		print("\n\(report)\n")
		XCTContext.runActivity(named: "Codemap pipeline performance smoke report") { activity in
			activity.add(XCTAttachment(string: report))
		}
	}

	private func measure(_ workload: BenchmarkWorkload) throws -> Measurement {
		var captureCount = 0
		var generatedAPICount = 0
		var nilAPICount = 0
		var parseAndQueryNanoseconds: UInt64 = 0
		var generatorNanoseconds: UInt64 = 0
		let totalStart = DispatchTime.now().uptimeNanoseconds

		for file in workload.files {
			let parseStart = DispatchTime.now().uptimeNanoseconds
			let captures = try SyntaxManager.shared.codeMap(
				content: file.content,
				fileExtension: file.fileExtension
			)
			let parseElapsed = DispatchTime.now().uptimeNanoseconds - parseStart
			parseAndQueryNanoseconds += parseElapsed
			CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.parseAndQueryDuration, TimeInterval(parseElapsed) / 1_000_000_000.0)
			captureCount += captures.count

			let generatorStart = DispatchTime.now().uptimeNanoseconds
			let generatorStats = CodeMapPerfRuntime.makeGeneratorStats()
			let fileAPI = CodeMapGenerator.generateCodeMap(
				from: captures,
				content: file.content,
				fullPath: file.fullPath,
				perfOptions: CodeMapPerfRuntime.makeGeneratorOptions(),
				perfStats: generatorStats
			)
			let generatorElapsed = DispatchTime.now().uptimeNanoseconds - generatorStart
			generatorNanoseconds += generatorElapsed
			CodeMapPerfRuntime.sharedPipelineStats?.addDuration(\.generatorDuration, TimeInterval(generatorElapsed) / 1_000_000_000.0)
			if let generatorStats {
				CodeMapPerfRuntime.sharedPipelineStats?.mergeGeneratorStats(generatorStats)
			}
			if fileAPI == nil {
				nilAPICount += 1
			} else {
				generatedAPICount += 1
			}
		}

		let totalNanoseconds = DispatchTime.now().uptimeNanoseconds - totalStart
		return Measurement(
			signature: RunSignature(
				fileCount: workload.files.count,
				captureCount: captureCount,
				generatedAPICount: generatedAPICount,
				nilAPICount: nilAPICount
			),
			totalMilliseconds: Self.milliseconds(totalNanoseconds),
			parseAndQueryMilliseconds: Self.milliseconds(parseAndQueryNanoseconds),
			generatorMilliseconds: Self.milliseconds(generatorNanoseconds)
		)
	}

	private static func makeWorkloads() -> [BenchmarkWorkload] {
		[
			BenchmarkWorkload(
				name: "many small Swift files",
				files: makeSmallSwiftFiles(count: 180),
				minimumGeneratedAPIs: 150,
				expectedEmptyCaptures: false
			),
			BenchmarkWorkload(
				name: "mixed-language medium files",
				files: makeMixedMediumFiles(rounds: 24),
				minimumGeneratedAPIs: 60,
				expectedEmptyCaptures: false
			),
			BenchmarkWorkload(
				name: "oversized Swift guard",
				files: makeOversizedSwiftFiles(count: 3),
				minimumGeneratedAPIs: 0,
				expectedEmptyCaptures: true
			)
		]
	}

	private static func makeSmallSwiftFiles(count: Int) -> [BenchmarkFile] {
		(0..<count).map { index in
			let content = """
			import Foundation
			struct SmallCodemapFixture\(index) {
				let value: Int
				func doubled() -> Int { value * 2 }
				func label(prefix: String) -> String { "\\(prefix)-\\(value)" }
			}
			"""
			return BenchmarkFile(
				fullPath: "/benchmark/codemap/small/SmallCodemapFixture\(index).swift",
				fileExtension: "swift",
				content: content
			)
		}
	}

	private static func makeMixedMediumFiles(rounds: Int) -> [BenchmarkFile] {
		var files: [BenchmarkFile] = []
		files.reserveCapacity(rounds * 5)
		for index in 0..<rounds {
			files.append(BenchmarkFile(
				fullPath: "/benchmark/codemap/mixed/SwiftMedium\(index).swift",
				fileExtension: "swift",
				content: """
				import Foundation
				public final class SwiftMedium\(index)Store {
					private var values: [String: Int] = [:]
					public init() {}
					public func set(_ value: Int, for key: String) { values[key] = value }
					public func value(for key: String) -> Int? { values[key] }
				}
				"""
			))
			files.append(BenchmarkFile(
				fullPath: "/benchmark/codemap/mixed/TypeScriptMedium\(index).ts",
				fileExtension: "ts",
				content: """
				export interface TypeScriptMedium\(index)User { id: string; score: number }
				export class TypeScriptMedium\(index)Store {
					private values = new Map<string, TypeScriptMedium\(index)User>()
					load(id: string): TypeScriptMedium\(index)User | undefined { return this.values.get(id) }
					save(user: TypeScriptMedium\(index)User): void { this.values.set(user.id, user) }
				}
				export const makeTypeScriptMedium\(index)User = (id: string): TypeScriptMedium\(index)User => ({ id, score: id.length })
				"""
			))
			files.append(BenchmarkFile(
				fullPath: "/benchmark/codemap/mixed/ComponentMedium\(index).tsx",
				fileExtension: "tsx",
				content: """
				import React from 'react'
				export type ComponentMedium\(index)Props = { title: string; count: number }
				export function ComponentMedium\(index)(props: ComponentMedium\(index)Props) {
					return <section><h1>{props.title}</h1><span>{props.count}</span></section>
				}
				"""
			))
			files.append(BenchmarkFile(
				fullPath: "/benchmark/codemap/mixed/javascript_medium_\(index).js",
				fileExtension: "js",
				content: """
				export class JavaScriptMedium\(index)Controller {
					constructor(service) { this.service = service }
					load(id) { return this.service.load(id) }
				}
				export const makeJavaScriptMedium\(index) = (service) => new JavaScriptMedium\(index)Controller(service)
				"""
			))
			files.append(BenchmarkFile(
				fullPath: "/benchmark/codemap/mixed/c_medium_\(index).c",
				fileExtension: "c",
				content: """
				#include <stdint.h>
				typedef struct CMedium\(index)Point { int32_t x; int32_t y; } CMedium\(index)Point;
				int c_medium_\(index)_sum(int left, int right) { return left + right; }
				"""
			))
		}
		return files
	}

	private static func makeOversizedSwiftFiles(count: Int) -> [BenchmarkFile] {
		let content = String(repeating: "let oversizedCodemapLine = 1\n", count: SyntaxManager.parseLineLimit + 2)
		return (0..<count).map { index in
			BenchmarkFile(
				fullPath: "/benchmark/codemap/oversized/Oversized\(index).swift",
				fileExtension: "swift",
				content: content
			)
		}
	}

	private static func warmupReportLine(workload: String, measurement: Measurement) -> String {
		"warm-up \(workload) | total=\(formatMilliseconds(measurement.totalMilliseconds)) ms | parse/query=\(formatMilliseconds(measurement.parseAndQueryMilliseconds)) ms | generator=\(formatMilliseconds(measurement.generatorMilliseconds)) ms | \(measurement.signature)"
	}

	private static func reportLine(workload: String, measurements: [Measurement]) -> String {
		let total = measurements.map(\.totalMilliseconds)
		let parse = measurements.map(\.parseAndQueryMilliseconds)
		let generator = measurements.map(\.generatorMilliseconds)
		let signature = measurements.first?.signature.description ?? "<missing>"
		return "\(workload) | total median=\(formatMilliseconds(percentile(total, 0.5))) ms p90=\(formatMilliseconds(percentile(total, 0.9))) ms | parse/query median=\(formatMilliseconds(percentile(parse, 0.5))) ms | generator median=\(formatMilliseconds(percentile(generator, 0.5))) ms | \(signature)"
	}

	private static func appendInstrumentationReport(
		to reportRows: inout [String],
		label: String,
		stats: CodeMapPipelinePerfSnapshot
	) {
		let syntaxStageTotal = stats.syntaxLanguageLookupDuration
			+ stats.syntaxOversizeGuardDuration
			+ stats.syntaxParserCreateDuration
			+ stats.syntaxSetLanguageDuration
			+ stats.syntaxParseDuration
			+ stats.syntaxCodeMapQueryLookupDuration
			+ stats.syntaxQueryExecuteDuration
			+ stats.syntaxCaptureMaterializationDuration
		let syntaxUnattributed = stats.parseAndQueryDuration - syntaxStageTotal
		let captureLoopAttributionTotal = stats.generatorCaptureLoopLineAdvanceDuration
			+ stats.generatorCaptureLoopSwiftStrategyDuration
			+ stats.generatorCaptureLoopTSStrategyDuration
			+ stats.generatorCaptureLoopInterfaceHeuristicDuration
			+ stats.generatorCaptureLoopImportExportDuration
			+ stats.generatorCaptureLoopTypeAliasDuration
			+ stats.generatorCaptureLoopEnumMacroDuration
			+ stats.generatorCaptureLoopFunctionDuration
			+ stats.generatorCaptureLoopVariableDuration
			+ stats.generatorCaptureLoopSkippedDuration
			+ stats.generatorCaptureLoopUnclassifiedDuration
		let captureLoopUnattributed = stats.generatorCaptureLoopDuration - captureLoopAttributionTotal
		let swiftStrategyAttributionTotal = stats.generatorSwiftStrategyFunctionSignatureDuration
			+ stats.generatorSwiftStrategyFunctionNameLookupDuration
			+ stats.generatorSwiftStrategyParameterExtractionDuration
			+ stats.generatorSwiftStrategyReturnTypeExtractionDuration
			+ stats.generatorSwiftStrategyPropertyDeclarationDuration
			+ stats.generatorSwiftStrategyPropertyTypeExtractionDuration
			+ stats.generatorSwiftStrategyEnclosingTypeLookupDuration
			+ stats.generatorSwiftStrategyModelInsertionDuration
			+ stats.generatorSwiftStrategyContextOnlyDuration
		let swiftStrategyUnattributed = stats.generatorCaptureLoopSwiftStrategyDuration - swiftStrategyAttributionTotal
		let fallbackFunctionAttributionTotal = stats.generatorFallbackFunctionDeclarationDuration
			+ stats.generatorFallbackFunctionJSTSSignatureDuration
			+ stats.generatorFallbackFunctionNameExtractionDuration
			+ stats.generatorFallbackFunctionLTEParseDuration
			+ stats.generatorFallbackFunctionTSFastPathDuration
			+ stats.generatorFallbackFunctionReferencedTypesDuration
			+ stats.generatorFallbackFunctionRoutingDuration
			+ stats.generatorFallbackFunctionModelInsertionDuration
			+ stats.generatorFallbackFunctionSkippedDuration
		let fallbackFunctionUnattributed = stats.generatorCaptureLoopFunctionDuration - fallbackFunctionAttributionTotal

		reportRows.append("")
		reportRows.append("\(label) parseAndQuery=\(formatMilliseconds(stats.parseAndQueryDuration * 1_000)) ms, generator=\(formatMilliseconds(stats.generatorDuration * 1_000)) ms, queryStoreHits=\(stats.codeMapQueryCacheHits), queryStoreMisses=\(stats.codeMapQueryCacheMisses)")
		reportRows.append("\(label) syntax stages languageLookup=\(formatMilliseconds(stats.syntaxLanguageLookupDuration * 1_000)) ms, oversizeGuard=\(formatMilliseconds(stats.syntaxOversizeGuardDuration * 1_000)) ms, parserCreate=\(formatMilliseconds(stats.syntaxParserCreateDuration * 1_000)) ms, setLanguage=\(formatMilliseconds(stats.syntaxSetLanguageDuration * 1_000)) ms, parse=\(formatMilliseconds(stats.syntaxParseDuration * 1_000)) ms, queryLookup=\(formatMilliseconds(stats.syntaxCodeMapQueryLookupDuration * 1_000)) ms, queryExecute=\(formatMilliseconds(stats.syntaxQueryExecuteDuration * 1_000)) ms, captureMaterialize=\(formatMilliseconds(stats.syntaxCaptureMaterializationDuration * 1_000)) ms")
		reportRows.append("\(label) syntax attribution stageTotal=\(formatMilliseconds(syntaxStageTotal * 1_000)) ms, unattributed=\(formatMilliseconds(syntaxUnattributed * 1_000)) ms")
		reportRows.append("\(label) syntax counters calls=\(stats.syntaxCodeMapCalls), unsupported=\(stats.syntaxUnsupportedExtensionCount), oversized=\(stats.syntaxOversizedSkipCount), parseNilTree=\(stats.syntaxParseNilTreeCount), parseNilRoot=\(stats.syntaxParseNilRootCount), parserCreates=\(stats.syntaxParserCreateCount), queryExecutes=\(stats.syntaxQueryExecuteCount), captures=\(stats.syntaxCaptureCount)")
		reportRows.append("\(label) generator stages captureIndex=\(formatMilliseconds(stats.generatorCaptureIndexDuration * 1_000)) ms, swiftContext=\(formatMilliseconds(stats.generatorSwiftContextDuration * 1_000)) ms, tsContext=\(formatMilliseconds(stats.generatorTSContextDuration * 1_000)) ms, captureLoop=\(formatMilliseconds(stats.generatorCaptureLoopDuration * 1_000)) ms, declaration=\(formatMilliseconds(stats.generatorDeclarationExtractionDuration * 1_000)) ms")
		reportRows.append("\(label) generator captureLoop attribution lineAdvance=\(formatMilliseconds(stats.generatorCaptureLoopLineAdvanceDuration * 1_000)) ms, swiftStrategy=\(formatMilliseconds(stats.generatorCaptureLoopSwiftStrategyDuration * 1_000)) ms, tsStrategy=\(formatMilliseconds(stats.generatorCaptureLoopTSStrategyDuration * 1_000)) ms, interfaceHeuristic=\(formatMilliseconds(stats.generatorCaptureLoopInterfaceHeuristicDuration * 1_000)) ms, importExport=\(formatMilliseconds(stats.generatorCaptureLoopImportExportDuration * 1_000)) ms, typeAlias=\(formatMilliseconds(stats.generatorCaptureLoopTypeAliasDuration * 1_000)) ms, enumMacro=\(formatMilliseconds(stats.generatorCaptureLoopEnumMacroDuration * 1_000)) ms, function=\(formatMilliseconds(stats.generatorCaptureLoopFunctionDuration * 1_000)) ms, variable=\(formatMilliseconds(stats.generatorCaptureLoopVariableDuration * 1_000)) ms, skipped=\(formatMilliseconds(stats.generatorCaptureLoopSkippedDuration * 1_000)) ms, unclassified=\(formatMilliseconds(stats.generatorCaptureLoopUnclassifiedDuration * 1_000)) ms")
		reportRows.append("\(label) generator captureLoop attributionTotal=\(formatMilliseconds(captureLoopAttributionTotal * 1_000)) ms, captureLoopUnattributed=\(formatMilliseconds(captureLoopUnattributed * 1_000)) ms")
		reportRows.append("\(label) generator captureLoop counts lineAdvance=\(stats.generatorCaptureLoopLineAdvanceCount), swiftStrategy=\(stats.generatorCaptureLoopSwiftStrategyCount), tsStrategy=\(stats.generatorCaptureLoopTSStrategyCount), interfaceHeuristic=\(stats.generatorCaptureLoopInterfaceHeuristicCount), importExport=\(stats.generatorCaptureLoopImportExportCount), typeAlias=\(stats.generatorCaptureLoopTypeAliasCount), enumMacro=\(stats.generatorCaptureLoopEnumMacroCount), function=\(stats.generatorCaptureLoopFunctionCount), variable=\(stats.generatorCaptureLoopVariableCount), skipped=\(stats.generatorCaptureLoopSkippedCount), unclassified=\(stats.generatorCaptureLoopUnclassifiedCount)")
		reportRows.append("\(label) generator swiftStrategy attribution signature=\(formatMilliseconds(stats.generatorSwiftStrategyFunctionSignatureDuration * 1_000)) ms, nameLookup=\(formatMilliseconds(stats.generatorSwiftStrategyFunctionNameLookupDuration * 1_000)) ms, parameters=\(formatMilliseconds(stats.generatorSwiftStrategyParameterExtractionDuration * 1_000)) ms, returnType=\(formatMilliseconds(stats.generatorSwiftStrategyReturnTypeExtractionDuration * 1_000)) ms, propertyDecl=\(formatMilliseconds(stats.generatorSwiftStrategyPropertyDeclarationDuration * 1_000)) ms, propertyType=\(formatMilliseconds(stats.generatorSwiftStrategyPropertyTypeExtractionDuration * 1_000)) ms, enclosingType=\(formatMilliseconds(stats.generatorSwiftStrategyEnclosingTypeLookupDuration * 1_000)) ms, modelInsertion=\(formatMilliseconds(stats.generatorSwiftStrategyModelInsertionDuration * 1_000)) ms, contextOnly=\(formatMilliseconds(stats.generatorSwiftStrategyContextOnlyDuration * 1_000)) ms")
		reportRows.append("\(label) generator swiftStrategy attributionTotal=\(formatMilliseconds(swiftStrategyAttributionTotal * 1_000)) ms, swiftStrategyUnattributed=\(formatMilliseconds(swiftStrategyUnattributed * 1_000)) ms")
		reportRows.append("\(label) generator swiftStrategy counts signature=\(stats.generatorSwiftStrategyFunctionSignatureCount), nameLookup=\(stats.generatorSwiftStrategyFunctionNameLookupCount), parameters=\(stats.generatorSwiftStrategyParameterExtractionCount), returnType=\(stats.generatorSwiftStrategyReturnTypeExtractionCount), propertyDecl=\(stats.generatorSwiftStrategyPropertyDeclarationCount), propertyType=\(stats.generatorSwiftStrategyPropertyTypeExtractionCount), enclosingType=\(stats.generatorSwiftStrategyEnclosingTypeLookupCount), modelInsertion=\(stats.generatorSwiftStrategyModelInsertionCount), contextOnly=\(stats.generatorSwiftStrategyContextOnlyCount), handledFunctions=\(stats.generatorSwiftStrategyHandledFunctionCount), handledProperties=\(stats.generatorSwiftStrategyHandledPropertyCount)")
		reportRows.append("\(label) generator fallbackFunction attribution declaration=\(formatMilliseconds(stats.generatorFallbackFunctionDeclarationDuration * 1_000)) ms, jsts=\(formatMilliseconds(stats.generatorFallbackFunctionJSTSSignatureDuration * 1_000)) ms, name=\(formatMilliseconds(stats.generatorFallbackFunctionNameExtractionDuration * 1_000)) ms, lteParse=\(formatMilliseconds(stats.generatorFallbackFunctionLTEParseDuration * 1_000)) ms, tsFastPath=\(formatMilliseconds(stats.generatorFallbackFunctionTSFastPathDuration * 1_000)) ms, refs=\(formatMilliseconds(stats.generatorFallbackFunctionReferencedTypesDuration * 1_000)) ms, routing=\(formatMilliseconds(stats.generatorFallbackFunctionRoutingDuration * 1_000)) ms, modelInsertion=\(formatMilliseconds(stats.generatorFallbackFunctionModelInsertionDuration * 1_000)) ms, skipped=\(formatMilliseconds(stats.generatorFallbackFunctionSkippedDuration * 1_000)) ms")
		reportRows.append("\(label) generator fallbackFunction attributionTotal=\(formatMilliseconds(fallbackFunctionAttributionTotal * 1_000)) ms, fallbackFunctionUnattributed=\(formatMilliseconds(fallbackFunctionUnattributed * 1_000)) ms")
		reportRows.append("\(label) generator fallbackFunction counts declaration=\(stats.generatorFallbackFunctionDeclarationCount), jsts=\(stats.generatorFallbackFunctionJSTSSignatureCount), name=\(stats.generatorFallbackFunctionNameExtractionCount), lteParse=\(stats.generatorFallbackFunctionLTEParseCount), tsFastPath=\(stats.generatorFallbackFunctionTSFastPathCount), refs=\(stats.generatorFallbackFunctionReferencedTypesCount), routing=\(stats.generatorFallbackFunctionRoutingCount), modelInsertion=\(stats.generatorFallbackFunctionModelInsertionCount), skipped=\(stats.generatorFallbackFunctionSkippedCount), lightweight=\(stats.generatorFallbackFunctionLightweightCount), heavyweight=\(stats.generatorFallbackFunctionHeavyweightCount), globalInsert=\(stats.generatorFallbackFunctionGlobalInsertCount), methodInsert=\(stats.generatorFallbackFunctionMethodInsertCount), interfaceInsert=\(stats.generatorFallbackFunctionInterfaceInsertCount)")
		reportRows.append("\(label) generator extraction jsts=\(formatMilliseconds(stats.generatorJSTSSignatureDuration * 1_000)) ms, lteFunction=\(formatMilliseconds(stats.generatorLanguageTypeExtractorFunctionDuration * 1_000)) ms, lteVariable=\(formatMilliseconds(stats.generatorLanguageTypeExtractorVariableDuration * 1_000)) ms, typeCleaner=\(formatMilliseconds(stats.generatorTypeCleanerDuration * 1_000)) ms, refsFinalize=\(formatMilliseconds(stats.generatorReferencedTypesFinalizeDuration * 1_000)) ms, fileAPI=\(formatMilliseconds(stats.generatorFileAPIInitDuration * 1_000)) ms")
		reportRows.append("\(label) generator typeCleaner languages swift=\(formatMilliseconds(stats.generatorTypeCleanerSwiftDuration * 1_000)) ms (\(stats.typeCleanerSwiftCalls) calls), ts=\(formatMilliseconds(stats.generatorTypeCleanerTSDuration * 1_000)) ms (\(stats.typeCleanerTSCalls) calls), tsx=\(formatMilliseconds(stats.generatorTypeCleanerTSXDuration * 1_000)) ms (\(stats.typeCleanerTSXCalls) calls), js=\(formatMilliseconds(stats.generatorTypeCleanerJSDuration * 1_000)) ms (\(stats.typeCleanerJSCalls) calls), other=\(formatMilliseconds(stats.generatorTypeCleanerOtherLanguageDuration * 1_000)) ms (\(stats.typeCleanerOtherLanguageCalls) calls)")
		reportRows.append("\(label) generator typeCleaner phases preclean=\(formatMilliseconds(stats.generatorTypeCleanerPrecleanDuration * 1_000)) ms (\(stats.typeCleanerPrecleanCount) calls), tsLogic=\(formatMilliseconds(stats.generatorTypeCleanerTSLogicDuration * 1_000)) ms (\(stats.typeCleanerTSLogicCount) calls), nonTSLogic=\(formatMilliseconds(stats.generatorTypeCleanerNonTSLogicDuration * 1_000)) ms (\(stats.typeCleanerNonTSLogicCount) calls), tsObjectLiteral=\(formatMilliseconds(stats.generatorTypeCleanerTSObjectLiteralDuration * 1_000)) ms (\(stats.typeCleanerTSObjectLiteralCount) calls), filter=\(formatMilliseconds(stats.generatorTypeCleanerFilterDuration * 1_000)) ms (\(stats.typeCleanerFilterCount) calls), dedup=\(formatMilliseconds(stats.generatorTypeCleanerDedupDuration * 1_000)) ms (\(stats.typeCleanerDedupCount) calls)")
		reportRows.append("\(label) generator referencedTypes rawInsertions=\(stats.referencedTypesRawInsertions), prefilterSkips=\(stats.referencedTypesPrefilterSkips), emptyResults=\(stats.referencedTypesEmptyResults), outputTypes=\(stats.referencedTypesOutputTypeCount)")
		reportRows.append("\(label) generator counters captures=\(stats.capturesProcessed), swiftHandled=\(stats.swiftStrategyHandled), tsHandled=\(stats.tsStrategyHandled), fallbackHandled=\(stats.fallbackHandled), captureDeclCalls=\(stats.captureDeclarationCalls), jstsFunctionLike=\(stats.jstsSignatureCallsFunctionLike), jstsStatementLike=\(stats.jstsSignatureCallsStatementLike), lteFunctionCalls=\(stats.lteMatchAnyFunctionCalls), lteVariableCalls=\(stats.lteMatchAnyVariableCalls), typeCleanerCalls=\(stats.typeCleanerExtractCalls), typeCleanerHits=\(stats.typeCleanerCacheHits), typeCleanerMisses=\(stats.typeCleanerCacheMisses)")
		reportRows.append("\(label) generator memo jstsHits=\(stats.extractionMemoJSTSHits), jstsMisses=\(stats.extractionMemoJSTSMisses), functionHits=\(stats.extractionMemoFunctionHits), functionMisses=\(stats.extractionMemoFunctionMisses), functionParsedHits=\(stats.extractionMemoFunctionParsedHits), functionParsedMisses=\(stats.extractionMemoFunctionParsedMisses), variableHits=\(stats.extractionMemoVariableHits), variableMisses=\(stats.extractionMemoVariableMisses), tsFastPathHits=\(stats.extractionMemoTSFastPathHits), tsFastPathMisses=\(stats.extractionMemoTSFastPathMisses)")
	}

	// Keep this aligned with fields emitted by appendInstrumentationReport; startup fields are reported separately.
	private static func deltaStats(
		_ current: CodeMapPipelinePerfSnapshot,
		since baseline: CodeMapPipelinePerfSnapshot
	) -> CodeMapPipelinePerfSnapshot {
		var delta = CodeMapPipelinePerfSnapshot()
		delta.parseAndQueryDuration = current.parseAndQueryDuration - baseline.parseAndQueryDuration
		delta.generatorDuration = current.generatorDuration - baseline.generatorDuration
		delta.syntaxLanguageLookupDuration = current.syntaxLanguageLookupDuration - baseline.syntaxLanguageLookupDuration
		delta.syntaxOversizeGuardDuration = current.syntaxOversizeGuardDuration - baseline.syntaxOversizeGuardDuration
		delta.syntaxParserCreateDuration = current.syntaxParserCreateDuration - baseline.syntaxParserCreateDuration
		delta.syntaxSetLanguageDuration = current.syntaxSetLanguageDuration - baseline.syntaxSetLanguageDuration
		delta.syntaxParseDuration = current.syntaxParseDuration - baseline.syntaxParseDuration
		delta.syntaxCodeMapQueryLookupDuration = current.syntaxCodeMapQueryLookupDuration - baseline.syntaxCodeMapQueryLookupDuration
		delta.syntaxQueryExecuteDuration = current.syntaxQueryExecuteDuration - baseline.syntaxQueryExecuteDuration
		delta.syntaxCaptureMaterializationDuration = current.syntaxCaptureMaterializationDuration - baseline.syntaxCaptureMaterializationDuration
		delta.generatorCaptureIndexDuration = current.generatorCaptureIndexDuration - baseline.generatorCaptureIndexDuration
		delta.generatorSwiftContextDuration = current.generatorSwiftContextDuration - baseline.generatorSwiftContextDuration
		delta.generatorTSContextDuration = current.generatorTSContextDuration - baseline.generatorTSContextDuration
		delta.generatorCaptureLoopDuration = current.generatorCaptureLoopDuration - baseline.generatorCaptureLoopDuration
		delta.generatorCaptureLoopLineAdvanceDuration = current.generatorCaptureLoopLineAdvanceDuration - baseline.generatorCaptureLoopLineAdvanceDuration
		delta.generatorCaptureLoopSwiftStrategyDuration = current.generatorCaptureLoopSwiftStrategyDuration - baseline.generatorCaptureLoopSwiftStrategyDuration
		delta.generatorCaptureLoopTSStrategyDuration = current.generatorCaptureLoopTSStrategyDuration - baseline.generatorCaptureLoopTSStrategyDuration
		delta.generatorCaptureLoopInterfaceHeuristicDuration = current.generatorCaptureLoopInterfaceHeuristicDuration - baseline.generatorCaptureLoopInterfaceHeuristicDuration
		delta.generatorCaptureLoopImportExportDuration = current.generatorCaptureLoopImportExportDuration - baseline.generatorCaptureLoopImportExportDuration
		delta.generatorCaptureLoopTypeAliasDuration = current.generatorCaptureLoopTypeAliasDuration - baseline.generatorCaptureLoopTypeAliasDuration
		delta.generatorCaptureLoopEnumMacroDuration = current.generatorCaptureLoopEnumMacroDuration - baseline.generatorCaptureLoopEnumMacroDuration
		delta.generatorCaptureLoopFunctionDuration = current.generatorCaptureLoopFunctionDuration - baseline.generatorCaptureLoopFunctionDuration
		delta.generatorCaptureLoopVariableDuration = current.generatorCaptureLoopVariableDuration - baseline.generatorCaptureLoopVariableDuration
		delta.generatorCaptureLoopSkippedDuration = current.generatorCaptureLoopSkippedDuration - baseline.generatorCaptureLoopSkippedDuration
		delta.generatorCaptureLoopUnclassifiedDuration = current.generatorCaptureLoopUnclassifiedDuration - baseline.generatorCaptureLoopUnclassifiedDuration
		delta.generatorSwiftStrategyFunctionSignatureDuration = current.generatorSwiftStrategyFunctionSignatureDuration - baseline.generatorSwiftStrategyFunctionSignatureDuration
		delta.generatorSwiftStrategyFunctionNameLookupDuration = current.generatorSwiftStrategyFunctionNameLookupDuration - baseline.generatorSwiftStrategyFunctionNameLookupDuration
		delta.generatorSwiftStrategyParameterExtractionDuration = current.generatorSwiftStrategyParameterExtractionDuration - baseline.generatorSwiftStrategyParameterExtractionDuration
		delta.generatorSwiftStrategyReturnTypeExtractionDuration = current.generatorSwiftStrategyReturnTypeExtractionDuration - baseline.generatorSwiftStrategyReturnTypeExtractionDuration
		delta.generatorSwiftStrategyPropertyDeclarationDuration = current.generatorSwiftStrategyPropertyDeclarationDuration - baseline.generatorSwiftStrategyPropertyDeclarationDuration
		delta.generatorSwiftStrategyPropertyTypeExtractionDuration = current.generatorSwiftStrategyPropertyTypeExtractionDuration - baseline.generatorSwiftStrategyPropertyTypeExtractionDuration
		delta.generatorSwiftStrategyEnclosingTypeLookupDuration = current.generatorSwiftStrategyEnclosingTypeLookupDuration - baseline.generatorSwiftStrategyEnclosingTypeLookupDuration
		delta.generatorSwiftStrategyModelInsertionDuration = current.generatorSwiftStrategyModelInsertionDuration - baseline.generatorSwiftStrategyModelInsertionDuration
		delta.generatorSwiftStrategyContextOnlyDuration = current.generatorSwiftStrategyContextOnlyDuration - baseline.generatorSwiftStrategyContextOnlyDuration
		delta.generatorFallbackFunctionDeclarationDuration = current.generatorFallbackFunctionDeclarationDuration - baseline.generatorFallbackFunctionDeclarationDuration
		delta.generatorFallbackFunctionJSTSSignatureDuration = current.generatorFallbackFunctionJSTSSignatureDuration - baseline.generatorFallbackFunctionJSTSSignatureDuration
		delta.generatorFallbackFunctionNameExtractionDuration = current.generatorFallbackFunctionNameExtractionDuration - baseline.generatorFallbackFunctionNameExtractionDuration
		delta.generatorFallbackFunctionLTEParseDuration = current.generatorFallbackFunctionLTEParseDuration - baseline.generatorFallbackFunctionLTEParseDuration
		delta.generatorFallbackFunctionTSFastPathDuration = current.generatorFallbackFunctionTSFastPathDuration - baseline.generatorFallbackFunctionTSFastPathDuration
		delta.generatorFallbackFunctionReferencedTypesDuration = current.generatorFallbackFunctionReferencedTypesDuration - baseline.generatorFallbackFunctionReferencedTypesDuration
		delta.generatorFallbackFunctionRoutingDuration = current.generatorFallbackFunctionRoutingDuration - baseline.generatorFallbackFunctionRoutingDuration
		delta.generatorFallbackFunctionModelInsertionDuration = current.generatorFallbackFunctionModelInsertionDuration - baseline.generatorFallbackFunctionModelInsertionDuration
		delta.generatorFallbackFunctionSkippedDuration = current.generatorFallbackFunctionSkippedDuration - baseline.generatorFallbackFunctionSkippedDuration
		delta.generatorDeclarationExtractionDuration = current.generatorDeclarationExtractionDuration - baseline.generatorDeclarationExtractionDuration
		delta.generatorJSTSSignatureDuration = current.generatorJSTSSignatureDuration - baseline.generatorJSTSSignatureDuration
		delta.generatorLanguageTypeExtractorFunctionDuration = current.generatorLanguageTypeExtractorFunctionDuration - baseline.generatorLanguageTypeExtractorFunctionDuration
		delta.generatorLanguageTypeExtractorVariableDuration = current.generatorLanguageTypeExtractorVariableDuration - baseline.generatorLanguageTypeExtractorVariableDuration
		delta.generatorTypeCleanerDuration = current.generatorTypeCleanerDuration - baseline.generatorTypeCleanerDuration
		delta.generatorTypeCleanerSwiftDuration = current.generatorTypeCleanerSwiftDuration - baseline.generatorTypeCleanerSwiftDuration
		delta.generatorTypeCleanerTSDuration = current.generatorTypeCleanerTSDuration - baseline.generatorTypeCleanerTSDuration
		delta.generatorTypeCleanerTSXDuration = current.generatorTypeCleanerTSXDuration - baseline.generatorTypeCleanerTSXDuration
		delta.generatorTypeCleanerJSDuration = current.generatorTypeCleanerJSDuration - baseline.generatorTypeCleanerJSDuration
		delta.generatorTypeCleanerOtherLanguageDuration = current.generatorTypeCleanerOtherLanguageDuration - baseline.generatorTypeCleanerOtherLanguageDuration
		delta.generatorTypeCleanerPrecleanDuration = current.generatorTypeCleanerPrecleanDuration - baseline.generatorTypeCleanerPrecleanDuration
		delta.generatorTypeCleanerTSLogicDuration = current.generatorTypeCleanerTSLogicDuration - baseline.generatorTypeCleanerTSLogicDuration
		delta.generatorTypeCleanerNonTSLogicDuration = current.generatorTypeCleanerNonTSLogicDuration - baseline.generatorTypeCleanerNonTSLogicDuration
		delta.generatorTypeCleanerTSObjectLiteralDuration = current.generatorTypeCleanerTSObjectLiteralDuration - baseline.generatorTypeCleanerTSObjectLiteralDuration
		delta.generatorTypeCleanerFilterDuration = current.generatorTypeCleanerFilterDuration - baseline.generatorTypeCleanerFilterDuration
		delta.generatorTypeCleanerDedupDuration = current.generatorTypeCleanerDedupDuration - baseline.generatorTypeCleanerDedupDuration
		delta.generatorReferencedTypesFinalizeDuration = current.generatorReferencedTypesFinalizeDuration - baseline.generatorReferencedTypesFinalizeDuration
		delta.generatorFileAPIInitDuration = current.generatorFileAPIInitDuration - baseline.generatorFileAPIInitDuration

		delta.codeMapQueryCacheHits = current.codeMapQueryCacheHits - baseline.codeMapQueryCacheHits
		delta.codeMapQueryCacheMisses = current.codeMapQueryCacheMisses - baseline.codeMapQueryCacheMisses
		delta.syntaxCodeMapCalls = current.syntaxCodeMapCalls - baseline.syntaxCodeMapCalls
		delta.syntaxUnsupportedExtensionCount = current.syntaxUnsupportedExtensionCount - baseline.syntaxUnsupportedExtensionCount
		delta.syntaxOversizedSkipCount = current.syntaxOversizedSkipCount - baseline.syntaxOversizedSkipCount
		delta.syntaxParseNilTreeCount = current.syntaxParseNilTreeCount - baseline.syntaxParseNilTreeCount
		delta.syntaxParseNilRootCount = current.syntaxParseNilRootCount - baseline.syntaxParseNilRootCount
		delta.syntaxParserCreateCount = current.syntaxParserCreateCount - baseline.syntaxParserCreateCount
		delta.syntaxQueryExecuteCount = current.syntaxQueryExecuteCount - baseline.syntaxQueryExecuteCount
		delta.syntaxCaptureCount = current.syntaxCaptureCount - baseline.syntaxCaptureCount
		delta.capturesProcessed = current.capturesProcessed - baseline.capturesProcessed
		delta.swiftStrategyHandled = current.swiftStrategyHandled - baseline.swiftStrategyHandled
		delta.tsStrategyHandled = current.tsStrategyHandled - baseline.tsStrategyHandled
		delta.fallbackHandled = current.fallbackHandled - baseline.fallbackHandled
		delta.generatorCaptureLoopLineAdvanceCount = current.generatorCaptureLoopLineAdvanceCount - baseline.generatorCaptureLoopLineAdvanceCount
		delta.generatorCaptureLoopSwiftStrategyCount = current.generatorCaptureLoopSwiftStrategyCount - baseline.generatorCaptureLoopSwiftStrategyCount
		delta.generatorCaptureLoopTSStrategyCount = current.generatorCaptureLoopTSStrategyCount - baseline.generatorCaptureLoopTSStrategyCount
		delta.generatorCaptureLoopInterfaceHeuristicCount = current.generatorCaptureLoopInterfaceHeuristicCount - baseline.generatorCaptureLoopInterfaceHeuristicCount
		delta.generatorCaptureLoopImportExportCount = current.generatorCaptureLoopImportExportCount - baseline.generatorCaptureLoopImportExportCount
		delta.generatorCaptureLoopTypeAliasCount = current.generatorCaptureLoopTypeAliasCount - baseline.generatorCaptureLoopTypeAliasCount
		delta.generatorCaptureLoopEnumMacroCount = current.generatorCaptureLoopEnumMacroCount - baseline.generatorCaptureLoopEnumMacroCount
		delta.generatorCaptureLoopFunctionCount = current.generatorCaptureLoopFunctionCount - baseline.generatorCaptureLoopFunctionCount
		delta.generatorCaptureLoopVariableCount = current.generatorCaptureLoopVariableCount - baseline.generatorCaptureLoopVariableCount
		delta.generatorCaptureLoopSkippedCount = current.generatorCaptureLoopSkippedCount - baseline.generatorCaptureLoopSkippedCount
		delta.generatorCaptureLoopUnclassifiedCount = current.generatorCaptureLoopUnclassifiedCount - baseline.generatorCaptureLoopUnclassifiedCount
		delta.generatorSwiftStrategyFunctionSignatureCount = current.generatorSwiftStrategyFunctionSignatureCount - baseline.generatorSwiftStrategyFunctionSignatureCount
		delta.generatorSwiftStrategyFunctionNameLookupCount = current.generatorSwiftStrategyFunctionNameLookupCount - baseline.generatorSwiftStrategyFunctionNameLookupCount
		delta.generatorSwiftStrategyParameterExtractionCount = current.generatorSwiftStrategyParameterExtractionCount - baseline.generatorSwiftStrategyParameterExtractionCount
		delta.generatorSwiftStrategyReturnTypeExtractionCount = current.generatorSwiftStrategyReturnTypeExtractionCount - baseline.generatorSwiftStrategyReturnTypeExtractionCount
		delta.generatorSwiftStrategyPropertyDeclarationCount = current.generatorSwiftStrategyPropertyDeclarationCount - baseline.generatorSwiftStrategyPropertyDeclarationCount
		delta.generatorSwiftStrategyPropertyTypeExtractionCount = current.generatorSwiftStrategyPropertyTypeExtractionCount - baseline.generatorSwiftStrategyPropertyTypeExtractionCount
		delta.generatorSwiftStrategyEnclosingTypeLookupCount = current.generatorSwiftStrategyEnclosingTypeLookupCount - baseline.generatorSwiftStrategyEnclosingTypeLookupCount
		delta.generatorSwiftStrategyModelInsertionCount = current.generatorSwiftStrategyModelInsertionCount - baseline.generatorSwiftStrategyModelInsertionCount
		delta.generatorSwiftStrategyContextOnlyCount = current.generatorSwiftStrategyContextOnlyCount - baseline.generatorSwiftStrategyContextOnlyCount
		delta.generatorSwiftStrategyHandledFunctionCount = current.generatorSwiftStrategyHandledFunctionCount - baseline.generatorSwiftStrategyHandledFunctionCount
		delta.generatorSwiftStrategyHandledPropertyCount = current.generatorSwiftStrategyHandledPropertyCount - baseline.generatorSwiftStrategyHandledPropertyCount
		delta.generatorFallbackFunctionDeclarationCount = current.generatorFallbackFunctionDeclarationCount - baseline.generatorFallbackFunctionDeclarationCount
		delta.generatorFallbackFunctionJSTSSignatureCount = current.generatorFallbackFunctionJSTSSignatureCount - baseline.generatorFallbackFunctionJSTSSignatureCount
		delta.generatorFallbackFunctionNameExtractionCount = current.generatorFallbackFunctionNameExtractionCount - baseline.generatorFallbackFunctionNameExtractionCount
		delta.generatorFallbackFunctionLTEParseCount = current.generatorFallbackFunctionLTEParseCount - baseline.generatorFallbackFunctionLTEParseCount
		delta.generatorFallbackFunctionTSFastPathCount = current.generatorFallbackFunctionTSFastPathCount - baseline.generatorFallbackFunctionTSFastPathCount
		delta.generatorFallbackFunctionReferencedTypesCount = current.generatorFallbackFunctionReferencedTypesCount - baseline.generatorFallbackFunctionReferencedTypesCount
		delta.generatorFallbackFunctionRoutingCount = current.generatorFallbackFunctionRoutingCount - baseline.generatorFallbackFunctionRoutingCount
		delta.generatorFallbackFunctionModelInsertionCount = current.generatorFallbackFunctionModelInsertionCount - baseline.generatorFallbackFunctionModelInsertionCount
		delta.generatorFallbackFunctionSkippedCount = current.generatorFallbackFunctionSkippedCount - baseline.generatorFallbackFunctionSkippedCount
		delta.generatorFallbackFunctionLightweightCount = current.generatorFallbackFunctionLightweightCount - baseline.generatorFallbackFunctionLightweightCount
		delta.generatorFallbackFunctionHeavyweightCount = current.generatorFallbackFunctionHeavyweightCount - baseline.generatorFallbackFunctionHeavyweightCount
		delta.generatorFallbackFunctionGlobalInsertCount = current.generatorFallbackFunctionGlobalInsertCount - baseline.generatorFallbackFunctionGlobalInsertCount
		delta.generatorFallbackFunctionMethodInsertCount = current.generatorFallbackFunctionMethodInsertCount - baseline.generatorFallbackFunctionMethodInsertCount
		delta.generatorFallbackFunctionInterfaceInsertCount = current.generatorFallbackFunctionInterfaceInsertCount - baseline.generatorFallbackFunctionInterfaceInsertCount
		delta.captureDeclarationCalls = current.captureDeclarationCalls - baseline.captureDeclarationCalls
		delta.jstsSignatureCallsFunctionLike = current.jstsSignatureCallsFunctionLike - baseline.jstsSignatureCallsFunctionLike
		delta.jstsSignatureCallsStatementLike = current.jstsSignatureCallsStatementLike - baseline.jstsSignatureCallsStatementLike
		delta.lteMatchAnyFunctionCalls = current.lteMatchAnyFunctionCalls - baseline.lteMatchAnyFunctionCalls
		delta.lteMatchAnyVariableCalls = current.lteMatchAnyVariableCalls - baseline.lteMatchAnyVariableCalls
		delta.typeCleanerExtractCalls = current.typeCleanerExtractCalls - baseline.typeCleanerExtractCalls
		delta.typeCleanerCacheHits = current.typeCleanerCacheHits - baseline.typeCleanerCacheHits
		delta.typeCleanerCacheMisses = current.typeCleanerCacheMisses - baseline.typeCleanerCacheMisses
		delta.typeCleanerSwiftCalls = current.typeCleanerSwiftCalls - baseline.typeCleanerSwiftCalls
		delta.typeCleanerTSCalls = current.typeCleanerTSCalls - baseline.typeCleanerTSCalls
		delta.typeCleanerTSXCalls = current.typeCleanerTSXCalls - baseline.typeCleanerTSXCalls
		delta.typeCleanerJSCalls = current.typeCleanerJSCalls - baseline.typeCleanerJSCalls
		delta.typeCleanerOtherLanguageCalls = current.typeCleanerOtherLanguageCalls - baseline.typeCleanerOtherLanguageCalls
		delta.typeCleanerPrecleanCount = current.typeCleanerPrecleanCount - baseline.typeCleanerPrecleanCount
		delta.typeCleanerTSLogicCount = current.typeCleanerTSLogicCount - baseline.typeCleanerTSLogicCount
		delta.typeCleanerNonTSLogicCount = current.typeCleanerNonTSLogicCount - baseline.typeCleanerNonTSLogicCount
		delta.typeCleanerTSObjectLiteralCount = current.typeCleanerTSObjectLiteralCount - baseline.typeCleanerTSObjectLiteralCount
		delta.typeCleanerFilterCount = current.typeCleanerFilterCount - baseline.typeCleanerFilterCount
		delta.typeCleanerDedupCount = current.typeCleanerDedupCount - baseline.typeCleanerDedupCount
		delta.referencedTypesRawInsertions = current.referencedTypesRawInsertions - baseline.referencedTypesRawInsertions
		delta.referencedTypesPrefilterSkips = current.referencedTypesPrefilterSkips - baseline.referencedTypesPrefilterSkips
		delta.referencedTypesEmptyResults = current.referencedTypesEmptyResults - baseline.referencedTypesEmptyResults
		delta.referencedTypesOutputTypeCount = current.referencedTypesOutputTypeCount - baseline.referencedTypesOutputTypeCount
		delta.extractionMemoJSTSHits = current.extractionMemoJSTSHits - baseline.extractionMemoJSTSHits
		delta.extractionMemoJSTSMisses = current.extractionMemoJSTSMisses - baseline.extractionMemoJSTSMisses
		delta.extractionMemoFunctionHits = current.extractionMemoFunctionHits - baseline.extractionMemoFunctionHits
		delta.extractionMemoFunctionMisses = current.extractionMemoFunctionMisses - baseline.extractionMemoFunctionMisses
		delta.extractionMemoFunctionParsedHits = current.extractionMemoFunctionParsedHits - baseline.extractionMemoFunctionParsedHits
		delta.extractionMemoFunctionParsedMisses = current.extractionMemoFunctionParsedMisses - baseline.extractionMemoFunctionParsedMisses
		delta.extractionMemoVariableHits = current.extractionMemoVariableHits - baseline.extractionMemoVariableHits
		delta.extractionMemoVariableMisses = current.extractionMemoVariableMisses - baseline.extractionMemoVariableMisses
		delta.extractionMemoTSFastPathHits = current.extractionMemoTSFastPathHits - baseline.extractionMemoTSFastPathHits
		delta.extractionMemoTSFastPathMisses = current.extractionMemoTSFastPathMisses - baseline.extractionMemoTSFastPathMisses
		return delta
	}

	private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
		guard !values.isEmpty else { return 0 }
		let sorted = values.sorted()
		let clampedFraction = min(max(fraction, 0), 1)
		let index = Int((Double(sorted.count - 1) * clampedFraction).rounded(.up))
		return sorted[index]
	}

	private static func milliseconds(_ nanoseconds: UInt64) -> Double {
		Double(nanoseconds) / 1_000_000.0
	}

	private static func formatMilliseconds(_ milliseconds: Double) -> String {
		String(format: "%.2f", milliseconds)
	}

	private static func iterationCountFromEnvironment(defaultValue: Int) -> Int {
		let rawValue = ProcessInfo.processInfo.environment[CodeMapPerfRuntime.benchmarkIterationsEnvironmentKey]
		guard let rawValue, let parsed = Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
			return defaultValue
		}
		return max(parsed, 1)
	}

	private static func environmentDescription(_ name: String) -> String {
		ProcessInfo.processInfo.environment[name] ?? "<unset>"
	}
}
