import Foundation

extension ContextBuilderResponseType {
	var headlessMode: HeadlessMode? {
		switch self {
		case .plan:
			return .plan
		case .question:
			return .chat
		case .review:
			return .review
		case .clarify:
			return nil
		}
	}
}
