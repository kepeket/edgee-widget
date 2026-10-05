import XCTest
import UserNotifications
@testable import EdgeeCore
@testable import EdgeeWidget

@MainActor
final class WatchdogMonitorTests: XCTestCase {
    private let date = ISO8601DateFormatter().date(from: "2026-10-01T13:00:00Z")!
    private func withDefaults(_ body: (UserDefaults) async throws -> Void) async rethrows {
        let name = "WatchdogTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try await body(defaults)
    }
    private func refresh(_ monitor: WatchdogMonitor) async {
        monitor.refresh()
        let deadline = Date().addingTimeInterval(3)
        while monitor.isRefreshing, Date() < deadline { await Task.yield() }
        XCTAssertFalse(monitor.isRefreshing)
    }
    func testMonthlyDeliveryPersistsAcrossRestartAndUsesCalendarRegardlessOfOverview() async {
        await withDefaults { defaults in
            defaults.set("rolling", forKey: "usageWindowMode")
            let service = WatchdogServiceMock(date: date)
            var delivered: [WatchdogAlert] = []
            let monitor = WatchdogMonitor(service: service, defaults: defaults, now: { self.date }, deliver: { alert, _ in delivered.append(alert) })
            await refresh(monitor)
            await refresh(monitor)
            XCTAssertEqual(delivered.map(\.kind), [.monthlySpend])
            let reopened = WatchdogMonitor(service: service, defaults: defaults, now: { self.date }, deliver: { alert, _ in delivered.append(alert) })
            await refresh(reopened)
            XCTAssertEqual(delivered.count, 1)
            let modes = await service.modes
            XCTAssertTrue(modes.allSatisfy { $0 == .calendar })
            XCTAssertEqual(defaults.string(forKey: "usageWindowMode"), "rolling")
        }
    }
    func testDeliveryFailureIsVisibleAndRetried() async {
        await withDefaults { defaults in
            let service = WatchdogServiceMock(date: date)
            var attempts = 0
            let monitor = WatchdogMonitor(service: service, defaults: defaults, now: { self.date }, deliver: { _, _ in
                attempts += 1
                if attempts == 1 { throw WatchdogTestError.failure }
            })
            await refresh(monitor)
            XCTAssertNotNil(monitor.notifications.message)
            await refresh(monitor)
            XCTAssertEqual(attempts, 2)
            XCTAssertNil(monitor.notifications.message)
        }
    }
    func testDailyFailureDoesNotSuppressMonthlyProtection() async {
        await withDefaults { defaults in
            let service = WatchdogServiceMock(date: date, failDay: true)
            var delivered: [WatchdogAlert] = []
            let monitor = WatchdogMonitor(service: service, defaults: defaults, now: { self.date }, deliver: { alert, _ in delivered.append(alert) })
            await refresh(monitor)
            XCTAssertNil(monitor.day)
            XCTAssertNotNil(monitor.month)
            XCTAssertNotNil(monitor.error)
            XCTAssertEqual(delivered.map(\.kind), [.monthlySpend])
        }
    }
    func testDemoNeverFetchesNotifiesOrPersistsPreferences() async {
        await withDefaults { defaults in
            let service = WatchdogServiceMock(date: date)
            var sent = false
            let monitor = WatchdogMonitor(service: service, defaults: defaults, now: { self.date }, deliver: { _, _ in sent = true })
            monitor.setDemo(true)
            monitor.rules.monthlyLimit = 1
            await refresh(monitor)
            let modes = await service.modes
            XCTAssertTrue(modes.isEmpty)
            XCTAssertFalse(sent)
            XCTAssertNil(defaults.data(forKey: "watchdog.rules.v2"))
        }
    }
    func testRolesMigrateWithoutChangingOverviewBudget() async throws {
        try await withDefaults { defaults in
            var old = WatchdogSettings(dailySpendLimit: 42)
            old.modelRoleOverrides = ["opus": .executor]
            let data = try JSONEncoder().encode(old)
            defaults.set(data, forKey: "watchdogSettings")
            let monitor = WatchdogMonitor(service: WatchdogServiceMock(date: date), defaults: defaults)
            XCTAssertEqual(monitor.rules.modelRoles, old.modelRoleOverrides)
            monitor.rules.monthlyLimit = 999
            XCTAssertEqual(defaults.data(forKey: "watchdogSettings"), data)
        }
    }
    func testAccountSwitchDuringCheckSuppressesAlerts() async {
        await withDefaults { defaults in
            let service = WatchdogServiceMock(date: date, switchAccount: true)
            var sent = false
            let monitor = WatchdogMonitor(service: service, defaults: defaults, now: { self.date }, deliver: { _, _ in sent = true })
            await refresh(monitor)
            XCTAssertFalse(sent)
            XCTAssertTrue(monitor.alerts.isEmpty)
            XCTAssertNil(monitor.month)
            XCTAssertNotNil(monitor.error)
        }
    }
    func testNotificationContentHasNativeActionAndExplicitInterruptionLevel() {
        let alert = WatchdogAlert(id: "monthly/123", severity: .critical, title: "Budget", message: "$1,000 spent", kind: .monthlySpend)
        let standard = WatchdogNotifications.content(for: alert, timeSensitive: false)
        let urgent = WatchdogNotifications.content(for: alert, timeSensitive: true)
        XCTAssertEqual(standard.categoryIdentifier, WatchdogNotifications.category)
        XCTAssertEqual(standard.interruptionLevel, .active)
        XCTAssertEqual(urgent.interruptionLevel, .timeSensitive)
        XCTAssertEqual(urgent.userInfo["watchdogAlertID"] as? String, alert.id)
        XCTAssertEqual(urgent.threadIdentifier, "watchdog.monthlySpend")
    }
    func testRoutingActionOpensWatchdogPreviewWithoutChangingUsageSelectionOrAgentRoute() async {
        await withDefaults { defaults in
            let service = WatchdogServiceMock(date: date)
            let store = AppStore(service: service, demo: true, defaults: defaults)
            store.period = .week
            store.showSettings = true
            let originalAgents = store.agents
            let originalMenuTitle = store.statusTitle
            store.openWatchdog(alertID: "monthly/123", reviewRouting: true)
            XCTAssertEqual(store.selectedTab, .watchdog)
            XCTAssertFalse(store.showSettings)
            XCTAssertTrue(store.watchdog.showRouting)
            XCTAssertEqual(store.watchdog.selectedAlertID, "monthly/123")
            XCTAssertEqual(store.period, .week)
            XCTAssertEqual(store.agents, originalAgents)
            XCTAssertEqual(store.statusTitle, originalMenuTitle)
            let modes = await service.modes
            XCTAssertTrue(modes.isEmpty)
        }
    }
}

