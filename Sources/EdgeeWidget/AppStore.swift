import AppKit
import Foundation
import SwiftUI
import UserNotifications
import EdgeeCore

@MainActor final class AppStore: ObservableObject {
    @Published var period: UsagePeriod = .day
    @Published var usage: UsageSnapshot?
    @Published var dailyUsage: UsageSnapshot?
    @Published var identity: EdgeeIdentity?
    @Published var agents: [AgentConfiguration] = []
    @Published var modelsByAgent: [String: [AvailableModel]] = [:]
    @Published var pendingAgents: Set<String> = []
    @Published var loadingModels: Set<String> = []
    @Published var isRefreshing = false
    @Published var isLoggingIn = false
    @Published var isDemo = false
    @Published var errorMessage: String?
    @Published var lastRefresh: Date?
    @Published var alerts: [WatchdogAlert] = []
    @Published var watchdogSettings: WatchdogSettings {
        didSet { if !isDemo { persistSettings() }; reevaluateWatchdog() }
    }
    @Published var notificationsEnabled: Bool
    @Published var selectedTab: PanelTab = .overview
    @Published var showSettings = false
    @Published var pinned = false
    var onStatusChange: (() -> Void)?
    var onPinChange: ((Bool) -> Void)?
    private let defaults: UserDefaults
    private let service: any EdgeeServing
    private var pollTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var previousObservation: WatchdogObservation?
    private var deliveredAlerts: [String: Date] = [:]
    private var generation = 0

