import Foundation
import Darwin

public enum EdgeeServiceError: LocalizedError, Sendable, Equatable {
    case cliNotFound
    case authenticationRequired
    case missingMemberScope
    case unsupportedCredentialFormat
    case unsafeConsoleHost
    case invalidResponse(String)
    case commandFailed(String)
    case timedOut(String)
    case apiFailure(Int, String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "The Edgee CLI was not found. Install it with Homebrew and try again."
        case .authenticationRequired:
            return "Edgee authentication is required. Sign in and try again."
        case .missingMemberScope:
            return "The active Edgee profile has no user ID, so usage cannot be proven to be member-scoped. Sign in again with the Edgee CLI."
        case .unsupportedCredentialFormat:
            return "The Edgee credential file is not a supported profile-based configuration. Sign in again with the Edgee CLI."
        case .unsafeConsoleHost:
            return "The configured Console API host is not the official Edgee API host. Authentication was not sent."
        case let .invalidResponse(context):
            return "Edgee returned an invalid \(context) response."
        case let .commandFailed(command):
            return "The Edgee \(command) command failed."
        case let .timedOut(operation):
            return "The Edgee \(operation) operation timed out."
        case let .apiFailure(status, message):
            return message.isEmpty ? "The Edgee API request failed (HTTP \(status))." : message
        }
    }
}

