import Foundation
import XCTest
@testable import EdgeeWidget
@testable import EdgeeCore

@MainActor
final class AppStoreTests: XCTestCase {
    func testDemoMakesNoServiceCallsIncludingAgentMutations() async {
        let service = MockEdgeeService()
        let suite = isolatedDefaults()
        defer { suite.clear() }
        let store = AppStore(service: service, demo: true, defaults: suite.defaults)

        store.refresh()
        store.selectPeriod(.week)
        store.setAgentSetting("claude", setting: .toolCompression, enabled: false)
        store.setRoute("claude", model: "other-model")
        store.loadModels(for: "claude")
        store.selectPeriod(.month)
        await Task.yield()

        let calls = await service.calls()
        XCTAssertTrue(calls.isEmpty)
        XCTAssertEqual(store.period, .month)
        XCTAssertEqual(store.usage?.period, .month)
        XCTAssertEqual(store.dailyUsage?.period, .day)
    }

    func testWeekAndMonthSelectionsAlwaysMaintainDailySnapshot() async {
        let service = MockEdgeeService(
            dayPlans: [.success(snapshot(.day, cost: 1)), .success(snapshot(.day, cost: 2))],
            weekPlans: [.success(snapshot(.week, cost: 7))],
            monthPlans: [.success(snapshot(.month, cost: 30))]
        )
        let suite = isolatedDefaults()
        defer { suite.clear() }
        let store = AppStore(service: service, defaults: suite.defaults)

        store.selectPeriod(.week)
        await waitFor { store.usage?.period == .week && store.dailyUsage?.period == .day }
        store.selectPeriod(.month)
        await waitFor { store.usage?.period == .month && store.dailyUsage?.period == .day }

        XCTAssertEqual(store.period, .month)
        XCTAssertEqual(store.dailyUsage?.totalCost, 2)
        let usageRequests = await service.usageRequests()
        XCTAssertEqual(usageRequests, [.day, .week, .day, .month])
    }

    func testFailedWeekStillPublishesDailySnapshot() async {
        let service = MockEdgeeService(
            dayPlans: [.success(snapshot(.day, cost: 3))],
            weekPlans: [.failure]
        )
        let suite = isolatedDefaults()
        defer { suite.clear() }
        let store = AppStore(service: service, defaults: suite.defaults)

        store.selectPeriod(.week)
        await waitFor { !store.isRefreshing && store.errorMessage != nil }

        XCTAssertEqual(store.period, .week)
        XCTAssertEqual(store.dailyUsage?.period, .day)
        XCTAssertEqual(store.dailyUsage?.totalCost, 3)
        XCTAssertNil(store.usage)
    }

    func testRapidPeriodSwitchIgnoresStaleResult() async {
        let service = MockEdgeeService(
            dayPlans: [.success(snapshot(.day, cost: 1)), .success(snapshot(.day, cost: 2))],
            weekPlans: [.suspended(snapshot(.week, cost: 7))],
            monthPlans: [.success(snapshot(.month, cost: 30))]
        )
        let suite = isolatedDefaults()
        defer { suite.clear() }
        let store = AppStore(service: service, defaults: suite.defaults)

        store.selectPeriod(.week)
        await waitFor { await service.usageRequestCount(for: .week) == 1 }
        store.selectPeriod(.month)
        await waitFor { store.usage?.period == .month && store.dailyUsage?.totalCost == 2 }

        await service.resumeUsage(for: .week)
        await waitFor { await service.completedSuspendedUsageCount(for: .week) == 1 }
        await Task.yield()

        XCTAssertEqual(store.period, .month)
        XCTAssertEqual(store.usage?.period, .month)
        XCTAssertEqual(store.usage?.totalCost, 30)
        XCTAssertEqual(store.dailyUsage?.totalCost, 2)
    }

