import Foundation

/// Generates deterministic, believable code for TS/Go/Swift using Mulberry32 RNG.
/// Used by the benchmark generator to replace filler lines and to add decoys.
enum BelievableCodeFactory {
	// MARK: - Public entry points
	
	static func tsUtilityModule(rng: inout Mulberry32, module: String? = nil, approxLines: Int = 100) -> String {
		let mod = module ?? "Util\(rng.nextInt(upperBound: 10_000))"
		var out: [String] = []
		out.append("/* auto-generated believable TS module */")
		out.append("export namespace \(mod) {")
		out.append("    export interface Pair<T, U> { left: T; right: U }")
		out.append("    export type Nullable<T> = T | null;")
		out.append("")
		out.append("    export class Counter {")
		out.append("        private n: number")
		out.append("        constructor(n: number = 0) { this.n = n }")
		out.append("        inc(): number { this.n++; return this.n }")
		out.append("        add(d: number): number { this.n += d; return this.n }")
		out.append("        value(): number { return this.n }")
		out.append("    }")
		out.append("")
		out.append("    export function clamp(n: number, min = 0, max = 100): number {")
		out.append("        return Math.min(Math.max(n, min), max)")
		out.append("    }")
		out.append("")
		out.append("    export function toPairs(xs: string[]): Pair<string, number>[] {")
		out.append("        const res: Pair<string, number>[] = [];")
		out.append("        let i = 0;")
		out.append("        for (const x of xs) { res.push({ left: x, right: i++ }) }")
		out.append("        return res;")
		out.append("    }")
		out.append("")
		out.append("    export function sum(ns: number[]): number {")
		out.append("        let s = 0;")
		out.append("        for (const n of ns) s += n;")
		out.append("        return s;")
		out.append("    }")
		out.append("")

		let fnNames = ["format", "uniq", "flatten", "chunked", "pad", "slug", "join", "take", "drop"]
		let words = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india"]
		var total = out.count
		while total < approxLines {
			let idx = rng.nextInt(upperBound: fnNames.count)
			let w1 = words[rng.nextInt(upperBound: words.count)]
			let w2 = words[rng.nextInt(upperBound: words.count)]
			switch idx {
			case 0:
				out.append("    export function \(fnNames[idx])(s: string): string { return `[\(w1)] \(w2): ${'$'}{s}` }")
			case 1:
				out.append("    export function \(fnNames[idx])<T>(xs: T[]): T[] { return Array.from(new Set(xs)) }")
			case 2:
				out.append("    export function \(fnNames[idx])<T>(xss: T[][]): T[] { return xss.reduce((a, b) => a.concat(b), []) }")
			case 3:
				out.append("    export function \(fnNames[idx])<T>(xs: T[], n = 2): T[][] {")
				out.append("        const out: T[][] = [];")
				out.append("        for (let i = 0; i < xs.length; i += n) out.push(xs.slice(i, i + n));")
				out.append("        return out;")
				out.append("    }")
				total += 3
			case 4:
				out.append("    export function \(fnNames[idx])(s: string, n = 2): string { return s.padStart(s.length + n, ' ') }")
			case 5:
				out.append("    export function \(fnNames[idx])(s: string): string { return s.toLowerCase().replace(/\\W+/g, '-') }")
			case 6:
				out.append("    export function \(fnNames[idx])(xs: string, sep = ','): string[] { return xs.split(sep) }")
			case 7:
				out.append("    export function \(fnNames[idx])<T>(xs: T[], n: number): T[] { return xs.slice(0, n) }")
			default:
				out.append("    export function \(fnNames[idx])<T>(xs: T[], n: number): T[] { return xs.slice(n) }")
			}
			total += 1
		}
		out.append("}")
		return out.joined(separator: "\n")
	}
	
