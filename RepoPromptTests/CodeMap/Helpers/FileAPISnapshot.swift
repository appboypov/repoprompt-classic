//
//  FileAPISnapshot.swift
//  RepoPromptTests
//
//  Stable, sorted snapshot of FileAPI for golden file comparisons.
//  Normalizes ordering to reduce diff noise across runs.
//

import Foundation
import SwiftTreeSitter
@testable import RepoPrompt

// MARK: - Snapshot Models

/// A stable, sorted snapshot of FileAPI for golden file comparisons.
/// Normalizes ordering and uses stable paths to reduce diff noise.
struct FileAPISnapshot: Codable, Equatable {
	let filePath: String
	let imports: [String]
	let exports: [String]
	let classes: [ClassSnapshot]
	let interfaces: [InterfaceSnapshot]
	let aliases: [TypeAliasSnapshot]
	let literalUnions: [String]
	let functions: [FunctionSnapshot]
	let enums: [EnumSnapshot]
	let globalVars: [VariableSnapshot]
	let macros: [String]
	let referencedTypes: [String]
	let functionSignatureTypes: [String]
	let propertySignatureTypes: [String]
	
	init(api: FileAPI, stablePath: String) {
		self.filePath = stablePath
		self.imports = api.imports.sorted()
		self.exports = api.exports.sorted()
		self.classes = api.classes.map { ClassSnapshot(from: $0) }.sorted { $0.name < $1.name }
		self.interfaces = api.interfaces.map { InterfaceSnapshot(from: $0) }.sorted { $0.name < $1.name }
		self.aliases = api.aliases.map { TypeAliasSnapshot(from: $0) }.sorted { $0.name < $1.name }
		self.literalUnions = api.literalUnions.sorted()
		self.functions = sortFunctions(api.functions.map { FunctionSnapshot(from: $0) })
		self.enums = api.enums.map { EnumSnapshot(from: $0) }.sorted { $0.name < $1.name }
		self.globalVars = api.globalVars.map { VariableSnapshot(from: $0) }.sorted { $0.name < $1.name }
		self.macros = api.macros.sorted()
		self.referencedTypes = api.referencedTypes.sorted()
		let language = Self.languageType(for: stablePath)
		if let lang = language {
			self.functionSignatureTypes = Self.collectFunctionSignatureTypes(api: api, language: lang)
			self.propertySignatureTypes = Self.collectPropertySignatureTypes(api: api, language: lang)
		} else {
			self.functionSignatureTypes = []
			self.propertySignatureTypes = []
		}
	}
}

fileprivate func sortFunctions(_ functions: [FunctionSnapshot]) -> [FunctionSnapshot] {
	return functions.sorted { lhs, rhs in
		let lhsLine = lhs.lineNumber ?? Int.max
		let rhsLine = rhs.lineNumber ?? Int.max
		if lhsLine != rhsLine { return lhsLine < rhsLine }
		if lhs.definitionLine != rhs.definitionLine { return lhs.definitionLine < rhs.definitionLine }
		return lhs.name < rhs.name
	}
}

private extension FileAPISnapshot {
	static func languageType(for path: String) -> LanguageType? {
		let ext = (path as NSString).pathExtension.lowercased()
		return SyntaxManager.shared.extensionToLanguage[ext]
	}
	
	static func collectFunctionSignatureTypes(api: FileAPI, language: LanguageType) -> [String] {
		var types = Set<String>()
		let functionList = api.functions
			+ api.classes.flatMap { $0.methods }
			+ api.interfaces.flatMap { $0.methods }
		
		for fn in functionList {
			if let returnType = fn.returnType {
				for t in TypeCleaner.extractBaseTypes(from: returnType, language: language) {
					types.insert(t)
				}
			}
			for param in fn.parameters {
				if let typeName = param.typeName {
					for t in TypeCleaner.extractBaseTypes(from: typeName, language: language) {
						types.insert(t)
					}
				}
			}
		}
		
		return Array(types).sorted()
	}
	