public actor EdgeeService: EdgeeServing {
    private static let officialConsoleHost = "api.edgee.app"
    private static let providerOrder = [
        "claude", "claude_desktop", "codebuddy", "codex", "codex_desktop",
        "opencode", "crush", "pi", "kimi", "kilo", "copilot", "cursor"
    ]

    private let session: URLSession
    private let redirectDelegate: OfficialEdgeeRedirectDelegate

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let redirectDelegate = OfficialEdgeeRedirectDelegate()
        self.redirectDelegate = redirectDelegate
        session = URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }

    public func identity() async throws -> EdgeeIdentity {
        let data = try await runCLI(["auth", "status", "--json"], timeout: 15, operation: "authentication status")
        return try Self.parseIdentity(data)
    }

    public func usage(for period: UsagePeriod) async throws -> UsageSnapshot {
        let credentials = try await readCredentials()
        guard let userID = credentials.userID, !userID.isEmpty else {
            throw EdgeeServiceError.missingMemberScope
        }

        let body: [String: Any] = [
            "period": period.cliValue,
            "user_id": [userID],
            "interval": period == .day ? "hour" : "day"
        ]
        let data = try await apiRequest(
            credentials: credentials,
            pathComponents: ["v1", "organizations", credentials.organizationID, "usage"],
            method: "POST",
            body: body
        )
        var snapshot = try Self.parseUsage(data, period: period)
        do {
            snapshot.sessions = try await sessions(for: period, credentials: credentials, userID: userID)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let sessionNotice = "Session monitoring is temporarily unavailable. Usage totals are up to date."
            snapshot.notice = [snapshot.notice, sessionNotice].compactMap { $0 }.joined(separator: " ")
        }
        return snapshot
    }

    public func agents() async throws -> [AgentConfiguration] {
        let credentials = try await readCredentials()
        let configured = Self.providerOrder.filter { credentials.providers[$0]?.configured == true }

        return await withTaskGroup(of: (Int, AgentConfiguration).self) { group in
            for (index, agentID) in configured.enumerated() {
                let provider = credentials.providers[agentID]
                group.addTask { [session] in
                    let name = Self.agentName(agentID)
                    guard let keyID = provider?.apiKeyID, !keyID.isEmpty else {
                        return (index, AgentConfiguration(
                            id: agentID,
                            name: name,
                            canEdit: false,
                            detail: Self.agentDetail(connection: provider?.connection, suffix: "No server key ID")
                        ))
                    }
                    do {
                        let data = try await Self.apiRequest(
                            session: session,
                            credentials: credentials,
                            pathComponents: ["v1", "organizations", credentials.organizationID, "api_keys", keyID],
                            method: "GET",
                            body: nil
                        )
                        return (index, try Self.parseAgentConfiguration(
                            data,
                            agentID: agentID,
                            name: name,
                            connection: provider?.connection
                        ))
                    } catch {
                        return (index, AgentConfiguration(
                            id: agentID,
                            name: name,
                            canEdit: false,
                            detail: Self.agentDetail(connection: provider?.connection, suffix: "Settings unavailable")
                        ))
                    }
                }
            }

            var values: [(Int, AgentConfiguration)] = []
            for await value in group { values.append(value) }
            return values.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    public func availableModels(agentID: String) async throws -> [AvailableModel] {
        guard !agentID.isEmpty else { throw EdgeeServiceError.invalidResponse("agent") }
        let data = try await runCLI(
            ["route", "models", "--agent", agentID, "--json"],
            timeout: 45,
            operation: "route models"
        )
        return try Self.parseRouteModels(data)
    }

    public func updateSetting(agentID: String, setting: AgentSetting, enabled: Bool) async throws {
        let credentials = try await readCredentials()
        guard let provider = credentials.providers[agentID], provider.configured,
              let keyID = provider.apiKeyID, !keyID.isEmpty else {
            throw EdgeeServiceError.invalidResponse("agent configuration")
        }

        let currentData = try await apiRequest(
            credentials: credentials,
            pathComponents: ["v1", "organizations", credentials.organizationID, "api_keys", keyID],
            method: "GET"
        )
        let settings = try JSONDecoder().decode(APIKeySettings.self, from: currentData)
        var compression = settings.compression ?? CompressionSettings()
        switch setting {
        case .toolCompression: compression.toolResultTrimming = enabled
        case .toolSurfaceReduction: compression.toolSurfaceReduction = enabled
        case .outputBrevity: compression.outputBrevity = enabled
        }
        guard let raw = try JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
            throw EdgeeServiceError.invalidResponse("agent settings")
        }
        var rawCompression = raw["compression"] as? [String: Any] ?? [:]
        rawCompression["tool_result_trimming"] = compression.toolResultTrimming
        rawCompression["tool_surface_reduction"] = compression.toolSurfaceReduction
        rawCompression["output_brevity"] = compression.outputBrevity
        let rawFallbacks = raw["fallbacks"] as? [Any] ?? []
        let rawReroutes = raw["reroutes"] as? [Any] ?? []

        let body: [String: Any] = [
            "compression": rawCompression,
            "fallback": !rawFallbacks.isEmpty,
            "fallbacks": rawFallbacks.isEmpty ? NSNull() : rawFallbacks,
            "reroutes": rawReroutes.isEmpty ? NSNull() : rawReroutes
        ]
        _ = try await apiRequest(
            credentials: credentials,
            pathComponents: ["v1", "organizations", credentials.organizationID, "api_keys", keyID],
            method: "POST",
            body: body
        )
    }

    public func updateRoute(agentID: String, modelID: String?) async throws {
        guard !agentID.isEmpty else { throw EdgeeServiceError.invalidResponse("agent") }
        var arguments = ["route", "set", "--agent", agentID]
        if let modelID, !modelID.isEmpty {
            arguments += ["--strategy", "reroute", "--model", modelID]
        } else {
            arguments += ["--strategy", "passthrough"]
        }
        _ = try await runCLI(arguments, timeout: 45, operation: "route update")
    }

    public func login() async throws {
        var arguments = ["auth", "login", "--json"]
        let previousCredentials = try? await readCredentials()
        if let organization = previousCredentials?.organizationSlug, !organization.isEmpty {
            arguments += ["--org", organization]
        }
        let data = try await runCLI(arguments, timeout: 330, operation: "login")
        let result = try JSONDecoder().decode(LoginResult.self, from: data)
        guard result.loggedIn else { throw EdgeeServiceError.authenticationRequired }
        if result.needsOrganizationSelection {
            throw EdgeeServiceError.commandFailed("login: organization selection is required")
        }
    }

    // MARK: - Public parsers

    public static func parseIdentity(_ data: Data) throws -> EdgeeIdentity {
        let status: AuthStatus
        do { status = try JSONDecoder().decode(AuthStatus.self, from: data) }
        catch { throw EdgeeServiceError.invalidResponse("authentication status") }
        guard status.loggedIn else { throw EdgeeServiceError.authenticationRequired }
        let name = status.email?.nonEmpty ?? status.profile
        return EdgeeIdentity(
            name: name,
            organization: status.organizationSlug ?? "",
            profile: status.profile
        )
    }

    public static func parseUsage(
        _ data: Data,
        period: UsagePeriod,
        sessions: [SessionUsage] = []
    ) throws -> UsageSnapshot {
        let response: UsageResponse
        do { response = try JSONDecoder().decode(UsageResponse.self, from: data) }
        catch { throw EdgeeServiceError.invalidResponse("usage") }

        let summary = response.summary
        let tokens: [TokenUsage] = [
            summary.inputTokens.map { TokenUsage(kind: .input, count: $0, cost: dollars(summary.inputCost)) },
            summary.cacheCreationInputTokens.map {
                TokenUsage(kind: .cacheWrite, count: $0, cost: dollars(summary.cacheCreationInputCost))
            },
            summary.cachedInputTokens.map {
                TokenUsage(kind: .cacheRead, count: $0, cost: dollars(summary.cachedInputCost))
            },
            summary.outputTokens.map { TokenUsage(kind: .output, count: $0, cost: dollars(summary.outputCost)) }
        ].compactMap { $0 }
        let models = response.statsByModel.map {
            ModelUsage(
                id: $0.model,
                name: $0.model,
                tokens: $0.totalTokens,
                cost: $0.totalCost / 1_000_000_000,
                requests: Int(clamping: $0.totalRequests)
            )
        }.sorted { $0.cost > $1.cost }
        let series = response.statsByTime.data.compactMap { row -> UsagePoint? in
            guard let date = parseTimestamp(row.timestamp) else { return nil }
            return UsagePoint(date: date, cost: row.totalCost / 1_000_000_000, tokens: row.totalTokens)
        }.sorted { $0.date < $1.date }

        let savingParts = [
            summary.toolCompressionCostSavings,
            summary.outputCostSavings,
            summary.mcpSurfaceCostSavings
        ]
        let savedCost: Double? = savingParts.contains(where: { $0 != nil })
            ? dollars(savingParts.compactMap { $0 }.reduce(0, +))
            : nil
        let notice = (summary.reasoningOutputTokens ?? 0) > 0
            ? "Reasoning tokens are included in the total."
            : nil

        return UsageSnapshot(
            period: period,
            totalCost: summary.totalCost / 1_000_000_000,
            totalTokens: summary.totalTokens,
            requests: Int(clamping: summary.totalRequests),
            savedCost: savedCost,
            tokens: tokens,
            models: models,
            series: series,
            sessions: sessions,
            fetchedAt: Date(),
            scope: "Your usage",
            notice: notice
        )
    }

    public static func parseSessions(
        _ data: Data,
        agentNamesByKeyID: [String: String],
        since: Date,
        through: Date = .distantFuture
    ) throws -> [SessionUsage] {
        try parseSessionPage(
            data,
            agentNamesByKeyID: agentNamesByKeyID,
            since: since,
            through: through
        ).sessions
    }

    public static func parseAgentConfiguration(
        _ data: Data,
        agentID: String,
        name: String,
        connection: String? = nil
    ) throws -> AgentConfiguration {
        let key: APIKeySettings
        do { key = try JSONDecoder().decode(APIKeySettings.self, from: data) }
        catch { throw EdgeeServiceError.invalidResponse("agent settings") }
        let compression = key.compression ?? CompressionSettings()
        return AgentConfiguration(
            id: agentID,
            name: name,
            toolCompression: compression.toolResultTrimming,
            toolSurfaceReduction: compression.toolSurfaceReduction,
            outputBrevity: compression.outputBrevity,
            routedModel: key.reroutes.first?.model,
            canEdit: true,
            detail: agentDetail(connection: connection, suffix: key.fallbacks.first.map { "Fallback: \($0.model)" })
        )
    }

    public static func parseAvailableModels(
        _ data: Data,
        allowedProviders: Set<String> = [],
        byokOnly: Bool = false
    ) throws -> [AvailableModel] {
        let catalog: [GatewayModel]
        do { catalog = try JSONDecoder().decode([GatewayModel].self, from: data) }
        catch { throw EdgeeServiceError.invalidResponse("model catalog") }

        let appProviders = Set(["cursor", "github_copilot"])
        return catalog.compactMap { model in
            guard model.active else { return nil }
            let providers = model.providers.keys.sorted()
            if !providers.isEmpty, providers.allSatisfy(appProviders.contains) { return nil }
            if byokOnly, providers.allSatisfy({ !allowedProviders.contains($0) }) { return nil }
            let provider = providers.first(where: { !appProviders.contains($0) }) ?? model.authorID
            let identifier = model.aliases.first?.nonEmpty
                ?? provider.nonEmpty.map { "\($0)/\(model.modelID)" }
            guard let identifier else { return nil }
            return AvailableModel(
                id: identifier,
                name: model.displayName.nonEmpty ?? identifier,
                provider: model.authorID.nonEmpty ?? provider
            )
        }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public static func parseRouteModels(_ data: Data) throws -> [AvailableModel] {
        let models: [RouteModel]
        do { models = try JSONDecoder().decode([RouteModel].self, from: data) }
        catch { throw EdgeeServiceError.invalidResponse("route models") }

        return models.compactMap { model in
            guard let id = model.name.nonEmpty ?? model.aliases.first?.nonEmpty else { return nil }
            let provider = model.catalogID.split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return AvailableModel(
                id: id,
                name: model.displayName.nonEmpty ?? id,
                provider: provider
            )
        }
    }

    // MARK: - CLI

    private func runCLI(
        _ arguments: [String],
        timeout: TimeInterval,
        operation: String
    ) async throws -> Data {
        guard let executable = Self.edgeeExecutable() else { throw EdgeeServiceError.cliNotFound }
        let result = try await ProcessRunner.run(executable: executable, arguments: arguments, timeout: timeout)
        guard result.status == 0 else {
            if result.status == 124 { throw EdgeeServiceError.timedOut(operation) }
            throw EdgeeServiceError.commandFailed(operation)
        }
        guard !result.stdout.isEmpty else { throw EdgeeServiceError.invalidResponse(operation) }
        return result.stdout
    }

    private static func edgeeExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/edgee",
            "/usr/local/bin/edgee",
            "\(home)/.local/bin/edgee",
            "\(home)/.edgee/bin/edgee"
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    // MARK: - Console API

    private func sessions(
        for period: UsagePeriod,
        credentials: Credentials,
        userID: String
    ) async throws -> [SessionUsage] {
        var agentNamesByKeyID: [String: String] = [:]
        for agentID in Self.providerOrder {
            guard let provider = credentials.providers[agentID] else { continue }
            guard provider.configured, let keyID = provider.apiKeyID?.nonEmpty else { continue }
            agentNamesByKeyID[keyID] = agentNamesByKeyID[keyID] ?? Self.agentName(agentID)
        }
        guard !agentNamesByKeyID.isEmpty else { return [] }

        let through = Date()
        let since = through.addingTimeInterval(-period.duration)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var page = 1
        var allSessions: [SessionUsage] = []

        while true {
            var queryItems = [
                URLQueryItem(name: "from_date", value: formatter.string(from: since)),
                URLQueryItem(name: "to_date", value: formatter.string(from: through)),
                URLQueryItem(name: "user_id[]", value: userID),
                URLQueryItem(name: "page", value: String(page)),
                URLQueryItem(name: "page_size", value: "100")
            ]
            queryItems += agentNamesByKeyID.keys.sorted().map {
                URLQueryItem(name: "api_key_id[]", value: $0)
            }
            let data = try await apiRequest(
                credentials: credentials,
                pathComponents: ["v1", "organizations", credentials.organizationID, "sessions"],
                method: "GET",
                queryItems: queryItems
            )
            let parsed = try Self.parseSessionPage(
                data,
                agentNamesByKeyID: agentNamesByKeyID,
                since: since,
                through: through
            )
            allSessions.append(contentsOf: parsed.sessions)
            guard parsed.hasMore else { break }
            page += 1
            guard page <= 100 else { throw EdgeeServiceError.invalidResponse("sessions pagination") }
        }

        var seen = Set<String>()
        return allSessions
            .filter { seen.insert($0.id).inserted }
            .sorted { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }
    }

    private func apiRequest(
        credentials: Credentials,
        pathComponents: [String],
        method: String,
        body: [String: Any]? = nil,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        try await Self.apiRequest(
            session: session,
            credentials: credentials,
            pathComponents: pathComponents,
            method: method,
            body: body,
            queryItems: queryItems
        )
    }

    private static func apiRequest(
        session: URLSession,
        credentials: Credentials,
        pathComponents: [String],
        method: String,
        body: [String: Any]?,
        queryItems: [URLQueryItem] = []
    ) async throws -> Data {
        guard let baseURL = URL(string: credentials.consoleAPIURL),
              baseURL.scheme == "https",
              baseURL.host?.lowercased() == officialConsoleHost else {
            throw EdgeeServiceError.unsafeConsoleHost
        }
        var url = baseURL
        for component in pathComponents { url.appendPathComponent(component) }
        if !queryItems.isEmpty {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw EdgeeServiceError.invalidResponse("API URL")
            }
            components.queryItems = queryItems
            guard let queryURL = components.url else { throw EdgeeServiceError.invalidResponse("API URL") }
            url = queryURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(credentials.userToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw EdgeeServiceError.apiFailure(0, "Could not reach the Edgee API.") }
        guard let http = response as? HTTPURLResponse else {
            throw EdgeeServiceError.invalidResponse("API")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw EdgeeServiceError.authenticationRequired }
            let message = sanitizedAPIMessage(data)
            throw EdgeeServiceError.apiFailure(http.statusCode, message)
        }
        return data
    }

    private static func sanitizedAPIMessage(_ data: Data) -> String {
        struct Envelope: Decodable { let error: APIErrorBody? }
        struct APIErrorBody: Decodable { let message: String? }
        guard let message = try? JSONDecoder().decode(Envelope.self, from: data).error?.message,
              !message.isEmpty else { return "" }
        let flattened = message.replacingOccurrences(of: "\n", with: " ").prefix(240)
        let lowered = flattened.lowercased()
        guard !["token", "secret", "authorization", "api key"].contains(where: lowered.contains) else {
            return "The Edgee API rejected the request."
        }
        return String(flattened)
    }

    // MARK: - Credentials

    private func readCredentials() async throws -> Credentials {
        try await Task.detached(priority: .utility) {
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config/edgee/credentials.toml")
            let data = try Data(contentsOf: path, options: .mappedIfSafe)
            guard let text = String(data: data, encoding: .utf8) else {
                throw EdgeeServiceError.unsupportedCredentialFormat
            }
            return try Self.parseCredentials(text)
        }.value
    }

    private static func parseCredentials(_ text: String) throws -> Credentials {
        var activeProfile = "default"
        var currentSection = ""
        var values: [String: [String: String]] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                currentSection = String(line.dropFirst().dropLast())
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            let value = decodeTOMLString(line[line.index(after: equals)...])
            values[currentSection, default: [:]][key] = value
            if currentSection.isEmpty, key == "active_profile", !value.isEmpty { activeProfile = value }
        }

        let profileSection = "profiles.\(activeProfile)"
        guard let profile = values[profileSection],
              let token = profile["user_token"]?.nonEmpty,
              let organizationID = profile["org_id"]?.nonEmpty else {
            throw EdgeeServiceError.unsupportedCredentialFormat
        }

        var providers: [String: ProviderCredential] = [:]
        for provider in providerOrder {
            let section = values["\(profileSection).\(provider)"] ?? [:]
            let configured = section["api_key"]?.nonEmpty != nil || section["api_key_id"]?.nonEmpty != nil
            if configured {
                providers[provider] = ProviderCredential(
                    configured: true,
                    apiKeyID: section["api_key_id"]?.nonEmpty,
                    connection: section["connection"]?.nonEmpty
                )
            }
        }

        return Credentials(
            userToken: token,
            userID: profile["user_id"]?.nonEmpty,
            organizationID: organizationID,
            organizationSlug: profile["org_slug"]?.nonEmpty,
            profile: activeProfile,
            consoleAPIURL: profile["console_api_url"]?.nonEmpty ?? "https://\(officialConsoleHost)",
            providers: providers
        )
    }

    private static func decodeTOMLString(_ raw: Substring) -> String {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard value.first == "\"", value.count >= 2 else {
            return value.split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        }
        var output = ""
        var escaped = false
        for character in value.dropFirst() {
            if escaped {
                switch character {
                case "n": output.append("\n")
                case "r": output.append("\r")
                case "t": output.append("\t")
                default: output.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                break
            } else {
                output.append(character)
            }
        }
        return output
    }

    private static func agentName(_ id: String) -> String {
        switch id {
        case "claude": return "Claude Code"
        case "claude_desktop": return "Claude Desktop"
        case "codebuddy": return "CodeBuddy"
        case "codex": return "Codex"
        case "codex_desktop": return "Codex Desktop"
        case "opencode": return "OpenCode"
        case "crush": return "Crush"
        case "pi": return "Pi"
        case "kimi": return "Kimi Code"
        case "kilo": return "Kilo Code"
        case "copilot": return "GitHub Copilot"
        case "cursor": return "Cursor"
        default: return id
        }
    }

    private static func agentDetail(connection: String?, suffix: String?) -> String? {
        [connection?.nonEmpty.map { "\($0.capitalized) connection" }, suffix?.nonEmpty]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nonEmpty
    }

    private static func dollars(_ nanoUSD: Double?) -> Double? {
        nanoUSD.map { $0 / 1_000_000_000 }
    }

    private static func parseTimestamp(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: value)
    }

    private static func parseSessionPage(
        _ data: Data,
        agentNamesByKeyID: [String: String],
        since: Date,
        through: Date
    ) throws -> ParsedSessionPage {
        let response: SessionResponse
        do { response = try JSONDecoder().decode(SessionResponse.self, from: data) }
        catch { throw EdgeeServiceError.invalidResponse("sessions") }

        let sessions = response.data.compactMap { row -> SessionUsage? in
            guard
                let keyID = row.keyUUID,
                let agentName = agentNamesByKeyID[keyID],
                let id = row.sessionID?.nonEmpty,
                let totalCost = row.totalCost,
                let inputTokens = row.totalInputTokens,
                let cacheWriteTokens = row.totalCacheCreationInputTokens,
                let cacheReadTokens = row.totalCachedInputTokens,
                let outputTokens = row.totalOutputTokens,
                let reasoningTokens = row.totalReasoningOutputTokens,
                let updatedAtText = row.lastRequest,
                let updatedAt = parseTimestamp(updatedAtText),
                updatedAt >= since,
                updatedAt <= through
            else { return nil }

            return SessionUsage(
                id: id,
                name: row.name?.nonEmpty ?? "\(agentName) session",
                cost: totalCost / 1_000_000_000,
                tokens: inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens + reasoningTokens,
                updatedAt: updatedAt
            )
        }
        return ParsedSessionPage(sessions: sessions, hasMore: response.hasMore)
    }
}

