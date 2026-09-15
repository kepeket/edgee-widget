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
    @State private var isModelPickerPresented = false
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
                Button { isModelPickerPresented = true; store.loadModels(for: agent.id) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Theme.mint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ROUTE TO").font(.system(size: 8, weight: .semibold, design: .monospaced)).tracking(0.8).foregroundStyle(Theme.muted)
                            Text(agent.routedModel ?? "Original model · passthrough").font(.system(size: 11, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 3)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(Theme.muted)
                    }.padding(10).background(Theme.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
                }.buttonStyle(.plain).disabled(!agent.canEdit || busy).popover(isPresented: $isModelPickerPresented, arrowEdge: .trailing) { ModelPicker(agent: agent, isPresented: $isModelPickerPresented).environmentObject(store) }
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
struct ModelPicker: View {
    @EnvironmentObject var store: AppStore
    let agent: AgentConfiguration
    @Binding var isPresented: Bool
    @State private var query = ""
    private var models: [AvailableModel] { (store.modelsByAgent[agent.id] ?? []).filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query) } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Route \(agent.name)").font(.system(size: 14, weight: .semibold))
            Text("Choose a fixed destination for future requests.").font(.system(size: 10)).foregroundStyle(Theme.muted)
            TextField("Search models…", text: $query).textFieldStyle(.roundedBorder)
            Button { store.setRoute(agent.id, model: nil); isPresented = false } label: { Label("Original model · passthrough", systemImage: "arrow.right").font(.system(size: 11)).frame(maxWidth: .infinity, alignment: .leading) }.buttonStyle(.plain).padding(.vertical, 5)
            Divider()
            HStack {
                if store.loadingModels.contains(agent.id) {
                    ProgressView().controlSize(.mini)
                    Text("Loading models from Edgee…").font(.system(size: 10)).foregroundStyle(Theme.muted)
                } else {
                    Text("\(models.count) models").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { store.loadModels(for: agent.id) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.plain).foregroundStyle(Theme.mint).help("Reload available models")
                    .accessibilityLabel("Reload available models").disabled(store.loadingModels.contains(agent.id))
            }.frame(height: 18)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(models) { model in
                        Button { store.setRoute(agent.id, model: model.id); isPresented = false } label: {
                            HStack { VStack(alignment: .leading, spacing: 3) { Text(model.name).font(.system(size: 11, weight: .medium)); Text(model.id).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted) }; Spacer(); if agent.routedModel == model.id { Image(systemName: "checkmark").foregroundStyle(Theme.mint) } }.padding(8).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if let error = store.modelErrors[agent.id] {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Could not load available models", systemImage: "exclamationmark.circle").foregroundStyle(Theme.amber)
                            Text(error).foregroundStyle(Theme.muted)
                            Button("Try again") { store.loadModels(for: agent.id) }.buttonStyle(.plain).foregroundStyle(Theme.mint)
                        }.font(.system(size: 11)).padding(.vertical, 8)
                    } else if models.isEmpty && !store.loadingModels.contains(agent.id) {
                        Text(query.isEmpty ? "Edgee returned no routable models for this agent. Check its model access in Edgee, then reload." : "No models match “\(query)”. Try another search.")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted).padding(.vertical, 8)
                    }
                }
            }.frame(height: 240)
        }.padding(18).frame(width: 330).background(Theme.background).foregroundStyle(Theme.text).preferredColorScheme(.dark)
    }
}
