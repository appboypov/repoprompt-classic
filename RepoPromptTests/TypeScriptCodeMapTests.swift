import XCTest
@testable import RepoPrompt

class TypeScriptCodeMapTests: XCTestCase {
    
    func testBasicTypeScriptClass() {
        let content = """
        export class BaseRoom {
            CHANNEL = "$mylobby";
            maxClients = 5;
            protected _nextIndex = 1;
            protected _host: Player;
            
            protected showHint(playerId: string) {
                console.log("hint");
            }
            
            async onCreate(options: any) {
                console.log("onCreate");
            }
            
            private resetPlayerHintTimer(sessionId: string) {
                clearTimeout(this._playerHintsTimeout[sessionId]);
            }
        }
        """
        
        do {
            let captures = try SyntaxManager.shared.codeMap(content: content, fileExtension: "ts")
            
            // Debug print all captures
            print("=== TypeScript CodeMap Captures ===")
            for capture in captures {
                let captureText = (content as NSString).substring(with: capture.range)
                print("\(capture.name): '\(captureText)'")
            }
            print("=== End Captures ===")
            
            // Check for class
            let classCaptures = captures.filter { $0.name == "class" || $0.name == "type.class" }
            XCTAssertEqual(classCaptures.count, 1, "Should capture one class")
            if let classCapture = classCaptures.first {
                let className = (content as NSString).substring(with: classCapture.range)
                XCTAssertEqual(className, "BaseRoom")
            }
            
            // Check for methods
            let methodCaptures = captures.filter { $0.name == "method" || $0.name == "function.definition" }
            XCTAssertGreaterThan(methodCaptures.count, 0, "Should capture methods")
            
            // Check for fields
            let fieldCaptures = captures.filter { $0.name == "variable.field" || $0.name == "variable.global" }
            XCTAssertGreaterThan(fieldCaptures.count, 0, "Should capture fields")
            
        } catch {
            XCTFail("Failed to parse TypeScript: \(error)")
        }
    }
    
    func testTypeScriptHeavyweightParsing() throws {
        // Note: debugLogging is a let constant, so we can't disable it here
        
        let content = """
        export class TestClass {
            private name: string;
            public age: number;
            
            constructor(name: string, age: number) {
                this.name = name;
                this.age = age;
            }
            
            getName(): string {
                return this.name;
            }
            
            setAge(age: number): void {
                this.age = age;
            }
        }
        
        const arrowFunc = (x: number): number => x * 2;
        let normalVar: string = "hello";
        """
        
        let captures = try SyntaxManager.shared.codeMap(content: content, fileExtension: "ts")
        
        // Debug: Print all captures to understand what's being detected
        print("\n--- Raw Captures Debug ---")
        for (index, capture) in captures.enumerated() {
            let captureText = (content as NSString).substring(with: capture.range)
            print("\(index): \(capture.name) -> '\(captureText)'")
        }
        print("--- End Raw Captures ---\n")
        
        let api = CodeMapGenerator.generateCodeMap(
            from: captures,
            content: content,
            fullPath: "/tmp/test.ts"
        )
        
        XCTAssertNotNil(api)
        guard let api = api else { return }
        
        print("\n--- TypeScript Heavyweight Parsing Output ---")
        print(api.getFullAPIDescription())
        
        // Debug: Print all API components
        print("\n--- API Components Debug ---")
        print("Classes: \(api.classes.count)")
        for cls in api.classes {
            print("  - \(cls.name) (methods: \(cls.methods.count), properties: \(cls.properties.count))")
        }
        print("Functions: \(api.functions.count)")
        for function in api.functions {
            print("  - \(function.name)")
        }
        print("Global Variables: \(api.globalVars.count)")
        for globalVar in api.globalVars {
            print("  - \(globalVar.name)")
        }
        print("Interfaces: \(api.interfaces.count)")
        print("Type Aliases: \(api.aliases.count)")
        print("Enums: \(api.enums.count)")
        print("--- End API Components ---\n")
        
            // We expect a single class: TestClass (no synthetic main class for TS)
            XCTAssertEqual(api.classes.count, 1)
        
        // Find the real TestClass
        let testClass = api.classes.first { $0.name == "TestClass" }
        XCTAssertNotNil(testClass)
        
        // Check TestClass methods
        if let testClass = testClass {
            let methods = testClass.methods
            print("\nTestClass Methods found: \(methods.map { $0.name })")
            XCTAssertEqual(methods.count, 3) // constructor, getName, setAge
            XCTAssertTrue(methods.contains { $0.name == "constructor" })
            XCTAssertTrue(methods.contains { $0.name == "getName" })
            XCTAssertTrue(methods.contains { $0.name == "setAge" })
            
            // Check TestClass properties
            let properties = testClass.properties
            print("TestClass Properties found: \(properties.map { $0.name })")
            XCTAssertEqual(properties.count, 2) // name, age
            XCTAssertTrue(properties.contains { $0.name.contains("name") })
            XCTAssertTrue(properties.contains { $0.name.contains("age") })
        }

        // Verify globals keep top-level items for TS/TSX
		print("\nGlobal functions: \(api.functions.map { $0.name })")
		print("Global variables: \(api.globalVars.map { $0.name })")
		XCTAssertEqual(api.functions.count, 1)
		XCTAssertEqual(api.globalVars.count, 1)
		XCTAssertTrue(api.functions.contains { $0.name == "arrowFunc" })
		XCTAssertTrue(api.globalVars.contains { $0.name.contains("normalVar") })
		if let arrowFunc = api.functions.first(where: { $0.name == "arrowFunc" }) {
			XCTAssertEqual(arrowFunc.returnType, "number")
			XCTAssertFalse(arrowFunc.returnType?.contains("=>") ?? false)
		}
	}
    
