import XCTest
@testable import RepoPrompt

final class MCPServiceNameTests: XCTestCase {
    func testEncodeDebugAddsDebugTag() {
        let name = MCPServiceName(deviceID: "dev", buildFlavor: .debug, protocolTag: "-MCP2")
        XCTAssertEqual(name.encoded(), "dev-DEBUG-MCP2")
    }

    func testEncodeReleaseOmitsDebugTag() {
        let name = MCPServiceName(deviceID: "dev", buildFlavor: .release, protocolTag: "-MCP2")
        XCTAssertEqual(name.encoded(), "dev-MCP2")
    }

    func testParseRoundTripsDebugName() {
        let encoded = MCPServiceName(deviceID: "abc", buildFlavor: .debug, protocolTag: "-MCP2").encoded()
        let parsed = MCPServiceName.parse(encoded)
        XCTAssertEqual(parsed?.deviceID, "abc")
        XCTAssertEqual(parsed?.buildFlavor, .debug)
        XCTAssertEqual(parsed?.protocolTag, "-MCP2")
    }

    func testParseKeepsAlternateProtocolTag() {
        let parsed = MCPServiceName.parse("dev-DEBUG-MCPX")
        XCTAssertEqual(parsed?.protocolTag, "-MCPX")
        XCTAssertEqual(parsed?.buildFlavor, .debug)
        XCTAssertEqual(parsed?.deviceID, "dev")
    }

    func testParseRejectsMissingProtocolMarker() {
        XCTAssertNil(MCPServiceName.parse("dev-DEBUG"))
        XCTAssertNil(MCPServiceName.parse("dev"))
    }
}
