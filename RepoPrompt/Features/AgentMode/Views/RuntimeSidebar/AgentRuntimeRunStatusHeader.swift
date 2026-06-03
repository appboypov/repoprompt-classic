import SwiftUI

struct AgentRuntimeRunStatusHeader: View {
	let runState: AgentSessionRunState
	let isAgentBusy: Bool
	let isWaitingForInstruction: Bool
	let hasPendingQuestion: Bool
	let hasPendingApproval: Bool
	let lastUpdatedAt: Date?

	private var statusText: String {
		switch runState {
		case .running:
			return "Running"
		case .waitingForUser:
			return "Waiting for instruction"
		case .waitingForQuestion:
			return "Waiting for answer"
		case .waitingForApproval:
			return "Waiting for approval"
		case .completed:
			return "Completed"
		case .cancelled:
			return "Cancelled"
		case .failed:
			return "Failed"
		case .idle:
			return "Idle"
		}
	}

	private var statusColor: Color {
		switch runState {
		case .running:
			return .blue
		case .waitingForUser, .waitingForQuestion, .waitingForApproval:
			return .orange
		case .completed:
			return .green
		case .cancelled, .failed:
			return .red
		case .idle:
			return .secondary
		}
	}

	private var waitingDetail: String? {
		if hasPendingApproval {
			return "Pending approval request"
		}
		if hasPendingQuestion {
			return "Pending user question"
		}
		if isWaitingForInstruction {
			return "Waiting for follow-up instruction"
		}
		return nil
	}

	private var lastUpdatedText: String? {
		guard let lastUpdatedAt else { return nil }
		let formatter = RelativeDateTimeFormatter()
		formatter.unitsStyle = .short
		return formatter.localizedString(for: lastUpdatedAt, relativeTo: Date())
	}

	var body: some View {
		AgentRuntimeSectionCard(
			title: "Runtime",
			subtitle: waitingDetail
		) {
			HStack(spacing: 8) {
				Circle()
					.fill(statusColor)
					.frame(width: 8, height: 8)
				Text(statusText)
					.font(.system(size: 12, weight: .medium))
			}

			if isAgentBusy && runState == .running {
				ProgressView()
					.controlSize(.small)
			}

			if let lastUpdatedText {
				Text("Last update \(lastUpdatedText)")
					.font(.system(size: 10))
					.foregroundStyle(.secondary)
			}
		}
	}
}