    func testTypeScriptImportsAndExports() {
        let content = """
        import { Room, Client } from "@colyseus/core";
        import { MoveableObject, BaseRoomState } from "./schema/BaseRoomState";
        
        export * from './helpers';
        export { Foo, Bar as B } from './utils';
        
        export interface GameState {
            players: Player[];
            started: boolean;
        }
        
        export type Direction = "up" | "down" | "left" | "right";
        
        export enum GameStatus {
            WAITING,
            PLAYING,
            FINISHED
        }
        
        export function calculateScore(points: number): number {
            return points * 100;
        }
        
        export const MAX_PLAYERS = 5;
        """
        
        do {
            let captures = try SyntaxManager.shared.codeMap(content: content, fileExtension: "ts")
            
            // Debug print
            print("\n=== Import/Export Test Captures ===")
            for capture in captures {
                let captureText = (content as NSString).substring(with: capture.range)
                print("\(capture.name): '\(captureText)'")
            }
            
            // Check imports
            let importCaptures = captures.filter { $0.name == "import" }
            XCTAssertEqual(importCaptures.count, 2, "Should capture two imports")
            
            // Check re-exports (export ... from ...)
            let reexportCaptures = captures.filter { $0.name == "export.source" }
            XCTAssertEqual(reexportCaptures.count, 2, "Should capture two re-exports")
            
            // Check interface
            let interfaceCaptures = captures.filter { $0.name == "interface" }
            XCTAssertEqual(interfaceCaptures.count, 1, "Should capture one interface")
            
            // Check type alias
            let typeAliasCaptures = captures.filter { $0.name == "typeAlias" }
            XCTAssertEqual(typeAliasCaptures.count, 1, "Should capture one type alias")
            
            // Check enum
            let enumCaptures = captures.filter { $0.name == "type.enum" }
            XCTAssertEqual(enumCaptures.count, 1, "Should capture one enum")
            
            // Check function
            let functionCaptures = captures.filter { $0.name == "function" || $0.name == "function.definition" }
            XCTAssertGreaterThan(functionCaptures.count, 0, "Should capture function")
            
            // Check global variable
            let globalVarCaptures = captures.filter { $0.name == "variable.global" }
            XCTAssertGreaterThan(globalVarCaptures.count, 0, "Should capture global variable")
            
        } catch {
            XCTFail("Failed to parse TypeScript: \(error)")
        }
    }
    
    func testTypeScriptCodeMapGeneration() {
        let content = """
        import { Room } from "@colyseus/core";
        
        export class GameRoom extends Room {
            maxPlayers = 4;
            private gameStarted = false;
            
            onCreate(options: any) {
                console.log("Room created");
            }
            
            onJoin(client: any) {
                console.log("Player joined");
            }
            
            private startGame() {
                this.gameStarted = true;
            }
        }
        """
        
        let tempFile = "/tmp/test_game_room.ts"
        
        do {
            // First get the named ranges
            let namedRanges = try SyntaxManager.shared.codeMap(content: content, fileExtension: "ts")
            
            // Generate FileAPI using CodeMapGenerator
            let fileAPI = CodeMapGenerator.generateCodeMap(
                from: namedRanges,
                content: content,
                fullPath: tempFile
            )
            
            XCTAssertNotNil(fileAPI, "Should generate FileAPI")
            
            if let api = fileAPI {
                print("\n=== Generated FileAPI ===")
                print("Imports: \(api.imports)")
                print("Exports: \(api.exports)")
                print("Classes: \(api.classes.map { $0.name })")
                print("Functions: \(api.functions.map { $0.name })")
                print("Interfaces: \(api.interfaces.map { $0.name })")
                print("Type Aliases: \(api.aliases.map { $0.name })")
                print("Enums: \(api.enums.map { $0.name })")
                print("Global Vars: \(api.globalVars.map { $0.name })")
                
                // Verify the API
                XCTAssertEqual(api.imports.count, 1)
                XCTAssertEqual(api.classes.count, 1)
                
                if let gameRoom = api.classes.first {
                    XCTAssertEqual(gameRoom.name, "GameRoom")
                    XCTAssertGreaterThan(gameRoom.methods.count, 0, "Should have methods")
                    XCTAssertGreaterThan(gameRoom.properties.count, 0, "Should have properties")
                }
            }
            
        } catch {
            XCTFail("Failed to generate code map: \(error)")
        }
    }
    
