import Foundation

/// The intended role of a model when evaluating usage.
///
/// Assign `WatchdogSettings.modelRoleOverrides` for reliable classification. The
/// built-in names are only a convenience fallback and are always reported as
/// heuristic classifications.
public enum WatchdogModelRole: String, CaseIterable, Codable, Sendable, Equatable {
    case thinking
    case executor
    case frontier
    case balanced
}

public enum WatchdogModelRoleSource: String, Codable, Sendable, Equatable {
    case explicitOverride
    case namingHeuristic
    case unknown
}

public struct WatchdogModelClassification: Codable, Sendable, Equatable {
    public var role: WatchdogModelRole?
    public var source: WatchdogModelRoleSource

    public init(role: WatchdogModelRole?, source: WatchdogModelRoleSource) {
        self.role = role
        self.source = source
    }
}

/// User-editable limits used by `WatchdogEngine`.
public struct WatchdogSettings: Codable, Sendable, Equatable {
    /// Spend allowed in the API's trailing 24-hour window, in USD.
    public var dailySpendLimit: Double
    public var dailyTokenLimit: Double
    /// The fraction of a trailing-24-hour limit at which a budget warning begins.
    public var budgetWarningFraction: Double
    /// The largest acceptable share of trailing-24-hour cost attributed to frontier models.
    public var maximumFrontierCostShare: Double
    /// The largest acceptable thinking-cost / executor-cost ratio.
    public var maximumThinkingToExecutorCostRatio: Double
    /// The largest acceptable increase in a session's cost per hour.
    public var maximumSessionCostIncreasePerHour: Double
    /// Prevents very small cost changes from producing a session-rate alert.
    public var minimumSessionCostIncrease: Double
    /// Samples farther apart than this are considered stale for session-rate checks.
    public var maximumObservationAge: TimeInterval
    /// Explicit roles, keyed preferably by `ModelUsage.id` and optionally by name.
    /// Thinking/executor ratio alerts use only these explicit assignments.
    public var modelRoleOverrides: [String: WatchdogModelRole]

    /// Accept known suggestions without replacing any manual ID or name assignment.
    public mutating func applySuggestedRoles(for models: [ModelUsage]) {
        for model in models where modelRoleOverrides[model.id] == nil && modelRoleOverrides[model.name] == nil {
            if let role = WatchdogEngine.suggestedRole(for: model) {
                modelRoleOverrides[model.id] = role
            }
        }
    }

    public init(
        dailySpendLimit: Double = 20,
        dailyTokenLimit: Double = 10_000_000,
        budgetWarningFraction: Double = 0.8,
        maximumFrontierCostShare: Double = 0.65,
        maximumThinkingToExecutorCostRatio: Double = 0.5,
        maximumSessionCostIncreasePerHour: Double = 2,
        minimumSessionCostIncrease: Double = 0.25,
        maximumObservationAge: TimeInterval = 6 * 60 * 60,
        modelRoleOverrides: [String: WatchdogModelRole] = [:]
    ) {
        self.dailySpendLimit = dailySpendLimit
        self.dailyTokenLimit = dailyTokenLimit
        self.budgetWarningFraction = budgetWarningFraction
        self.maximumFrontierCostShare = maximumFrontierCostShare
        self.maximumThinkingToExecutorCostRatio = maximumThinkingToExecutorCostRatio
        self.maximumSessionCostIncreasePerHour = maximumSessionCostIncreasePerHour
        self.minimumSessionCostIncrease = minimumSessionCostIncrease
        self.maximumObservationAge = maximumObservationAge
        self.modelRoleOverrides = modelRoleOverrides
    }
}

/// A persisted trailing-24-hour snapshot that can become the baseline for the next fetch.
public struct WatchdogObservation: Codable, Sendable, Equatable {
    public var snapshot: UsageSnapshot
    public var timestamp: Date

    public init(snapshot: UsageSnapshot, timestamp: Date? = nil) {
        self.snapshot = snapshot
        self.timestamp = timestamp ?? snapshot.fetchedAt
    }
}

public enum WatchdogAlertSeverity: String, Codable, Sendable, Equatable {
    case warning
    case critical
}

public enum WatchdogAlertKind: String, Codable, Sendable, Equatable {
    case dailySpend
    case dailyTokens
    case frontierShare
    case thinkingToExecutorRatio
    case sessionCostIncrease
}

