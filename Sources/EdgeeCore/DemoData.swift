import Foundation

public enum DemoData {
    public static func usage(_ period: UsagePeriod, now: Date = Date()) -> UsageSnapshot {
        let factor: Double = switch period { case .day: 1; case .week: 5.8; case .month: 23.4 }
        let total = 12.84 * factor
        let weights: [Double] = [0.06, 0.04, 0.02, 0.02, 0.04, 0.1, 0.3, 0.55, 0.39, 0.7, 0.53, 0.83, 0.61, 0.88, 0.7, 1, 0.72, 0.81, 0.56, 0.69, 0.5, 0.39, 0.53, 0.29]
        let start = now.addingTimeInterval(-86400 * (period == .day ? 1 : period == .week ? 7 : 30))
        let interval = now.timeIntervalSince(start) / Double(weights.count)
        return UsageSnapshot(period: period, totalCost: total, totalTokens: 4_820_000 * factor, requests: Int(386 * factor), savedCost: 8.36 * factor,
            tokens: [
                .init(kind: .input, count: 1_420_000 * factor, cost: 4.26 * factor),
                .init(kind: .cacheWrite, count: 280_000 * factor, cost: 1.05 * factor),
                .init(kind: .cacheRead, count: 2_740_000 * factor, cost: 0.82 * factor),
                .init(kind: .output, count: 380_000 * factor, cost: 6.71 * factor)
            ], models: [
                .init(id: "anthropic/claude-opus-4.6", name: "Claude Opus 4.6", tokens: 1_760_000 * factor, cost: 8.52 * factor, requests: Int(122 * factor)),
                .init(id: "anthropic/claude-sonnet-4.6", name: "Claude Sonnet 4.6", tokens: 2_310_000 * factor, cost: 3.41 * factor, requests: Int(189 * factor)),
                .init(id: "openai/gpt-5-mini", name: "GPT-5 mini", tokens: 750_000 * factor, cost: 0.91 * factor, requests: Int(75 * factor))
            ], series: weights.enumerated().map { .init(date: start.addingTimeInterval(Double($0.offset) * interval), cost: total * $0.element / weights.reduce(0,+), tokens: 4_820_000 * factor * $0.element / weights.reduce(0,+)) },
            sessions: [.init(id: "demo-session", name: "Codex · edgee-widget", cost: 4.32, tokens: 1_280_000, updatedAt: now)], fetchedAt: now, scope: "Demo workspace")
    }
    public static var agents: [AgentConfiguration] { [
        .init(id: "claude", name: "Claude Code", toolCompression: true, toolSurfaceReduction: true, outputBrevity: false, routedModel: "anthropic/claude-sonnet-4.6"),
        .init(id: "codex", name: "Codex", toolCompression: true, toolSurfaceReduction: false, outputBrevity: true),
        .init(id: "cursor", name: "Cursor", toolCompression: true, toolSurfaceReduction: true, outputBrevity: true, routedModel: "openai/gpt-5-mini")
    ] }
    public static var models: [AvailableModel] { [
        .init(id: "anthropic/claude-opus-4.6", name: "Claude Opus 4.6", provider: "Anthropic"),
        .init(id: "anthropic/claude-sonnet-4.6", name: "Claude Sonnet 4.6", provider: "Anthropic"),
        .init(id: "openai/gpt-5-mini", name: "GPT-5 mini", provider: "OpenAI")
    ] }
}
