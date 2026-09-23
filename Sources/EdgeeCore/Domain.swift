import Foundation

public enum UsagePeriod: String, CaseIterable, Codable, Sendable {
    case day, week, month
    public var title: String { switch self { case .day: "Day"; case .week: "Week"; case .month: "Month" } }
    public var cliValue: String { switch self { case .day: "24h"; case .week: "7d"; case .month: "30d" } }
    public var windowLabel: String { switch self { case .day: "Last 24 hours"; case .week: "Last 7 days"; case .month: "Last 30 days" } }
}

public enum TokenKind: String, CaseIterable, Codable, Sendable {
    case input, cacheWrite, cacheRead, output
    public var title: String { switch self { case .input: "Input"; case .cacheWrite: "Cache write"; case .cacheRead: "Cache read"; case .output: "Output" } }
}
public struct TokenUsage: Identifiable, Codable, Sendable, Equatable {
    public var id: TokenKind { kind }
    public var kind: TokenKind
    public var count: Double
    public var cost: Double?
    public init(kind: TokenKind, count: Double, cost: Double?) { self.kind = kind; self.count = count; self.cost = cost }
}
public struct ModelUsage: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var tokens: Double
    public var cost: Double
    public var requests: Int
    public init(id: String, name: String, tokens: Double, cost: Double, requests: Int) {
        self.id = id; self.name = name; self.tokens = tokens; self.cost = cost; self.requests = requests
    }
}
public struct UsagePoint: Identifiable, Codable, Sendable, Equatable {
    public var id: Date { date }
    public var date: Date
    public var cost: Double
    public var tokens: Double
    public init(date: Date, cost: Double, tokens: Double = 0) { self.date = date; self.cost = cost; self.tokens = tokens }
}
public struct SessionUsage: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var cost: Double
    public var tokens: Double
    public var updatedAt: Date?
    public init(id: String, name: String, cost: Double, tokens: Double, updatedAt: Date? = nil) {
        self.id = id; self.name = name; self.cost = cost; self.tokens = tokens; self.updatedAt = updatedAt
    }
}
public struct UsageSnapshot: Codable, Sendable, Equatable {
    public var period: UsagePeriod
    public var window: UsageWindow?
    public var effectiveWindow: UsageWindow { window ?? UsageWindow(period: period, end: fetchedAt) }
    public var windowMode: UsageWindowMode { effectiveWindow.mode }
    public var totalCost: Double
    public var totalTokens: Double
    public var requests: Int
    public var savedCost: Double?
    public var tokens: [TokenUsage]
    public var models: [ModelUsage]
    public var series: [UsagePoint]
    public var sessions: [SessionUsage]
    public var fetchedAt: Date
    public var scope: String
    public var notice: String?
    public init(period: UsagePeriod, totalCost: Double, totalTokens: Double, requests: Int, savedCost: Double? = nil,
                tokens: [TokenUsage], models: [ModelUsage], series: [UsagePoint] = [], sessions: [SessionUsage] = [],
                fetchedAt: Date = Date(), scope: String = "Your usage", notice: String? = nil, window: UsageWindow? = nil) {
        self.window = window
        self.period = period; self.totalCost = totalCost; self.totalTokens = totalTokens; self.requests = requests
        self.savedCost = savedCost; self.tokens = tokens; self.models = models; self.series = series; self.sessions = sessions
        self.fetchedAt = fetchedAt; self.scope = scope; self.notice = notice
    }
}
public struct AgentConfiguration: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var toolCompression: Bool
    public var toolSurfaceReduction: Bool
    public var outputBrevity: Bool
    public var routedModel: String?
    public var canEdit: Bool
    public var detail: String?
    public init(id: String, name: String, toolCompression: Bool = false, toolSurfaceReduction: Bool = false,
                outputBrevity: Bool = false, routedModel: String? = nil, canEdit: Bool = true, detail: String? = nil) {
        self.id = id; self.name = name; self.toolCompression = toolCompression; self.toolSurfaceReduction = toolSurfaceReduction
        self.outputBrevity = outputBrevity; self.routedModel = routedModel; self.canEdit = canEdit; self.detail = detail
    }
}
public enum AgentSetting: String, Sendable { case toolCompression, toolSurfaceReduction, outputBrevity }
public struct AvailableModel: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var provider: String
    public init(id: String, name: String, provider: String = "") { self.id = id; self.name = name; self.provider = provider }
}
public struct EdgeeIdentity: Sendable, Equatable {
    public var name: String
    public var organization: String
    public var profile: String?
    public init(name: String, organization: String = "", profile: String? = nil) { self.name = name; self.organization = organization; self.profile = profile }
}
public protocol EdgeeServing: Sendable {
    func identity() async throws -> EdgeeIdentity
    func usage(for period: UsagePeriod, mode: UsageWindowMode) async throws -> UsageSnapshot
    func agents() async throws -> [AgentConfiguration]
    func availableModels(agentID: String) async throws -> [AvailableModel]
    func updateSetting(agentID: String, setting: AgentSetting, enabled: Bool) async throws
    func updateRoute(agentID: String, modelID: String?) async throws
    func login() async throws
}

public extension EdgeeServing {
    func usage(for period: UsagePeriod) async throws -> UsageSnapshot {
        try await usage(for: period, mode: .rolling)
    }
}
