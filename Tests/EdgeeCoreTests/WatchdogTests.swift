import XCTest
@testable import EdgeeCore

final class WatchdogTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_700_000_000)

    func testDefaultsMatchProductLimits() {
        let settings = WatchdogSettings()

        XCTAssertEqual(settings.dailySpendLimit, 20)
        XCTAssertEqual(settings.dailyTokenLimit, 10_000_000)
        XCTAssertEqual(settings.maximumFrontierCostShare, 0.65)
        XCTAssertEqual(settings.maximumThinkingToExecutorCostRatio, 0.5)
    }

    func testDailySpendWarnsAtBoundaryAndBecomesCriticalAtLimit() throws {
        var settings = WatchdogSettings(modelRoleOverrides: [:])
        let warning = WatchdogEngine.evaluate(
            snapshot: snapshot(cost: 16, tokens: 0), previous: nil, settings: settings
        )
        XCTAssertEqual(warning.first(where: { $0.kind == .dailySpend })?.severity, .warning)

        settings.dailySpendLimit = 16
        let critical = WatchdogEngine.evaluate(
            snapshot: snapshot(cost: 16, tokens: 0), previous: nil, settings: settings
        )
        let alert = try XCTUnwrap(critical.first(where: { $0.kind == .dailySpend }))
        XCTAssertEqual(alert.severity, .critical)
        XCTAssertEqual(alert.id, "daily-spend")
        XCTAssertTrue(alert.message.contains("trailing 24-hour"))
    }

    func testDailyTokenLimitDoesNotAlertBelowBoundary() {
        let settings = WatchdogSettings()
        let alerts = WatchdogEngine.evaluate(
            snapshot: snapshot(cost: 0, tokens: 7_999_999), previous: nil, settings: settings
        )

        XCTAssertFalse(alerts.contains { $0.kind == .dailyTokens })
    }

    func testExplicitRoleOverrideWinsAndIsReported() {
        let model = ModelUsage(id: "astra", name: "Astra", tokens: 1, cost: 4, requests: 1)
        let settings = WatchdogSettings(modelRoleOverrides: ["astra": .executor])

        XCTAssertEqual(
            WatchdogEngine.classify(model, settings: settings),
            WatchdogModelClassification(role: .executor, source: .explicitOverride)
        )
    }

    func testCatalogHeuristicsAreLabeled() {
        let settings = WatchdogSettings()
        let roles = ["Opus", "o3", "Sonnet", "Haiku"].map { name in
            WatchdogEngine.classify(ModelUsage(id: name, name: name, tokens: 0, cost: 0, requests: 0), settings: settings)
        }

        XCTAssertEqual(roles.map(\.role), [.thinking, .thinking, .executor, .executor])
        XCTAssertEqual(roles.map(\.source), Array(repeating: .namingHeuristic, count: 4))
    }

    func testSuggestedRolesRecognizeRealisticAliasesCaseInsensitively() {
        let thinkingAliases = [
            ("ANTHROPIC.CLAUDE_OPUS_4.6", "CLAUDE_OPUS_4.6"),
            ("OPENAI.GPT_5.6_SOL", "GPT_5.6_SOL"),
            ("openai/gpt-sol", "GPT Sol"),
            ("moonshot.kimi.k3", "Kimi.K3"),
            ("moonshot/kimi-k3", "kimi-k3"),
            ("moonshot_kimi_3", "KIMI_3"),
            ("zai-glm_5_3", "GLM_5_3"),
            ("DEEPSEEK V4_1", "DeepSeek V4_1")
        ]
        let executorAliases = [
            ("ANTHROPIC.CLAUDE_SONNET_4.6", "CLAUDE_SONNET_4.6"),
            ("OPENAI.GPT_5.6_TERRA", "GPT_5.6_TERRA"),
            ("openai/gpt-terra", "GPT Terra"),
            ("openai.gpt-5.6-luna", "GPT-5.6-LUNA"),
            ("openai/gpt-luna", "GPT Luna"),
            ("alibaba_qwen3_coder", "Qwen3_Coder"),
            ("moonshot.kimi.k2.5", "Kimi.2.5")
        ]

        for (id, name) in thinkingAliases {
            XCTAssertEqual(WatchdogEngine.suggestedRole(for: model(id: id, name: name)), .thinking, id)
        }
        for (id, name) in executorAliases {
            XCTAssertEqual(WatchdogEngine.suggestedRole(for: model(id: id, name: name)), .executor, id)
        }
    }

    func testSuggestedRolesRequireTokenBoundariesAndExactVersions() {
        let unknownModels = [
            model(id: "moonshot/kimi-2.50", name: "Kimi 2.50"),
            model(id: "zai/glm-5.30", name: "GLM 5.30"),
            model(id: "deepseek/deepseek-4.10", name: "Deepseek 4.10"),
            model(id: "acme/solar-1", name: "Solar"),
            model(id: "acme/lunatic-1", name: "Lunatic"),
            model(id: "other/terra-1", name: "Terra by another vendor")
        ]

        for model in unknownModels {
            XCTAssertNil(WatchdogEngine.suggestedRole(for: model), model.id)
        }
    }

    func testSuggestedRoleFeedsClassificationBeforeGenericFallback() {
        let settings = WatchdogSettings()

        XCTAssertEqual(
            WatchdogEngine.classify(model(id: "anthropic/opus", name: "Opus"), settings: settings),
            WatchdogModelClassification(role: .thinking, source: .namingHeuristic)
        )
        XCTAssertEqual(
            WatchdogEngine.classify(model(id: "anthropic/sonnet", name: "Sonnet"), settings: settings),
            WatchdogModelClassification(role: .executor, source: .namingHeuristic)
        )
        XCTAssertEqual(
            WatchdogEngine.classify(model(id: "custom/frontier", name: "Frontier Model"), settings: settings),
            WatchdogModelClassification(role: .frontier, source: .namingHeuristic)
        )
    }

    func testExplicitIDAndNameOverridesWinOverSuggestions() {
        let byID = model(id: "openai/gpt-5.6-sol", name: "GPT Sol")
        let byName = model(id: "anthropic/claude-opus", name: "Claude Opus")
        let settings = WatchdogSettings(modelRoleOverrides: [
            byID.id: .executor,
            byName.name: .balanced
        ])

        XCTAssertEqual(
            WatchdogEngine.classify(byID, settings: settings),
            WatchdogModelClassification(role: .executor, source: .explicitOverride)
        )
        XCTAssertEqual(
            WatchdogEngine.classify(byName, settings: settings),
            WatchdogModelClassification(role: .balanced, source: .explicitOverride)
        )
    }

    func testApplySuggestedRolesFillsOnlyUnsetModelsAndIsIdempotent() {
        let manualByID = model(id: "openai/gpt-5.6-sol", name: "GPT Sol")
        let manualByName = model(id: "anthropic/claude-sonnet", name: "Claude Sonnet")
        let inferred = model(id: "alibaba/qwen3-coder", name: "Qwen3 Coder")
        let unknown = model(id: "custom/model", name: "Custom Model")
        var settings = WatchdogSettings(modelRoleOverrides: [
            manualByID.id: .executor,
            manualByName.name: .thinking
        ])

        settings.applySuggestedRoles(for: [manualByID, manualByName, inferred, unknown])
        let once = settings.modelRoleOverrides
        settings.applySuggestedRoles(for: [manualByID, manualByName, inferred, unknown])

        XCTAssertEqual(settings.modelRoleOverrides[manualByID.id], .executor)
        XCTAssertNil(settings.modelRoleOverrides[manualByID.name])
        XCTAssertEqual(settings.modelRoleOverrides[manualByName.name], .thinking)
        XCTAssertNil(settings.modelRoleOverrides[manualByName.id])
        XCTAssertEqual(settings.modelRoleOverrides[inferred.id], .executor)
        XCTAssertNil(settings.modelRoleOverrides[unknown.id])
        XCTAssertEqual(settings.modelRoleOverrides, once)
        XCTAssertEqual(
            WatchdogEngine.classify(inferred, settings: settings).source,
            .explicitOverride
        )
    }

    func testThinkingExecutorRatioAlertsOnlyAfterApplyingSuggestions() {
        let models = [
            ModelUsage(id: "openai/gpt-5.6-sol", name: "GPT Sol", tokens: 1, cost: 8, requests: 1),
            ModelUsage(id: "openai/gpt-5.6-luna", name: "GPT Luna", tokens: 1, cost: 2, requests: 1)
        ]
        let usage = snapshot(cost: 10, tokens: 1, models: models)
        var settings = WatchdogSettings(
            dailySpendLimit: 100,
            dailyTokenLimit: 1_000,
            maximumThinkingToExecutorCostRatio: 0.5
        )

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: settings).contains {
            $0.kind == .thinkingToExecutorRatio
        })

        settings.applySuggestedRoles(for: models)

        XCTAssertTrue(WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: settings).contains {
            $0.kind == .thinkingToExecutorRatio
        })
    }

    func testFrontierShareAndThinkingRatioAlertBeyondConfiguredLimits() {
        let settings = WatchdogSettings(
            dailySpendLimit: 100,
            dailyTokenLimit: 1_000,
            maximumFrontierCostShare: 0.65,
            maximumThinkingToExecutorCostRatio: 0.5,
            modelRoleOverrides: ["thinking": .thinking, "executor": .executor]
        )
        let usage = snapshot(cost: 100, tokens: 1, models: [
            ModelUsage(id: "frontier", name: "Generic Frontier Model", tokens: 1, cost: 70, requests: 1),
            ModelUsage(id: "thinking", name: "Custom thinking", tokens: 1, cost: 20, requests: 1),
            ModelUsage(id: "executor", name: "Custom executor", tokens: 1, cost: 10, requests: 1)
        ])

        let alerts = WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: settings)

        let frontier = alerts.first(where: { $0.kind == .frontierShare })
        XCTAssertEqual(frontier?.id, "frontier-share")
        XCTAssertTrue(frontier?.message.contains("trailing 24-hour") == true)
        XCTAssertTrue(frontier?.message.contains("naming heuristic") == true)
        XCTAssertEqual(alerts.first(where: { $0.kind == .thinkingToExecutorRatio })?.id, "thinking-executor-ratio")
    }

    func testFrontierShareAtExactLimitDoesNotAlert() {
        let settings = WatchdogSettings(dailySpendLimit: 100, dailyTokenLimit: 1_000)
        let usage = snapshot(cost: 100, tokens: 1, models: [
            ModelUsage(id: "frontier", name: "Generic Frontier Model", tokens: 1, cost: 65, requests: 1),
            ModelUsage(id: "balanced", name: "Generic Balanced Model", tokens: 1, cost: 35, requests: 1)
        ])

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: settings).contains { $0.kind == .frontierShare })
    }

    func testThinkingExecutorRatioRequiresExplicitRoles() {
        let settings = WatchdogSettings(dailySpendLimit: 100, dailyTokenLimit: 1_000)
        let usage = snapshot(cost: 10, tokens: 1, models: [
            ModelUsage(id: "o3", name: "o3", tokens: 1, cost: 8, requests: 1),
            ModelUsage(id: "haiku", name: "Haiku", tokens: 1, cost: 2, requests: 1)
        ])

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: settings).contains { $0.kind == .thinkingToExecutorRatio })
    }

    func testFirstFetchDoesNotProduceSessionRateAlert() {
        let usage = snapshot(cost: 1, tokens: 1, sessions: [session(cost: 10)])

        let alerts = WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: WatchdogSettings())

        XCTAssertFalse(alerts.contains { $0.kind == .sessionCostIncrease })
    }

    func testSessionRateUsesElapsedTimeAndHasStableID() throws {
        let earlier = snapshot(cost: 1, tokens: 1, sessions: [session(cost: 1)], fetchedAt: day)
        let current = snapshot(cost: 4, tokens: 1, sessions: [session(cost: 4)], fetchedAt: day.addingTimeInterval(3_600))
        let previous = WatchdogObservation(snapshot: earlier)
        let settings = WatchdogSettings(maximumSessionCostIncreasePerHour: 2, minimumSessionCostIncrease: 0.25)

        let alerts = WatchdogEngine.evaluate(snapshot: current, previous: previous, settings: settings)
        let alert = try XCTUnwrap(alerts.first(where: { $0.kind == .sessionCostIncrease }))
        XCTAssertEqual(alert.id, "session-cost-increase/session-1")
        XCTAssertEqual(alert.severity, .warning)
        XCTAssertTrue(alert.message.contains("$3.00/hour"))
    }

    func testStaleAndNonMonotonicSamplesDoNotProduceSessionRateAlert() {
        let base = snapshot(cost: 1, tokens: 1, sessions: [session(cost: 1)], fetchedAt: day)
        let observation = WatchdogObservation(snapshot: base)
        let stale = snapshot(cost: 10, tokens: 1, sessions: [session(cost: 10)], fetchedAt: day.addingTimeInterval(7 * 3_600))
        let backward = snapshot(cost: 10, tokens: 1, sessions: [session(cost: 10)], fetchedAt: day.addingTimeInterval(-3_600))
        let settings = WatchdogSettings(maximumSessionCostIncreasePerHour: 1)

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: stale, previous: observation, settings: settings).contains { $0.kind == .sessionCostIncrease })
        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: backward, previous: observation, settings: settings).contains { $0.kind == .sessionCostIncrease })
    }

    func testSessionCounterResetDoesNotProduceRateAlert() {
        let base = snapshot(cost: 10, tokens: 1, sessions: [session(cost: 10)], fetchedAt: day)
        let reset = snapshot(cost: 1, tokens: 1, sessions: [session(cost: 1)], fetchedAt: day.addingTimeInterval(3_600))
        let observation = WatchdogObservation(snapshot: base)

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: reset, previous: observation, settings: WatchdogSettings()).contains { $0.kind == .sessionCostIncrease })
    }

    func testDuplicateSessionIDsDoNotTrapOrProduceRateAlert() {
        let base = snapshot(cost: 1, tokens: 1, sessions: [
            session(cost: 1),
            session(cost: 2)
        ], fetchedAt: day)
        let current = snapshot(
            cost: 10,
            tokens: 1,
            sessions: [session(cost: 9)],
            fetchedAt: day.addingTimeInterval(3_600)
        )

        let alerts = WatchdogEngine.evaluate(
            snapshot: current,
            previous: WatchdogObservation(snapshot: base),
            settings: WatchdogSettings(maximumSessionCostIncreasePerHour: 1)
        )

        XCTAssertFalse(alerts.contains { $0.kind == .sessionCostIncrease })
    }

    func testScopeMismatchAndStaleSessionTimestampDoNotProduceRateAlert() {
        let base = snapshot(
            cost: 1,
            tokens: 1,
            sessions: [session(cost: 1, updatedAt: day)],
            fetchedAt: day
        )
        let observation = WatchdogObservation(snapshot: base)
        let settings = WatchdogSettings(maximumSessionCostIncreasePerHour: 1)
        var changedScope = snapshot(
            cost: 4,
            tokens: 1,
            sessions: [session(cost: 4, updatedAt: day.addingTimeInterval(3_600))],
            fetchedAt: day.addingTimeInterval(3_600)
        )
        changedScope.scope = "Another account"
        let staleSession = snapshot(
            cost: 4,
            tokens: 1,
            sessions: [session(cost: 4, updatedAt: day)],
            fetchedAt: day.addingTimeInterval(3_600)
        )

        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: changedScope, previous: observation, settings: settings).contains { $0.kind == .sessionCostIncrease })
        XCTAssertFalse(WatchdogEngine.evaluate(snapshot: staleSession, previous: observation, settings: settings).contains { $0.kind == .sessionCostIncrease })
    }

    func testNonFiniteMetricsDoNotProduceAlerts() {
        let prior = snapshot(cost: 1, tokens: 1, sessions: [session(cost: 1)], fetchedAt: day)
        let malformed = snapshot(
            cost: .nan,
            tokens: .infinity,
            models: [
                ModelUsage(id: "opus", name: "Opus", tokens: .infinity, cost: .infinity, requests: 1),
                ModelUsage(id: "thinking", name: "Thinking", tokens: 1, cost: .nan, requests: 1)
            ],
            sessions: [session(cost: .infinity)],
            fetchedAt: day.addingTimeInterval(3_600)
        )
        let settings = WatchdogSettings(
            maximumSessionCostIncreasePerHour: 1,
            modelRoleOverrides: ["thinking": .thinking]
        )

        XCTAssertTrue(WatchdogEngine.evaluate(
            snapshot: malformed,
            previous: WatchdogObservation(snapshot: prior),
            settings: settings
        ).isEmpty)
    }

    func testNonDailySnapshotIsIgnored() {
        var usage = snapshot(cost: 100, tokens: 100)
        usage.period = .week

        XCTAssertTrue(WatchdogEngine.evaluate(snapshot: usage, previous: nil, settings: WatchdogSettings()).isEmpty)
    }

    private func snapshot(
        cost: Double,
        tokens: Double,
        models: [ModelUsage] = [],
        sessions: [SessionUsage] = [],
        fetchedAt: Date? = nil
    ) -> UsageSnapshot {
        UsageSnapshot(
            period: .day,
            totalCost: cost,
            totalTokens: tokens,
            requests: 1,
            tokens: [],
            models: models,
            sessions: sessions,
            fetchedAt: fetchedAt ?? day
        )
    }

    private func session(cost: Double, updatedAt: Date? = nil, id: String = "session-1") -> SessionUsage {
        SessionUsage(id: id, name: "Build feature", cost: cost, tokens: 1, updatedAt: updatedAt)
    }

    private func model(id: String, name: String) -> ModelUsage {
        ModelUsage(id: id, name: name, tokens: 0, cost: 0, requests: 0)
    }
}