	static func goUtilityModule(rng: inout Mulberry32, pkg: String = "util", approxLines: Int = 80) -> String {
		var out: [String] = []
		out.append("// auto-generated believable Go package")
		out.append("package \(pkg)")
		out.append("")
		out.append("import (")
		out.append("    \"fmt\"")
		out.append("    \"strings\"")
		out.append(")")
		out.append("")
		out.append("func Clamp(n, min, max int) int {")
		out.append("    if n < min { return min }")
		out.append("    if n > max { return max }")
		out.append("    return n")
		out.append("}")
		out.append("")
		out.append("func Sum(xs []int) int { s := 0; for _, v := range xs { s += v }; return s }")
		out.append("func Join(xs []string, sep string) string { return strings.Join(xs, sep) }")
		out.append("func Debug(v any) { fmt.Println(v) }")
		out.append("")
		let extras = [
			"func Map[T any, U any](xs []T, f func(T) U) []U { ys := make([]U, len(xs)); for i, v := range xs { ys[i] = f(v) }; return ys }",
			"func Filter[T any](xs []T, f func(T) bool) []T { ys := make([]T, 0, len(xs)); for _, v := range xs { if f(v) { ys = append(ys, v) } }; return ys }",
			"func Repeat(s string, n int) string { return strings.Repeat(s, n) }",
			"func Pairwise(xs []int, f func(int, int) int) []int { if len(xs) < 2 { return nil }; ys := make([]int, 0, len(xs)-1); for i := 0; i < len(xs)-1; i++ { ys = append(ys, f(xs[i], xs[i+1])) }; return ys }",
			"func Contains[T comparable](xs []T, needle T) bool { for _, v := range xs { if v == needle { return true } }; return false }"
		]
		var total = out.count
		while total < approxLines {
			out.append(extras[rng.nextInt(upperBound: extras.count)])
			total += 1
		}
		return out.joined(separator: "\n")
	}
	
	// MARK: - Decoys
	
	static func tsDecoyFile(rng: inout Mulberry32, name: String) -> (path: String, content: String) {
		let path = "src/ts/decoy/\(name).ts"
		let mod = "Decoy\(name)"
		var content = tsUtilityModule(rng: &rng, module: mod, approxLines: 60)
		// Append plausible code without standardized markers
		content += """

export function use(a: string, b: string): string { return a + b; }

export function block2(n: number): number {
    // alternative implementation
    const t = n * 3
    return t
}

export function render(list: string[]): string {
    let out = ""
    for (let i = 0; i < 2; i++) {
        out += use("a" + i, "b" + i)
    }
    return out
}
"""
		return (path, content)
	}
	
	static func goDecoyFile(rng: inout Mulberry32, name: String) -> (path: String, content: String) {
		let path = "src/go/decoy/\(name).go"
		return (path, goUtilityModule(rng: &rng, pkg: "decoy\(name)", approxLines: 50))
	}
	
	// MARK: - Swift
	
	static func swiftUtilityModule(rng: inout Mulberry32, module: String = "Utils", approxLines: Int = 80) -> String {
		let mod = module
		var out: [String] = []
		out.append("/* auto-generated believable Swift module */")
		out.append("public enum \(mod) {")
		out.append("\tpublic struct Pair<T,U> { public let left: T; public let right: U }")
		out.append("")
		out.append("\tpublic final class Counter {")
		out.append("\t\tprivate var n: Int")
		out.append("\t\tpublic init(_ n: Int = 0) { self.n = n }")
		out.append("\t\tpublic func inc() -> Int { n += 1; return n }")
		out.append("\t\tpublic func add(_ d: Int) -> Int { n += d; return n }")
		out.append("\t\tpublic var value: Int { n }")
		out.append("\t}")
		out.append("")
		out.append("\tpublic static func clamp(_ n: Int, min: Int = 0, max: Int = 100) -> Int {")
		out.append("\t\treturn Swift.min(Swift.max(n, min), max)")
		out.append("\t}")
		out.append("")
		out.append("\tpublic static func sum(_ xs: [Int]) -> Int { xs.reduce(0, +) }")
		out.append("}")
		out.append("")
		let words = ["alpha","bravo","charlie","delta","echo","foxtrot","golf"]
		while out.count < approxLines {
			let w1 = words[rng.nextInt(upperBound: words.count)]
			let w2 = words[rng.nextInt(upperBound: words.count)]
			out.append("public func \(w1)_\(w2)(_ s: String) -> String { \"[\(w1)] \(w2): \\(s)\" }")
		}
		return out.joined(separator: "\n")
	}
	
