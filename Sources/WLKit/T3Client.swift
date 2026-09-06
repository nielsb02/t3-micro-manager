import Foundation

public enum T3Error: LocalizedError {
    case invalidURL, invalidPairingCode, unauthorized, forbidden, badResponse, http(Int), missingEnvironment

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Enter a T3 server HTTP or HTTPS address without credentials, a query, or a fragment."
        case .invalidPairingCode: return "Paste a T3 pairing token or pairing link."
        case .unauthorized: return "T3 pairing is missing or expired. Create a new pairing link in T3 Settings → Connections and pair again."
        case .forbidden: return "This T3 connection does not have permission to read sessions. Pair again with a new link."
        case .badResponse: return "T3 returned an unsupported response. Check the server address and T3 version."
        case .http(let code): return "T3 returned HTTP \(code)."
        case .missingEnvironment: return "Connect to T3 before opening a session so its environment can be identified."
        }
    }
}

/// The local T3 server's shell endpoint contains session summaries without chat messages.
@MainActor public final class T3Client {
    private var settings: T3ConnectionSettings
    private let transport: URLSession
    private var discoveredEnvironmentID: String?

    public convenience init(settings: T3ConnectionSettings) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpCookieStorage = nil
        self.init(settings: settings, transport: URLSession(configuration: configuration))
    }

    init(settings: T3ConnectionSettings, transport: URLSession) {
        self.settings = settings
        self.transport = transport
    }

    public func listSessions() async throws -> [AgentSession] {
        let environmentID: String
        if !settings.environmentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            environmentID = settings.environmentID.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if let discoveredEnvironmentID {
            environmentID = discoveredEnvironmentID
        } else {
            let data = try await request(path: "/.well-known/t3/environment", authenticated: false)
            guard let descriptor = try? JSONDecoder().decode(Descriptor.self, from: data),
                  !descriptor.environmentId.isEmpty else { throw T3Error.badResponse }
            environmentID = descriptor.environmentId
            discoveredEnvironmentID = environmentID
        }
        return try Self.parseShell(data: await request(path: "/api/orchestration/shell"), environmentID: environmentID)
    }

    /// A browser must pair separately. The manager's bearer credential is never put in a URL.
    public func sessionURL(_ session: AgentSession) throws -> URL {
        let environmentID = session.environmentID ?? discoveredEnvironmentID ?? settings.environmentID
        guard !environmentID.isEmpty else { throw T3Error.missingEnvironment }
        guard !session.id.isEmpty else { throw T3Error.badResponse }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let environment = environmentID.addingPercentEncoding(withAllowedCharacters: allowed),
              let thread = session.id.addingPercentEncoding(withAllowedCharacters: allowed),
              var components = URLComponents(url: try baseURL(), resolvingAgainstBaseURL: false)
        else { throw T3Error.invalidURL }
        components.percentEncodedPath += "/\(environment)/\(thread)"
        guard let url = components.url else { throw T3Error.invalidURL }
        return url
    }

    /// Exchange an explicitly supplied pairing token for this app's own read-only credential.
    public func pair(code: String) async throws -> String {
        let credential = try Self.pairingCredential(code)
        let form = [
            ("grant_type", "urn:ietf:params:oauth:grant-type:token-exchange"),
            ("subject_token", credential),
            ("subject_token_type", "urn:t3:params:oauth:token-type:environment-bootstrap"),
            ("requested_token_type", "urn:ietf:params:oauth:token-type:access_token"),
            ("scope", "orchestration:read"),
            ("client_label", "Micro Manager"),
            ("client_device_type", "desktop"),
            ("client_os", "macOS"),
        ]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = form.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        let data = try await request(path: "/oauth/token", authenticated: false,
                                     body: Data(body.utf8), contentType: "application/x-www-form-urlencoded")
        guard let token = try? JSONDecoder().decode(TokenResponse.self, from: data),
              token.token_type == "Bearer", !token.access_token.isEmpty,
              token.scope.split(separator: " ").contains("orchestration:read") else { throw T3Error.badResponse }
        settings.bearerToken = token.access_token
        return token.access_token
    }

    /// Reads the runtime metadata T3 also uses for CLI discovery, without secrets or databases.
    public nonisolated static func discoverLocalEndpoint() -> String? {
        let configuredHome = ProcessInfo.processInfo.environment["T3CODE_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = configuredHome.flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory() + "/.t3"
        let file = URL(fileURLWithPath: base).appendingPathComponent("userdata/server-runtime.json")
        guard let data = try? Data(contentsOf: file) else { return nil }
        return localEndpoint(from: data)
    }

    nonisolated static func localEndpoint(from data: Data) -> String? {
        struct RuntimeState: Decodable { let version: Int; let origin: String; let devUrl: String? }
        guard let state = try? JSONDecoder().decode(RuntimeState.self, from: data), state.version == 1,
              let components = URLComponents(string: state.devUrl ?? state.origin),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              ["127.0.0.1", "localhost", "[::1]", "::1"].contains(components.host?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        return components.url?.absoluteString
    }

    public nonisolated static func parseShell(data: Data, environmentID: String) throws -> [AgentSession] {
        guard let shell = try? JSONDecoder().decode(Shell.self, from: data),
              shell.threads.allSatisfy({ !$0.id.isEmpty && !$0.title.isEmpty }),
              Set(shell.threads.map(\.id)).count == shell.threads.count else { throw T3Error.badResponse }
        let directories = Dictionary(shell.projects.map { ($0.id, $0.workspaceRoot) }, uniquingKeysWith: { first, _ in first })
        return shell.threads.filter { $0.archivedAt == nil && $0.deletedAt == nil }.map { thread in
            AgentSession(id: thread.id, title: thread.title, status: thread.status,
                         updatedAt: thread.latestUserMessageAt ?? thread.latestTurn?.requestedAt ?? thread.updatedAt,
                         isPinned: thread.pinnedAt != nil, environmentID: environmentID,
                         directory: thread.worktreePath ?? directories[thread.projectId],
                         completionID: thread.latestTurn?.turnId ?? thread.latestTurn?.completedAt
                            ?? thread.latestTurn?.requestedAt)
        }
    }

    private func baseURL() throws -> URL {
        let raw = settings.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: raw),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { throw T3Error.invalidURL }
        while components.path.hasSuffix("/") { components.path.removeLast() }
        guard let url = components.url else { throw T3Error.invalidURL }
        return url
    }

    private func request(path: String, authenticated: Bool = true, body: Data? = nil,
                         contentType: String? = nil) async throws -> Data {
        let url = try baseURL().appendingPathComponent(String(path.dropFirst()))
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated && !settings.bearerToken.isEmpty {
            request.setValue("Bearer \(settings.bearerToken)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw T3Error.badResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw T3Error.unauthorized
        case 403: throw T3Error.forbidden
        default: throw T3Error.http(http.statusCode)
        }
    }

    private nonisolated static func pairingCredential(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw T3Error.invalidPairingCode }
        if let url = URLComponents(string: text), url.scheme != nil {
            // T3's current /pair links keep credentials in #token=….
            if let fragment = url.percentEncodedFragment, let query = URLComponents(string: "?" + fragment),
               let token = query.queryItems?.first(where: { $0.name == "token" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty { return token }
            if let token = url.queryItems?.first(where: { $0.name == "token" })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
               !token.isEmpty { return token }
            throw T3Error.invalidPairingCode
        }
        guard !text.contains(where: \.isWhitespace) else { throw T3Error.invalidPairingCode }
        return text
    }

    private struct Descriptor: Decodable { let environmentId: String }
    private struct TokenResponse: Decodable { let access_token: String; let token_type: String; let scope: String }
    private struct Shell: Decodable { let threads: [Thread]; let projects: [Project] }
    private struct Project: Decodable { let id: String; let workspaceRoot: String }
    private struct Session: Decodable { let status: String }
    private struct Turn: Decodable {
        let turnId: String?
        let state: String
        let requestedAt: String?
        let completedAt: String?
    }
    private struct Thread: Decodable {
        let id: String
        let projectId: String
        let title: String
        let updatedAt: String
        let latestUserMessageAt: String?
        let worktreePath: String?
        let pinnedAt: String?
        let archivedAt: String?
        let deletedAt: String?
        let session: Session?
        let latestTurn: Turn?
        let hasPendingApprovals: Bool
        let hasPendingUserInput: Bool
        let hasActionableProposedPlan: Bool?
        let backgroundLiveness: String?

        var status: SessionStatus {
            if hasPendingApprovals || hasPendingUserInput || hasActionableProposedPlan == true { return .blocked }
            if session?.status == "error" || latestTurn?.state == "error" { return .error }
            if ["starting", "running"].contains(session?.status ?? "") || latestTurn?.state == "running"
                || ["working", "monitoring"].contains(backgroundLiveness ?? "") { return .working }
            if latestTurn?.state == "interrupted" || ["interrupted", "stopped"].contains(session?.status ?? "") { return .idle }
            if latestTurn?.state == "completed" { return .done }
            if session == nil || ["ready", "idle"].contains(session?.status ?? "") { return .idle }
            return .unknown
        }
    }
}
