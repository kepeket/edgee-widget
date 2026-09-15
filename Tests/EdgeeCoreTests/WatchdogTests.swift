import XCTest
@testable import EdgeeCore

final class WatchdogTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    func testDefaultsMatchProductLimits() {
        let settings = WatchdogSettings()

        XCTAssertEqual(settings.dailySpendLimit, 20)
        XCTAssertEqual(settings.dailyTokenLimit, 10_000_000)
        XCTAssertEqual(settings.maximumFrontierCostShare, 0.65)
        XCTAssertEqual(settings.maximumThinkingToExecutorCostRatio, 0.5)
    }

    func testDailySpendWarnsAtBoundaryAndBecomesCriticalAtLimit() throws {
        var settings = WatchdogSettings(modelRoleOverrides: [:])
        let warning = WatchdogEngine.evaluate(
            snapshot: snapshot(cost: 16, tokens: 0), previous: nil, settings: settings
        )
        XCTAssertEqual(warning.first(where: { $0.kind == .dailySpend })?.severity, .warning)

        settings.dailySpendLimit = 16
        let critical = WatchdogEngine.evaluate(
            snapshot: snapshot(cost: 16, tokens: 0), previous: nil, settings: settings
        )
        let alert = try XCTUnwrap(critical.first(where: { $0.kind == .dailySpend }))
        XCTAssertEqual(alert.severity, .critical)
        XCTAssertEqual(alert.id, "daily-spend")
        XCTAssertTrue(alert.message.contains("trailing 24-hour"))
    }

    func testDailyTokenLimitDoesNotAlertBelowBoundary() {
        let settings = WatchdogSettings()
        let alerts = WatchdogEngine.evaluate(
            snapshot: snapshot(cost: 0, tokens: 7_999_999), previous: nil, settings: settings
        )

        XCTAssertFalse(alerts.contains { $0.kind == .dailyTokens })
    }

    func testExplicitRoleOverrideWinsAndIsReported() {
        let model = ModelUsage(id: "astra", name: "Astra", tokens: 1, cost: 4, requests: 1)
        let settings = WatchdogSettings(modelRoleOverrides: ["astra": .executor])

        XCTAssertEqual(
            WatchdogEngine.classify(model, settings: settings),
            WatchdogModelClassification(role: .executor, source: .explicitOverride)
        )
    }

    func testCatalogHeuristicsAreLabeled() {
        let settings = WatchdogSettings()
        let roles = ["Opus", "o3", "Sonnet", "Haiku"].map { name in
            WatchdogEngine.classify(ModelUsage(id: name, name: name, tokens: 0, cost: 0, requests: 0), settings: settings)
        }

        XCTAssertEqual(roles.map(\.role), [.frontier, .thinking, .balanced, .executor])
        XCTAssertEqual(roles.map(\.source), Array(repeating: .namingHeuristic, count: 4))
    }

    func testFrontierShareAndThinkingRatioAlertBeyondConfiguredLimits() {
        let settings = WatchdogSettings(
            dailySpendLimit: 100,
            dailyTokenLimit: 1_000,
            maximumFrontierCostShare: 0.65,
            maximumThinkingToExecutorCostRatio: 0.5,
            modelRoleOverrides: ["thinking": .thinking, "executor": .executor]
        )
        let usage = snapshot(cost: 100, tokens: 1, models: [
            ModelUsage(id: "opus", name: "Opus", tokens: 1, cost: 70, requests: 1),
            ModelUsage(id: "thinking", name: "Custom thinking", tokens: 1, cost: 20, requests: 1),
            ModelUsage(id: "executor", name: "Custom executor", tokens: 1, cost: 10, requests: 1)
        ])

        let alerts = WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: settings)

        let frontier = alerts.first(where: { $0.kind == .frontierShare })
        XCTAssertEqual(frontier?.id, "frontier-share")
        XCTAssertTrue(frontier?.message.contains("trailing 24-hour") == true)
        XCTAssertTrue(frontier?.message.contains("naming heuristic") == true)
        XCTAssertEqual(alerts.first(where: { $0.kind == .thinkingToExecutorRatio })?.id, "thinking-executor-ratio")
    }

    func testFrontierShareAtExactLimitDoesNotAlert() {
        let settings = WatchdogSettings(dailySpendLimit: 100, dailyTokenLimit: 1_000)
        let usage = snapshot(cost: 100, tokens: 1, models: [
            ModelUsage(id: "opus", name: "Opus", tokens: 1, cost: 65, requests: 1),
            ModelUsage(id: "sonnet", name: "Sonnet", tokens: 1, cost: 35, requests: 1)
        ])

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: settings).contains { $0.kind == .frontierShare })
    }

    func testThinkingExecutorRatioRequiresExplicitRoles() {
        let settings = WatchdogSettings(dailySpendLimit: 100, dailyTokenLimit: 1_000)
        let usage = snapshot(cost: 10, tokens: 1, models: [
            ModelUsage(id: "o3", name: "o3", tokens: 1, cost: 8, requests: 1),
            ModelUsage(id: "haiku", name: "Haiku", tokens: 1, cost: 2, requests: 1)
        ])

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: settings).contains { $0.kind == .thinkingToExecutorRatio })
    }

    func testFirstFetchDoesNotProduceSessionRateAlert() {
        let usage = snapshot(cost: 1, tokens: 1, sessions: [session(cost: 10)])

        let alerts = WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: WatchdogSettings())

        XCTAssertFalse(alerts.contains { $0.kind == .sessionCostIncrease })
    }

    func testSessionRateUsesElapsedTimeAndHasStableID() throws {
        let earlier = snapshot(cost: 1, tokens: 1, sessions: [session(cost: 1)], fetchedAt: day)
        let current = snapshot(cost: 4, tokens: 1, sessions: [session(cost: 4)], fetchedAt: day.addingTimeInterval(3_600))
        let previous = WatchdogObservation(snapshot: earlier)
        let settings = WatchdogSettings(maximumSessionCostIncreasePerHour: 2, minimumSessionCostIncrease: 0.25)

        let alerts = WatchdogEngine.evaluate(snapshot: current, previous: previous, settings: settings)
        let alert = try XCTUnwrap(alerts.first(where: { $0.kind == .sessionCostIncrease }))
        XCTAssertEqual(alert.id, "session-cost-increase/session-1")
        XCTAssertEqual(alert.severity, .warning)
        XCTAssertTrue(alert.message.contains("$3.00/hour"))
    }

    func testStaleAndNonMonotonicSamplesDoNotProduceSessionRateAlert() {
        let base = snapshot(cost: 1, tokens: 1, sessions: [session(cost: 1)], fetchedAt: day)
        let observation = WatchdogObservation(snapshot: base)
        let stale = snapshot(cost: 10, tokens: 1, sessions: [session(cost: 10)], fetchedAt: day.addingTimeInterval(7 * 3_600))
        let backward = snapshot(cost: 10, tokens: 1, sessions: [session(cost: 10)], fetchedAt: day.addingTimeInterval(-3_600))
        let settings = WatchdogSettings(maximumSessionCostIncreasePerHour: 1)

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: stale, previous: observation, settings: settings).contains { $0.kind == .sessionCostIncrease })
        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: backward, previous: observation, settings: settings).contains { $0.kind == .sessionCostIncrease })
    }

    func testSessionCounterResetDoesNotProduceRateAlert() {
        let base = snapshot(cost: 10, tokens: 1, sessions: [session(cost: 10)], fetchedAt: day)
        let reset = snapshot(cost: 1, tokens: 1, sessions: [session(cost: 1)], fetchedAt: day.addingTimeInterval(3_600))
        let observation = WatchdogObservation(snapshot: base)

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: reset, previous: observation, settings: WatchdogSettings()).contains { $0.kind == .sessionCostIncrease })
    }

    func testDuplicateSessionIDsDoNotTrapOrProduceRateAlert() {
        let base = snapshot(cost: 1, tokens: 1, sessions: [
            session(cost: 1),
            session(cost: 2)
        ], fetchedAt: day)
        let current = snapshot(
            cost: 10,
            tokens: 1,
            sessions: [session(cost: 9)],
            fetchedAt: day.addingTimeInterval(3_600)
        )

        let alerts = WatchdogEngine.evaluate(
            snapshot: current,
            previous: WatchdogObservation(snapshot: base),
            settings: WatchdogSettings(maximumSessionCostIncreasePerHour: 1)
        )

        XCTAssertFalse(alerts.contains { $0.kind == .sessionCostIncrease })
    }

    func testScopeMismatchAndStaleSessionTimestampDoNotProduceRateAlert() {
        let base = snapshot(
            cost: 1,
            tokens: 1,
            sessions: [session(cost: 1, updatedAt: day)],
            fetchedAt: day
        )
        let observation = WatchdogObservation(snapshot: base)
        let settings = WatchdogSettings(maximumSessionCostIncreasePerHour: 1)
        var changedScope = snapshot(
            cost: 4,
            tokens: 1,
            sessions: [session(cost: 4, updatedAt: day.addingTimeInterval(3_600))],
            fetchedAt: day.addingTimeInterval(3_600)
        )
        changedScope.scope = "Another account"
        let staleSession = snapshot(
            cost: 4,
            tokens: 1,
            sessions: [session(cost: 4, updatedAt: day)],
            fetchedAt: day.addingTimeInterval(3_600)
        )

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: changedScope, previous: observation, settings: settings).contains { $0.kind == .sessionCostIncrease })
        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: staleSession, previous: observation, settings: settings).contains { $0.kind == .sessionCostIncrease })
    }

    func testNonFiniteMetricsDoNotProduceAlerts() {
        let prior = snapshot(cost: 1, tokens: 1, sessions: [session(cost: 1)], fetchedAt: day)
        let malformed = snapshot(
            cost: .nan,
            tokens: .infinity,
            models: [
                ModelUsage(id: "opus", name: "Opus", tokens: .infinity, cost: .infinity, requests: 1),
                ModelUsage(id: "thinking", name: "Thinking", tokens: 1, cost: .nan, requests: 1)
            ],
            sessions: [session(cost: .infinity)],
            fetchedAt: day.addingTimeInterval(3_600)
        )
        let settings = WatchdogSettings(
            maximumSessionCostIncreasePerHour: 1,
            modelRoleOverrides: ["thinking": .thinking]
        )

        XCTAssertTrue(WatchdogEngine.evaluate(
            snapshot: malformed,
            previous: WatchdogObservation(snapshot: prior),
            settings: settings
        ).isEmpty)
    }

    func testNonDailySnapshotIsIgnored() {
        var usage = snapshot(cost: 100, tokens: 100)
        usage.period = .week

        XCTAssertTrue(WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: WatchdogSettings()).isEmpty)
    }

    private func snapshot(
        cost: Double,
        tokens: Double,
        models: [ModelUsage] = [],
        sessions: [SessionUsage] = [],
        fetchedAt: Date? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            period: .day,
            totalCost: cost,
            totalTokens: tokens,
            requests: 1,
            tokens: [],
            models: models,
            sessions: sessions,
            fetchedAt: fetchedAt ?? day
        )
    }

    private func session(cost: Double, updatedAt: Date? = nil, id: String = "session-1") -> SessionUsage {
        SessionUsage(id: id, name: "Build feature", cost: cost, tokens: 1, updatedAt: updatedAt)
    }
}
