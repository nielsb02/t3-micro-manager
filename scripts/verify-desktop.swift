import Foundation
import Darwin
@testable import WLKit

@main struct VerifyDesktop {
    @MainActor static func main() async throws {
        let root = CommandLine.arguments[1]
        let legacy = try JSONDecoder().decode(T3ConnectionSettings.self, from: Data("{\"baseURL\":\"http://localhost:3773\",\"bearerToken\":\"saved-token\",\"environmentID\":\"env\"}".utf8))
        precondition(legacy.openTarget == .browser && legacy.bearerToken == "saved-token" && legacy.desktopApplicationPath.isEmpty)
        var settings = T3ConnectionSettings()
        precondition(settings.openTarget == .desktop)
        settings.desktopSocketPath = root + "/ok.sock"
        settings.desktopApplicationPath = "/Applications/Chosen T3.app"
        let roundtrip = try JSONDecoder().decode(T3ConnectionSettings.self, from: JSONEncoder().encode(settings))
        precondition(roundtrip == settings)
        settings.desktopApplicationPath = ""

        for path in ["relative.app", root + "/missing.app", "/System/Applications/Calculator.app"] {
            do {
                _ = try T3DesktopClient.applicationURL(path: path)
                fatalError("Accepted an invalid T3 app: \(path)")
            } catch T3DesktopError.invalidApplication { }
        }
        let app = URL(fileURLWithPath: root + "/Fixture.app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "com.t3tools.t3code.fixture." + UUID().uuidString,
                    "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL", "FixtureSocket": root + "/launch.sock"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        try FileManager.default.copyItem(atPath: CommandLine.arguments[2], toPath: app.appendingPathComponent("Contents/MacOS/Fixture").path)
        let alias = root + "/Chosen.app"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: app.path)
        let resolved = try T3DesktopClient.applicationURL(path: alias)
        precondition(resolved == app.resolvingSymlinksInPath())
        let resources = app.appendingPathComponent("Contents/Resources")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: resources.appendingPathComponent("fixture.txt"))
        try sign(app)
        let translocated = URL(fileURLWithPath: root)
            .appendingPathComponent("AppTranslocation/\(UUID().uuidString)/d/Fixture.app")
        try FileManager.default.createDirectory(at: translocated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: translocated)
        let matchingCopy = await T3DesktopClient.matchesApplication(translocated, selected: app)
        precondition(matchingCopy, "Rejected the same signed app relocated by Gatekeeper")
        let ordinaryCopy = URL(fileURLWithPath: root + "/Other.app")
        try FileManager.default.copyItem(at: app, to: ordinaryCopy)
        let differentInstall = await T3DesktopClient.matchesApplication(ordinaryCopy, selected: app)
        precondition(!differentInstall, "Accepted a different installation outside App Translocation")
        try Data("modified".utf8).write(to: translocated.appendingPathComponent("Contents/Resources/fixture.txt"))
        let tamperedCopy = await T3DesktopClient.matchesApplication(translocated, selected: app)
        precondition(!tamperedCopy, "Accepted a damaged signature")
        try sign(translocated)
        let differentBuild = await T3DesktopClient.matchesApplication(translocated, selected: app)
        precondition(!differentBuild, "Accepted another signed build with the same bundle ID")
        print("PASS: Gatekeeper relocation accepts only the same verified build; different installations, tampering and other builds are rejected")
        let automatic = try await T3DesktopClient.prepareApplication(path: "")
        precondition(automatic.processID == nil && !automatic.launched)

        let expected = try String(contentsOfFile: root + "/expected-path", encoding: .utf8)
        precondition(T3DesktopClient.socketPath(stateDirectory: "/Users/test/.t3/userdata", temporaryDirectory: "/tmp", userID: 501) == expected)
        let session = AgentSession(id: "thread/with space 雪", title: "Duplicate title", status: .done, environmentID: "target-environment")
        try await T3DesktopClient.openThread(session, settings: settings)
        print("PASS: desktop settings migration, socket discovery and fragmented response over a real socket")

        let serverPID = pid_t(try String(contentsOfFile: root + "/server-pid", encoding: .utf8))!
        let request = T3DesktopClient.Request(requestId: UUID().uuidString, environmentId: session.environmentID!, threadId: session.id)
        let payload = try JSONEncoder().encode(request) + Data([10])
        let reply = try T3DesktopClient.exchange(path: root + "/peer.sock", payload: payload, expectedProcessID: serverPID)
        try T3DesktopClient.validateResponse(reply, request: request)
        do {
            _ = try T3DesktopClient.exchange(path: root + "/wrong-peer.sock", payload: payload, expectedProcessID: getpid())
            fatalError("Sent a request to the wrong desktop app")
        } catch T3DesktopError.wrongInstance { }
        try Data().write(to: URL(fileURLWithPath: root + "/start-delayed"))
        let delayed = try T3DesktopClient.exchange(path: root + "/delayed.sock", payload: payload,
                                                   expectedProcessID: serverPID, waitForStart: true)
        try T3DesktopClient.validateResponse(delayed, request: request)
        do {
            _ = try T3DesktopClient.exchange(path: root + "/never-starts.sock", payload: payload, timeout: 0.05, waitForStart: true)
            fatalError("Waited forever for a desktop app that never started")
        } catch T3DesktopError.timeout { }
        print("PASS: optional app selection, symlink resolution, socket owner verification and bounded startup wait")

        for action in T3MicroAction.allCases {
            let request = T3DesktopClient.MicroRequest(requestId: UUID().uuidString, action: action)
            let reply = try T3DesktopClient.exchange(path: root + "/\(action.rawValue).sock",
                                                    payload: JSONEncoder().encode(request) + Data([10]),
                                                    expectedProcessID: serverPID)
            try T3DesktopClient.validateResponse(reply, request: request)
        }
        print("PASS: every dial and assignable-button action round-trips over owner-verified sockets")

        for fixture in ["id", "env", "thread", "old", "reject", "closed", "large"] {
            settings.desktopSocketPath = root + "/\(fixture).sock"
            do {
                try await T3DesktopClient.openThread(session, settings: settings)
                fatalError("Accepted invalid desktop response: \(fixture)")
            } catch is T3DesktopError { }
        }
        do {
            _ = try T3DesktopClient.exchange(path: root + "/wait.sock", payload: Data("{}\n".utf8), timeout: 0.05)
            fatalError("Did not time out")
        } catch T3DesktopError.timeout { }
        for path in ["relative.sock", "/" + String(repeating: "x", count: 104)] {
            do {
                _ = try T3DesktopClient.exchange(path: path, payload: Data())
                fatalError("Accepted invalid path")
            } catch T3DesktopError.invalidPath { }
        }
        do {
            _ = try T3DesktopClient.exchange(path: root + "/missing.sock", payload: Data("{}\n".utf8))
            fatalError("Accepted missing desktop")
        } catch T3DesktopError.unavailable { }
        print("PASS: wrong session/environment/request, legacy replies, rejection, closed/oversized replies, timeout and unavailable desktop")

        settings.desktopSocketPath = root + "/launch.sock"
        settings.desktopApplicationPath = alias
        try await T3DesktopClient.openThread(session, settings: settings)
        print("PASS: launched a selected app through NSWorkspace, waited for its socket, verified the owning process and opened the exact session")
    }

    private static func sign(_ app: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", app.path]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Could not sign the disposable fixture")
    }
}