    func testFailedMutationRetainsOriginalAgentState() async {
        let service = MockEdgeeService(failMutations: true)
        let suite = isolatedDefaults()
        defer { suite.clear() }
        let store = AppStore(service: service, defaults: suite.defaults)
        let original = AgentConfiguration(id: "agent", name: "Agent", toolCompression: false, routedModel: "model-a")
        store.agents = [original]

        store.setAgentSetting("agent", setting: .toolCompression, enabled: true)
        await waitFor { !store.pendingAgents.contains("agent") && store.errorMessage != nil }

        XCTAssertEqual(store.agents, [original])
        let mutationCallCount = await service.mutationCallCount()
        XCTAssertEqual(mutationCallCount, 1)
    }

    func testSetRouteIsReadOnlyForLiveServiceWhileModelsStillLoad() async {
        let model = AvailableModel(id: "provider/model-b", name: "Model B")
        let service = MockEdgeeService(models: [model])
        let suite = isolatedDefaults()
        defer { suite.clear() }
        let store = AppStore(service: service, defaults: suite.defaults)
        let original = AgentConfiguration(id: "agent", name: "Agent", toolCompression: false, routedModel: "model-a")
        store.agents = [original]

        store.setRoute("agent", model: model.id)
        store.setRoute("agent", model: nil)
        store.loadModels(for: "agent")
        await waitFor { !store.loadingModels.contains("agent") }

        XCTAssertEqual(store.agents, [original])
        XCTAssertEqual(store.modelsByAgent["agent"], [model])
        let calls = await service.calls()
        XCTAssertEqual(calls, [.availableModels])
    }

    func testSetRouteIsReadOnlyForDemoAgentIncludingPassthrough() async throws {
        let service = MockEdgeeService()
        let suite = isolatedDefaults()
        defer { suite.clear() }
        let store = AppStore(service: service, demo: true, defaults: suite.defaults)
        let originalAgents = store.agents
        let agent = try XCTUnwrap(originalAgents.first)

        store.setRoute(agent.id, model: "other-model")
        store.setRoute(agent.id, model: nil)

        XCTAssertEqual(store.agents, originalAgents)
        let calls = await service.calls()
        XCTAssertFalse(calls.contains(.updateRoute))
    }

    func testModelLoadFailureIsVisibleInPickerAndRetryRecovers() async {
        let model = AvailableModel(id: "provider/model-b", name: "Model B")
        let service = MockEdgeeService(modelFailures: 1, models: [model])
        let suite = isolatedDefaults()
        defer { suite.clear() }
        let store = AppStore(service: service, defaults: suite.defaults)

        store.loadModels(for: "claude")
        await waitFor { !store.loadingModels.contains("claude") }
        XCTAssertEqual(store.modelErrors["claude"], "Planned test failure")
        XCTAssertNil(store.errorMessage)
        XCTAssertNil(store.modelsByAgent["claude"])

        store.loadModels(for: "claude")
        XCTAssertNil(store.modelErrors["claude"])
        await waitFor { !store.loadingModels.contains("claude") }
        XCTAssertEqual(store.modelsByAgent["claude"], [model])
        XCTAssertNil(store.modelErrors["claude"])
    }

    private func waitFor(
        timeout: TimeInterval = 1,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else {
                XCTFail("Timed out waiting for asynchronous state", file: file, line: line)
                return
            }
            await Task.yield()
        }
    }

    private func isolatedDefaults() -> DefaultsSuite {
        let name = "AppStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return DefaultsSuite(name: name, defaults: defaults)
    }

    private func snapshot(_ period: UsagePeriod, cost: Double) -> UsageSnapshot {
        UsageSnapshot(
            period: period,
            totalCost: cost,
            totalTokens: 100,
            requests: 1,
            tokens: [],
            models: [],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000),
            scope: "Test account"
        )
    }
}

private struct DefaultsSuite {
    let name: String
    let defaults: UserDefaults

    func clear() {
        defaults.removePersistentDomain(forName: name)
    }
}