private enum WatchdogTestError: Error { case failure }
private actor WatchdogServiceMock: EdgeeServing {
    let date: Date
    let failDay: Bool
    let switchAccount: Bool
    var identities = 0
    var modes: [UsageWindowMode] = []
    init(date: Date, failDay: Bool = false, switchAccount: Bool = false) { self.date = date; self.failDay = failDay; self.switchAccount = switchAccount }
    func identity() async throws -> EdgeeIdentity {
        identities += 1
        return EdgeeIdentity(name: switchAccount && identities > 1 ? "other" : "member", organization: "org")
    }
    func usage(for period: UsagePeriod, mode: UsageWindowMode) async throws -> UsageSnapshot {
        modes.append(mode)
        if failDay && period == .day { throw WatchdogTestError.failure }
        return UsageSnapshot(period: period, totalCost: period == .month ? 1_100 : 5, totalTokens: 100,
            requests: 1, tokens: [], models: [], fetchedAt: date, scope: "member",
            window: UsageWindow(period: period, mode: mode, end: date))
    }
    func agents() async throws -> [AgentConfiguration] { [] }
    func availableModels(agentID: String) async throws -> [AvailableModel] { [] }
    func updateSetting(agentID: String, setting: AgentSetting, enabled: Bool) async throws { XCTFail("Unexpected setting mutation") }
    func updateRoute(agentID: String, modelID: String?) async throws { XCTFail("Unexpected route mutation") }
    func login() async throws { XCTFail("Unexpected login") }
}
