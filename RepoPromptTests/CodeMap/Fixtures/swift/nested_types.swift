protocol OuterProtocol {
	func outerRequirement()
}

class Outer {
	protocol InnerProtocol {
		func innerRequirement()
	}

	class Inner {
		func innerMethod(value: String) -> Int {
			return value.count
		}
	}

	func outerMethod(flag: Bool) {
		if flag { }
	}
}
