import SwiftUI
import EdgeeCore

struct WatchdogView: View {
    @EnvironmentObject var store: AppStore
    @State private var showRoles = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) { Text("A little less on your mind.").font(.system(size: 19, weight: .medium)).tracking(-0.4); Text("Quiet checks. Timely nudges. You stay in control.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                Spacer()
                Image(systemName: "shield.lefthalf.filled").font(.system(size: 25, weight: .light)).foregroundStyle(Theme.mint)
            }.padding(.vertical, 5)
            if store.alerts.isEmpty {
                Card {
                    HStack(alignment: .top, spacing: 12) { Image(systemName: "checkmark.shield").font(.system(size: 22)).foregroundStyle(Theme.mint); VStack(alignment: .leading, spacing: 6) { Text(store.dailyUsage == nil ? "Ready when you connect" : "Within your guardrails").font(.system(size: 13, weight: .semibold)); Text(store.dailyUsage == nil ? "Connect Edgee to start monitoring your activity." : "No configured thresholds are currently triggered.").font(.system(size: 11)).foregroundStyle(Theme.muted) } }
                }
            }
            ForEach(store.alerts) { alert in
                Card {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Image(systemName: alert.severity == .critical ? "exclamationmark.octagon" : "sparkles").foregroundStyle(Theme.amber); Text(alert.title).font(.system(size: 12, weight: .semibold)); Spacer() }
                        Text(alert.message).font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3)
                        if let tip = alert.recommendation { Text(tip).font(.system(size: 11)).foregroundStyle(Theme.text.opacity(0.85)).lineSpacing(3) }
                        if alert.kind == .frontierShare || alert.kind == .dailySpend || alert.kind == .thinkingToExecutorRatio {
                            Button { store.selectedTab = .agents } label: { HStack { Text("Review agent routing"); Image(systemName: "arrow.up.right") }.font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.mint) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 15) {
                    SectionCaption(title: "YOUR GUARDRAILS", trailing: "TRAILING 24H")
                    numberSetting("Spend budget", icon: "dollarsign.circle", value: $store.watchdogSettings.dailySpendLimit, suffix: "USD", range: 0...1_000_000)
                    numberSetting("Token budget", icon: "square.stack", value: Binding(get: { store.watchdogSettings.dailyTokenLimit / 1_000_000 }, set: { store.watchdogSettings.dailyTokenLimit = $0 * 1_000_000 }), suffix: "M tokens", range: 0...10_000)
                    numberSetting("Frontier cost share", icon: "sparkle", value: Binding(get: { store.watchdogSettings.maximumFrontierCostShare * 100 }, set: { store.watchdogSettings.maximumFrontierCostShare = $0 / 100 }), suffix: "% max", range: 0...100)
                    numberSetting("Thinking / executor cost", icon: "arrow.triangle.branch", value: $store.watchdogSettings.maximumThinkingToExecutorCostRatio, suffix: ": 1 max", range: 0...100)
                    numberSetting("Session burn rate", icon: "flame", value: $store.watchdogSettings.maximumSessionCostIncreasePerHour, suffix: "USD / h", range: 0...1_000_000)
                    Text("Budget value 0 disables that limit. Session alerts require two fresh observations and a meaningful cost increase.").font(.system(size: 9)).foregroundStyle(Theme.muted).lineSpacing(3)
                    Rectangle().fill(Theme.line).frame(height: 1)
                    HStack { VStack(alignment: .leading, spacing: 4) { Text("macOS notifications").font(.system(size: 11, weight: .medium)); Text("At most once per alert level per hour").font(.system(size: 9)).foregroundStyle(Theme.muted) }; Spacer(); Toggle("macOS notifications", isOn: Binding(get: { store.notificationsEnabled }, set: store.setNotifications)).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.mint).disabled(store.isDemo) }
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Button { withAnimation { showRoles.toggle() } } label: { HStack { Text("MODEL ROLES").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.3); Spacer(); Image(systemName: showRoles ? "chevron.up" : "chevron.down").font(.system(size: 10)) }.foregroundStyle(Theme.muted) }.buttonStyle(.plain)
                    Text("Assign roles to make model-mix advice meaningful for your workflow. Automatic labels are name-based estimates.").font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
                    if showRoles {
                        if (store.dailyUsage?.models ?? []).isEmpty { Text("Models appear after your first usage refresh.").font(.system(size: 10)).foregroundStyle(Theme.muted) }
                        ForEach(store.dailyUsage?.models ?? []) { model in
                            HStack { Text(model.name).font(.system(size: 10)).lineLimit(1); Spacer(); Picker("Role for \(model.name)", selection: Binding(get: { store.watchdogSettings.modelRoleOverrides[model.id]?.rawValue ?? "automatic" }, set: { value in store.watchdogSettings.modelRoleOverrides[model.id] = WatchdogModelRole(rawValue: value) })) { Text("Automatic").tag("automatic"); ForEach(WatchdogModelRole.allCases, id: \.self) { role in Text(role.rawValue.capitalized).tag(role.rawValue) } }.labelsHidden().frame(width: 120).controlSize(.small) }
                        }
                    }
                }
            }
            if let snapshot = store.dailyUsage {
                Card {
                    VStack(alignment: .leading, spacing: 11) {
                        SectionCaption(title: "SESSION WATCH", trailing: "\(snapshot.sessions.count) OBSERVED")
                        if snapshot.sessions.isEmpty {
                            Text("No session observations are available for spike checks yet.").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                        ForEach(Array(snapshot.sessions.prefix(4))) { session in
                            HStack { Text(session.name).font(.system(size: 10)).lineLimit(1); Spacer(); Text(Display.money(session.cost)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted) }
                        }
                    }
                }
            }
            Label("Checks run every minute while Edgee is running. Advice never changes a route automatically.", systemImage: "clock.arrow.circlepath").font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
        }
    }
    private func numberSetting(_ title: String, icon: String, value: Binding<Double>, suffix: String, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 16)
            Text(title).font(.system(size: 11))
            Spacer()
            TextField(title, value: Binding(get: { value.wrappedValue }, set: { if $0.isFinite { value.wrappedValue = min(range.upperBound, max(range.lowerBound, $0)) } }), format: .number.precision(.fractionLength(0...2))).font(.system(size: 11, design: .monospaced)).multilineTextAlignment(.trailing).textFieldStyle(.plain).padding(.horizontal, 7).padding(.vertical, 5).frame(width: 67).background(Theme.background, in: RoundedRectangle(cornerRadius: 6))
            Text(suffix).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 55, alignment: .leading)
        }
    }
}