/// An advisory only. The app owns notification delivery and any route change.
public struct WatchdogAlert: Identifiable, Codable, Sendable, Equatable {
    /// Stable across evaluations while the underlying condition remains true.
    public var id: String
    public var severity: WatchdogAlertSeverity
    public var title: String
    public var message: String
    public var kind: WatchdogAlertKind
    /// Human-readable suggestion; it never directs or performs an automatic reroute.
    public var recommendation: String?

    public init(
        id: String,
        severity: WatchdogAlertSeverity,
        title: String,
        message: String,
        kind: WatchdogAlertKind,
        recommendation: String? = nil
    ) {
        self.id = id
        self.severity = severity
        self.title = title
        self.message = message
        self.kind = kind
        self.recommendation = recommendation
    }
}

/// A stateless, deterministic usage evaluator. It never changes a model route.
public enum WatchdogEngine: Sendable {
    public static func evaluate(
        snapshot: UsageSnapshot,
        previous: WatchdogObservation?,
        settings: WatchdogSettings
    ) -> [WatchdogAlert] {
        guard snapshot.period == .day else { return [] }

        var alerts: [WatchdogAlert] = []
        appendBudgetAlerts(snapshot: snapshot, settings: settings, alerts: &alerts)
        appendModelMixAlerts(snapshot: snapshot, settings: settings, alerts: &alerts)
        appendSessionRateAlerts(
            snapshot: snapshot,
            previous: previous,
            settings: settings,
            alerts: &alerts
        )
        return alerts
    }

