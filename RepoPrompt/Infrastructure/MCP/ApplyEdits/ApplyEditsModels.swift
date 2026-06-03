import Foundation

enum ApplyEditsMode: Equatable {
	case rewrite(newText: String, onMissing: OnMissing)
	case single(search: String, replace: String, replaceAll: Bool)
	case batch([ApplyEditsOperation])
}

struct ApplyEditsOperation: Equatable {
	let search: String
	let replace: String
	let replaceAll: Bool
}

enum OnMissing: String, Equatable {
	case error
	case create
}

struct ApplyEditsRequest: Equatable {
	let path: String
	let mode: ApplyEditsMode
	let verbose: Bool

	var editCount: Int {
		switch mode {
		case .rewrite, .single:
			return 1
		case .batch(let edits):
			return edits.count
		}
	}
}

struct ApplyEditsExecutionOptions: Equatable, Sendable {
	let includeToolCardUnifiedDiff: Bool

	static let `default` = ApplyEditsExecutionOptions(includeToolCardUnifiedDiff: true)
	static let delegateSandbox = ApplyEditsExecutionOptions(includeToolCardUnifiedDiff: false)
}

enum ApplyEditsError: Swift.Error, Equatable {
	case invalidParams(String)
	case internalError(String)
}