private extension UsagePeriod {
    var duration: TimeInterval {
        switch self {
        case .day: return 24 * 60 * 60
        case .week: return 7 * 24 * 60 * 60
        case .month: return 30 * 24 * 60 * 60
        }
    }
}

private final class OfficialEdgeeRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        guard request.url?.scheme == "https",
              request.url?.host?.lowercased() == "api.edgee.app" else { return nil }
        return request
    }
}

// MARK: - Process execution

private enum ProcessRunner {
    private static func readBounded(_ handle: FileHandle, limit: Int) throws -> Data {
        var output = Data()
        var exceeded = false
        while let chunk = try handle.read(upToCount: 16_384), !chunk.isEmpty {
            if !exceeded && output.count + chunk.count <= limit { output.append(chunk) }
            else { exceeded = true }
        }
        guard !exceeded else { throw EdgeeServiceError.invalidResponse("oversized command") }
        return output
    }
    struct Result: Sendable {
        let status: Int32
        let stdout: Data
    }

    static func run(executable: URL, arguments: [String], timeout: TimeInterval) async throws -> Result {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8"
        ]

        do { try process.run() }
        catch { throw EdgeeServiceError.commandFailed("launch") }

        let stdoutTask = Task.detached(priority: .utility) {
            try readBounded(stdoutPipe.fileHandleForReading, limit: 8 * 1_024 * 1_024)
        }
        let stderrTask = Task.detached(priority: .utility) {
            while let chunk = try stderrPipe.fileHandleForReading.read(upToCount: 16_384), !chunk.isEmpty { }
        }
        let started = Date()

