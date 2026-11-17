import SwiftUI
import ThymeCore

/// The day as a calendar: hours top to bottom, each app's blocks drawn like events. Apps in use in the same stretch
/// sit side by side for that stretch (`CalendarLayout`). The thin strip beside the hours is the phone's in-use minutes.
struct UsageCalendar: View {
    let timeline: DayTimeline
    let items: [UUID: TrackedItem]
    let dayStart: Date
    var tint: Color = .accentColor
    var showWebsites = false
    /// Points per hour.
    var scale: CGFloat = 120

    @State private var selected: CalendarPiece?
    @State private var position = ScrollPosition(edge: .top)
    @State private var visible = CGRect.zero

    private let gutter: CGFloat = 52
    /// The shortest a piece is drawn: shorter ones would vanish.
    private let minHeight: CGFloat = 2

    var body: some View {
        let placed = CalendarLayout.place(blocks)
        ScrollView {
            ZStack(alignment: .topLeading) {
                hours
                inUseStrip
                GeometryReader { geometry in
                    let width = geometry.size.width - gutter - 8
                    ForEach(placed) { piece in
                        event(piece, width: width)
                    }
                }
                nowLine
            }
            .frame(height: scale * 24 + 16)
            .padding(.trailing, 8)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: CGRect.self, of: \.visibleRect) { _, rect in visible = rect }
        .onAppear(perform: scrollToFirstUse)
        .onChange(of: dayStart, scrollToFirstUse)
        // Zooming keeps the time in the middle of the screen where it was.
        .onChange(of: scale) { old, new in
            let middle = (visible.midY - 8) / old * new + 8
            position.scrollTo(y: max(0, middle - visible.height / 2))
        }
        .overlay {
            if blocks.isEmpty && timeline.inUse.isEmpty {
                ContentUnavailableView("No use recorded", systemImage: "calendar")
            }
        }
    }

    private var blocks: [UsageBlock] {
        timeline.blocks.filter { showWebsites || items[$0.itemID]?.kind != .domain }
    }

    /// To an hour before the first use, or the current hour on a day with none yet.
    private func scrollToFirstUse() {
        let first = (blocks.map(\.start) + timeline.inUse.map(\.start)).min()
            ?? (Date().timeIntervalSince(dayStart) < 86400 ? Date() : dayStart.addingTimeInterval(8 * 3600))
        let hour = max(0, Int(first.timeIntervalSince(dayStart) / 3600) - 1)
        position.scrollTo(y: CGFloat(hour) * scale)
    }

    private func y(_ date: Date) -> CGFloat {
        CGFloat(min(max(date.timeIntervalSince(dayStart), 0), 86400) / 3600) * scale + 8
    }

    private var hours: some View {
        VStack(spacing: 0) {
            ForEach(0...24, id: \.self) { hour in
                HStack(alignment: .center, spacing: 6) {
                    Text(hour == 24 ? "" : dayStart.addingTimeInterval(Double(hour) * 3600).formatted(.dateTime.hour()))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: gutter - 6, alignment: .trailing)
                    Rectangle().fill(.separator).frame(height: 0.5)
                }
                .frame(height: 16)
                .frame(height: hour == 24 ? 16 : scale, alignment: .top)
            }
        }
    }

    private var inUseStrip: some View {
        ForEach(Array(timeline.inUse.enumerated()), id: \.offset) { _, minute in
            Rectangle()
                .fill(tint.opacity(minute.inferred ? 0.35 : 0.8))
                .frame(width: 3, height: max(1, y(minute.end) - y(minute.start)))
                .offset(x: gutter - 1, y: y(minute.start))
        }
    }

    @ViewBuilder
    private var nowLine: some View {
        let now = Date()
        if now >= dayStart, now.timeIntervalSince(dayStart) < 86400 {
            HStack(spacing: 0) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Rectangle().fill(.red).frame(height: 1)
            }
            .offset(x: gutter - 3.5, y: y(now) - 3.5)
            .allowsHitTesting(false)
        }
    }

    private func event(_ piece: CalendarPiece, width: CGFloat) -> some View {
        let block = piece.block
        let column = width / CGFloat(piece.columns)
        let isFirst = piece.start == block.start, isLast = piece.end == block.end
        // A point of space below each block, as between events in a calendar.
        let height = max(minHeight, y(piece.end) - y(piece.start) - (isLast ? 1 : 0))
        let color = Self.color(for: block.itemID)
        let shape = UnevenRoundedRectangle(topLeadingRadius: isFirst ? 4 : 0, bottomLeadingRadius: isLast ? 4 : 0,
                                           bottomTrailingRadius: isLast ? 4 : 0, topTrailingRadius: isFirst ? 4 : 0)
        return ZStack(alignment: .topLeading) {
            shape.fill(color.opacity(0.12 + 0.28 * block.intensity))
            // Use the phone's in-use minutes don't place: its time is a guess, so dashed.
            if block.somewhereIn != nil {
                shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            Rectangle().fill(color).frame(width: 3)
            if piece.isLabeled && height >= 14 {
                VStack(alignment: .leading, spacing: 1) {
                    ItemName(item: items[block.itemID], showIcon: height >= 36 && piece.columns <= 2)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if height >= 32 {
                        Text("\(Format.time(block.start)) · \(duration(block))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.leading, 7)
                .padding(.trailing, 3)
                .padding(.vertical, height >= 32 ? 2 : 0)
            }
        }
        .clipShape(shape)
        .frame(width: max(4, column - 2), height: height, alignment: .topLeading)
        .contentShape(.rect)
        .onTapGesture { selected = piece }
        .popover(isPresented: Binding(get: { selected == piece }, set: { if !$0 { selected = nil } })) {
            detail(block).presentationCompactAdaptation(.popover)
        }
        .offset(x: gutter + 4 + column * CGFloat(piece.column), y: y(piece.start))
    }

    private func duration(_ block: UsageBlock) -> String {
        block.seconds < 60 ? "\(Int(block.seconds.rounded())) s" : Format.minutes(Int((block.seconds / 60).rounded()))
    }

    private func detail(_ block: UsageBlock) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ItemName(item: items[block.itemID]).font(.headline)
            Text("\(Format.time(block.start))–\(Format.time(block.end))").monospacedDigit()
            Text("\(duration(block)) of use")
            if let window = block.somewhereIn {
                Text("Sometime between \(Format.time(window.start)) and \(Format.time(window.end)): the phone's check-ins don't say when.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if block.intensity < 0.95 {
                Text("In use for \(Int((block.intensity * 100).rounded()))% of this stretch, alongside other apps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(idealWidth: 260)
    }

    /// Stable per app, across days and launches.
    static func color(for item: UUID) -> Color {
        let palette: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown, .red, .mint, .cyan, .yellow]
        let hash = withUnsafeBytes(of: item.uuid) { $0.reduce(UInt(0)) { $0 &* 31 &+ UInt($1) } }
        return palette[Int(hash % UInt(palette.count))]
    }
}