private actor MockEdgeeService: EdgeeServing {
    enum UsagePlan: Sendable {
        case success(UsageSnapshot)
        case failure
        case suspended(UsageSnapshot)
    }

    enum MockError: Error, LocalizedError, Sendable {
        case plannedFailure

        var errorDescription: String? { "Planned test failure" }
    }

    enum Call: Sendable, Equatable {
        case identity
        case usage(UsagePeriod)
        case agents
        case availableModels
        case updateSetting
        case updateRoute
        case login
    }

    private var plans: [String: [UsagePlan]]
    private var suspended: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var completedSuspended: [String: Int] = [:]
    private var recordedCalls: [Call] = []
    private let failMutations: Bool
    private var modelFailures: Int
    private let models: [AvailableModel]

    init(
        dayPlans: [UsagePlan] = [],
        weekPlans: [UsagePlan] = [],
        monthPlans: [UsagePlan] = [],
        failMutations: Bool = false,
        modelFailures: Int = 0,
        models: [AvailableModel] = []
    ) {
        plans = [
            UsagePeriod.day.rawValue: dayPlans,
            UsagePeriod.week.rawValue: weekPlans,
            UsagePeriod.month.rawValue: monthPlans
        ]
        self.failMutations = failMutations
        self.modelFailures = modelFailures
        self.models = models
    }

    func identity() async throws -> EdgeeIdentity {
        recordedCalls.append(.identity)
        return EdgeeIdentity(name: "test@example.com", organization: "Test account")
    }

    func usage(for period: UsagePeriod) async throws -> UsageSnapshot {
        recordedCalls.append(.usage(period))
        let key = period.rawValue
        var periodPlans = plans[key] ?? []
        let plan = periodPlans.isEmpty ? .success(defaultSnapshot(for: period)) : periodPlans.removeFirst()
        plans[key] = periodPlans

        switch plan {
        case let .success(snapshot):
            return snapshot
        case .failure:
            throw MockError.plannedFailure
        case let .suspended(snapshot):
            await withCheckedContinuation { continuation in
                suspended[key, default: []].append(continuation)
            }
            completedSuspended[key, default: 0] += 1
            return snapshot
        }
    }

    func agents() async throws -> [AgentConfiguration] {
        recordedCalls.append(.agents)
        return []
    }

    func availableModels(agentID: String) async throws -> [AvailableModel] {
        recordedCalls.append(.availableModels)
        if modelFailures > 0 { modelFailures -= 1; throw MockError.plannedFailure }
        return models
    }

    func updateSetting(agentID: String, setting: AgentSetting, enabled: Bool) async throws {
        recordedCalls.append(.updateSetting)
        if failMutations { throw MockError.plannedFailure }
    }

    func updateRoute(agentID: String, modelID: String?) async throws {
        recordedCalls.append(.updateRoute)
        if failMutations { throw MockError.plannedFailure }
    }

    func login() async throws {
        recordedCalls.append(.login)
    }

    func calls() -> [Call] { recordedCalls }

    func usageRequests() -> [UsagePeriod] {
        recordedCalls.compactMap {
            guard case let .usage(period) = $0 else { return nil }
            return period
        }
    }

    func usageRequestCount(for period: UsagePeriod) -> Int {
        recordedCalls.count { call in
            guard case let .usage(requested) = call else { return false }
            return requested == period
        }
    }

    func resumeUsage(for period: UsagePeriod) {
        let key = period.rawValue
        guard var continuations = suspended[key], !continuations.isEmpty else { return }
        let continuation = continuations.removeFirst()
        suspended[key] = continuations
        continuation.resume()
    }

    func completedSuspendedUsageCount(for period: UsagePeriod) -> Int {
        completedSuspended[period.rawValue, default: 0]
    }

    func mutationCallCount() -> Int {
        recordedCalls.count { $0 == .updateSetting || $0 == .updateRoute }
    }

    private func defaultSnapshot(for period: UsagePeriod) -> UsageSnapshot {
        UsageSnapshot(
            period: period,
            totalCost: 1,
            totalTokens: 100,
            requests: 1,
            tokens: [],
            models: [],
            scope: "Test account"
        )
    }
}