        do {
            while process.isRunning {
                try Task.checkCancellation()
                if Date().timeIntervalSince(started) >= timeout {
                    process.terminate()
                    for _ in 0..<20 where process.isRunning {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                    _ = try? await stderrTask.value
                    _ = try? await stdoutTask.value
                    return Result(status: 124, stdout: Data())
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        } catch {
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            _ = try? await stderrTask.value
            _ = try? await stdoutTask.value
            throw error
        }

        process.waitUntilExit()
        let stdout = try await stdoutTask.value
        _ = try? await stderrTask.value // Intentionally discarded: it may contain login URLs.
        guard stdout.count <= 8 * 1_024 * 1_024 else {
            throw EdgeeServiceError.invalidResponse("oversized command")
        }
        return Result(status: process.terminationStatus, stdout: stdout)
    }
}

// MARK: - Wire models

private struct AuthStatus: Decodable {
    let loggedIn: Bool
    let profile: String
    let email: String?
    let organizationSlug: String?

    enum CodingKeys: String, CodingKey {
        case loggedIn = "logged_in"
        case profile, email
        case organizationSlug = "org_slug"
    }
}

private struct LoginResult: Decodable {
    let loggedIn: Bool
    let needsOrganizationSelection: Bool

    enum CodingKeys: String, CodingKey {
        case loggedIn = "logged_in"
        case needsOrganizationSelection = "needs_org_selection"
    }
}

private struct Credentials: Sendable {
    let userToken: String
    let userID: String?
    let organizationID: String
    let organizationSlug: String?
    let profile: String
    let consoleAPIURL: String
    let providers: [String: ProviderCredential]
}

private struct ProviderCredential: Sendable {
    let configured: Bool
    let apiKeyID: String?
    let connection: String?
}

private struct UsageResponse: Decodable {
    let summary: UsageSummary
    let statsByModel: [UsageModel]
    let statsByTime: UsageTimeSeries

    enum CodingKeys: String, CodingKey {
        case summary
        case statsByModel = "stats_by_model"
        case statsByTime = "stats_by_time"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(UsageSummary.self, forKey: .summary)
        statsByModel = try container.decodeIfPresent([UsageModel].self, forKey: .statsByModel) ?? []
        statsByTime = try container.decodeIfPresent(UsageTimeSeries.self, forKey: .statsByTime) ?? UsageTimeSeries(data: [])
    }
}

private struct UsageSummary: Decodable {
    let totalRequests: Int64
    let totalCost: Double
    let totalTokens: Double
    let inputTokens: Double?
    let inputCost: Double?
    let cacheCreationInputTokens: Double?
    let cacheCreationInputCost: Double?
    let cachedInputTokens: Double?
    let cachedInputCost: Double?
    let outputTokens: Double?
    let outputCost: Double?
    let reasoningOutputTokens: Double?
    let toolCompressionCostSavings: Double?
    let outputCostSavings: Double?
    let mcpSurfaceCostSavings: Double?

    enum CodingKeys: String, CodingKey {
        case totalRequests = "total_requests", totalCost = "total_cost", totalTokens = "total_tokens"
        case inputTokens = "input_tokens", inputCost = "input_cost"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreationInputCost = "cache_creation_input_cost"
        case cachedInputTokens = "cached_input_tokens", cachedInputCost = "cached_input_cost"
        case outputTokens = "output_tokens", outputCost = "output_cost"
        case reasoningOutputTokens = "reasoning_output_tokens"
        case toolCompressionCostSavings = "tool_compression_cost_savings"
        case outputCostSavings = "output_cost_savings"
        case mcpSurfaceCostSavings = "mcp_surface_cost_savings"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        totalRequests = try c.decode(Int64.self, forKey: .totalRequests)
        totalCost = try c.decode(Double.self, forKey: .totalCost)
        totalTokens = try c.decode(Double.self, forKey: .totalTokens)
        inputTokens = try c.decodeIfPresent(Double.self, forKey: .inputTokens)
        inputCost = try c.decodeIfPresent(Double.self, forKey: .inputCost)
        cacheCreationInputTokens = try c.decodeIfPresent(Double.self, forKey: .cacheCreationInputTokens)
        cacheCreationInputCost = try c.decodeIfPresent(Double.self, forKey: .cacheCreationInputCost)
        cachedInputTokens = try c.decodeIfPresent(Double.self, forKey: .cachedInputTokens)
        cachedInputCost = try c.decodeIfPresent(Double.self, forKey: .cachedInputCost)
        outputTokens = try c.decodeIfPresent(Double.self, forKey: .outputTokens)
        outputCost = try c.decodeIfPresent(Double.self, forKey: .outputCost)
        reasoningOutputTokens = try c.decodeIfPresent(Double.self, forKey: .reasoningOutputTokens)
        toolCompressionCostSavings = try c.decodeIfPresent(Double.self, forKey: .toolCompressionCostSavings)
        outputCostSavings = try c.decodeIfPresent(Double.self, forKey: .outputCostSavings)
        mcpSurfaceCostSavings = try c.decodeIfPresent(Double.self, forKey: .mcpSurfaceCostSavings)
    }
}

private struct UsageModel: Decodable {
    let model: String
    let totalTokens: Double
    let totalCost: Double
    let totalRequests: Int64

    enum CodingKeys: String, CodingKey {
        case model
        case totalTokens = "total_tokens"
        case totalCost = "total_cost"
        case totalRequests = "total_requests"
    }
}

private struct UsageTimeSeries: Decodable {
    let data: [UsageTimePoint]
}

private struct UsageTimePoint: Decodable {
    let timestamp: String
    let totalCost: Double
    let totalTokens: Double

    enum CodingKeys: String, CodingKey {
        case timestamp
        case totalCost = "total_cost"
        case totalTokens = "total_tokens"
    }
}

private struct SessionResponse: Decodable {
    let data: [SessionWire]
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case data
        case hasMore = "has_more"
    }
}

private struct SessionWire: Decodable {
    let sessionID: String?
    let keyUUID: String?
    let name: String?
    let lastRequest: String?
    let totalCost: Double?
    let totalInputTokens: Double?
    let totalCacheCreationInputTokens: Double?
    let totalCachedInputTokens: Double?
    let totalOutputTokens: Double?
    let totalReasoningOutputTokens: Double?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case keyUUID = "key_uuid"
        case name
        case lastRequest = "last_request"
        case totalCost = "total_cost"
        case totalInputTokens = "total_input_tokens"
        case totalCacheCreationInputTokens = "total_cache_creation_input_tokens"
        case totalCachedInputTokens = "total_cached_input_tokens"
        case totalOutputTokens = "total_output_tokens"
        case totalReasoningOutputTokens = "total_reasoning_output_tokens"
    }
}

