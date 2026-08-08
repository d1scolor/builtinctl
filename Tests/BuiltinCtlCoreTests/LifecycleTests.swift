import Foundation
import XCTest
@testable import BuiltinCtlCore

final class LifecycleTests: XCTestCase {
    private let currentSession = SystemSessionIdentity(
        bootTimeSeconds: 1_000,
        bootTimeMicroseconds: 42,
        auditSessionID: 50_001
    )

    private func markerData(_ identity: SystemSessionIdentity?) throws -> Data {
        try JSONEncoder().encode(DisabledStateMarker(identity: identity))
    }

    private func crashSuspensionData(_ identity: SystemSessionIdentity?) throws -> Data {
        try JSONEncoder().encode(CrashSuspensionMarker(identity: identity))
    }

    func testDisabledMarkerFromSameSessionRequiresConservativeRecovery() throws {
        XCTAssertEqual(
            disabledStateOrigin(
                markerData: try markerData(currentSession),
                currentIdentity: currentSession
            ),
            .sameSession
        )
    }

    func testDisabledMarkerFromDifferentBootIsPriorSession() throws {
        let priorBoot = SystemSessionIdentity(
            bootTimeSeconds: currentSession.bootTimeSeconds - 500,
            bootTimeMicroseconds: currentSession.bootTimeMicroseconds,
            auditSessionID: currentSession.auditSessionID
        )

        XCTAssertEqual(
            disabledStateOrigin(
                markerData: try markerData(priorBoot),
                currentIdentity: currentSession
            ),
            .priorSession
        )
    }

    func testDisabledMarkerFromDifferentLoginIsPriorSession() throws {
        let priorLogin = SystemSessionIdentity(
            bootTimeSeconds: currentSession.bootTimeSeconds,
            bootTimeMicroseconds: currentSession.bootTimeMicroseconds,
            auditSessionID: currentSession.auditSessionID - 1
        )

        XCTAssertEqual(
            disabledStateOrigin(
                markerData: try markerData(priorLogin),
                currentIdentity: currentSession
            ),
            .priorSession
        )
    }

    func testLegacyCorruptAndUnavailableIdentityMarkersAreUnknown() throws {
        XCTAssertEqual(
            disabledStateOrigin(
                markerData: Data("disabled\n".utf8),
                currentIdentity: currentSession
            ),
            .unknown
        )
        XCTAssertEqual(
            disabledStateOrigin(
                markerData: try markerData(nil),
                currentIdentity: currentSession
            ),
            .unknown
        )
        XCTAssertEqual(
            disabledStateOrigin(
                markerData: try markerData(currentSession),
                currentIdentity: nil
            ),
            .unknown
        )
    }

    func testCrashSuspensionCanBeClearedOnlyInANewSession() throws {
        let priorSession = SystemSessionIdentity(
            bootTimeSeconds: currentSession.bootTimeSeconds,
            bootTimeMicroseconds: currentSession.bootTimeMicroseconds,
            auditSessionID: currentSession.auditSessionID - 1
        )

        XCTAssertEqual(
            crashSuspensionOrigin(
                markerData: try crashSuspensionData(currentSession),
                currentIdentity: currentSession
            ),
            .sameSession
        )
        XCTAssertEqual(
            crashSuspensionOrigin(
                markerData: try crashSuspensionData(priorSession),
                currentIdentity: currentSession
            ),
            .priorSession
        )
    }

    func testUserAndLegacyCrashSuspensionsRemainConservative() {
        XCTAssertNil(
            crashSuspensionOrigin(
                markerData: Data("user\n".utf8),
                currentIdentity: currentSession
            )
        )
        XCTAssertEqual(
            crashSuspensionOrigin(
                markerData: Data("unclean-exit\n".utf8),
                currentIdentity: currentSession
            ),
            .unknown
        )
    }

    func testRearmRequestMustBeNewerThanTheDaemon() {
        let startedAt = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(
            BuiltinCtlPaths.rearmRequestIsCurrent("1001\n", startedAt: startedAt)
        )
        XCTAssertFalse(
            BuiltinCtlPaths.rearmRequestIsCurrent("999\n", startedAt: startedAt)
        )
        XCTAssertFalse(
            BuiltinCtlPaths.rearmRequestIsCurrent("invalid\n", startedAt: startedAt)
        )
    }

    func testCurrentExecutableLocatorReturnsAnAbsoluteExecutablePath() {
        let executable = ExecutableLocator.current()

        XCTAssertTrue(executable.path.hasPrefix("/"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: executable.path))
    }

    func testExecutableLocatorPrefersThePathReportedByMacOS() {
        let resolved = ExecutableLocator.resolve(
            reportedExecutablePath: "/opt/homebrew/Cellar/builtinctl/0.1.2/bin/builtinctl",
            argument0: "builtinctl",
            currentDirectoryPath: "/Users/example",
            environmentPath: "/opt/homebrew/bin:/usr/bin"
        )

        XCTAssertEqual(
            resolved.path,
            "/opt/homebrew/Cellar/builtinctl/0.1.2/bin/builtinctl"
        )
    }

