import Charts
import EdgeeCore
import SwiftUI

/// Hover decoration stays outside ChartContent so it never changes plot layout or scales.
struct SpendChart: View {
    let points: [UsagePoint]
    @State private var selectedTime: Date?

    private var selectedPoint: UsagePoint? {
        guard let selectedTime else { return nil }
        return points.min { abs($0.date.timeIntervalSince(selectedTime)) < abs($1.date.timeIntervalSince(selectedTime)) }
    }
    private var timeDomain: ClosedRange<Date> {
        let first = points.map(\.date).min() ?? Date()
        let last = points.map(\.date).max() ?? first
        return first...max(last, first.addingTimeInterval(1))
    }
    private var costMaximum: Double { max(0.001, (points.map(\.cost).max() ?? 0) * 1.05) }

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Time", point.date), y: .value("Cost", point.cost))
                .foregroundStyle(LinearGradient(colors: [Theme.mint.opacity(0.22), Theme.mint.opacity(0)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Time", point.date), y: .value("Cost", point.cost))
                .foregroundStyle(Theme.mint)
                .lineStyle(StrokeStyle(lineWidth: 1.8))
                .interpolationMethod(.monotone)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: timeDomain)
        .chartYScale(domain: 0...costMaximum)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                if let plotFrame = proxy.plotFrame {
                    let plot = geometry[plotFrame]
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            selectedTime = proxy.value(atX: min(max(0, value.location.x - plot.minX), plot.width), as: Date.self)
                        })
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard plot.contains(location) else { selectedTime = nil; return }
                                selectedTime = proxy.value(atX: location.x - plot.minX, as: Date.self)
                            case .ended:
                                selectedTime = nil
                            }
                        }
                    if let selectedPoint, let position = proxy.position(forX: selectedPoint.date) {
                        let x = plot.minX + position
                        Path { path in
                            path.move(to: CGPoint(x: x, y: plot.minY))
                            path.addLine(to: CGPoint(x: x, y: plot.maxY))
                        }
                        .stroke(Theme.muted.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .allowsHitTesting(false)
                        Text(Display.money(selectedPoint.cost))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(Theme.elevated, in: RoundedRectangle(cornerRadius: 4))
                            .position(x: min(max(x, 40), max(40, geometry.size.width - 40)), y: plot.minY + 8)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
        .frame(height: 40)
        .onChange(of: points) { _, _ in selectedTime = nil }
        .accessibilityLabel("Spend history, \(points.count) time intervals")
    }
}
