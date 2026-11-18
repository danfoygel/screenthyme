import SwiftUI
import ThymeCore

/// The day as a calendar: hours top to bottom, each app's blocks drawn like events. Blocks that overlap sit side by
/// side in swim lanes (`CalendarLayout`). Long stretches with nothing drawn are cut out of the tape
/// (`CalendarAxis`). The line beside the hours says how well each stretch is placed (`Coverage`): use the check-ins
/// don't place is drawn dashed, at a best guess.
struct UsageCalendar: View {
    let timeline: DayTimeline
    let items: [UUID: TrackedItem]
    let dayStart: Date
    var showWebsites = false
    /// Leaves out blocks with under `shortUse` of use (after joining short pauses): brief switches between apps.
    var hideShort = true
    /// Points per hour; pinching changes it.
    @Binding var scale: Double

    static let scales: ClosedRange<Double> = 30...960
    static let shortUse: TimeInterval = 120

    @State private var selected: CalendarPiece?
    @State private var position = ScrollPosition(edge: .top)
    @State private var geometry: ScrollGeometry?
    /// While pinching. Gesture state, so a pinch that's cancelled can't leave a stale anchor for the next one.
    @GestureState private var pinch: Pinch?
    /// The pinch already scrolled to keep its spot in place; the scale change it commits needn't.
    @State private var pinched = false

    private struct Pinch: Equatable {
        var magnification: Double
        /// The time under the fingers when the pinch began, and its height on screen.
        var anchor: Date
        var screenY: CGFloat
    }

    private var visible: CGRect { geometry?.visibleRect ?? .zero }

    /// Points per hour, as drawn.
    private var hourHeight: Double { pinch.map { Self.clamp(scale * $0.magnification) } ?? scale }

    private static func clamp(_ scale: Double) -> Double {
        min(max(scale, scales.lowerBound), scales.upperBound)
    }

    private let gutter: CGFloat = 52
    /// Above the first hour line, so its label isn't cut off.
    private let inset: CGFloat = 8
    /// The shortest a piece is drawn: shorter ones would vanish.
    private let minHeight: CGFloat = 2

