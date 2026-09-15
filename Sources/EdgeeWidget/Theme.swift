import SwiftUI
import EdgeeCore

enum Theme {
    static let background = Color(red: 0.045, green: 0.055, blue: 0.064)
    static let card = Color(red: 0.085, green: 0.099, blue: 0.11)
    static let elevated = Color(red: 0.12, green: 0.135, blue: 0.145)
    static let line = Color.white.opacity(0.075)
    static let text = Color(red: 0.92, green: 0.94, blue: 0.94)
    static let muted = Color(red: 0.48, green: 0.54, blue: 0.56)
    static let mint = Color(red: 0.70, green: 0.96, blue: 0.45)
    static let teal = Color(red: 0.36, green: 0.83, blue: 0.76)
    static let violet = Color(red: 0.69, green: 0.59, blue: 0.97)
    static let blue = Color(red: 0.40, green: 0.67, blue: 0.96)
    static let amber = Color(red: 1, green: 0.72, blue: 0.39)
    static let modelColors = [mint, blue, violet, teal, amber]
    static func color(_ kind: TokenKind) -> Color {
        switch kind { case .input: blue; case .cacheWrite: violet; case .cacheRead: teal; case .output: mint }
    }
}
enum Display {
    static func money(_ value: Double) -> String { value.formatted(.currency(code: "USD").precision(.fractionLength(2)).locale(Locale(identifier: "en_US"))) }
    static func compact(_ value: Double) -> String {
        if value >= 1_000_000 { return String(format: "%.2fM", value / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fK", value / 1_000) }
        return String(format: "%.0f", value)
    }
    static func percent(_ value: Double) -> String { String(format: "%.0f%%", max(0, value) * 100) }
}
struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View { content.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Theme.card, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.line)) }
}
struct SectionCaption: View {
    let title: String
    var trailing: String = ""
    var body: some View { HStack { Text(title).font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.5); Spacer(); Text(trailing).font(.system(size: 10, design: .monospaced)) }.foregroundStyle(Theme.muted) }
}
struct StatusPill: View {
    let label: String
    var color: Color = Theme.mint
    var body: some View { HStack(spacing: 5) { Circle().fill(color).frame(width: 5, height: 5); Text(label).font(.system(size: 9, weight: .semibold, design: .monospaced)).tracking(0.7) }.foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5).background(color.opacity(0.08), in: Capsule()).overlay(Capsule().strokeBorder(color.opacity(0.15))) }
}
struct EdgeeWordmark: View {
    var body: some View {
        Image(nsImage: BrandAssets.image(named: "EdgeeWordmark"))
            .resizable().renderingMode(.template).scaledToFit()
            .frame(width: 108, height: 26)
            .foregroundStyle(Theme.text)
            .accessibilityLabel("Edgee")
    }
}
struct SmallIconButton: View {
    let symbol: String
    let help: String
    var action: () -> Void
    var body: some View { Button(action: action) { Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.muted).frame(width: 28, height: 28).background(Theme.elevated.opacity(0.4), in: RoundedRectangle(cornerRadius: 8)) }.buttonStyle(.plain).help(help).accessibilityLabel(help) }
}
struct MintButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label.font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.background).padding(.horizontal, 14).padding(.vertical, 10).background(Theme.mint.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 10)) }
}
