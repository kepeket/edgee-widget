import SwiftUI
import EdgeeCore

struct WatchdogView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        WatchdogContent(monitor: store.watchdog).environmentObject(store).id("watchdog-top")
    }
}

private struct WatchdogContent: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject var monitor: WatchdogMonitor
    @State private var showSettings = false
    @State private var selectedAgent = ""
    private var thinkingShare: Double? {
        monitor.day.flatMap { WatchdogRulesEngine.thinkingFraction($0, rules: monitor.rules) }
    }
    private var recentSpend: (cost: Double, seconds: Double)? {
        monitor.month.flatMap { WatchdogRulesEngine.recentSpend(month: $0, history: monitor.history) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Keep your spending in check.").font(.system(size: 19, weight: .medium)).tracking(-0.4)
                    Text("Three signals. A timely nudge to review your models.")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 0)
            }.padding(.vertical, 5)

            if monitor.showRouting { routingPreview }

            if let error = monitor.error {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Some checks are unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(Theme.amber)
                        Text(error).font(.system(size: 11)).foregroundStyle(Theme.muted)
                        Button("Retry checks") { monitor.refresh() }.disabled(monitor.isRefreshing)
                    }.font(.system(size: 12, weight: .medium))
                }
            }

            ForEach(monitor.alerts) { alert in
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(alert.title, systemImage: "exclamationmark.bubble")
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.amber)
                        Text(alert.message).font(.system(size: 11)).lineSpacing(3)
                        Button("Review model routing") { store.openWatchdog(alertID: alert.id, reviewRouting: true) }
                            .font(.system(size: 11, weight: .medium)).tint(Theme.mint)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(monitor.selectedAlertID == alert.id ? Theme.amber : .clear))
            }

            ruleCard(title: "Thinking-heavy day", icon: "brain", enabled: $monitor.rules.thinkingEnabled,
                     value: thinkingShare.map(Display.percent) ?? "—", caption: "of today's tokens use thinking families",
                     detail: "After noon on this Mac, warn above \(Display.percent(monitor.rules.thinkingShare)). Suggest an executor for routine work.")
            ruleCard(title: "Monthly spending", icon: "calendar", enabled: $monitor.rules.monthlyEnabled,
                     value: monitor.month.map { Display.money($0.totalCost) } ?? "—", caption: "of \(Display.money(monitor.rules.monthlyLimit)) this month",
                     detail: "Notify once when your calendar-month spending reaches this threshold.")
            ruleCard(title: "Fast spending", icon: "flame", enabled: $monitor.rules.rapidSpendEnabled,
                     value: recentSpend.map { Display.money($0.cost) } ?? "Collecting samples",
                     caption: recentSpend.map { "observed in \(max(1, Int(ceil($0.seconds / 60)))) minutes" } ?? "Two fresh observations needed",
                     detail: "Warn at \(Display.money(monitor.rules.rapidSpendLimit)) spent in less than an hour. Uses actual increases, not projected rates.")

            WatchdogNotificationControls(notifications: monitor.notifications, isDemo: monitor.isDemo)

            Card {
                DisclosureGroup("Thresholds & model families", isExpanded: $showSettings) {
                    VStack(alignment: .leading, spacing: 14) {
                        numberSetting("Thinking token share", value: Binding(get: { monitor.rules.thinkingShare * 100 }, set: { monitor.rules.thinkingShare = $0 / 100 }), unit: "%", range: 1...100)
                        numberSetting("Monthly spending", value: $monitor.rules.monthlyLimit, unit: "USD", range: 1...1_000_000)
                        numberSetting("Spend within an hour", value: $monitor.rules.rapidSpendLimit, unit: "USD", range: 1...1_000_000)
                        Text("Daily and monthly totals use Edgee's UTC calendar boundaries. All costs are USD. Family suggestions are estimates; override them below.")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
                        ForEach(monitor.day?.models ?? []) { model in
                            HStack {
                                Text(model.name).font(.system(size: 10)).lineLimit(2)
                                Spacer()
                                Picker("Role for \(model.name)", selection: Binding(
                                    get: { monitor.rules.modelRoles[model.id]?.rawValue ?? "automatic" },
                                    set: { monitor.rules.modelRoles.removeValue(forKey: model.name); monitor.rules.modelRoles[model.id] = WatchdogModelRole(rawValue: $0) }
                                )) {
                                    Text("Automatic").tag("automatic")
                                    ForEach(WatchdogModelRole.allCases, id: \.self) { role in Text(role.rawValue.capitalized).tag(role.rawValue) }
                                }.labelsHidden().frame(width: 130).controlSize(.small)
                            }
                        }
                        if monitor.day?.models.isEmpty != false {
                            Text("Model families appear after usage is available.").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                    }.padding(.top, 12)
                }.font(.system(size: 12, weight: .medium)).tint(Theme.mint)
            }
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                VStack(alignment: .leading, spacing: 4) {
                    if monitor.isRefreshing { Text("Checking usage…") }
                    else if let checked = monitor.lastChecked {
                        Text("Last checked \(checked.formatted(date: .omitted, time: .shortened))")
                    } else { Text("Waiting for your first check") }
                    Text("Checks every minute while Edgee is running. Thresholds notify; they don't stop spending. Routing previews don't change your model.")
                }
                Spacer(minLength: 0)
                SmallIconButton(symbol: "arrow.clockwise", help: "Refresh Watchdog") { monitor.refresh() }.disabled(monitor.isRefreshing || monitor.isDemo)
            }.font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
        }
        .task { if !monitor.isDemo { await monitor.notifications.refreshStatus(); monitor.refresh() } }
    }

    private func ruleCard(title: String, icon: String, enabled: Binding<Bool>, value: String, caption: String, detail: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Toggle(title, isOn: enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.mint)
                }
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(value).font(.system(size: 23, weight: .medium, design: .rounded)).foregroundStyle(enabled.wrappedValue ? Theme.mint : Theme.muted)
                    Text(caption).font(.system(size: 10)).foregroundStyle(Theme.muted)
                }
                Text(enabled.wrappedValue ? detail : "This alert is off.").font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
            }
        }
    }

    private var routingPreview: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Review model routing").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    SmallIconButton(symbol: "xmark", help: "Close routing preview") { monitor.showRouting = false }
                }
                Text("Consider an executor for routine work. Choose an agent to inspect its current route and available models.")
                    .font(.system(size: 11)).foregroundStyle(Theme.muted)
                if store.agents.isEmpty {
                    Text("No agents loaded. Connect Edgee and refresh to view your configured agents.").font(.system(size: 11))
                } else {
                    Picker("Agent", selection: $selectedAgent) {
                        Text("Choose an agent").tag("")
                        ForEach(store.agents) { agent in Text(agent.name).tag(agent.id) }
                    }.controlSize(.small)
                    if let agent = store.agents.first(where: { $0.id == selectedAgent }) {
                        Text("Current: \(agent.routedModel ?? "Original model · passthrough")").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        RouteModelPreview(agent: agent)
                    }
                }
            }
        }
        .onAppear { if selectedAgent.isEmpty { selectedAgent = store.agents.first?.id ?? "" } }
        .onChange(of: selectedAgent) { _, id in if !id.isEmpty { store.loadModels(for: id) } }
    }

    private func numberSetting(_ title: String, value: Binding<Double>, unit: String, range: ClosedRange<Double>) -> some View {
        HStack {
            Text(title).font(.system(size: 11))
            Spacer()
            TextField(title, value: Binding(get: { value.wrappedValue }, set: { if $0.isFinite { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) } }), format: .number.precision(.fractionLength(0...2)))
                .multilineTextAlignment(.trailing).frame(width: 75).textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
            Text(unit).font(.system(size: 10)).foregroundStyle(Theme.muted).frame(width: 30, alignment: .leading)
        }
    }
}

