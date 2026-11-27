import SwiftUI
import ThymeCore

/// The day timeline (PLAN.md §4.8): the in-use strip from total fires, then one lane per app or website used that
/// day, from Apple's samples. A block's opacity is the share of its stretch the app was in use.
struct TimelineLanes: View {
    let timeline: DayTimeline
    let items: [UUID: TrackedItem]
    let dayStart: Date
    var tint: Color = .accentColor

    @State private var wholeDay = false
    @State private var selected: UsageBlock?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Timeline").font(.headline)
                Spacer()
                Picker("Span", selection: $wholeDay) {
                    Text("Active hours").tag(false)
                    Text("Whole day").tag(true)
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
            if timeline.inUse.isEmpty && timeline.blocks.isEmpty {
                Text("No use recorded.").foregroundStyle(.secondary)
            } else {
                axis
                lane(title: Text("In use"), height: 8) { width in
                    ForEach(Array(timeline.inUse.enumerated()), id: \.offset) { _, minute in
                        bar(start: minute.start, end: minute.end, width: width, height: 8)
                            .fill(Color.gray.opacity(minute.inferred ? 0.4 : 1))
                    }
                }
                ForEach(lanes, id: \.self) { item in
                    lane(title: ItemName(item: items[item]), height: 14) { width in
                        ForEach(timeline.blocks.filter { $0.itemID == item }) { block in
                            bar(start: block.start, end: block.end, width: width, height: 14)
                                .fill(tint.opacity(0.25 + 0.75 * block.intensity))
                                .onTapGesture { selected = block }
                        }
                    }
                }
                if let selected {
                    detail(selected)
                }
            }
        }
    }

    /// Items used that day with blocks, most first (a website seen only inside an app has none).
    private var lanes: [UUID] {
        let drawn = Set(timeline.blocks.map(\.itemID))
        return timeline.items.filter { drawn.contains($0.key) }.sorted { $0.value.seconds > $1.value.seconds }.map(\.key)
    }

    private var span: DateInterval {
        let day = DateInterval(start: dayStart, duration: 86400)
        let starts = timeline.inUse.map(\.start) + timeline.blocks.map(\.start)
        let ends = timeline.inUse.map(\.end) + timeline.blocks.map(\.end)
        guard !wholeDay, let first = starts.min(), let last = ends.max() else { return day }
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let end = calendar.dateInterval(of: .hour, for: last)?.end ?? last
        return DateInterval(start: max(day.start, start), end: min(day.end, max(end, start.addingTimeInterval(3600))))
    }

    private func lane<Title: View, Bars: View>(title: Title, height: CGFloat,
                                               @ViewBuilder bars: @escaping (CGFloat) -> Bars) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.caption)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: height)
                    bars(geometry.size.width)
                }
            }
            .frame(height: height)
        }
    }

    private var axis: some View {
        GeometryReader { geometry in
            let hours = Int(span.duration / 3600)
            let step = max(1, hours / 6)
            ForEach(Array(stride(from: 0, through: hours, by: step)), id: \.self) { hour in
                let date = span.start.addingTimeInterval(Double(hour) * 3600)
                Text(date.formatted(.dateTime.hour()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .position(x: x(date, width: geometry.size.width), y: 6)
            }
        }
        .frame(height: 12)
    }

    private func bar(start: Date, end: Date, width: CGFloat, height: CGFloat) -> some Shape {
        let left = x(start, width: width)
        let right = max(left + 1.5, x(end, width: width))
        return Rectangle().path(in: CGRect(x: left, y: 0, width: right - left, height: height))
    }

    private func x(_ date: Date, width: CGFloat) -> CGFloat {
        let fraction = date.timeIntervalSince(span.start) / span.duration
        return CGFloat(min(max(fraction, 0), 1)) * width
    }

    private func detail(_ block: UsageBlock) -> some View {
        HStack {
            ItemName(item: items[block.itemID], showIcon: false)
            Spacer()
            Text("\(Format.time(block.start))–\(Format.time(block.end)) · \(Format.minutes(Int((block.seconds / 60).rounded())))")
                .monospacedDigit()
        }
        .font(.footnote)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .onTapGesture { selected = nil }
    }
}
