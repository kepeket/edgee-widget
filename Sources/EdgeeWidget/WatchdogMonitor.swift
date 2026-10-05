import Foundation
import EdgeeCore

/// Owns calendar monitoring independently of the Overview/menu bar selection.
@MainActor
final class WatchdogMonitor: ObservableObject {
    @Published var rules: WatchdogRules {
        didSet {
            if !isDemo, let data = try? JSONEncoder().encode(rules) { defaults.set(data, forKey: "watchdog.rules.v2") }
            evaluate()
        }
    }
    @Published private(set) var day: UsageSnapshot?
    @Published private(set) var month: UsageSnapshot?
    @Published private(set) var alerts: [WatchdogAlert] = []
    @Published private(set) var history: [SpendObservation] = []
    @Published private(set) var lastChecked: Date?
    @Published private(set) var error: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var isDemo = false
    @Published var showRouting = false
    @Published var selectedAlertID: String?
    let notifications: WatchdogNotifications
    var onAlertsChange: (([WatchdogAlert]) -> Void)?
    private let service: any EdgeeServing
    private let defaults: UserDefaults
    private let now: () -> Date
    private let deliver: ((WatchdogAlert, String) async throws -> Void)?
    private var ledger: WatchdogDeliveryLedger
    private var accountKey: String?
    private var generation = 0
    private var loop: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    init(service: any EdgeeServing, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         deliver: ((WatchdogAlert, String) async throws -> Void)? = nil) {
        self.service = service; self.defaults = defaults; self.now = now; self.deliver = deliver
        notifications = WatchdogNotifications(defaults: defaults)
        var settings = WatchdogRules()
        if let data = defaults.data(forKey: "watchdog.rules.v2"), let saved = try? JSONDecoder().decode(WatchdogRules.self, from: data) {
            settings = saved
        } else if let data = defaults.data(forKey: "watchdogSettings"), let legacy = try? JSONDecoder().decode(WatchdogSettings.self, from: data) {
            settings.modelRoles = legacy.modelRoleOverrides
        }
        rules = settings
        ledger = defaults.data(forKey: "watchdog.deliveries.v2").flatMap { try? JSONDecoder().decode(WatchdogDeliveryLedger.self, from: $0) } ?? WatchdogDeliveryLedger()
    }

    func start() {
        guard loop == nil else { return }
        refresh()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }
    func stop() {
        loop?.cancel(); loop = nil
        refreshTask?.cancel(); refreshTask = nil
        generation += 1; isRefreshing = false
    }

    func setDemo(_ value: Bool) {
        refreshTask?.cancel(); generation += 1; isRefreshing = false
        isDemo = value; day = nil; month = nil; history = []; alerts = []; error = nil; lastChecked = nil; accountKey = nil
        showRouting = false; selectedAlertID = nil
        if value {
            day = DemoData.usage(.day, mode: .calendar, now: now())
            month = DemoData.usage(.month, mode: .calendar, now: now())
            lastChecked = now()
        } else {
            if let data = defaults.data(forKey: "watchdog.rules.v2"), let saved = try? JSONDecoder().decode(WatchdogRules.self, from: data) {
                rules = saved
            } else {
                var saved = WatchdogRules()
                if let data = defaults.data(forKey: "watchdogSettings"), let legacy = try? JSONDecoder().decode(WatchdogSettings.self, from: data) {
                    saved.modelRoles = legacy.modelRoleOverrides
                }
                rules = saved
            }
        }
        evaluate()
        if !value, loop != nil { refresh() }
    }