	static func swiftDecoyFile(rng: inout Mulberry32, name: String) -> (path: String, content: String) {
		let path = "src/swift/decoy/\(name).swift"
		var content = swiftUtilityModule(rng: &rng, module: "Decoy\(name)", approxLines: 60)
		// Append plausible code without standardized markers
		content += """

public func use(_ a: String, _ b: String) -> String { a + b }

public func block2(_ n: Int) -> Int {
	// alternative implementation
	let t = n * 3
	return t
}

public func render(_ list: [String]) -> String {
	var out = ""
	for i in 0..<2 {
		out += use("a\\(i)", "b\\(i)")
	}
	return out
}
"""
		return (path, content)
	}

	// MARK: - Complex insert_guard hardened generators

	/// Generates a complex TypeScript clamp function family with nested code and near-duplicates.
	/// Creates ambiguous search contexts to force models to use larger search blocks.
	static func tsClampFamilyComplex(
		rng: inout Mulberry32,
		mainName: String = "clamp",
		anchorUID: String? = nil,
		decoyAnchorUIDs: [String] = [],
		nearMissFunctions: Int = 4,
		inFunctionShadowClusters: Int = 2
	) -> String {
		var out: [String] = []

		// Main clamp function with complex nested structure
		out.append("export function \(mainName)(n: number): number {")
		out.append("    const limit = 100")
		out.append("")

		// Cluster A - main insertion point
		if let uid = anchorUID {
			out.append("    // ANCHOR:start:\(uid)")
			out.append("    const normalized = Math.abs(n)")
			out.append("    // ANCHOR:end:\(uid)")
		} else {
			out.append("    const normalized = Math.abs(n)")
		}

		// Add nested complexity with repeated normalized patterns
		out.append("    if (normalized > limit) {")
		out.append("        const normalized = normalized - 1  // shadowed normalized")
		out.append("        return normalized")
		out.append("    }")
		out.append("")

		// Cluster B - similar pattern
		out.append("    // Processing loop with normalized")
		out.append("    for (let i = 0; i < 2; i++) {")
		out.append("        const normalized = Math.abs(n + i)")
		out.append("        if (normalized > limit) break")
		out.append("    }")
		out.append("")

		// Add shadow clusters within function if requested
		for i in 0..<inFunctionShadowClusters {
			out.append("    // Validation cluster \(i + 1)")
			out.append("    const normalized\(i + 1) = Math.abs(n * \(i + 2))")
			out.append("    if (normalized\(i + 1) > limit) {")
			out.append("        const normalized = normalized\(i + 1)  // another normalized reference")
			out.append("    }")
			out.append("")
		}

		// Nested helper function
		out.append("    function adjust(n: number): number {")
		out.append("        const normalized = Math.abs(n)  // nested normalized")
		out.append("        return normalized")
		out.append("    }")
		out.append("")
		out.append("    return Math.min(Math.abs(n), limit)")
		out.append("}")
		out.append("")

		// Generate near-miss functions
		let nearMissNames = ["clampStrict", "clampBounded", "clampPrime", "clampNormalized", "clampNormalized2", "clampSafe"]
		for i in 0..<min(nearMissFunctions, nearMissNames.count) {
			let fnName = nearMissNames[i]
			out.append("export function \(fnName)(n: number): number {")
			out.append("    const limit = 100")

			// Add decoy anchor if available
			if i < decoyAnchorUIDs.count {
				out.append("    // ANCHOR:start:\(decoyAnchorUIDs[i])")
				out.append("    const normalized = Math.abs(n)")
				out.append("    // ANCHOR:end:\(decoyAnchorUIDs[i])")
			} else {
				out.append("    const normalized = Math.abs(n)")
			}

			out.append("    if (normalized > limit) {")
			out.append("        const normalized = normalized - 1")
			out.append("        return normalized")
			out.append("    }")
			out.append("    return Math.min(normalized, limit)")
			out.append("}")
			out.append("")
		}

		// Add shadow cluster at EOF if requested
		if inFunctionShadowClusters > 0 {
			out.append("// SHADOW START (do not edit)")
			out.append("const normalized = Math.abs(42)")
			out.append("// SHADOW END (do not edit)")
		}

		return out.joined(separator: "\n")
	}

