import XCTest
@testable import EdgeeCore

final class WatchdogRulesTests: XCTestCase {
    private let noon = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }
    private func snapshot(_ period: UsagePeriod, cost: Double = 0, date: Date? = nil, thinking: Double = 60) -> UsageSnapshot {
        let date = date ?? noon
        return UsageSnapshot(period: period, totalCost: cost, totalTokens: 100, requests: 1, tokens: [],
            models: [ModelUsage(id: "anthropic/claude-opus-4.6", name: "Opus", tokens: thinking, cost: 1, requests: 1)],
            fetchedAt: date, scope: "member", window: UsageWindow(period: period, mode: .calendar, end: date))
    }
    private func evaluate(day: UsageSnapshot? = nil, month: UsageSnapshot? = nil, history: [SpendObservation] = [], rules: WatchdogRules = WatchdogRules(), now: Date? = nil) -> [WatchdogAlert] {
        WatchdogRulesEngine.evaluate(day: day, month: month, history: history, rules: rules, now: now ?? noon, calendar: utc)
    }
    func testThinkingUsesTokenMajorityAndLocalNoon() {
        let morning = noon.addingTimeInterval(-60)
        XCTAssertTrue(evaluate(day: snapshot(.day, date: morning), now: morning).isEmpty)
        XCTAssertEqual(evaluate(day: snapshot(.day)).map(\.kind), [.thinkingTokens])
        XCTAssertTrue(evaluate(day: snapshot(.day, thinking: 50)).isEmpty)
        XCTAssertTrue(evaluate(day: snapshot(.day, thinking: 0)).isEmpty)
        var paris = utc; paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        XCTAssertEqual(WatchdogRulesEngine.evaluate(day: snapshot(.day, date: morning), month: nil, history: [], rules: WatchdogRules(), now: morning, calendar: paris).count, 1)
    }
    func testRolesOverrideFamilyAndUnknownTokensStayInDenominator() {
        var rules = WatchdogRules()
        rules.modelRoles["anthropic/claude-opus-4.6"] = .executor
        XCTAssertTrue(evaluate(day: snapshot(.day), rules: rules).isEmpty)
        XCTAssertTrue(evaluate(day: snapshot(.day, thinking: 40)).isEmpty)
        XCTAssertTrue(evaluate(day: snapshot(.day, thinking: 101)).isEmpty)
    }
    func testMonthlyBoundaryAndThreshold() {
        XCTAssertTrue(evaluate(month: snapshot(.month, cost: 999.99)).isEmpty)
        XCTAssertEqual(evaluate(month: snapshot(.month, cost: 1_000)).map(\.kind), [.monthlySpend])
        let yesterday = noon.addingTimeInterval(-86_400)
        XCTAssertTrue(evaluate(month: snapshot(.month, cost: 9_000, date: yesterday)).isEmpty)
        var rolling = snapshot(.month, cost: 9_000)
        rolling.window = UsageWindow(period: .month, mode: .rolling, end: noon)
        XCTAssertTrue(evaluate(month: rolling).isEmpty)
    }
    func testBurnUsesActualAccumulatedSpendNotProjectedRate() {
        var history: [SpendObservation] = []
        WatchdogRulesEngine.record(snapshot(.month, cost: 100, date: noon.addingTimeInterval(-1_800)), in: &history)
        WatchdogRulesEngine.record(snapshot(.month, cost: 125, date: noon.addingTimeInterval(-600)), in: &history)
        let current = snapshot(.month, cost: 150)
        WatchdogRulesEngine.record(current, in: &history)
        XCTAssertEqual(evaluate(month: current, history: history).map(\.kind), [.rapidSpend])
        XCTAssertTrue(evaluate(month: snapshot(.month, cost: 149), history: history).isEmpty)
        // $1 in one second would extrapolate to $3,600/hour, but must not alert.
        let tinyHistory = [SpendObservation(snapshot: snapshot(.month, cost: 149, date: noon.addingTimeInterval(-1)))]
        XCTAssertTrue(evaluate(month: current, history: tinyHistory).isEmpty)
    }
    func testOneHourIsExcludedAndBaselineNeeded() {
        let month = snapshot(.month, cost: 200)
        let history = [SpendObservation(snapshot: snapshot(.month, cost: 0, date: noon.addingTimeInterval(-3_600)))]
        XCTAssertTrue(evaluate(month: month, history: history).isEmpty)
        XCTAssertTrue(evaluate(month: month).isEmpty)
    }
    func testHistoryResetsForMonthScopeOrCostResetAndRejectsOldSamples() {
        let old = snapshot(.month, cost: 100, date: noon.addingTimeInterval(-60))
        var history = [SpendObservation(snapshot: old)]
        WatchdogRulesEngine.record(snapshot(.month, cost: 5), in: &history)
        XCTAssertEqual(history.count, 1)
        WatchdogRulesEngine.record(old, in: &history)
        XCTAssertEqual(history.count, 1)
        var next = snapshot(.month, cost: 100, date: noon.addingTimeInterval(60)); next.scope = "another member"
        WatchdogRulesEngine.record(next, in: &history)
        XCTAssertEqual(history.count, 1)
        let nextMonth = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
        WatchdogRulesEngine.record(snapshot(.month, cost: 200, date: nextMonth), in: &history)
        XCTAssertEqual(history.count, 1)
    }
    func testDisabledInvalidAndStaleRulesDoNotNotify() {
        var rules = WatchdogRules(); rules.thinkingEnabled = false; rules.monthlyEnabled = false; rules.rapidSpendEnabled = false
        XCTAssertTrue(evaluate(day: snapshot(.day), month: snapshot(.month, cost: 2_000), rules: rules).isEmpty)
        rules = WatchdogRules(); rules.thinkingShare = .nan; rules.monthlyLimit = .infinity; rules.rapidSpendLimit = -1
        XCTAssertTrue(evaluate(day: snapshot(.day), month: snapshot(.month, cost: 2_000), rules: rules).isEmpty)
        XCTAssertTrue(evaluate(day: snapshot(.day), month: snapshot(.month, cost: 2_000), now: noon.addingTimeInterval(301)).isEmpty)
        XCTAssertTrue(evaluate(day: snapshot(.day, date: noon.addingTimeInterval(1))).isEmpty)
    }
    func testLedgerPersistsScopesAndRateLimits() throws {
        let alert = evaluate(month: snapshot(.month, cost: 1_000))[0]
        var ledger = WatchdogDeliveryLedger()
        XCTAssertTrue(ledger.shouldDeliver(alert, account: "a", now: noon))
        ledger.record(alert, account: "a", now: noon)
        ledger = try JSONDecoder().decode(WatchdogDeliveryLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertFalse(ledger.shouldDeliver(alert, account: "a", now: noon.addingTimeInterval(7_200)))
        XCTAssertTrue(ledger.shouldDeliver(alert, account: "b", now: noon))
        let nextMonth = ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z")!
        let newAlert = evaluate(month: snapshot(.month, cost: 1_000, date: nextMonth), now: nextMonth)[0]
        XCTAssertTrue(ledger.shouldDeliver(newAlert, account: "a", now: nextMonth))
        let burn = WatchdogAlert(id: "rapid-spend", severity: .critical, title: "Burn", message: "", kind: .rapidSpend)
        ledger.record(burn, account: "a", now: noon)
        XCTAssertFalse(ledger.shouldDeliver(burn, account: "a", now: noon.addingTimeInterval(3_599)))
        XCTAssertTrue(ledger.shouldDeliver(burn, account: "a", now: noon.addingTimeInterval(3_600)))
    }
}
