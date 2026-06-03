import Foundation
import Security

struct RuntimeCodeSigningInfo: Equatable {
	let teamIdentifier: String?
	let codeIdentifier: String?
	let isAdHocSignature: Bool?
	let appleTeamValidation: AppleTeamSigningValidation
	let detectionErrorDescription: String?
}

enum AppleTeamSigningValidation: Equatable {
	case verified
	case rejected(OSStatus)
	case unavailable(String)
}

enum RuntimeCodeSigningDetector {
	static func currentProcessSigningInfo() -> RuntimeCodeSigningInfo {
		var code: SecCode?
		let selfStatus = SecCodeCopySelf([], &code)
		guard selfStatus == errSecSuccess, let code else {
			return unavailableSigningInfo(status: selfStatus)
		}

		var staticCode: SecStaticCode?
		let staticStatus = SecCodeCopyStaticCode(code, [], &staticCode)
		guard staticStatus == errSecSuccess, let staticCode else {
			return unavailableSigningInfo(status: staticStatus)
		}

		var information: CFDictionary?
		let infoStatus = SecCodeCopySigningInformation(
			staticCode,
			SecCSFlags(rawValue: kSecCSSigningInformation),
			&information
		)
		guard infoStatus == errSecSuccess, let dictionary = information as? [String: Any] else {
			return unavailableSigningInfo(status: infoStatus)
		}

		let teamIdentifier = normalizedString(dictionary[kSecCodeInfoTeamIdentifier as String])
		let codeIdentifier = normalizedString(dictionary[kSecCodeInfoIdentifier as String])
		let isAdHocSignature = adHocSignature(from: dictionary[kSecCodeInfoFlags as String])
		return RuntimeCodeSigningInfo(
			teamIdentifier: teamIdentifier,
			codeIdentifier: codeIdentifier,
			isAdHocSignature: isAdHocSignature,
			appleTeamValidation: validateAppleTeamSignature(staticCode, teamIdentifier: teamIdentifier),
			detectionErrorDescription: nil
		)
	}

	private static func validateAppleTeamSignature(
		_ staticCode: SecStaticCode,
		teamIdentifier: String?
	) -> AppleTeamSigningValidation {
		guard let teamIdentifier,
				SecureStorageRuntimePolicy.isValidAppleTeamIdentifier(teamIdentifier) else {
			return .unavailable("Missing or malformed Apple Team identifier")
		}

		let requirementText = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
		var requirement: SecRequirement?
		let requirementStatus = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
		guard requirementStatus == errSecSuccess, let requirement else {
			return .unavailable(errorDescription(for: requirementStatus))
		}

		let validationStatus = SecStaticCodeCheckValidity(
			staticCode,
			SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
			requirement
		)
		return validationStatus == errSecSuccess ? .verified : .rejected(validationStatus)
	}

	private static func adHocSignature(from value: Any?) -> Bool? {
		guard let number = value as? NSNumber else { return nil }
		// Security.framework declares kSecCodeSignatureAdhoc as the 0x0002 flag,
		// but this SDK does not surface that C enum case directly to Swift.
		let adHocSignatureMask = SecCodeSignatureFlags(rawValue: 0x0002).rawValue
		return number.uint32Value & adHocSignatureMask != 0
	}

	private static func normalizedString(_ value: Any?) -> String? {
		guard let string = value as? String else { return nil }
		let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
		return trimmed.isEmpty ? nil : trimmed
	}

	private static func unavailableSigningInfo(status: OSStatus) -> RuntimeCodeSigningInfo {
		let description = errorDescription(for: status)
		return RuntimeCodeSigningInfo(
			teamIdentifier: nil,
			codeIdentifier: nil,
			isAdHocSignature: nil,
			appleTeamValidation: .unavailable(description),
			detectionErrorDescription: description
		)
	}

	private static func errorDescription(for status: OSStatus) -> String {
		SecCopyErrorMessageString(status, nil) as String? ?? "Code signing information unavailable (\(status))"
	}
}
