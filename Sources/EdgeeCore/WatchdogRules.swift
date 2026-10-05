import Foundation

/// Watchdog-only preferences. Overview budgets and usage-window preferences are separate.
public struct WatchdogRules: Codable, Equatable, Sendable {
    public var thinkingEnabled = true
    public var monthlyEnabled = true
    public var rapidSpendEnabled = true
    public var thinkingShare = 0.5
    public var monthlyLimit = 1_000.0
    public var rapidSpendLimit = 50.0
    public var modelRoles: [String: WatchdogModelRole] = [:]

    public init() {}

    public var classificationSettings: WatchdogSettings {
        WatchdogSettings(modelRoleOverrides: modelRoles)
    }
}

/// Cumulative calendar-month totals, never an extrapolated hourly rate.
public struct SpendObservation: Codable, Equatable, Sendable {
    public var date: Date
    public var monthStart: Date
    public var cost: Double
    public var scope: String

    public init(snapshot: UsageSnapshot) {
        date = snapshot.fetchedAt
        monthStart = snapshot.effectiveWindow.start
        cost = snapshot.totalCost
        scope = snapshot.scope
    }
}

public enum WatchdogRulesEngine {
    public static func isFresh(_ snapshot: UsageSnapshot, period: UsagePeriod, now: Date) -> Bool {
        snapshot.period == period && snapshot.windowMode == .calendar
            && snapshot.effectiveWindow.isCurrent(at: now)
            && (0...300).contains(now.timeIntervalSince(snapshot.fetchedAt))
    }

    public static func thinkingFraction(_ day: UsageSnapshot, rules: WatchdogRules) -> Double? {
        guard day.totalTokens.isFinite, day.totalTokens > 0 else { return nil }
        let tokens = day.models.filter {
            WatchdogEngine.classify($0, settings: rules.classificationSettings).role == .thinking
        }.reduce(0.0) { $0 + ($1.tokens.isFinite && $1.tokens >= 0 ? $1.tokens : 0) }
        guard tokens.isFinite, tokens <= day.totalTokens else { return nil }
        return tokens / day.totalTokens
    }

    public static func record(_ month: UsageSnapshot, in history: inout [SpendObservation]) {
        guard month.period == .month, month.windowMode == .calendar,
              month.totalCost.isFinite, month.totalCost >= 0 else { history = []; return }
        let sample = SpendObservation(snapshot: month)
        if let last = history.last {
            guard sample.date > last.date else { return }
            if last.monthStart != sample.monthStart || last.scope != sample.scope || sample.cost < last.cost {
                history = []
            }
        }
        history.removeAll { sample.date.timeIntervalSince($0.date) >= 3_600 }
        history.append(sample)
        // Bounds persisted data even if refresh is requested unusually often.
        if history.count > 3_600 { history.removeFirst(history.count - 3_600) }
    }

    public static func recentSpend(month: UsageSnapshot, history: [SpendObservation]) -> (cost: Double, seconds: Double)? {
        guard let first = history.first(where: {
            $0.scope == month.scope && $0.monthStart == month.effectiveWindow.start
                && $0.date < month.fetchedAt && month.fetchedAt.timeIntervalSince($0.date) < 3_600
                && $0.cost.isFinite && $0.cost >= 0 && $0.cost <= month.totalCost
        }) else { return nil }
        return (month.totalCost - first.cost, month.fetchedAt.timeIntervalSince(first.date))
    }

    public static func evaluate(day: UsageSnapshot?, month: UsageSnapshot?, history: [SpendObservation],
                                rules: WatchdogRules, now: Date, calendar: Calendar = .current) -> [WatchdogAlert] {
        var alerts: [WatchdogAlert] = []
        let suggestion = "Consider switching routine work to an executor model. Open routing to review your options."
        if rules.thinkingEnabled, rules.thinkingShare.isFinite, (0...1).contains(rules.thinkingShare),
           calendar.component(.hour, from: now) >= 12,
           let day, isFresh(day, period: .day, now: now),
           let share = thinkingFraction(day, rules: rules), share > rules.thinkingShare {
            alerts.append(WatchdogAlert(id: "thinking-tokens/\(Int(day.effectiveWindow.start.timeIntervalSince1970))",
                severity: .warning, title: "Thinking models dominate today's tokens",
                message: "\(Int(share * 100))% of today's tokens (UTC) used thinking families. Consider an executor for routine work.",
                kind: .thinkingTokens, recommendation: suggestion))
        }
        if let month, isFresh(month, period: .month, now: now), month.totalCost.isFinite, month.totalCost >= 0 {
            if rules.monthlyEnabled, rules.monthlyLimit.isFinite, rules.monthlyLimit > 0, month.totalCost >= rules.monthlyLimit {
                alerts.append(WatchdogAlert(id: "monthly-spend/\(Int(month.effectiveWindow.start.timeIntervalSince1970))",
                    severity: .critical, title: "Monthly spending limit reached",
                    message: "\(money(month.totalCost)) spent this calendar month (UTC), above your \(money(rules.monthlyLimit)) alert threshold.",
                    kind: .monthlySpend, recommendation: suggestion))
            }
            if rules.rapidSpendEnabled, rules.rapidSpendLimit.isFinite, rules.rapidSpendLimit > 0,
               let spend = recentSpend(month: month, history: history), spend.cost >= rules.rapidSpendLimit {
                alerts.append(WatchdogAlert(id: "rapid-spend", severity: .critical, title: "Spending is rising quickly",
                    message: "\(money(spend.cost)) spent in \(max(1, Int(ceil(spend.seconds / 60)))) minutes. Review your model routing now.",
                    kind: .rapidSpend, recommendation: suggestion))
            }
        }
        return alerts
    }

    private static func money(_ value: Double) -> String { String(format: "$%.2f", value) }
}

/// Day/month alerts notify once per window; rapid spending at most once per hour.
/// The caller includes account identity in the key and persists successful deliveries only.
public struct WatchdogDeliveryLedger: Codable, Sendable {
    public var delivered: [String: Date] = [:]
    public init() {}
    public func shouldDeliver(_ alert: WatchdogAlert, account: String, now: Date) -> Bool {
        guard let last = delivered[account + "/" + alert.id] else { return true }
        return alert.kind == .rapidSpend && now.timeIntervalSince(last) >= 3_600
    }
    public mutating func record(_ alert: WatchdogAlert, account: String, now: Date) {
        delivered = delivered.filter { now.timeIntervalSince($0.value) < 62 * 86_400 }
        delivered[account + "/" + alert.id] = now
    }
}