    func refresh() {
        guard !isDemo else { return }
        guard !isRefreshing else { return }
        generation += 1
        let ticket = generation
        isRefreshing = true
        // Stale values never masquerade as active alerts while a request is in flight.
        evaluate()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if ticket == self.generation { self.isRefreshing = false } }
            do {
                let identity = try await self.service.identity()
                guard ticket == self.generation else { return }
                let key = Self.accountKey(identity)
                if key != self.accountKey {
                    self.accountKey = key
                    self.day = nil; self.month = nil; self.alerts = []; self.history = []; self.lastChecked = nil
                    self.onAlertsChange?([])
                    if let data = self.defaults.data(forKey: "watchdog.history." + key),
                       let saved = try? JSONDecoder().decode([SpendObservation].self, from: data) { self.history = saved }
                }
                // Fail independently: monthly spending protection survives a failed daily request.
                var failures: [String] = []
                do {
                    let day = try await self.service.usage(for: .day, mode: .calendar)
                    guard ticket == self.generation else { return }
                    guard WatchdogRulesEngine.isFresh(day, period: .day, now: self.now()) else { throw WatchdogReadError.stale }
                    self.day = day
                } catch {
                    guard ticket == self.generation else { return }
                    self.day = nil; failures.append("Today's tokens: \(error.localizedDescription)")
                }
                do {
                    let month = try await self.service.usage(for: .month, mode: .calendar)
                    guard ticket == self.generation else { return }
                    guard WatchdogRulesEngine.isFresh(month, period: .month, now: self.now()) else { throw WatchdogReadError.stale }
                    self.month = month
                    WatchdogRulesEngine.record(month, in: &self.history)
                } catch {
                    guard ticket == self.generation else { return }
                    self.month = nil; failures.append("Spending: \(error.localizedDescription)")
                }
                // Never associate data fetched across an account switch with the old identity.
                let finalIdentity = try await self.service.identity()
                guard ticket == self.generation else { return }
                guard finalIdentity == identity else { throw WatchdogReadError.accountChanged }
                if let data = try? JSONEncoder().encode(self.history) { self.defaults.set(data, forKey: "watchdog.history." + key) }
                self.error = failures.isEmpty ? nil : failures.joined(separator: "\n")
                self.lastChecked = self.now()
                self.evaluate()
                if self.deliver == nil { await self.notifications.refreshStatus() }
                guard ticket == self.generation else { return }
                await self.sendAlerts(account: key, ticket: ticket)
            } catch {
                guard ticket == self.generation else { return }
                self.day = nil; self.month = nil; self.history = []; self.alerts = []
                self.onAlertsChange?([])
                self.error = error.localizedDescription
            }
        }
    }

    private func evaluate() {
        alerts = WatchdogRulesEngine.evaluate(day: day, month: month, history: history, rules: rules, now: now())
        onAlertsChange?(alerts)
    }

    private func sendAlerts(account: String, ticket: Int) async {
        guard !isDemo, deliver != nil || notifications.canDeliver else { return }
        for alert in alerts {
            guard ticket == generation, !isDemo,
                  deliver != nil || notifications.canDeliver,
                  self.alerts.contains(where: { $0.id == alert.id }),
                  ledger.shouldDeliver(alert, account: account, now: now()) else { continue }
            do {
                let key = "watchdog/" + account + "/" + alert.id
                if let deliver { try await deliver(alert, key) }
                else { try await notifications.send(alert, key: key) }
                guard ticket == generation else { return }
                notifications.message = nil
                ledger.record(alert, account: account, now: now())
                if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: "watchdog.deliveries.v2") }
            } catch { notifications.message = "Notification failed: \(error.localizedDescription). Watchdog will retry on the next check." }
        }
    }

    private static func accountKey(_ identity: EdgeeIdentity) -> String {
        // Length-delimited fields prevent ambiguous account keys; no credentials are stored.
        [identity.profile ?? "", identity.organization, identity.name].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

private enum WatchdogReadError: LocalizedError {
    case stale, accountChanged
    var errorDescription: String? {
        switch self {
        case .stale: return "Fresh calendar usage is unavailable. Retrying on the next check."
        case .accountChanged: return "Account changed during the check. Retrying with the current account."
        }
    }
}