private struct WatchdogNotificationControls: View {
    @ObservedObject var notifications: WatchdogNotifications
    let isDemo: Bool
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("macOS notifications", isOn: Binding(get: { notifications.enabled }, set: { value in Task { await notifications.setEnabled(value) } }))
                    .font(.system(size: 12, weight: .semibold)).toggleStyle(.switch).controlSize(.small).tint(Theme.mint)
                    .disabled(isDemo || notifications.busy)
                Text(isDemo ? "Notifications aren't sent in demo mode." : notifications.status).font(.system(size: 10)).foregroundStyle(Theme.muted)
                Toggle("Allow alerts during Focus / DND", isOn: Binding(get: { notifications.allowDuringFocus }, set: { value in Task { await notifications.setAllowDuringFocus(value) } }))
                    .font(.system(size: 11)).toggleStyle(.switch).controlSize(.mini).tint(Theme.mint)
                    .disabled(isDemo || notifications.busy || !notifications.supportsTimeSensitive)
                Text(notifications.focusStatus).font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
                HStack {
                    Button("Send test") { Task { await notifications.sendTest() } }.disabled(isDemo || !notifications.enabled)
                    Button("Notifications settings") { notifications.openSettings() }
                    Button("Focus settings") { notifications.openSettings(focus: true) }
                }.font(.system(size: 10)).buttonStyle(.bordered).controlSize(.small)
                if let message = notifications.message { Text(message).font(.system(size: 10)).foregroundStyle(Theme.amber).lineSpacing(3) }
            }
        }
    }
}
