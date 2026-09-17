import Foundation

/// Pure ordering rules for the workspace catalog.
enum WorkspaceOrdering {
	/// Applies a reorder of the visible entries over the full catalog order.
	/// Entries absent from `visibleOrder` (hidden or system workspaces) keep their slots;
	/// the visible slots are refilled in the order `visibleOrder` gives.
	/// IDs in `visibleOrder` that are not in `fullOrder` are ignored.
	static func applyVisibleMove(fullOrder: [UUID], visibleOrder: [UUID]) -> [UUID] {
		let full = Set(fullOrder)
		let visible = visibleOrder.filter { full.contains($0) }
		let visibleSet = Set(visible)
		var replacements = visible.makeIterator()
		return fullOrder.map { id in
			guard visibleSet.contains(id) else { return id }
			return replacements.next() ?? id
		}
	}

	/// True when `candidate` is a permutation of `expected`.
	static func isPermutation(_ candidate: [UUID], of expected: [UUID]) -> Bool {
		candidate.count == expected.count && Set(candidate) == Set(expected) && Set(candidate).count == candidate.count
	}
}