	static func collectPropertySignatureTypes(api: FileAPI, language: LanguageType) -> [String] {
		var types = Set<String>()
		let propertyList = api.globalVars.map { PropertyInfo(name: $0.name, typeName: $0.typeName) }
			+ api.classes.flatMap { $0.properties }
			+ api.interfaces.flatMap { $0.properties }
		
		for prop in propertyList {
			if let typeName = prop.typeName {
				for t in TypeCleaner.extractBaseTypes(from: typeName, language: language) {
					types.insert(t)
				}
			}
		}
		
		return Array(types).sorted()
	}
}

struct ClassSnapshot: Codable, Equatable {
	let name: String
	let methods: [FunctionSnapshot]
	let properties: [PropertySnapshot]
	
	init(from info: ClassInfo) {
		self.name = info.name
		self.methods = sortFunctions(info.methods.map { FunctionSnapshot(from: $0) })
		self.properties = info.properties.map { PropertySnapshot(from: $0) }.sorted { $0.name < $1.name }
	}
}

struct InterfaceSnapshot: Codable, Equatable {
	let name: String
	let methods: [FunctionSnapshot]
	let properties: [PropertySnapshot]
	
	init(from info: InterfaceInfo) {
		self.name = info.name
		self.methods = sortFunctions(info.methods.map { FunctionSnapshot(from: $0) })
		self.properties = info.properties.map { PropertySnapshot(from: $0) }.sorted { $0.name < $1.name }
	}
}

struct FunctionSnapshot: Codable, Equatable {
	let name: String
	let definitionLine: String
	let lineNumber: Int?
	let returnType: String?
	let parameters: [ParameterSnapshot]
	
	init(from info: FunctionInfo) {
		self.name = info.name
		self.definitionLine = info.definitionLine
		self.lineNumber = info.lineNumber
		self.returnType = info.returnType
		self.parameters = info.parameters.map { ParameterSnapshot(from: $0) }
	}
}

struct ParameterSnapshot: Codable, Equatable {
	let externalName: String?
	let localName: String
	let typeName: String?
	
	init(from info: ParameterInfo) {
		self.externalName = info.externalName
		self.localName = info.localName
		self.typeName = info.typeName
	}
}

struct PropertySnapshot: Codable, Equatable {
	let name: String
	let typeName: String?
	
	init(from info: PropertyInfo) {
		self.name = info.name
		self.typeName = info.typeName
	}
}

struct TypeAliasSnapshot: Codable, Equatable {
	let name: String
	let definitionLine: String
	
	init(from info: TypeAliasInfo) {
		self.name = info.name
		self.definitionLine = info.definitionLine
	}
}

struct EnumSnapshot: Codable, Equatable {
	let name: String
	let cases: [String]
	
	init(from info: EnumInfo) {
		self.name = info.name
		self.cases = info.cases // Preserve order - enum case order is meaningful
	}
}

struct VariableSnapshot: Codable, Equatable {
	let name: String
	let typeName: String?
	let definitionLine: String
	
	init(from info: VariableInfo) {
		self.name = info.name
		self.typeName = info.typeName
		self.definitionLine = info.definitionLine
	}
}

// MARK: - Capture Snapshot

/// Lightweight snapshot of tree-sitter captures for regression detection.
/// Uses counts-by-name to avoid brittleness from offset changes.
struct CaptureSnapshot: Codable, Equatable {
	let fixture: String
	let totalCaptures: Int
	let captureCountsByName: [String: Int]
	
	init(fixture: String, captures: [NamedRange]) {
		self.fixture = fixture
		self.totalCaptures = captures.count
		
		var counts: [String: Int] = [:]
		for capture in captures {
			counts[capture.name, default: 0] += 1
		}
		self.captureCountsByName = counts
	}
}