	/// Generates a complex Go Clamp function family with nested code and near-duplicates.
	static func goClampFamilyComplex(
		rng: inout Mulberry32,
		mainName: String = "Clamp",
		anchorUID: String? = nil,
		decoyAnchorUIDs: [String] = [],
		nearMissFunctions: Int = 4,
		inFunctionShadowClusters: Int = 2
	) -> String {
		var out: [String] = []

		// Main Clamp function with complex nested structure
		out.append("func \(mainName)(n int) int {")
		out.append("    limit := 100")
		out.append("")

		// Cluster A - main insertion point
		if let uid = anchorUID {
			out.append("    // ANCHOR:start:\(uid)")
			out.append("    normalized := n")
			out.append("    if normalized < 0 {")
			out.append("        normalized = -normalized")
			out.append("    }")
			out.append("    // ANCHOR:end:\(uid)")
		} else {
			out.append("    normalized := n")
			out.append("    if normalized < 0 {")
			out.append("        normalized = -normalized")
			out.append("    }")
		}

		// Add nested complexity
		out.append("    if normalized > limit {")
		out.append("        normalized := normalized - 1  // shadowed normalized")
		out.append("        return normalized")
		out.append("    }")
		out.append("")

		// Cluster B - similar pattern
		out.append("    // Processing loop with normalized")
		out.append("    for i := 0; i < 2; i++ {")
		out.append("        normalized := n + i")
		out.append("        if normalized < 0 {")
		out.append("            normalized = -normalized")
		out.append("        }")
		out.append("        if normalized > limit {")
		out.append("            break")
		out.append("        }")
		out.append("    }")
		out.append("")

		// Add shadow clusters within function
		for i in 0..<inFunctionShadowClusters {
			out.append("    // Validation cluster \(i + 1)")
			out.append("    normalized\(i + 1) := n * \(i + 2)")
			out.append("    if normalized\(i + 1) < 0 {")
			out.append("        normalized\(i + 1) = -normalized\(i + 1)")
			out.append("    }")
			out.append("    if normalized\(i + 1) > limit {")
			out.append("        normalized := normalized\(i + 1)  // another normalized reference")
			out.append("        _ = normalized")
			out.append("    }")
			out.append("")
		}

		// Nested helper function
		out.append("    adjust := func(n int) int {")
		out.append("        normalized := n  // nested normalized")
		out.append("        if normalized < 0 {")
		out.append("            normalized = -normalized")
		out.append("        }")
		out.append("        return normalized")
		out.append("    }")
		out.append("    _ = adjust")
		out.append("")
		out.append("    if n < 0 {")
		out.append("        return 0")
		out.append("    }")
		out.append("    if n > limit {")
		out.append("        return limit")
		out.append("    }")
		out.append("    return n")
		out.append("}")
		out.append("")

		// Generate near-miss functions
		let nearMissNames = ["ClampStrict", "ClampBounded", "ClampPrime", "ClampNormalized", "ClampNormalized2", "ClampSafe"]
		for i in 0..<min(nearMissFunctions, nearMissNames.count) {
			let fnName = nearMissNames[i]
			out.append("func \(fnName)(n int) int {")
			out.append("    limit := 100")

			// Add decoy anchor if available
			if i < decoyAnchorUIDs.count {
				out.append("    // ANCHOR:start:\(decoyAnchorUIDs[i])")
				out.append("    normalized := n")
				out.append("    if normalized < 0 {")
				out.append("        normalized = -normalized")
				out.append("    }")
				out.append("    // ANCHOR:end:\(decoyAnchorUIDs[i])")
			} else {
				out.append("    normalized := n")
				out.append("    if normalized < 0 {")
				out.append("        normalized = -normalized")
				out.append("    }")
			}

			out.append("    if normalized > limit {")
			out.append("        normalized := normalized - 1")
			out.append("        return normalized")
			out.append("    }")
			out.append("    if normalized < 0 {")
			out.append("        return 0")
			out.append("    }")
			out.append("    return normalized")
			out.append("}")
			out.append("")
		}

		// Add shadow cluster at EOF if requested
		if inFunctionShadowClusters > 0 {
			out.append("// SHADOW START (do not edit)")
			out.append("var normalized = 42")
			out.append("// SHADOW END (do not edit)")
		}

		return out.joined(separator: "\n")
	}

