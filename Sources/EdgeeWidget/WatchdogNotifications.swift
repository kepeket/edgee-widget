import AppKit
import UserNotifications
import EdgeeCore

@MainActor
final class WatchdogNotifications: ObservableObject {
    static let category = "watchdog.advice"
    static let routingAction = "watchdog.review-routing"
    @Published private(set) var enabled: Bool
    @Published private(set) var allowDuringFocus: Bool
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var timeSensitiveSetting: UNNotificationSetting = .notSupported
    @Published private(set) var alertSetting: UNNotificationSetting = .notSupported
    @Published private(set) var busy = false
    @Published var message: String?
    private let defaults: UserDefaults
    let supportsTimeSensitive: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: "notificationsEnabled")
        allowDuringFocus = defaults.bool(forKey: "watchdog.allowDuringFocus")
        supportsTimeSensitive = Bundle.main.object(forInfoDictionaryKey: "EdgeeTimeSensitiveNotificationsEnabled") as? Bool ?? false
    }

    static func registerCategories() {
        let action = UNNotificationAction(identifier: routingAction, title: "Review model routing", options: [.foreground])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [action], intentIdentifiers: [], options: [])
        ])
    }

    var canDeliver: Bool { enabled && authorization == .authorized }
    var status: String {
        if authorization == .denied { return "Blocked by macOS. Allow Edgee in Notifications settings." }
        if !enabled { return "Off. Enable to request macOS permission." }
        if authorization == .notDetermined { return "Permission has not been requested yet." }
        if alertSetting != .enabled { return "Notifications allowed; banners are disabled in macOS." }
        return "Notifications allowed by macOS."
    }
    var focusStatus: String {
        if !supportsTimeSensitive {
            return "To receive alerts during DND, allow Edgee in System Settings → Focus → Do Not Disturb → Allowed Apps. This build uses standard notifications."
        }
        if timeSensitiveSetting != .enabled {
            return "Allow Time Sensitive notifications for Edgee in Notifications settings, and in each Focus you use."
        }
        return "Time Sensitive alerts are allowed for Edgee. Your Focus must also allow Time Sensitive notifications."
    }

    func refreshStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorization = settings.authorizationStatus
        timeSensitiveSetting = settings.timeSensitiveSetting
        alertSetting = settings.alertSetting
    }

    func setEnabled(_ value: Bool) async {
        guard !busy else { return }
        if !value {
            enabled = false
            defaults.set(false, forKey: "notificationsEnabled")
            return
        }
        busy = true
        defer { busy = false }
        message = nil
        do {
            enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            defaults.set(enabled, forKey: "notificationsEnabled")
        } catch { message = "Could not request notification permission: \(error.localizedDescription)" }
        await refreshStatus()
    }

    func setAllowDuringFocus(_ value: Bool) async {
        if value && !enabled { await setEnabled(true) }
        allowDuringFocus = value && enabled
        defaults.set(allowDuringFocus, forKey: "watchdog.allowDuringFocus")
        await refreshStatus()
    }

    static func content(for alert: WatchdogAlert, timeSensitive: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.message
        content.sound = .default
        content.categoryIdentifier = category
        content.threadIdentifier = "watchdog.\(alert.kind.rawValue)"
        content.userInfo = ["watchdogAlertID": alert.id]
        content.interruptionLevel = timeSensitive ? .timeSensitive : .active
        return content
    }

    func send(_ alert: WatchdogAlert, key: String) async throws {
        let content = Self.content(for: alert, timeSensitive: allowDuringFocus && supportsTimeSensitive)
        try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: key, content: content, trigger: nil))
    }

    func sendTest() async {
        await refreshStatus()
        guard canDeliver else { message = "Enable notifications and allow Edgee in macOS first."; return }
        do {
            let alert = WatchdogAlert(id: "test", severity: .warning, title: "Watchdog is ready",
                message: "This is a test. Use Review model routing to open your routing preview.", kind: .thinkingTokens)
            try await send(alert, key: "watchdog.test")
            message = "Test submitted to macOS. If it doesn't appear, check Notifications and Focus settings."
        } catch { message = "Test notification failed: \(error.localizedDescription)" }
    }

    func openSettings(focus: Bool = false) {
        let pane = focus ? "com.apple.Focus-Settings.extension" : "com.apple.Notifications-Settings.extension"
        if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
    }
}
