import AppKit
import SwiftUI
import XCTest
import EdgeeCore
@testable import EdgeeWidget

@MainActor
final class ModelColorTests: XCTestCase {
    func testInitialAssignmentsFollowCostRanking() {
        let store = makeStore()
        store.usage = snapshot([
            model("low", cost: 1), model("high", cost: 3), model("middle", cost: 2)
        ])

        XCTAssertEqual(store.modelColor(for: "high"), Theme.modelColors[0])
        XCTAssertEqual(store.modelColor(for: "middle"), Theme.modelColors[1])
        XCTAssertEqual(store.modelColor(for: "low"), Theme.modelColors[2])
    }

    func testEqualCostsUseModelIDToBreakTies() {
        let store = makeStore()
        store.usage = snapshot([model("b", cost: 1), model("a", cost: 1)])

        XCTAssertEqual(store.modelColor(for: "a"), Theme.modelColors[0])
        XCTAssertEqual(store.modelColor(for: "b"), Theme.modelColors[1])
    }

    func testAssignmentsSurviveReorderingMissingAndNewModels() {
        let store = makeStore()
        store.usage = snapshot([model("a", cost: 2), model("b", cost: 1)])
        let original = colors(in: store, ids: ["a", "b"])
        let updates = [[], [model("b", cost: 5)],
                       [model("new", cost: 10), model("b", cost: 4), model("a", cost: 1)]]

        store.usage = nil
        for models in updates {
            store.usage = snapshot(models)
            XCTAssertEqual(colors(in: store, ids: ["a", "b"]), original)
        }
        XCTAssertEqual(store.modelColor(for: "new"), Theme.modelColors[2])
    }

    func testFirstFiveColorsAreDistinctAndOverflowCycles() {
        let store = makeStore()
        let count = Theme.modelColors.count
        let models = (0..<(count * 2 + 1)).map { model("model-\($0)", cost: Double(count * 2 + 1 - $0)) }
        store.usage = snapshot(models)

        for (index, model) in models.enumerated() {
            XCTAssertEqual(store.modelColor(for: model.id), Theme.modelColors[index % count])
        }
        XCTAssertEqual(Set(colors(in: store, ids: models.prefix(count).map(\.id))).count, count)
    }

    func testFreshStoreStartsNewAssignments() {
        let first = makeStore()
        first.usage = snapshot([model("a", cost: 2), model("b", cost: 1)])
        let second = makeStore()
        second.usage = snapshot([model("b", cost: 2), model("a", cost: 1)])

        XCTAssertEqual(first.modelColor(for: "a"), Theme.modelColors[0])
        XCTAssertEqual(second.modelColor(for: "a"), Theme.modelColors[1])
    }

    func testDemoColorsSurvivePeriodAndWindowModeSwitches() throws {
        let store = makeStore(demo: true)
        let ids = try XCTUnwrap(store.usage).models.map(\.id)
        let original = colors(in: store, ids: ids)
        XCTAssertEqual(Set(original).count, ids.count)

        for period in UsagePeriod.allCases {
            store.selectPeriod(period)
            XCTAssertEqual(colors(in: store, ids: ids), original)
        }
        store.setWindowMode(.calendar)
        XCTAssertEqual(colors(in: store, ids: ids), original)
    }

    func testRenderedModelMixKeepsMarkerAndBarColorsAcrossMetricsAndReopening() throws {
        let store = makeStore()
        let models = [
            ModelUsage(id: "a", name: "Model A", tokens: 100, cost: 3, requests: 20),
            ModelUsage(id: "b", name: "Model B", tokens: 300, cost: 2, requests: 10),
            ModelUsage(id: "c", name: "Model C", tokens: 200, cost: 1, requests: 30)
        ]
        let usage = snapshot(models)
        store.usage = usage
        let expected = try [Theme.mint, Theme.blue, Theme.violet].map {
            (marker: try renderedColor($0), bar: try renderedColor($0.opacity(0.75), background: Theme.elevated))
        }
        let cases: [(MixMetric, [Int])] = [(.cost, [0, 1, 2]), (.tokens, [1, 2, 0]),
                                         (.requests, [2, 0, 1]), (.cost, [0, 1, 2])]

        for (metric, order) in cases {
            // Each render creates a fresh view, as when the panel is reopened.
            let content = OverviewView(metric: metric).mixCard(usage, store: store)
                .frame(width: 456)
                .background(Theme.background)
                .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.cgImage)
            let bitmap = NSBitmapImageRep(cgImage: image)
            var markerRows: [Double] = []
            for (marker, bar) in expected {
                var rows: [Int] = []
                var barPixels = 0
                // Left edge contains only model markers and bars, not metric buttons.
                for y in 40..<bitmap.pixelsHigh {
                    for x in 14..<28 {
                        guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                        if matches(pixel, marker) { rows.append(y) }
                        if matches(pixel, bar) { barPixels += 1 }
                    }
                }
                XCTAssertFalse(rows.isEmpty, "Missing \(metric.rawValue) marker")
                XCTAssertGreaterThan(barPixels, 5, "Missing \(metric.rawValue) bar")
                markerRows.append(rows.isEmpty ? -1 : Double(rows.reduce(0, +)) / Double(rows.count))
            }
            XCTAssertEqual(markerRows.indices.sorted { markerRows[$0] < markerRows[$1] }, order,
                           "\(metric.rawValue) must reorder models without swapping colors")
        }
    }

    private func renderedColor(_ color: Color, background: Color = Theme.background) throws -> NSColor {
        // Calibrate against SwiftUI's actual renderer/color space rather than NSColor conversion.
        let renderer = ImageRenderer(content: Rectangle().fill(color).frame(width: 8, height: 8)
            .background(background).environment(\.colorScheme, .dark))
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        return try XCTUnwrap(bitmap.colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB))
    }

    private func matches(_ pixel: NSColor, _ expected: NSColor) -> Bool {
        abs(pixel.redComponent - expected.redComponent) < 0.025 &&
        abs(pixel.greenComponent - expected.greenComponent) < 0.025 &&
        abs(pixel.blueComponent - expected.blueComponent) < 0.025
    }

    private func makeStore(demo: Bool = false) -> AppStore {
        let name = "ModelColorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return AppStore(service: StubService(), demo: demo, defaults: defaults)
    }

    private func colors(in store: AppStore, ids: [String]) -> [Color] {
        ids.map { store.modelColor(for: $0) }
    }

    private func model(_ id: String, cost: Double) -> ModelUsage {
        ModelUsage(id: id, name: id, tokens: 100, cost: cost, requests: 1)
    }

    private func snapshot(_ models: [ModelUsage]) -> UsageSnapshot {
        UsageSnapshot(period: .day, totalCost: models.reduce(0) { $0 + $1.cost }, totalTokens: 0,
                      requests: 0, tokens: [], models: models, series: [])
    }
}

private struct StubService: EdgeeServing {
    struct Unavailable: Error {}
    func identity() async throws -> EdgeeIdentity { throw Unavailable() }
    func usage(for period: UsagePeriod, mode: UsageWindowMode) async throws -> UsageSnapshot { throw Unavailable() }
    func agents() async throws -> [AgentConfiguration] { throw Unavailable() }
    func availableModels(agentID: String) async throws -> [AvailableModel] { throw Unavailable() }
    func updateSetting(agentID: String, setting: AgentSetting, enabled: Bool) async throws { throw Unavailable() }
    func updateRoute(agentID: String, modelID: String?) async throws { throw Unavailable() }
    func login() async throws { throw Unavailable() }
}