private struct ParsedSessionPage {
    let sessions: [SessionUsage]
    let hasMore: Bool
}

private struct CompressionSettings: Codable {
    var toolResultTrimming = false
    var toolSurfaceReduction = false
    var outputBrevity = false

    enum CodingKeys: String, CodingKey {
        case toolResultTrimming = "tool_result_trimming"
        case toolSurfaceReduction = "tool_surface_reduction"
        case outputBrevity = "output_brevity"
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        toolResultTrimming = try c.decodeIfPresent(Bool.self, forKey: .toolResultTrimming) ?? false
        toolSurfaceReduction = try c.decodeIfPresent(Bool.self, forKey: .toolSurfaceReduction) ?? false
        outputBrevity = try c.decodeIfPresent(Bool.self, forKey: .outputBrevity) ?? false
    }
}

private struct APIKeySettings: Decodable {
    var compression: CompressionSettings?
    var fallbacks: [ModelRoute]
    var reroutes: [ModelRoute]
    let byokOnly: Bool

    enum CodingKeys: String, CodingKey {
        case compression, fallbacks, reroutes
        case byokOnly = "byok_only"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        compression = try c.decodeIfPresent(CompressionSettings.self, forKey: .compression)
        fallbacks = try c.decodeIfPresent([ModelRoute].self, forKey: .fallbacks) ?? []
        reroutes = try c.decodeIfPresent([ModelRoute].self, forKey: .reroutes) ?? []
        byokOnly = try c.decodeIfPresent(Bool.self, forKey: .byokOnly) ?? false
    }
}

private struct ModelRoute: Decodable { let model: String }

private struct GatewayModel: Decodable {
    let modelID: String
    let authorID: String
    let displayName: String
    let aliases: [String]
    let providers: [String: GatewayProvider]
    let active: Bool

    enum CodingKeys: String, CodingKey {
        case modelID = "model_id", authorID = "author_id", displayName = "display_name"
        case aliases, providers, active
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelID = try c.decode(String.self, forKey: .modelID)
        authorID = try c.decodeIfPresent(String.self, forKey: .authorID) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        providers = try c.decodeIfPresent([String: GatewayProvider].self, forKey: .providers) ?? [:]
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? false
    }
}

private struct GatewayProvider: Decodable {}

private struct RouteModel: Decodable {
    let name: String
    let catalogID: String
    let displayName: String
    let aliases: [String]

    enum CodingKeys: String, CodingKey {
        case name, aliases
        case catalogID = "catalog_id"
        case displayName = "display_name"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        catalogID = try c.decodeIfPresent(String.self, forKey: .catalogID) ?? ""
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName) ?? ""
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
