import SwiftUI
import EdgeeCore

struct AgentsView: View {
    @EnvironmentObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) { Text("Less overhead. More building.").font(.system(size: 19, weight: .medium)).tracking(-0.4); Text("Fine-tune the agents connected to Edgee.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                Spacer()
                Text(String(format: "%02d", store.agents.count)).font(.system(size: 25, weight: .light, design: .monospaced)).foregroundStyle(Theme.muted)
            }.padding(.vertical, 5)
            if store.agents.isEmpty {
                Card { VStack(alignment: .leading, spacing: 10) { Image(systemName: "terminal").foregroundStyle(Theme.mint); Text(store.isRefreshing ? "Finding configured agents…" : "No configured agents found").font(.system(size: 14, weight: .medium)); Text("Launch an agent through the Edgee CLI, then refresh. Only existing agent keys appear here.").font(.system(size: 11)).foregroundStyle(Theme.muted) } }
            }
            ForEach(store.agents) { agent in AgentCard(agent: agent) }
            Label("Changes apply to future requests through this agent’s Edgee key.", systemImage: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.muted).lineSpacing(3)
        }
    }
}
struct AgentCard: View {
    @EnvironmentObject var store: AppStore
    let agent: AgentConfiguration
    @State private var isRoutePreviewExpanded = false
    private var busy: Bool { store.pendingAgents.contains(agent.id) }
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.mint).frame(width: 34, height: 34).background(Theme.mint.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) { Text(agent.name).font(.system(size: 14, weight: .semibold)); Text(agent.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted) }
                    Spacer()
                    if busy { ProgressView().controlSize(.mini) } else { StatusPill(label: agent.canEdit ? "CONNECTED" : "READ ONLY", color: agent.canEdit ? Theme.teal : Theme.muted) }
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                settingRow("Tool compression", detail: "Trim repetitive tool results", setting: .toolCompression, enabled: agent.toolCompression, icon: "arrow.down.right.and.arrow.up.left")
                settingRow("Tool surface reduction", detail: "Send fewer tool definitions", setting: .toolSurfaceReduction, enabled: agent.toolSurfaceReduction, icon: "square.stack.3d.up")
                settingRow("Output brevity", detail: "Keep responses focused", setting: .outputBrevity, enabled: agent.outputBrevity, icon: "text.alignleft")
                Button {
                    isRoutePreviewExpanded.toggle()
                    if isRoutePreviewExpanded { store.loadModels(for: agent.id) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ROUTE TO").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(Theme.muted)
                            Text(agent.routedModel ?? "Original model · passthrough").font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 3)
                        Image(systemName: isRoutePreviewExpanded ? "chevron.up" : "chevron.down").font(.system(size: 9)).foregroundStyle(Theme.muted)
                    }.padding(10).background(Theme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                }.buttonStyle(.plain)
                    .accessibilityLabel("Preview routing models for \(agent.name)")
                    .accessibilityValue(isRoutePreviewExpanded ? "Expanded" : "Collapsed")
                if isRoutePreviewExpanded {
                    // Keep the preview in the menu-bar panel. A nested NSPopover can
                    // crash AppKit while it transfers the search field's first responder.
                    RouteModelPreview(agent: agent)
                }
                if let detail = agent.detail { Text(detail).font(.system(size: 10)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
    private var symbol: String { switch agent.id { case "claude", "claude_desktop": "asterisk"; case "codex", "codex_desktop": "chevron.left.forwardslash.chevron.right"; case "cursor": "cursorarrow"; default: "terminal" } }
    private func settingRow(_ title: String, detail: String, setting: AgentSetting, enabled: Bool, icon: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 12)).foregroundStyle(Theme.muted).frame(width: 17)
            VStack(alignment: .leading, spacing: 3) { Text(title).font(.system(size: 11, weight: .medium)); Text(detail).font(.system(size: 9)).foregroundStyle(Theme.muted) }
            Spacer()
            Toggle(title, isOn: Binding(get: { enabled }, set: { store.setAgentSetting(agent.id, setting: setting, enabled: $0) })).labelsHidden().toggleStyle(.switch).controlSize(.mini).tint(Theme.mint).disabled(!agent.canEdit || busy).accessibilityLabel("\(agent.name): \(title)")
        }
    }
}
struct RouteModelPreview: View {
    @EnvironmentObject var store: AppStore
    let agent: AgentConfiguration
    private var models: [AvailableModel] { store.modelsByAgent[agent.id] ?? [] }
    private var loading: Bool { store.loadingModels.contains(agent.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                if loading {
                    ProgressView().controlSize(.mini)
                    Text("Loading models from Edgee…")
                } else {
                    Text("\(models.count) catalog models")
                }
                Spacer()
                Button { store.loadModels(for: agent.id) } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).foregroundStyle(Theme.mint).disabled(loading)
                .accessibilityLabel("Reload catalog models")
            }.font(.system(size: 10)).foregroundStyle(Theme.muted).frame(height: 18)

            if let error = store.modelErrors[agent.id] {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Could not load catalog models", systemImage: "exclamationmark.circle")
                        .foregroundStyle(Theme.amber)
                    Text(error).foregroundStyle(Theme.muted).lineLimit(3).help(error)
                    Button("Try again") { store.loadModels(for: agent.id) }
                        .buttonStyle(.plain).foregroundStyle(Theme.mint).disabled(loading)
                }.font(.system(size: 10))
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    modelRow(name: "Original model · passthrough", id: nil)
                    // Index identity keeps duplicate catalog entries from confusing SwiftUI.
                    ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                        modelRow(name: model.name, id: model.id)
                    }
                    if models.isEmpty && !loading && store.modelErrors[agent.id] == nil {
                        Text("No models returned by the Edgee catalog.")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted).padding(8)
                    }
                }
            }
            .frame(height: 180)
            .disabled(true).allowsHitTesting(false).accessibilityHidden(true)
            .overlay {
                ZStack {
                    Theme.background.opacity(0.70)
                    VStack(spacing: 8) {
                        Image(systemName: "lock.fill").font(.system(size: 17)).foregroundStyle(Theme.mint)
                        Text("Soon available").font(.system(size: 17, weight: .semibold))
                        Text("Model switching is coming soon.\nYour current route stays active.")
                            .font(.system(size: 10)).foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                    }.padding(16)
                }.accessibilityElement(children: .combine)
            }
            .background(Theme.background)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        }
    }

    private func modelRow(name: String, id: String?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 11, weight: .medium))
                if let id { Text(id).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted) }
            }
            Spacer()
            if agent.routedModel == id { Image(systemName: "checkmark").foregroundStyle(Theme.mint) }
        }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
    }
}
