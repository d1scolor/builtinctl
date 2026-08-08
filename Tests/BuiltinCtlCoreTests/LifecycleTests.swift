import Foundation
import XCTest
@testable import BuiltinCtlCore

final class LifecycleTests: XCTestCase {
    func testSingletonLockRejectsSecondOwner() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtinctl-lock-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("test.lock")

        let first = try ProcessLock(url: url, purpose: "test")
        XCTAssertThrowsError(try ProcessLock(url: url, purpose: "test"))
        withExtendedLifetime(first) {}
    }

    func testAgentRestartsOnlyAfterUnsuccessfulExit() throws {
        let plist = AgentManager.propertyList()
        XCTAssertEqual(plist["RunAtLoad"] as? Bool, true)
        XCTAssertEqual(plist["ThrottleInterval"] as? Int, 10)
        let keepAlive = try XCTUnwrap(plist["KeepAlive"] as? [String: Bool])
        XCTAssertEqual(keepAlive["SuccessfulExit"], false)
    }

    func testAgentStartsSuspendedAutoCommandFromStablePath() throws {
        let plist = AgentManager.propertyList()
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.last, "auto")
        XCTAssertEqual(arguments.first, AgentManager.installedExecutable.path)
    }

    func testAgentPropertyListSerializesAsXML() throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: AgentManager.propertyList(),
            format: .xml,
            options: 0
        )
        var format = PropertyListSerialization.PropertyListFormat.xml
        let decoded = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any]
        XCTAssertEqual(format, .xml)
        XCTAssertEqual(decoded?["Label"] as? String, AgentManager.label)
    }
}
