import SwiftUI
import ThymeCore

/// When in the week use happens (`UsageHeatmap`), GitHub's way: weekdays down, hours across, darker for more use on
/// average (fixed bands of minutes, `UsageHeatmap.level`). Hollow squares are hours no reported day covers yet. Tap a square for its numbers.
struct UsageHeatmapView: View {
    let heatmap: UsageHeatmap
    var tint: Color = .accentColor
    @State private var selected: UsageHeatmap.Cell?
    /// The grid's width, measured: squares sized to fit it.
    @State private var width: CGFloat = 0

    private let spacing: CGFloat = 2
    private let gutter: CGFloat = 30

    private var side: CGFloat { max(4, (width - gutter - spacing * 24) / 24) }

    var body: some View {
        let calendar = Calendar.current
        let weekdays = (0..<7).map { (calendar.firstWeekday - 1 + $0) % 7 + 1 }
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: spacing) {
                ForEach(weekdays, id: \.self) { weekday in
                    HStack(spacing: spacing) {
                        Text(calendar.shortStandaloneWeekdaySymbols[weekday - 1])
                            .frame(width: gutter, height: side, alignment: .leading)
                        ForEach(0..<24, id: \.self) { hour in
                            square(heatmap.cell(weekday: weekday, hour: hour))
                        }
                    }
                }
                HStack(spacing: spacing) {
                    Color.clear.frame(width: gutter, height: 1)
                    ForEach(0..<24, id: \.self) { hour in
                        Color.clear.frame(width: side, height: 12)
                            .overlay(alignment: .leading) {
                                if hour % 6 == 0 { Text(Self.hourStart(hour), format: .dateTime.hour()).fixedSize() }
                            }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
            HStack(alignment: .firstTextBaseline) {
                Text(selected.map(describe) ?? summary)
                    .font(.caption)
                    .foregroundStyle(selected == nil ? .secondary : .primary)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                legend
            }
        }
        .padding(.vertical, 4)
    }

    private func square(_ cell: UsageHeatmap.Cell) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        return shape
            .fill(fill(cell))
            .overlay { if cell.seconds == nil { shape.strokeBorder(.secondary.opacity(0.3), lineWidth: 0.5) } }
            .overlay { if selected == cell { shape.strokeBorder(.primary, lineWidth: 1.5) } }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onTapGesture { selected = selected == cell ? nil : cell }
    }

    private func fill(_ cell: UsageHeatmap.Cell) -> Color {
        guard cell.seconds != nil else { return .clear }
        return Self.fill(level: heatmap.level(cell), tint: tint)
    }

    static func fill(level: Int, tint: Color) -> Color {
        level == 0 ? Color.secondary.opacity(0.15) : tint.opacity([0.3, 0.5, 0.75, 1][level - 1])
    }

    private var legend: some View {
        HStack(spacing: spacing) {
            Text("Less").padding(.trailing, 2)
            ForEach(0..<5, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2).fill(Self.fill(level: level, tint: tint)).frame(width: 10, height: 10)
            }
            Text("More").padding(.leading, 2)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }

    // MARK: - Text

    static let footer = "Average use in each hour of the week over the last 4 weeks, on the days the phone reported use. Darker squares mean 5, 15 and 30 min or more. Tap a square for its numbers."

    private var summary: String {
        guard let busiest = heatmap.busiest else { return "No use in the last 4 weeks." }
        return "Busiest: \(describe(busiest))"
    }

    /// "Saturday 8 PM–9 PM: 15 min on average".
    private func describe(_ cell: UsageHeatmap.Cell) -> String {
        let day = Calendar.current.standaloneWeekdaySymbols[cell.weekday - 1]
        let hours = "\(Self.hourStart(cell.hour).formatted(.dateTime.hour()))–\(Self.hourStart(cell.hour + 1).formatted(.dateTime.hour()))"
        guard let seconds = cell.seconds else { return "\(day) \(hours): not reported yet" }
        let use = seconds == 0 ? "no use" : seconds < 30 ? "under 1 min" : Format.minutes(Int((seconds / 60).rounded()))
        return "\(day) \(hours): \(use) on average, over \(cell.days) \(cell.days == 1 ? "day" : "days")"
    }

    /// `hour` o'clock on a day without a clock change, for its label (24 is the next midnight).
    private static func hourStart(_ hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 15, hour: hour))!
    }
}