	/// Generates a complex Swift clamp function family with nested code and near-duplicates.
	/// Uses tabs for indentation.
	static func swiftClampFamilyComplex(
		rng: inout Mulberry32,
		mainName: String = "clamp",
		anchorUID: String? = nil,
		decoyAnchorUIDs: [String] = [],
		nearMissFunctions: Int = 4,
		inFunctionShadowClusters: Int = 2
	) -> String {
		var out: [String] = []

		// Main clamp function with complex nested structure
		out.append("public func \(mainName)(_ n: Int) -> Int {")
		out.append("\tlet limit = 100")
		out.append("")

		// Cluster A - main insertion point
		if let uid = anchorUID {
			out.append("\t// ANCHOR:start:\(uid)")
			out.append("\tlet normalized = abs(n)")
			out.append("\t// ANCHOR:end:\(uid)")
		} else {
			out.append("\tlet normalized = abs(n)")
		}

		// Add nested complexity
		out.append("\tif normalized > limit {")
		out.append("\t\tlet normalized = normalized - 1  // shadowed normalized")
		out.append("\t\treturn normalized")
		out.append("\t}")
		out.append("")

		// Cluster B - similar pattern
		out.append("\t// Processing loop with normalized")
		out.append("\tfor i in 0..<2 {")
		out.append("\t\tlet normalized = abs(n + i)")
		out.append("\t\tif normalized > limit { break }")
		out.append("\t}")
		out.append("")

		// Add shadow clusters within function
		for i in 0..<inFunctionShadowClusters {
			out.append("\t// Validation cluster \(i + 1)")
			out.append("\tlet normalized\(i + 1) = abs(n * \(i + 2))")
			out.append("\tif normalized\(i + 1) > limit {")
			out.append("\t\tlet normalized = normalized\(i + 1)  // another normalized reference")
			out.append("\t\t_ = normalized")
			out.append("\t}")
			out.append("")
		}

		// Nested helper function
		out.append("\tfunc adjust(_ n: Int) -> Int {")
		out.append("\t\tlet normalized = abs(n)  // nested normalized")
		out.append("\t\treturn normalized")
		out.append("\t}")
		out.append("\t_ = adjust")
		out.append("")
		out.append("\treturn min(abs(n), limit)")
		out.append("}")
		out.append("")

		// Generate near-miss functions
		let nearMissNames = ["clampStrict", "clampBounded", "clampPrime", "clampNormalized", "clampNormalized2", "clampSafe"]
		for i in 0..<min(nearMissFunctions, nearMissNames.count) {
			let fnName = nearMissNames[i]
			out.append("public func \(fnName)(_ n: Int) -> Int {")
			out.append("\tlet limit = 100")

			// Add decoy anchor if available
			if i < decoyAnchorUIDs.count {
				out.append("\t// ANCHOR:start:\(decoyAnchorUIDs[i])")
				out.append("\tlet normalized = abs(n)")
				out.append("\t// ANCHOR:end:\(decoyAnchorUIDs[i])")
			} else {
				out.append("\tlet normalized = abs(n)")
			}

			out.append("\tif normalized > limit {")
			out.append("\t\tlet normalized = normalized - 1")
			out.append("\t\treturn normalized")
			out.append("\t}")
			out.append("\treturn min(normalized, limit)")
			out.append("}")
			out.append("")
		}

		// Add shadow cluster at EOF if requested
		if inFunctionShadowClusters > 0 {
			out.append("// SHADOW START (do not edit)")
			out.append("let normalized = abs(42)")
			out.append("// SHADOW END (do not edit)")
		}

		return out.joined(separator: "\n")
	}

	// MARK: - Curly decoy generators for curly_fix hardening

	static func tsCurlyDecoy(rng: inout Mulberry32, name: String, approxLines: Int = 60) -> (path: String, content: String) {
		let path = "src/ts/decoy/BraceMaze_\(name).ts"
		var out: [String] = []
		out.append("// Decoy file with brace noise")
		out.append("export function demo(xs: string[]): number {")
		out.append("    let sum = 0")
		out.append("    // Brace noise: }")
		out.append("    const braceLiteral = \"}\"")
		out.append("    for (let i = 0; i < xs.length; i++) {")
		out.append("        if (xs[i].length > 0) {")
		out.append("            sum += xs[i].length")
		out.append("        }")
		out.append("    }")
		out.append("    return sum")
		out.append("}")
		out.append("")
		out.append("export function balanced(n: number): number {")
		out.append("    // Comment with brace: }")
		out.append("    const braceStr = \"}\"")
		out.append("    for (let i = 0; i < n; i++) {")
		out.append("        const temp = i * 2 // another brace: }")
		out.append("        if (temp > 10) {")
		out.append("            return temp")
		out.append("        }")
		out.append("    }")
		out.append("    return 0")
		out.append("}")
		out.append("")
		out.append("// More brace noise: } } }")
		out.append("const bracesInString = \"{ } { }\"")

		// Pad with additional noise if needed
		let words = ["alpha", "bravo", "charlie", "delta", "echo"]
		while out.count < approxLines {
			let w = words[rng.nextInt(upperBound: words.count)]
			out.append("export function \(w)\(rng.nextInt(upperBound: 100))(x: number): number { return x * 2 }")
		}

		return (path, out.joined(separator: "\n"))
	}

