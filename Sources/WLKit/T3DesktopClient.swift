import Foundation
import CryptoKit
import Darwin
import AppKit
import Security

public enum T3DesktopError: LocalizedError {
    case unavailable, invalidPath, timeout, invalidResponse, rejected(String)
    case invalidApplication, differentApplicationRunning(String), wrongInstance, notFrontmost
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Cannot reach T3 desktop. Choose your T3 app in Connection, or start the build with desktop navigation support. Check Desktop socket in Advanced connection settings if you use a custom T3 home."
        case .invalidPath: return "The T3 desktop socket must be an absolute path shorter than 104 bytes."
        case .timeout: return "T3 desktop did not confirm the request in time."
        case .invalidResponse: return "T3 desktop did not confirm the requested session or control action."
        case .rejected(let message): return "T3 desktop: \(message)"
        case .invalidApplication: return "Choose an installed T3 Code .app. The selected path is missing or is not a T3 desktop application."
        case .differentApplicationRunning(let path): return "A different T3 copy is running at \(path). Quit that copy and retry to use the selected desktop app."
        case .wrongInstance: return "The desktop socket belongs to a different app or T3 instance. Check your selected Desktop app and the Desktop socket in Advanced connection settings."
        case .notFrontmost: return "The selected T3 desktop must be frontmost to use these controls."
        }
    }
}

/// T3's desktop control protocol is one newline-delimited JSON request per local socket connection.
public enum T3DesktopClient {
    struct Request: Encodable, Sendable {
        let version = 1
        let requestId: String
        let type = "open-thread"
        let environmentId: String
        let threadId: String
    }
    struct MicroRequest: Encodable, Sendable {
        let version = 1
        let requestId: String
        let type = "micro-control"
        let action: T3MicroAction
    }
    private struct Response: Decodable {
        let version: Int
        let requestId: String
        let ok: Bool
        let environmentId: String?
        let threadId: String?
        let message: String?
        let action: T3MicroAction?
    }

    public static func defaultSocketPath() -> String {
        let home = ProcessInfo.processInfo.environment["T3CODE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = home.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.t3"
        return socketPath(stateDirectory: base + "/userdata", temporaryDirectory: NSTemporaryDirectory(), userID: getuid())
    }

    static func socketPath(stateDirectory: String, temporaryDirectory: String, userID: uid_t) -> String {
        let state = URL(fileURLWithPath: stateDirectory).standardizedFileURL.path
        let hash = SHA256.hash(data: Data(state.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: temporaryDirectory).appendingPathComponent("t3code-\(userID)/\(hash).sock").path
    }

    public static func applicationURL(path: String) throws -> URL {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { throw T3DesktopError.invalidApplication }
        let url = URL(fileURLWithPath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier,
              identifier == "com.t3tools.t3code" || identifier.hasPrefix("com.t3tools.t3code."),
              let executable = bundle.executableURL,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw T3DesktopError.invalidApplication }
        return url
    }

    static func matchesApplication(_ runningURL: URL?, selected: URL) async -> Bool {
        guard let running = runningURL?.resolvingSymlinksInPath().standardizedFileURL else { return false }
        let selected = selected.resolvingSymlinksInPath().standardizedFileURL
        if running.path == selected.path { return true }

        // Gatekeeper can run the selected app from a randomized read-only copy.
        // Only that relocation may match by its exact signed build instead of path.
        let components = running.pathComponents
        guard let index = components.firstIndex(of: "AppTranslocation"),
              components.count == index + 4,
              UUID(uuidString: components[index + 1]) != nil,
              components[index + 2] == "d" else { return false }
        return await Task.detached {
            if let original = translocationOrigin(of: running), original.path != running.path {
                return original.path == selected.path
            }
            guard let selectedIdentity = validatedCodeIdentity(at: selected),
                  let runningIdentity = validatedCodeIdentity(at: running) else { return false }
            return selectedIdentity == runningIdentity
        }.value
    }

    private static func translocationOrigin(of url: URL) -> URL? {
        // This Security SPI resolves the real mount origin without changing Gatekeeper.
        // Load it optionally; exact signature validation remains the fallback.
        guard let library = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_LOCAL) else { return nil }
        defer { dlclose(library) }
        guard let symbol = dlsym(library, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        typealias Resolve = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        let resolve = unsafeBitCast(symbol, to: Resolve.self)
        guard let original = resolve(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return (original as URL).resolvingSymlinksInPath().standardizedFileURL
    }

    private static func validatedCodeIdentity(at url: URL) -> Data? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil) == errSecSuccess
        else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(), &information) == errSecSuccess,
              let values = information as? [String: Any] else { return nil }
        return values[kSecCodeInfoUnique as String] as? Data
    }

