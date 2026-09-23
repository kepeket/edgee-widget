import SwiftUI
import EdgeeCore

enum MixMetric: String, CaseIterable { case cost = "Cost", tokens = "Tokens", requests = "Requests" }

struct OverviewView: View {
    @EnvironmentObject var store: AppStore
    @State private var metric: MixMetric = .cost
    var body: some View {
        VStack(spacing: 12) {
            periodPicker
            if let usage = store.usage {
                spendCard(usage)
                tokensCard(usage)
                mixCard(usage)
                if let notice = usage.notice { Label(notice, systemImage: "info.circle").font(.system(size: 10)).foregroundStyle(Theme.muted).frame(maxWidth: .infinity, alignment: .leading) }
            } else if store.isRefreshing {
                VStack(spacing: 16) { ProgressView().controlSize(.small); Text("Reading your Edgee activity…").font(.system(size: 12)).foregroundStyle(Theme.muted) }.frame(maxWidth: .infinity, minHeight: 260)
            } else {
                connectionCard
            }
        }
    }
    private var periodPicker: some View {
        HStack(spacing: 8) {
            HStack(spacing: 3) {
                ForEach(UsagePeriod.allCases, id: \.self) { period in
                    Button { store.selectPeriod(period) } label: {
                        Text(period.title(in: store.windowMode))
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(store.period == period ? Theme.text : Theme.muted)
                            .frame(minWidth: 53, minHeight: 28)
                            .padding(.horizontal, 7)
                            .background(store.period == period ? Theme.elevated : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityAddTraits(store.period == period ? .isSelected : [])
                }
            }.padding(3).background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            Spacer(minLength: 0)
            Text(store.period.windowLabel(in: store.windowMode))
                .font(.system(size: 10, design: .monospaced))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .foregroundStyle(Theme.muted)
        }
    }
    private var chartDateFormat: Date.FormatStyle {
        var format: Date.FormatStyle = store.period == .day
            ? .dateTime.hour().minute()
            : .dateTime.month(.abbreviated).day()
        format.timeZone = store.windowMode == .calendar ? UsageWindow.consoleTimeZone : .current
        return format
    }
    private func spendCard(_ usage: UsageSnapshot) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 6) {
                SectionCaption(title: "TOTAL SPEND", trailing: "USD")
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Display.money(usage.totalCost)).font(.system(size: 36, weight: .medium, design: .rounded)).tracking(-1.8).monospacedDigit()
                    Spacer()
                    if let saved = usage.savedCost, saved > 0 {
                        VStack(alignment: .trailing, spacing: 4) {
                            Label(Display.money(saved), systemImage: "arrow.down.right").font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Theme.mint)
                            Text("saved by Edgee").font(.system(size: 10)).foregroundStyle(Theme.muted)
                        }
                    }
                }
                if !usage.series.isEmpty {
                    SpendChart(points: usage.series)
                    HStack { Text(usage.series.first?.date ?? Date(), format: chartDateFormat); Spacer(); Text("NOW") }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
                } else {
                    Text("Time series unavailable for this account").font(.system(size: 10)).foregroundStyle(Theme.muted).frame(height: 38)
                }
                Rectangle().fill(Theme.line).frame(height: 1)
                HStack {
                    stat("TOKENS", Display.compact(usage.totalTokens))
                    Spacer()
                    stat("REQUESTS", usage.requests.formatted())
                    Spacer()
                    stat("CACHE SHARE", Display.percent((usage.tokens.first { $0.kind == .cacheRead }?.count ?? 0) / max(usage.totalTokens, 1)))
                }
                if store.period == .day, store.watchdogSettings.dailySpendLimit > 0 {
                    VStack(spacing: 6) {
                        GeometryReader { g in
                            ZStack(alignment: .leading) { Capsule().fill(Theme.elevated); Capsule().fill(usage.totalCost >= store.watchdogSettings.dailySpendLimit ? Theme.amber : Theme.mint.opacity(0.75)).frame(width: min(1, max(0, usage.totalCost / store.watchdogSettings.dailySpendLimit)) * g.size.width) }
                        }.frame(height: 3)
                        HStack { Text(store.windowMode == .calendar ? "Today’s budget" : "24-hour budget"); Spacer(); Text("\(Display.money(usage.totalCost)) / \(Display.money(store.watchdogSettings.dailySpendLimit))") }.font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted)
                    }.padding(.top, 2)
                }
            }
        }
    }
    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) { Text(title).font(.system(size: 8, weight: .medium, design: .monospaced)).tracking(0.7).foregroundStyle(Theme.muted); Text(value).font(.system(size: 16, weight: .medium, design: .monospaced)) }
    }
    private func tokensCard(_ usage: UsageSnapshot) -> some View {
        Card {
            VStack(spacing: 8) {
                SectionCaption(title: "TOKEN BREAKDOWN", trailing: "VOLUME / COST")
                GeometryReader { g in
                    HStack(spacing: 3) {
                        ForEach(usage.tokens) { token in RoundedRectangle(cornerRadius: 2).fill(Theme.color(token.kind)).frame(width: max(0, (g.size.width - Double(max(0,usage.tokens.count - 1)) * 3) * token.count / max(1, usage.totalTokens))) }
                    }
                }.frame(height: 5).accessibilityHidden(true)
                ForEach(usage.tokens) { token in
                    HStack(spacing: 8) {
                        Circle().fill(Theme.color(token.kind)).frame(width: 5, height: 5)
                        Text(token.kind.title).font(.system(size: 11)).foregroundStyle(Theme.text.opacity(0.85))
                        Spacer()
                        Text(Display.compact(token.count)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 70, alignment: .trailing)
                        Text(token.cost.map(Display.money) ?? "—").font(.system(size: 11, weight: .medium, design: .monospaced)).frame(width: 68, alignment: .trailing)
                    }
                }
            }
        }
    }
    private func mixCard(_ usage: UsageSnapshot) -> some View {
        Card {
            VStack(spacing: 13) {
                HStack {
                    Text("MODEL MIX").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.4).foregroundStyle(Theme.muted)
                    Spacer()
                    HStack(spacing: 10) { ForEach(MixMetric.allCases, id: \.self) { value in
                        Button { withAnimation(.easeInOut(duration: 0.2)) { metric = value } } label: { Text(value.rawValue).font(.system(size: 10, weight: .medium)).foregroundStyle(metric == value ? Theme.mint : Theme.muted) }.buttonStyle(.plain)
                    } }
                }
                if usage.models.isEmpty { Text("No model activity in this period.").font(.system(size: 11)).foregroundStyle(Theme.muted) }
                ForEach(Array(sortedModels(usage).enumerated()), id: \.element.id) { index, model in
                    VStack(spacing: 7) {
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.modelColors[index % Theme.modelColors.count]).frame(width: 6, height: 6)
                            Text(model.name).font(.system(size: 11, weight: .medium)).lineLimit(1).help(model.id)
                            Spacer(minLength: 4)
                            Text(modelValue(model)).font(.system(size: 11, weight: .medium, design: .monospaced))
                            Text(Display.percent(amount(model) / max(1e-9, mixTotal(usage)))).font(.system(size: 9, design: .monospaced)).foregroundStyle(Theme.muted).frame(width: 32, alignment: .trailing)
                        }
                        GeometryReader { g in
                            ZStack(alignment: .leading) { Capsule().fill(Theme.elevated); Capsule().fill(Theme.modelColors[index % Theme.modelColors.count].opacity(0.75)).frame(width: g.size.width * min(1, max(0,amount(model) / max(1e-9,mixTotal(usage))))) }
                        }.frame(height: 3)
                    }
                }
            }
        }
    }
    private func amount(_ m: ModelUsage) -> Double { switch metric { case .cost: m.cost; case .tokens: m.tokens; case .requests: Double(m.requests) } }
    private func mixTotal(_ usage: UsageSnapshot) -> Double { usage.models.reduce(0) { $0 + amount($1) } }
    private func sortedModels(_ usage: UsageSnapshot) -> [ModelUsage] { usage.models.sorted { amount($0) > amount($1) } }
    private func modelValue(_ m: ModelUsage) -> String { switch metric { case .cost: Display.money(m.cost); case .tokens: Display.compact(m.tokens); case .requests: m.requests.formatted() } }
    private var connectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 32, weight: .light)).foregroundStyle(Theme.mint)
                Text("Your agents.\nEvery token. One glance.").font(.system(size: 26, weight: .medium)).tracking(-0.8)
                Text("Connect your Edgee account to see your spend, tune your agents, and catch expensive habits before they add up.").font(.system(size: 12)).foregroundStyle(Theme.muted).lineSpacing(4)
                Button(store.isLoggingIn ? "Waiting for browser…" : "Connect with Edgee CLI") { store.login() }.buttonStyle(MintButton()).disabled(store.isLoggingIn)
                Button("Explore the interface with demo data ↗") { store.enterDemo() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.muted)
                Text("Uses your existing CLI profile and browser sign-in.").font(.system(size: 10)).foregroundStyle(Theme.muted)
            }.padding(.vertical, 16)
        }
    }
}
