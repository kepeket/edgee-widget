import SwiftUI
import AppKit
import ServiceManagement

struct PanelView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(spacing: 0) {
            header
            navigation
            if let error = store.errorMessage {
                HStack(alignment: .top, spacing: 7) { Image(systemName: "exclamationmark.circle"); Text(error).lineLimit(4).textSelection(.enabled); Spacer(minLength: 0); Button { store.errorMessage = nil } label: { Image(systemName: "xmark").font(.system(size: 8)) }.buttonStyle(.plain) }.font(.system(size: 10)).foregroundStyle(Theme.amber).padding(12).background(Theme.amber.opacity(0.07)).padding(.horizontal, 20).padding(.bottom, 10)
            }
            ScrollView {
                VStack(spacing: 14) {
                    if store.showSettings { SettingsContent() }
                    else { switch store.selectedTab { case .overview: OverviewView(); case .agents: AgentsView(); case .watchdog: WatchdogView() } }
                }.padding(.horizontal, 20).padding(.top, 2).padding(.bottom, 20)
            }.scrollIndicators(.hidden)
            footer
        }
        .frame(width: 456, height: 760)
        .background(Theme.background).foregroundStyle(Theme.text).preferredColorScheme(.dark)
    }
    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 5) { EdgeeWordmark(); Text("/ pulse").font(.system(size: 12, weight: .light, design: .monospaced)).foregroundStyle(Theme.muted) }
                Text(store.identity?.organization.isEmpty == false ? store.identity!.organization : "YOUR AGENT CONTROL ROOM").font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(1.0).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer()
            StatusPill(label: store.isDemo ? "DEMO" : store.dailyUsage == nil ? "OFFLINE" : store.errorMessage == nil ? "LIVE" : "STALE", color: store.isDemo ? Theme.amber : store.dailyUsage == nil ? Theme.muted : store.errorMessage == nil ? Theme.mint : Theme.amber)
            SmallIconButton(symbol: store.pinned ? "pin.fill" : "pin", help: store.pinned ? "Unpin panel" : "Keep panel open") { store.setPinned(!store.pinned) }
            SmallIconButton(symbol: store.showSettings ? "xmark" : "slider.horizontal.3", help: "Settings") { store.showSettings.toggle() }
        }.padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 14)
    }
    private var navigation: some View {
        HStack(spacing: 22) {
            ForEach(PanelTab.allCases, id: \.self) { tab in
                Button { withAnimation(.easeInOut(duration: 0.16)) { store.selectedTab = tab; store.showSettings = false } } label: {
                    VStack(spacing: 11) {
                        HStack(spacing: 5) { Text(tab.rawValue).font(.system(size: 12, weight: .medium)); if tab == .watchdog && !store.alerts.isEmpty { Text("\(store.alerts.count)").font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(Theme.background).padding(.horizontal, 4).padding(.vertical, 2).background(Theme.amber, in: Capsule()) } }
                        Rectangle().fill(store.selectedTab == tab && !store.showSettings ? Theme.mint : .clear).frame(height: 2)
                    }.foregroundStyle(store.selectedTab == tab && !store.showSettings ? Theme.text : Theme.muted)
                }.buttonStyle(.plain).accessibilityAddTraits(store.selectedTab == tab ? .isSelected : [])
            }
            Spacer()
        }.padding(.horizontal, 20).overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 1) }.padding(.bottom, 16)
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Circle().fill(store.errorMessage != nil ? Theme.amber : Theme.teal).frame(width: 4, height: 4)
            if store.isRefreshing { Text("Syncing…") }
            else if let date = store.lastRefresh { Text("Updated"); Text(date, style: .relative) }
            else { Text("Waiting for connection") }
            Spacer()
            SmallIconButton(symbol: "arrow.clockwise", help: "Refresh usage") { store.refresh(force: true) }.disabled(store.isRefreshing)
            Button { NSWorkspace.shared.open(URL(string: "https://www.edgee.ai")!) } label: { HStack(spacing: 4) { Text("Console"); Image(systemName: "arrow.up.right").font(.system(size: 8)) } }.buttonStyle(.plain).help("Open Edgee in your browser")
        }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted).padding(.horizontal, 20).padding(.vertical, 8).background(Theme.card.opacity(0.55)).overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }
}
struct SettingsContent: View {
    @EnvironmentObject var store: AppStore
    @State private var startsAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make yourself at home.").font(.system(size: 21, weight: .medium)).tracking(-0.5)
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionCaption(title: "ACCOUNT")
                    Text(store.identity?.name ?? "Not connected").font(.system(size: 14, weight: .semibold))
                    if let profile = store.identity?.profile { Text("CLI profile: \(profile)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted) }
                    Text("Edgee Pulse uses your active CLI profile. Switch profiles with edgee auth switch, then refresh.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3)
                    Button(store.isLoggingIn ? "Waiting for browser…" : "Sign in with Edgee") { if store.isDemo { store.leaveDemo() }; store.login() }.buttonStyle(MintButton()).disabled(store.isLoggingIn)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionCaption(title: "PREFERENCES")
                    Toggle("Launch at login", isOn: Binding(get: { startsAtLogin }, set: { value in
                        do { if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; startsAtLogin = SMAppService.mainApp.status == .enabled }
                        catch { loginError = error.localizedDescription }
                    })).font(.system(size: 11)).toggleStyle(.switch).controlSize(.small).tint(Theme.mint)
                    if let loginError { Text(loginError).font(.system(size: 10)).foregroundStyle(Theme.amber) }
                    Text("Refreshes every 60 seconds. Runs locally in your menu bar; closing the panel keeps monitoring active.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3)
                    Text("Day, Week, and Month represent the API’s trailing 24-hour, 7-day, and 30-day windows. The menu bar always shows your trailing 24-hour spend.").font(.system(size: 11)).foregroundStyle(Theme.muted).lineSpacing(3)
                }
            }
            Card {
                VStack(alignment: .leading, spacing: 13) {
                    SectionCaption(title: "EDGEE PULSE", trailing: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                    Text("A calmer home for your AI usage.").font(.system(size: 12))
                    HStack { Button("View source ↗") { NSWorkspace.shared.open(URL(string: "https://github.com/kepeket/edgee-widget")!) }; Spacer(); Button(store.isDemo ? "Exit demo" : "Explore demo") { if store.isDemo { store.leaveDemo() } else { store.enterDemo() } } }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.mint)
                }
            }
            Button("Quit Edgee Pulse") { NSApplication.shared.terminate(nil) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.top, 4)
        }
    }
}