    init(service: any EdgeeServing = EdgeeService(), demo: Bool = false, defaults: UserDefaults = .standard) {
        self.service = service
        self.defaults = defaults
        self.notificationsEnabled = defaults.bool(forKey: "notificationsEnabled")
        if let data = defaults.data(forKey: "watchdogSettings"), let value = try? JSONDecoder().decode(WatchdogSettings.self, from: data) { watchdogSettings = value }
        else { watchdogSettings = WatchdogSettings() }
        if demo { enterDemo() }
    }
    var statusTitle: String {
        guard let dailyUsage else { return "—" }
        return Display.money(dailyUsage.totalCost) + (isDemo ? " ◇" : errorMessage != nil ? " !" : "")
    }
    var statusDescription: String {
        if isDemo { return "Edgee · Demo data" }
        guard let dailyUsage else { return "Edgee · Connect your account" }
        return "Your Edgee spend · last 24 hours: \(Display.money(dailyUsage.totalCost))" + (errorMessage != nil ? " · Data may be stale" : "")
    }
    func start() {
        guard pollTask == nil else { return }
        if !isDemo { refresh() }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled, let self else { return }
                if !self.isDemo { self.refresh() }
            }
        }
    }
    func stop() { pollTask?.cancel(); refreshTask?.cancel() }
    func selectPeriod(_ next: UsagePeriod) {
        guard next != period else { return }
        period = next
        if isDemo { usage = DemoData.usage(next); return }
        usage = nil
        refresh(force: true)
    }
    func refresh(force: Bool = false) {
        if isDemo { usage = DemoData.usage(period); dailyUsage = DemoData.usage(.day); lastRefresh = Date(); onStatusChange?(); return }
        if isRefreshing && !force { return }
        if force { refreshTask?.cancel() }
        generation += 1
        let ticket = generation
        let requestedPeriod = period
        isRefreshing = true
        refreshTask = Task { [weak self] in
            guard let self else { return }
            defer { if ticket == self.generation { self.isRefreshing = false; self.onStatusChange?() } }
            do {
                let account = try await self.service.identity()
                guard ticket == self.generation, !Task.isCancelled else { return }
                if let old = self.identity, old != account {
                    self.usage = nil; self.dailyUsage = nil; self.agents = []; self.modelsByAgent = [:]
                    self.previousObservation = nil; self.deliveredAlerts = [:]; self.alerts = []
                }
                self.identity = account
                let daily = try await self.service.usage(for: .day)
                guard ticket == self.generation, !Task.isCancelled else { return }
                self.dailyUsage = daily
                self.alerts = WatchdogEngine.evaluate(snapshot: daily, previous: self.previousObservation, settings: self.watchdogSettings)
                self.previousObservation = WatchdogObservation(snapshot: daily)
                self.onStatusChange?()
                let selected = requestedPeriod == .day ? daily : try await self.service.usage(for: requestedPeriod)
                guard ticket == self.generation, !Task.isCancelled else { return }
                self.usage = selected
                self.lastRefresh = Date()
                self.errorMessage = nil
                await self.deliverNotifications()
                do {
                    let agents = try await self.service.agents()
                    guard ticket == self.generation, !Task.isCancelled else { return }
                    self.agents = agents
                } catch {
                    guard ticket == self.generation, !Task.isCancelled else { return }
                    self.errorMessage = "Usage updated; agent settings unavailable. \(error.localizedDescription)"
                }
            } catch {
                guard ticket == self.generation, !Task.isCancelled else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }
    func enterDemo() {
        refreshTask?.cancel(); generation += 1; isRefreshing = false
        isDemo = true; errorMessage = nil
        identity = EdgeeIdentity(name: "Developer", organization: "Demo workspace")
        agents = DemoData.agents; usage = DemoData.usage(period); dailyUsage = DemoData.usage(.day)
        lastRefresh = Date(); modelsByAgent = [:]; previousObservation = nil
        var demoSettings = WatchdogSettings()
        demoSettings.modelRoleOverrides = ["anthropic/claude-opus-4.6": .frontier, "anthropic/claude-sonnet-4.6": .balanced, "openai/gpt-5-mini": .executor]
        watchdogSettings = demoSettings
        reevaluateWatchdog(); onStatusChange?()
    }
    func leaveDemo() {
        generation += 1; isDemo = false; usage = nil; dailyUsage = nil; identity = nil; agents = []; alerts = []; modelsByAgent = [:]; previousObservation = nil
        if let data = defaults.data(forKey: "watchdogSettings"), let value = try? JSONDecoder().decode(WatchdogSettings.self, from: data) { watchdogSettings = value }
        else { watchdogSettings = WatchdogSettings() }
        onStatusChange?(); refresh(force: true)
    }
    func login() {
        guard !isLoggingIn else { return }
        isLoggingIn = true; errorMessage = nil
        Task {
            defer { isLoggingIn = false }
            do { try await service.login(); refresh(force: true) }
            catch { errorMessage = error.localizedDescription }
        }
    }
    func loadModels(for agent: String) {
        guard !loadingModels.contains(agent) else { return }
        if isDemo { modelsByAgent[agent] = DemoData.models; return }
        loadingModels.insert(agent)
        let account = identity
        let wasDemo = isDemo
        Task {
            defer { loadingModels.remove(agent) }
            do {
                let models = try await service.availableModels(agentID: agent)
                guard account == identity, wasDemo == isDemo else { return }
                modelsByAgent[agent] = models
            } catch {
                guard account == identity, wasDemo == isDemo else { return }
                errorMessage = error.localizedDescription
            }
        }
    }
    func setAgentSetting(_ id: String, setting: AgentSetting, enabled: Bool) {
        if isDemo {
            if let index = agents.firstIndex(where: { $0.id == id }) {
                switch setting { case .toolCompression: agents[index].toolCompression = enabled; case .toolSurfaceReduction: agents[index].toolSurfaceReduction = enabled; case .outputBrevity: agents[index].outputBrevity = enabled }
            }
            return
        }
        mutateAgent(id) { try await self.service.updateSetting(agentID: id, setting: setting, enabled: enabled) }
    }
    func setRoute(_ id: String, model: String?) {
        if isDemo { if let index = agents.firstIndex(where: { $0.id == id }) { agents[index].routedModel = model }; return }
        mutateAgent(id) { try await self.service.updateRoute(agentID: id, modelID: model) }
    }
    private func mutateAgent(_ id: String, operation: @escaping () async throws -> Void) {
        guard !pendingAgents.contains(id) else { return }
        pendingAgents.insert(id); errorMessage = nil
        let account = identity
        Task {
            defer { pendingAgents.remove(id) }
            do {
                try await operation()
                let updated = try await service.agents()
                guard !isDemo, account == identity else { return }
                agents = updated
            } catch {
                guard !isDemo, account == identity else { return }
                errorMessage = "Could not update agent. \(error.localizedDescription)"
            }
        }
    }
    func setNotifications(_ enabled: Bool) {
        if !enabled { notificationsEnabled = false; defaults.set(false, forKey: "notificationsEnabled"); return }
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                notificationsEnabled = allowed
                defaults.set(allowed, forKey: "notificationsEnabled")
                if !allowed { errorMessage = "Notifications are disabled in macOS System Settings → Notifications → Edgee." }
            } catch { errorMessage = "Could not enable notifications: \(error.localizedDescription)" }
        }
    }
    func setPinned(_ value: Bool) { pinned = value; onPinChange?(value) }
    private func persistSettings() {
        if let data = try? JSONEncoder().encode(watchdogSettings) { defaults.set(data, forKey: "watchdogSettings") }
    }
    private func reevaluateWatchdog() {
        guard let dailyUsage else { return }
        alerts = WatchdogEngine.evaluate(snapshot: dailyUsage, previous: nil, settings: watchdogSettings)
    }
    private func deliverNotifications() async {
        guard notificationsEnabled, !isDemo else { return }
        for alert in alerts {
            let key = alert.id + ":" + alert.severity.rawValue
            guard Date().timeIntervalSince(deliveredAlerts[key] ?? .distantPast) > 3600 else { continue }
            let content = UNMutableNotificationContent()
            content.title = "Edgee · \(alert.title)"; content.body = alert.message; content.sound = .default
            do {
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
                deliveredAlerts[key] = Date()
            } catch { /* In-app advisories remain available if macOS delivery fails. */ }
        }
    }
}
enum PanelTab: String, CaseIterable { case overview = "Overview", agents = "Agents", watchdog = "Watchdog" }
