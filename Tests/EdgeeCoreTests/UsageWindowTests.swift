import XCTest
@testable import EdgeeCore

final class UsageWindowTests: XCTestCase {
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    func testAllSixRequestBodiesRetainUserScopeAndGranularity() {
        let presets: [(UsageWindowMode, [String])] = [(.rolling, ["24h", "7d", "30d"]), (.calendar, ["today", "this_week", "this_month"])]
        for (mode, expected) in presets {
            for (period, value) in zip(UsagePeriod.allCases, expected) {
                let window = UsageWindow(period: period, mode: mode)
                let body = EdgeeService.usageRequestBody(window: window, userID: "member-123")
                XCTAssertEqual(body["period"] as? String, value)
                XCTAssertEqual(body["user_id"] as? [String], ["member-123"])
                XCTAssertEqual(body["interval"] as? String, period == .day ? "hour" : "day")
            }
        }
    }

    func testRollingWindowsAreExactDurationsAcrossDST() {
        for end in [date("2026-03-08T03:30:00-07:00"), date("2026-11-01T01:30:00-08:00")] {
            for (period, hours) in zip(UsagePeriod.allCases, [24, 168, 720]) {
                let window = UsageWindow(period: period, end: end)
                XCTAssertEqual(end.timeIntervalSince(window.start), Double(hours * 3600))
            }
        }
    }

    func testCalendarBoundariesUseUTCAndMondayAcrossYears() {
        let end = date("2026-01-01T01:00:00+01:00")
        XCTAssertEqual(UsageWindow(period: .day, mode: .calendar, end: end).start, date("2026-01-01T00:00:00Z"))
        XCTAssertEqual(UsageWindow(period: .week, mode: .calendar, end: end).start, date("2025-12-29T00:00:00Z"))
        XCTAssertEqual(UsageWindow(period: .month, mode: .calendar, end: end).start, date("2026-01-01T00:00:00Z"))
        let sunday = date("2026-09-20T23:59:59Z")
        let monday = sunday.addingTimeInterval(1)
        XCTAssertEqual(UsageWindow(period: .week, mode: .calendar, end: sunday).start, date("2026-09-14T00:00:00Z"))
        XCTAssertEqual(UsageWindow(period: .week, mode: .calendar, end: monday).start, monday)
    }

    func testCalendarMonthHandlesLeapDayAndDoesNotMeanThirtyDays() {
        let leap = date("2024-02-29T23:59:59Z")
        let february = UsageWindow(period: .month, mode: .calendar, end: leap)
        XCTAssertEqual(february.start, date("2024-02-01T00:00:00Z"))
        XCTAssertFalse(february.isCurrent(at: leap.addingTimeInterval(1)))
        XCTAssertEqual(UsageWindow(period: .month, mode: .calendar, end: date("2026-03-31T12:00:00Z")).start, date("2026-03-01T00:00:00Z"))
    }

    func testCalendarDayIgnoresDeviceDSTOffset() {
        for end in [date("2026-03-08T23:30:00-07:00"), date("2026-11-01T23:30:00-08:00")] {
            let window = UsageWindow(period: .day, mode: .calendar, end: end)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = UsageWindow.consoleTimeZone
            XCTAssertEqual(calendar.component(.hour, from: window.start), 0)
            XCTAssertLessThan(end.timeIntervalSince(window.start), 86_400)
        }
    }

    func testLegacySnapshotDecodesAsRollingAndNewSnapshotRoundTrips() throws {
        let current = DemoData.usage(.month, mode: .calendar)
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(current)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: encoded), current)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "window")
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.windowMode, .rolling)
        XCTAssertEqual(decoded.effectiveWindow.end.timeIntervalSince(decoded.effectiveWindow.start), 30 * 86_400)
    }
}
