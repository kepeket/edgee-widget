import Foundation

public enum UsageWindowMode: String, CaseIterable, Codable, Sendable {
    case rolling, calendar
    public var title: String { self == .rolling ? "Rolling" : "Calendar" }
}

/// A request's time window. Console calendar presets use UTC, with Monday weeks.
/// Capture one end time for both aggregate usage and session filtering.
public struct UsageWindow: Codable, Sendable, Equatable {
    public let period: UsagePeriod
    public let mode: UsageWindowMode
    public let end: Date

    public init(period: UsagePeriod, mode: UsageWindowMode = .rolling, end: Date = Date()) {
        self.period = period; self.mode = mode; self.end = end
    }

    public static let consoleTimeZone = TimeZone(secondsFromGMT: 0)!
    private static var consoleCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = consoleTimeZone
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    public var start: Date {
        if mode == .rolling {
            let days: Double = switch period { case .day: 1; case .week: 7; case .month: 30 }
            return end.addingTimeInterval(-days * 86_400)
        }
        let component: Calendar.Component = switch period {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
        return Self.consoleCalendar.dateInterval(of: component, for: end)!.start
    }

    public var apiValue: String {
        if mode == .rolling { return period.cliValue }
        return switch period { case .day: "today"; case .week: "this_week"; case .month: "this_month" }
    }
    public var interval: String { period == .day ? "hour" : "day" }

    /// Rolling windows move continuously; calendar observations must share a boundary.
    public func canCompare(with other: UsageWindow) -> Bool {
        period == other.period && mode == other.mode && (mode == .rolling || start == other.start)
    }
    public func isCurrent(at date: Date) -> Bool {
        mode == .rolling || start == UsageWindow(period: period, mode: mode, end: date).start
    }
}

public extension UsagePeriod {
    func title(in mode: UsageWindowMode) -> String {
        guard mode == .calendar else { return title }
        return switch self { case .day: "Today"; case .week: "This week"; case .month: "This month" }
    }
    func windowLabel(in mode: UsageWindowMode) -> String {
        mode == .rolling ? windowLabel : title(in: mode) + " (UTC)"
    }
}