    @MainActor static func prepareApplication(path: String) async throws -> (processID: pid_t?, launched: Bool) {
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return (nil, false) }
        let selected = try applicationURL(path: path)
        guard let identifier = Bundle(url: selected)?.bundleIdentifier else { throw T3DesktopError.invalidApplication }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { !$0.isTerminated }
        for application in running {
            if await matchesApplication(application.bundleURL, selected: selected), !application.isTerminated {
                return (application.processIdentifier, false)
            }
        }
        if let other = running.first {
            throw T3DesktopError.differentApplicationRunning(other.bundleURL?.path ?? identifier)
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = false
        let application: (processID: pid_t, url: URL?) = try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.openApplication(at: selected, configuration: configuration) { application, error in
                if let error { continuation.resume(throwing: error) }
                else if let application { continuation.resume(returning: (application.processIdentifier, application.bundleURL)) }
                else { continuation.resume(throwing: T3DesktopError.invalidApplication) }
            }
        }
        guard await matchesApplication(application.url, selected: selected) else {
            throw T3DesktopError.differentApplicationRunning(application.url?.path ?? identifier)
        }
        return (application.processID, true)
    }

    public static func openThread(_ session: AgentSession, settings: T3ConnectionSettings) async throws {
        let environmentID = session.environmentID ?? settings.environmentID
        guard !environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !session.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw T3Error.missingEnvironment }
        let request = Request(requestId: UUID().uuidString, environmentId: environmentID, threadId: session.id)
        let override = settings.desktopSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = override.isEmpty ? defaultSocketPath() : override
        let application = try await prepareApplication(path: settings.desktopApplicationPath)
        try await Task.detached {
            let data = try exchange(path: path, payload: JSONEncoder().encode(request) + Data([10]),
                                    expectedProcessID: application.processID, waitForStart: application.launched)
            try validateResponse(data, request: request)
        }.value
    }

    @MainActor static var frontmostT3ProcessID: pid_t? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let identifier = application.bundleIdentifier,
              identifier == "com.t3tools.t3code" || identifier.hasPrefix("com.t3tools.t3code."),
              !application.isTerminated else { return nil }
        return application.processIdentifier
    }

    @MainActor public static func sendMicroControl(_ action: T3MicroAction, settings: T3ConnectionSettings,
                                                  expectedFrontmostProcessID: pid_t? = nil) async throws {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let processID = frontmostT3ProcessID,
              expectedFrontmostProcessID == nil || expectedFrontmostProcessID == processID else {
            throw T3DesktopError.notFrontmost
        }
        if !settings.desktopApplicationPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let selected = try applicationURL(path: settings.desktopApplicationPath)
            guard await matchesApplication(application.bundleURL, selected: selected) else { throw T3DesktopError.notFrontmost }
        }
        try Task.checkCancellation()
        guard frontmostT3ProcessID == processID else { throw T3DesktopError.notFrontmost }
        let request = MicroRequest(requestId: UUID().uuidString, action: action)
        let override = settings.desktopSocketPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = override.isEmpty ? defaultSocketPath() : override
        let exchangeTask = Task.detached {
            let data = try exchange(path: path, payload: JSONEncoder().encode(request) + Data([10]),
                                    expectedProcessID: processID)
            try validateResponse(data, request: request)
        }
        try await withTaskCancellationHandler {
            try await exchangeTask.value
        } onCancel: {
            exchangeTask.cancel()
        }
    }

    static func validateResponse(_ data: Data, request: MicroRequest) throws {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.version == 1, response.requestId == request.requestId else { throw T3DesktopError.invalidResponse }
        guard response.ok else { throw T3DesktopError.rejected(response.message ?? "The control action could not be applied.") }
        guard response.action == request.action else { throw T3DesktopError.invalidResponse }
    }

    static func validateResponse(_ data: Data, request: Request) throws {
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              response.version == 1, response.requestId == request.requestId else { throw T3DesktopError.invalidResponse }
        guard response.ok else { throw T3DesktopError.rejected(response.message ?? "The session could not be opened.") }
        guard response.environmentId == request.environmentId, response.threadId == request.threadId else {
            throw T3DesktopError.invalidResponse
        }
    }

    private static func connectSocket(path: String, deadline: TimeInterval) throws -> Int32 {
        var address = sockaddr_un()
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw T3DesktopError.invalidPath
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw T3DesktopError.unavailable }
        var connectedSuccessfully = false
        defer { if !connectedSuccessfully { Darwin.close(fd) } }
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout.size(ofValue: noSignal))) == 0,
              fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw T3DesktopError.unavailable }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            path.withCString { source in
                _ = strncpy(UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: CChar.self), source, path.utf8.count + 1)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw T3DesktopError.unavailable }
            try wait(fd, events: Int16(POLLOUT), deadline: deadline)
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout.size(ofValue: error))
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { throw T3DesktopError.unavailable }
        }
        connectedSuccessfully = true
        return fd
    }

    static func exchange(path: String, payload: Data, timeout: TimeInterval = 16,
                         expectedProcessID: pid_t? = nil, waitForStart: Bool = false) throws -> Data {
        try Task.checkCancellation()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        let fd: Int32 = try {
            while true {
                do {
                    return try connectSocket(path: path, deadline: deadline)
                } catch T3DesktopError.unavailable where waitForStart {
                    let remaining = deadline - ProcessInfo.processInfo.systemUptime
                    guard remaining > 0 else { throw T3DesktopError.timeout }
                    // Retry only before connecting; never replay a delivered navigation request.
                    usleep(useconds_t(min(remaining, 0.1) * 1_000_000))
                }
            }
        }()
        defer { Darwin.close(fd) }
        if let expectedProcessID {
            var peer: pid_t = 0
            var size = socklen_t(MemoryLayout<pid_t>.size)
            guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peer, &size) == 0,
                  peer == expectedProcessID else { throw T3DesktopError.wrongInstance }
        }
        try payload.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                try wait(fd, events: Int16(POLLOUT), deadline: deadline)
                try Task.checkCancellation()
                let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard count > 0 else { throw T3DesktopError.unavailable }
                offset += count
            }
        }
        var response = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(fd, events: Int16(POLLIN), deadline: deadline)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw T3DesktopError.invalidResponse }
            response.append(contentsOf: chunk.prefix(count))
            guard response.count <= 65_536 else { throw T3DesktopError.invalidResponse }
            if let newline = response.firstIndex(of: 10) { return response.prefix(upTo: newline) }
        }
    }

    private static func wait(_ fd: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw T3DesktopError.timeout }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = poll(&descriptor, 1, Int32(min(remaining * 1000 + 1, 100)))
            if result < 0 && errno == EINTR { continue }
            if result == 0 { continue }
            guard result > 0 else { throw T3DesktopError.unavailable }
            if descriptor.revents & (events | Int16(POLLHUP)) != 0 { return }
            throw T3DesktopError.unavailable
        }
    }
}