    /// Workflow suggestions based on model families, not a claim about model capabilities.
    /// Version boundaries keep, for example, Kimi 2.5 distinct from Kimi 2.50.
    public static func suggestedRole(for model: ModelUsage) -> WatchdogModelRole? {
        let names = [model.id, model.name].map {
            $0.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
        let rules: [(String, WatchdogModelRole)] = [
            (#"(?:^| )(?:opus|gpt(?: [0-9]+)* sol|kimi (?:k ?)?3|glm 5 3|deepseek v?4 1)(?: |$)"#, .thinking),
            (#"(?:^| )(?:sonnet|gpt(?: [0-9]+)* (?:terra|luna)|qwen[0-9]*|kimi (?:k ?)?2 5)(?: |$)"#, .executor)
        ]
        for name in names {
            for (pattern, role) in rules where name.range(of: pattern, options: .regularExpression) != nil {
                return role
            }
        }
        return nil
    }

    /// Classifies a model, preserving whether the answer is a configuration or a heuristic.
    public static func classify(
        _ model: ModelUsage,
        settings: WatchdogSettings
    ) -> WatchdogModelClassification {
        if let role = settings.modelRoleOverrides[model.id]
            ?? settings.modelRoleOverrides[model.name] {
            return WatchdogModelClassification(role: role, source: .explicitOverride)
        }

        if let role = suggestedRole(for: model) {
            return WatchdogModelClassification(role: role, source: .namingHeuristic)
        }

        let name = "\(model.id) \(model.name)".lowercased()
        if name.contains("opus") || name.contains("frontier") {
            return WatchdogModelClassification(role: .frontier, source: .namingHeuristic)
        }
        if name.contains("o1") || name.contains("o3") || name.contains("thinking") || name.contains("reasoning") {
            return WatchdogModelClassification(role: .thinking, source: .namingHeuristic)
        }
        if name.contains("haiku") || name.contains("mini") || name.contains("executor") {
            return WatchdogModelClassification(role: .executor, source: .namingHeuristic)
        }
        if name.contains("sonnet") || name.contains("balanced") {
            return WatchdogModelClassification(role: .balanced, source: .namingHeuristic)
        }
        return WatchdogModelClassification(role: nil, source: .unknown)
    }

    private static func appendBudgetAlerts(
        snapshot: UsageSnapshot,
        settings: WatchdogSettings,
        alerts: inout [WatchdogAlert]
    ) {
        let recommendation = cheaperExecutorRecommendation(snapshot: snapshot, settings: settings)
        appendBudgetAlert(
            value: snapshot.totalCost,
            limit: settings.dailySpendLimit,
            warningFraction: settings.budgetWarningFraction,
            id: "daily-spend",
            title: "Trailing 24-hour spend is high",
            unit: "$",
            kind: .dailySpend,
            recommendation: recommendation,
            alerts: &alerts
        )
        appendBudgetAlert(
            value: snapshot.totalTokens,
            limit: settings.dailyTokenLimit,
            warningFraction: settings.budgetWarningFraction,
            id: "daily-tokens",
            title: "Trailing 24-hour token use is high",
            unit: "tokens",
            kind: .dailyTokens,
            recommendation: recommendation,
            alerts: &alerts
        )
    }

    private static func appendBudgetAlert(
        value: Double,
        limit: Double,
        warningFraction: Double,
        id: String,
        title: String,
        unit: String,
        kind: WatchdogAlertKind,
        recommendation: String,
        alerts: inout [WatchdogAlert]
    ) {
        guard value.isFinite,
              limit.isFinite,
              warningFraction.isFinite,
              value >= 0,
              limit > 0,
              warningFraction > 0 else { return }
        let warningLimit = limit * min(warningFraction, 1)
        guard warningLimit.isFinite, value >= warningLimit else { return }
        let severity: WatchdogAlertSeverity = value >= limit ? .critical : .warning
        let renderedValue = unit == "$" ? money(value) : wholeNumber(value)
        let renderedLimit = unit == "$" ? money(limit) : wholeNumber(limit)
        alerts.append(WatchdogAlert(
            id: id,
            severity: severity,
            title: title,
            message: "\(renderedValue) of \(renderedLimit) trailing 24-hour \(unit == "$" ? "spend" : "tokens") used.",
            kind: kind,
            recommendation: recommendation
        ))
    }

    private static func appendModelMixAlerts(
        snapshot: UsageSnapshot,
        settings: WatchdogSettings,
        alerts: inout [WatchdogAlert]
    ) {
        let classified = snapshot.models.map { ($0, classify($0, settings: settings)) }
        let frontierModels = classified.filter {
            $0.1.role == .frontier && $0.0.cost.isFinite && $0.0.cost >= 0
        }
        let frontierCost = frontierModels.reduce(0) { $0 + $1.0.cost }
        if snapshot.totalCost.isFinite,
           snapshot.totalCost > 0,
           settings.maximumFrontierCostShare.isFinite,
           settings.maximumFrontierCostShare > 0 {
            let share = frontierCost / snapshot.totalCost
            if share.isFinite, share > settings.maximumFrontierCostShare {
                let heuristicNote = frontierModels.contains { $0.1.source == .namingHeuristic }
                    ? " Frontier classification uses a naming heuristic; configure a model role override to make it explicit."
                    : ""
                alerts.append(WatchdogAlert(
                    id: "frontier-share",
                    severity: share >= min(1, settings.maximumFrontierCostShare * 1.25) ? .critical : .warning,
                    title: "Frontier-model spend is high",
                    message: "\(percentage(share)) of trailing 24-hour spend is on frontier models; the configured maximum is \(percentage(settings.maximumFrontierCostShare)).\(heuristicNote)",
                    kind: .frontierShare,
                    recommendation: cheaperExecutorRecommendation(snapshot: snapshot, settings: settings)
                ))
            }
        }

        // Ratio warnings deliberately require manual roles. Heuristic labels may
        // be useful for the UI, but must not infer a user's reasoning policy.
        let explicitlyClassified = classified.filter { $0.1.source == .explicitOverride }
        let thinkingCost = explicitlyClassified
            .filter { $0.1.role == .thinking && $0.0.cost.isFinite && $0.0.cost >= 0 }
            .reduce(0) { $0 + $1.0.cost }
        let executorCost = explicitlyClassified
            .filter { $0.1.role == .executor && $0.0.cost.isFinite && $0.0.cost >= 0 }
            .reduce(0) { $0 + $1.0.cost }
        guard thinkingCost.isFinite,
              executorCost.isFinite,
              thinkingCost > 0,
              settings.maximumThinkingToExecutorCostRatio.isFinite,
              settings.maximumThinkingToExecutorCostRatio >= 0 else { return }
        let ratio = executorCost > 0 ? thinkingCost / executorCost : .infinity
        guard ratio > settings.maximumThinkingToExecutorCostRatio else { return }
        let ratioDescription = ratio.isFinite ? String(format: "%.2f:1", ratio) : "no executor spend"
        alerts.append(WatchdogAlert(
            id: "thinking-executor-ratio",
            severity: ratio >= max(1, settings.maximumThinkingToExecutorCostRatio * 2) ? .critical : .warning,
            title: "Thinking-to-executor cost ratio is high",
            message: "Thinking cost is \(ratioDescription); the configured maximum is \(String(format: "%.2f", settings.maximumThinkingToExecutorCostRatio)):1.",
            kind: .thinkingToExecutorRatio,
            recommendation: cheaperExecutorRecommendation(snapshot: snapshot, settings: settings)
        ))
    }

    private static func appendSessionRateAlerts(
        snapshot: UsageSnapshot,
        previous: WatchdogObservation?,
        settings: WatchdogSettings,
        alerts: inout [WatchdogAlert]
    ) {
        guard let previous,
              previous.snapshot.period == .day,
              snapshot.scope == previous.snapshot.scope,
              snapshot.fetchedAt > previous.snapshot.fetchedAt,
              snapshot.fetchedAt > previous.timestamp,
              settings.maximumSessionCostIncreasePerHour.isFinite,
              settings.maximumSessionCostIncreasePerHour > 0,
              settings.minimumSessionCostIncrease.isFinite,
              settings.minimumSessionCostIncrease >= 0,
              settings.maximumObservationAge.isFinite,
              settings.maximumObservationAge > 0 else { return }

        let elapsed = snapshot.fetchedAt.timeIntervalSince(previous.timestamp)
        guard elapsed.isFinite, elapsed > 0, elapsed <= settings.maximumObservationAge else { return }
        let previousSessions = Dictionary(grouping: previous.snapshot.sessions, by: \.id)
        let currentSessions = Dictionary(grouping: snapshot.sessions, by: \.id)

        for id in currentSessions.keys.sorted() {
            guard !id.isEmpty,
                  let current = currentSessions[id], current.count == 1,
                  let prior = previousSessions[id], prior.count == 1,
                  let session = current.first,
                  let earlier = prior.first,
                  session.cost.isFinite,
                  earlier.cost.isFinite,
                  hasFreshSessionTimestamp(session, comparedTo: earlier, previous: previous, snapshot: snapshot) else { continue }
            let increase = session.cost - earlier.cost
            guard increase.isFinite,
                  increase >= settings.minimumSessionCostIncrease,
                  increase > 0 else { continue }
            let perHour = increase / (elapsed / 60 / 60)
            guard perHour.isFinite, perHour > settings.maximumSessionCostIncreasePerHour else { continue }
            let severity: WatchdogAlertSeverity = perHour >= settings.maximumSessionCostIncreasePerHour * 2 ? .critical : .warning
            alerts.append(WatchdogAlert(
                id: "session-cost-increase/\(session.id)",
                severity: severity,
                title: "Session cost is rising quickly",
                message: "\(session.name) increased by \(money(increase)) in \(duration(elapsed)) (\(money(perHour))/hour).",
                kind: .sessionCostIncrease,
                recommendation: cheaperExecutorRecommendation(snapshot: snapshot, settings: settings)
            ))
        }
    }

    private static func money(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func wholeNumber(_ value: Double) -> String {
        String(format: "%.0f", value)
    }

    private static func percentage(_ value: Double) -> String {
        String(format: "%.0f%%", value * 100)
    }

    private static func duration(_ value: TimeInterval) -> String {
        if value >= 3_600 { return String(format: "%.1f hours", value / 3_600) }
        return String(format: "%.0f minutes", value / 60)
    }

    private static func cheaperExecutorRecommendation(
        snapshot: UsageSnapshot,
        settings: WatchdogSettings
    ) -> String {
        let executor = snapshot.models
            .filter {
                $0.cost.isFinite
                    && classify($0, settings: settings) == WatchdogModelClassification(role: .executor, source: .explicitOverride)
            }
            .min { $0.cost < $1.cost }
        if let executor {
            return "Consider delegating routine work to \(executor.name), a configured executor model, when appropriate."
        }
        return "Consider delegating routine work to a cheaper executor model when appropriate."
    }

    private static func hasFreshSessionTimestamp(
        _ current: SessionUsage,
        comparedTo previous: SessionUsage,
        previous observation: WatchdogObservation,
        snapshot: UsageSnapshot
    ) -> Bool {
        guard let previousUpdatedAt = previous.updatedAt else {
            guard let currentUpdatedAt = current.updatedAt else { return true }
            return currentUpdatedAt > observation.timestamp && currentUpdatedAt <= snapshot.fetchedAt
        }
        guard let currentUpdatedAt = current.updatedAt else { return false }
        return currentUpdatedAt > previousUpdatedAt
            && currentUpdatedAt > observation.timestamp
            && currentUpdatedAt <= snapshot.fetchedAt
    }
}