    var body: some View {
        let blocks = blocks
        let axis = makeAxis(for: blocks, scale: hourHeight)
        let placed = CalendarLayout.place(blocks)
        ScrollView {
            ZStack(alignment: .topLeading) {
                ticks(axis)
                coverageLine(axis)
                GeometryReader { proxy in
                    let width = proxy.size.width - gutter - 8
                    ForEach(placed) { piece in
                        event(piece, axis: axis, width: width)
                    }
                }
                ForEach(axis.breaks, id: \.interval) { tapeBreak($0) }
                nowLine(axis)
            }
            .frame(height: axis.height + inset * 2)
            .padding(.trailing, 8)
        }
        .scrollPosition($position)
        // On the scroll view, not its content, so the pinch's location is on screen (on the content it moves with
        // the scrolling). Scrolling stops while pinching: a pan or a fling under the fingers would fight the anchor.
        .simultaneousGesture(magnify)
        .scrollDisabled(pinch != nil)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, new in geometry = new }
        .onAppear(perform: scrollToFirstUse)
        .onChange(of: dayStart, scrollToFirstUse)
        // Pinching keeps the time under the fingers in place; when it ends (or is cancelled), at the scale it leaves.
        .onChange(of: pinch) { old, new in
            if let pinch = new ?? old { scroll(to: pinch.anchor, screenY: pinch.screenY, scale: hourHeight) }
        }
        // Zooming with the buttons keeps the time in the middle of the screen where it was.
        .onChange(of: scale) { old, new in
            if pinched {
                pinched = false
                return
            }
            let middle = makeAxis(for: blocks, scale: old).date(at: visible.midY - inset)
            scroll(to: middle, screenY: visible.height / 2, scale: new)
        }
        .overlay {
            if blocks.isEmpty && timeline.coverage.isEmpty {
                ContentUnavailableView("No use recorded", systemImage: "calendar")
            }
        }
    }

    private var blocks: [UsageBlock] {
        CalendarLayout.visible(timeline.blocks.filter { showWebsites || items[$0.itemID]?.kind != .domain },
                               minimum: hideShort ? Self.shortUse : 0)
    }

    private var day: DateInterval {
        DateInterval(start: dayStart, end: Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86400))
    }

    /// Keeps the blocks drawn and the current time; cuts the rest where it's long.
    private func makeAxis(for blocks: [UsageBlock], scale: Double) -> CalendarAxis {
        let now = Date()
        let keep = blocks.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) }
            + (day.contains(now) ? [DateInterval(start: now, duration: 0)] : [])
        return CalendarAxis(day: day, scale: scale, keep: keep)
    }

    /// Scrolls so `date` sits `screenY` points down the screen, as far as the content allows.
    private func scroll(to date: Date, screenY: CGFloat, scale: Double) {
        let axis = makeAxis(for: blocks, scale: scale)
        let bottom = max(0, axis.height + inset * 2 + (geometry?.contentInsets.bottom ?? 0) - visible.height)
        position.scrollTo(y: min(max(0, axis.y(date) + inset - screenY), bottom))
    }

    /// To a little before the first use, or the current time on a day with none yet.
    private func scrollToFirstUse() {
        let first = blocks.map(\.start).min() ?? timeline.coverage.first { $0.coverage != .quiet }?.start
            ?? (day.contains(Date()) ? Date() : dayStart.addingTimeInterval(8 * 3600))
        scroll(to: first, screenY: 80, scale: hourHeight)
    }

    /// Pinching stretches or squeezes the time axis around the fingers.
    private var magnify: some Gesture {
        MagnifyGesture()
            .updating($pinch) { value, pinch, _ in
                let screenY = pinch?.screenY ?? value.startLocation.y
                let anchor = pinch?.anchor
                    ?? makeAxis(for: blocks, scale: scale).date(at: visible.minY + screenY - inset)
                pinch = Pinch(magnification: value.magnification, anchor: anchor, screenY: screenY)
            }
            .onEnded { value in
                let new = Self.clamp(scale * value.magnification)
                if new != scale {
                    pinched = true
                    scale = new
                }
            }
    }

    /// The time labels and their lines: hours, and minutes as far as there's room.
    private func ticks(_ axis: CalendarAxis) -> some View {
        ForEach(axis.ticks(spacing: 24), id: \.self) { tick in
            let isHour = Calendar.current.component(.minute, from: tick) == 0
            HStack(alignment: .center, spacing: 6) {
                Group {
                    if tick == axis.day.end {
                        Text("")
                    } else if isHour {
                        Text(tick.formatted(.dateTime.hour()))
                    } else {
                        Text(Self.minuteFormat.string(from: tick))
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: gutter - 6, alignment: .trailing)
                Rectangle().fill(.separator.opacity(isHour ? 1 : 0.4)).frame(height: 0.5)
            }
            .frame(height: 16)
            .offset(y: axis.y(tick) + inset - 8)
        }
    }

    /// "2:15" (or "14:15"): the locale's own hour pattern, without AM/PM. Formatting with the AM/PM omitted pads the
    /// hour to "02:15" on some phones.
    private static let minuteFormat: DateFormatter = {
        let formatter = DateFormatter()
        let pattern = DateFormatter.dateFormat(fromTemplate: "jmm", options: 0, locale: .current) ?? "h:mm"
        formatter.dateFormat = pattern.replacingOccurrences(of: "a", with: "").trimmingCharacters(in: .whitespaces)
        return formatter
    }()

    /// A stretch cut out of the tape: torn edges, and what was cut.
    private func tapeBreak(_ segment: CalendarAxis.Segment) -> some View {
        let interval = segment.interval
        let blind = timeline.coverage.contains {
            $0.coverage == .blind && $0.start < interval.end && $0.end > interval.start
        }
        let minutes = Int((interval.duration / 60).rounded())
        return ZStack {
            TornTape().fill(Color(uiColor: .secondarySystemBackground))
            TornTape(edgesOnly: true).stroke(.separator, lineWidth: 1)
            HStack(spacing: 4) {
                Text("\(Format.time(interval.start))–\(Format.time(interval.end))")
                Text("·")
                Text(blind ? "\(Format.minutes(minutes)), no check-ins" : Format.minutes(minutes))
            }
            .font(.caption2)
            .foregroundStyle(blind ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .lineLimit(1)
        }
        .frame(height: segment.height)
        .offset(y: segment.top + inset)
        .allowsHitTesting(false)
    }

    private func coverageLine(_ axis: CalendarAxis) -> some View {
        ForEach(Array(timeline.coverage.enumerated()), id: \.offset) { _, span in
            Rectangle()
                .fill(Self.color(for: span.coverage))
                .frame(width: 3, height: max(1, axis.y(span.end) - axis.y(span.start)))
                .offset(x: gutter - 1, y: axis.y(span.start) + inset)
        }
    }

    static func color(for coverage: Coverage) -> Color {
        switch coverage {
        case .placed: .green
        case .quiet: .gray.opacity(0.5)
        case .blind: .red
        case .burst: .yellow
        }
    }

    @ViewBuilder
    private func nowLine(_ axis: CalendarAxis) -> some View {
        let now = Date()
        if day.contains(now) {
            HStack(spacing: 0) {
                Circle().fill(.red).frame(width: 7, height: 7)
                Rectangle().fill(.red).frame(height: 1)
            }
            .offset(x: gutter - 3.5, y: axis.y(now) + inset - 3.5)
            .allowsHitTesting(false)
        }
    }

    private func event(_ piece: CalendarPiece, axis: CalendarAxis, width: CGFloat) -> some View {
        let block = piece.block
        let column = width / CGFloat(piece.columns)
        // A point of space below each block, as between events in a calendar.
        let height = max(minHeight, axis.y(block.end) - axis.y(block.start) - 1)
        let color = Self.color(for: block.itemID)
        let shape = RoundedRectangle(cornerRadius: 4)
        return ZStack(alignment: .topLeading) {
            shape.fill(color.opacity(0.12 + 0.28 * block.intensity))
            // Use the phone's in-use minutes don't place: its time is a guess, so dashed.
            if block.somewhereIn != nil {
                shape.strokeBorder(color, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            Rectangle().fill(color).frame(width: 3)
            if height >= 14 {
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
        .offset(x: gutter + 4 + column * CGFloat(piece.column), y: axis.y(block.start) + inset)
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

/// A band across the calendar with zigzag edges, like tape torn and rejoined. `edgesOnly` draws just the two edges.
private struct TornTape: Shape {
    var edgesOnly = false
    private let tooth: CGFloat = 8, depth: CGFloat = 3, margin: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let top = zigzag(y: rect.minY + margin, in: rect)
        let bottom = zigzag(y: rect.maxY - margin - depth, in: rect)
        var path = Path()
        if edgesOnly {
            path.addLines(top)
            path.addLines(bottom)
        } else {
            path.addLines(top + bottom.reversed())
            path.closeSubpath()
        }
        return path
    }

    private func zigzag(y: CGFloat, in rect: CGRect) -> [CGPoint] {
        stride(from: rect.minX, through: rect.maxX + tooth, by: tooth / 2).enumerated().map { index, x in
            CGPoint(x: min(x, rect.maxX), y: y + (index.isMultiple(of: 2) ? 0 : depth))
        }
    }
}