	static func goCurlyDecoy(rng: inout Mulberry32, name: String, approxLines: Int = 60) -> (path: String, content: String) {
		let path = "src/go/decoy/BraceMaze_\(name).go"
		var out: [String] = []
		out.append("// Decoy file with brace noise")
		out.append("package decoy")
		out.append("")
		out.append("import \"fmt\"")
		out.append("")
		out.append("func Demo(xs []string) int {")
		out.append("    sum := 0")
		out.append("    // Brace noise: }")
		out.append("    braceLiteral := \"}\"")
		out.append("    for i := 0; i < len(xs); i++ {")
		out.append("        if len(xs[i]) > 0 {")
		out.append("            sum += len(xs[i])")
		out.append("        }")
		out.append("    }")
		out.append("    _ = braceLiteral")
		out.append("    return sum")
		out.append("}")
		out.append("")
		out.append("func Balanced(n int) int {")
		out.append("    // Comment with brace: }")
		out.append("    braceStr := \"}\"")
		out.append("    for i := 0; i < n; i++ {")
		out.append("        temp := i * 2 // another brace: }")
		out.append("        if temp > 10 {")
		out.append("            fmt.Println(braceStr)")
		out.append("            return temp")
		out.append("        }")
		out.append("    }")
		out.append("    return 0")
		out.append("}")
		out.append("")
		out.append("// More brace noise: } } }")
		out.append("var bracesInString = \"{ } { }\"")

		// Pad with additional noise if needed
		let words = ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
		while out.count < approxLines {
			let w = words[rng.nextInt(upperBound: words.count)]
			out.append("func \(w)\(rng.nextInt(upperBound: 100))(x int) int { return x * 2 }")
		}

		return (path, out.joined(separator: "\n"))
	}

	static func swiftCurlyDecoy(rng: inout Mulberry32, name: String, approxLines: Int = 60) -> (path: String, content: String) {
		let path = "src/swift/decoy/BraceMaze_\(name).swift"
		var out: [String] = []
		out.append("// Decoy file with brace noise")
		out.append("public func demo(_ xs: [String]) -> Int {")
		out.append("\tvar sum = 0")
		out.append("\t// Brace noise: }")
		out.append("\tlet braceLiteral = \"}\"")
		out.append("\tfor i in 0..<xs.count {")
		out.append("\t\tif xs[i].count > 0 {")
		out.append("\t\t\tsum += xs[i].count")
		out.append("\t\t}")
		out.append("\t}")
		out.append("\t_ = braceLiteral")
		out.append("\treturn sum")
		out.append("}")
		out.append("")
		out.append("public func balanced(_ n: Int) -> Int {")
		out.append("\t// Comment with brace: }")
		out.append("\tlet braceStr = \"}\"")
		out.append("\tfor i in 0..<n {")
		out.append("\t\tlet temp = i * 2 // another brace: }")
		out.append("\t\tif temp > 10 {")
		out.append("\t\t\tprint(braceStr)")
		out.append("\t\t\treturn temp")
		out.append("\t\t}")
		out.append("\t}")
		out.append("\treturn 0")
		out.append("}")
		out.append("")
		out.append("// More brace noise: } } }")
		out.append("let bracesInString = \"{ } { }\"")

		// Pad with additional noise if needed
		let words = ["alpha", "bravo", "charlie", "delta", "echo"]
		while out.count < approxLines {
			let w = words[rng.nextInt(upperBound: words.count)]
			out.append("public func \(w)\(rng.nextInt(upperBound: 100))(_ x: Int) -> Int { x * 2 }")
		}

		return (path, out.joined(separator: "\n"))
	}
}