    func testMinimalTypeScriptMethod() {
        let content = """
        class Test {
            myMethod() {
                console.log("test");
            }
        }
        """
        
        do {
            let captures = try SyntaxManager.shared.codeMap(content: content, fileExtension: "ts")
            
            print("\n=== Minimal Test - Captures ===")
            print("Total: \(captures.count)")
            for capture in captures {
                let text = (content as NSString).substring(with: capture.range)
                print("  \(capture.name): '\(text)'")
            }
            
            // Check specific captures
            let methodCaptures = captures.filter { $0.name == "method" || $0.name == "function.definition" }
            XCTAssertGreaterThan(methodCaptures.count, 0, "Should capture at least one method, but got \(methodCaptures.count)")
            
        } catch {
            XCTFail("Failed to parse TypeScript: \(error)")
        }
    }
    
    func testActualBaseRoomFile() {
        // Test with actual BaseRoom content to debug the issue
        let content = """
        export class BaseRoom {
            CHANNEL = "$mylobby";
            maxClients = 5;
            protected _nextIndex = 1;
            protected _host: Player;
            
            protected showHint(playerId: string) {
                const task = this._progress.getTaskNeverDoneByPlayer(playerId);
                if (task && this.clients.getById(playerId)) {
                    this._analytics.recordEvent(playerId, "SHOW_HINT", task);
                }
            }
            
            async onCreate(options: any) {
                this.roomId = await this.generateRoomId();
                console.log("Room on create");
            }
            
            onJoin(client: Client, options: any) {
                console.log(client.sessionId, "joined!");
            }
        }
        """
        
        do {
            let captures = try SyntaxManager.shared.codeMap(content: content, fileExtension: "ts")
            
            print("\n=== BaseRoom Test - Raw Captures ===")
            print("Total captures: \(captures.count)")
            
            // Group by type
            var capturesByType: [String: [String]] = [:]
            for capture in captures {
                let text = (content as NSString).substring(with: capture.range)
                if capturesByType[capture.name] == nil {
                    capturesByType[capture.name] = []
                }
                capturesByType[capture.name]?.append(text)
            }
            
            // Print grouped
            for (type, texts) in capturesByType.sorted(by: { $0.key < $1.key }) {
                print("\n\(type) (\(texts.count)):")
                for text in texts {
                    print("  - \(text)")
                }
            }
            
            // Generate FileAPI
            let fileAPI = CodeMapGenerator.generateCodeMap(
                from: captures,
                content: content,
                fullPath: "/tmp/BaseRoom.ts"
            )
            
            print("\n=== BaseRoom Test - FileAPI Result ===")
            if let api = fileAPI {
                print(api.apiDescription)
                
                XCTAssertEqual(api.classes.count, 1, "Should have one class")
                
                if let baseRoom = api.classes.first {
                    XCTAssertEqual(baseRoom.name, "BaseRoom")
                    print("\nClass '\(baseRoom.name)':")
                    print("  Methods (\(baseRoom.methods.count)): \(baseRoom.methods.map { $0.name })")
                    print("  Properties (\(baseRoom.properties.count)): \(baseRoom.properties.map { $0.name })")
                    
                    // More strict assertions
                    XCTAssertTrue(baseRoom.methods.count > 0, "BaseRoom should have methods but has \(baseRoom.methods.count)")
                    XCTAssertTrue(baseRoom.properties.count > 0, "BaseRoom should have properties but has \(baseRoom.properties.count)")
                }
            } else {
                XCTFail("Failed to generate FileAPI")
            }
            
        } catch {
            XCTFail("Failed to parse TypeScript: \(error)")
        }
    }
}