    func testExecutableLocatorFindsBareCommandNameOnPathAsFallback() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("builtinctl-executable-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let executable = bin.appendingPathComponent("builtinctl")
        defer { try? manager.removeItem(at: root) }

        try manager.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: executable)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let resolved = ExecutableLocator.resolve(
            reportedExecutablePath: nil,
            argument0: "builtinctl",
            currentDirectoryPath: root.path,
            environmentPath: "/usr/bin:\(bin.path)"
        )

        XCTAssertEqual(resolved.path, executable.path)
    }

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

    func testAgentStartsPersistentLauncherFromStablePath() throws {
        let plist = AgentManager.propertyList()
        let arguments = try XCTUnwrap(plist["ProgramArguments"] as? [String])
        XCTAssertEqual(arguments.last, "_launch-auto")
        XCTAssertEqual(arguments.first, AgentManager.installedExecutable.path)
    }

    func testDerivesStableHomebrewOptExecutable() {
        let source = URL(
            fileURLWithPath: "/opt/homebrew/Cellar/builtinctl/0.1.4/bin/builtinctl"
        )

        XCTAssertEqual(
            AgentManager.stableHomebrewExecutable(for: source)?.path,
            "/opt/homebrew/opt/builtinctl/bin/builtinctl"
        )
        XCTAssertEqual(AgentManager.homebrewVersionIdentifier(for: source), "0.1.4")
        XCTAssertNil(
            AgentManager.stableHomebrewExecutable(
                for: URL(fileURLWithPath: "/tmp/builtinctl")
            )
        )
    }

    func testPreparesPersistentVersionedRuntimeCopy() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("builtinctl-runtime-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("Cellar/builtinctl/0.1.4/bin/builtinctl")
        let fallback = root.appendingPathComponent("fallback/builtinctl")
        let sourceRecord = root.appendingPathComponent("update-source")
        let versions = root.appendingPathComponent("versions", isDirectory: true)
        defer { try? manager.removeItem(at: root) }

        for executable in [source, fallback] {
            try manager.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(executable == source ? "new".utf8 : "fallback".utf8).write(to: executable)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        }
        try Data("\(source.path)\n".utf8).write(to: sourceRecord)

        let prepared = try AgentManager.prepareAutomaticExecutable(
            fileManager: manager,
            fallback: fallback,
            sourceRecordURL: sourceRecord,
            versionsDirectory: versions
        )

        XCTAssertEqual(prepared.path, versions.appendingPathComponent("0.1.4/builtinctl").path)
        XCTAssertEqual(try Data(contentsOf: prepared), Data("new".utf8))
        XCTAssertTrue(manager.isExecutableFile(atPath: prepared.path))
    }

    func testAutomaticExecutableFallsBackWithoutAnUpdateSource() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtinctl-fallback-\(UUID().uuidString)", isDirectory: true)
        let fallback = root.appendingPathComponent("builtinctl")
        defer { try? FileManager.default.removeItem(at: root) }

        let selected = try AgentManager.prepareAutomaticExecutable(
            fallback: fallback,
            sourceRecordURL: root.appendingPathComponent("missing-update-source"),
            versionsDirectory: root.appendingPathComponent("versions")
        )

        XCTAssertEqual(selected, fallback)
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

    func testPurgeRemovesManagedDirectoriesAndLeavesUnrelatedFiles() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("builtinctl-purge-\(UUID().uuidString)", isDirectory: true)
        let applicationDirectory = root.appendingPathComponent("application", isDirectory: true)
        let logsDirectory = root.appendingPathComponent("logs", isDirectory: true)
        let configDirectory = root.appendingPathComponent("config", isDirectory: true)
        let unrelated = root.appendingPathComponent("keep.txt")
        defer { try? manager.removeItem(at: root) }

        for directory in [applicationDirectory, logsDirectory, configDirectory] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("managed".utf8).write(to: directory.appendingPathComponent("file"))
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelated)

        try AgentManager.removeResidualData(
            fileManager: manager,
            applicationDirectory: applicationDirectory,
            logsDirectory: logsDirectory,
            configDirectory: configDirectory
        )

        XCTAssertFalse(manager.fileExists(atPath: applicationDirectory.path))
        XCTAssertFalse(manager.fileExists(atPath: logsDirectory.path))
        XCTAssertFalse(manager.fileExists(atPath: configDirectory.path))
        XCTAssertTrue(manager.fileExists(atPath: unrelated.path))
    }

    func testPurgeCleanupIsIdempotentWhenDirectoriesAreAbsent() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("builtinctl-purge-absent-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertNoThrow(
            try AgentManager.removeResidualData(
                applicationDirectory: root.appendingPathComponent("application"),
                logsDirectory: root.appendingPathComponent("logs"),
                configDirectory: root.appendingPathComponent("config")
            )
        )
    }

    func testLaunchctlMissingServiceDetectionIsConservative() {
        XCTAssertTrue(
            AgentManager.serviceIsMissing(
                status: 113,
                output: "Could not find service \"io.github.builtinctl.auto\" in domain for user gui: 501"
            )
        )
        XCTAssertFalse(
            AgentManager.serviceIsMissing(status: 1, output: "Operation not permitted")
        )
        XCTAssertFalse(
            AgentManager.serviceIsMissing(status: 0, output: "")
        )
    }
}
