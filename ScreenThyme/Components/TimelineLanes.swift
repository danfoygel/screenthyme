import SwiftUI
import ThymeCore

/// The day timeline (PLAN.md §4.8): a minute-by-minute in-use strip, then one lane per app used that day.
/// Opacity shows confidence; mixed and unexplained time get their own lanes.
struct TimelineLanes: View {
    let timeline: DayTimeline
    let items: [UUID: TrackedItem]
    let dayStart: Date
    var tint: Color = .accentColor

    @State private var wholeDay = false
    @State private var selected: Segment?

    private enum Lane: Hashable {
        case item(UUID), mixed, unexplained
    }

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
            if timeline.inUse.isEmpty {
                Text("No use recorded.").foregroundStyle(.secondary)
            } else {
                axis
                lane(title: Text("In use"), bars: timeline.inUse.map { ($0.start, $0.end, $0.inferred ? 0.4 : 1.0) },
                     color: .gray)
                ForEach(lanes, id: \.self) { lane in
                    laneView(lane)
                }
                if let selected {
                    detail(selected)
                }
            }
        }
    }

    // MARK: - Layout

    private var span: DateInterval {
        let day = DateInterval(start: dayStart, duration: 86400)
        guard !wholeDay, let first = timeline.inUse.first?.start, let last = timeline.inUse.map(\.end).max() else {
            return day
        }
        let calendar = Calendar.current
        let start = calendar.dateInterval(of: .hour, for: first)?.start ?? first
        let end = calendar.dateInterval(of: .hour, for: last)?.end ?? last
        return DateInterval(start: max(day.start, start), end: min(day.end, max(end, start.addingTimeInterval(3600))))
    }

    private var lanes: [Lane] {
        var minutes: [UUID: Int] = [:]
        var hasMixed = false, hasUnexplained = false
        for segment in timeline.segments {
            switch segment.owner {
            case let .item(id): minutes[id, default: 0] += segment.minutes
            case .mixed: hasMixed = true
            case .unexplained: hasUnexplained = true
            }
        }
        var lanes = minutes.sorted { $0.value > $1.value }.map { Lane.item($0.key) }
        if hasMixed { lanes.append(.mixed) }
        if hasUnexplained { lanes.append(.unexplained) }
        return lanes
    }

    @ViewBuilder
    private func laneView(_ lane: Lane) -> some View {
        let segments = timeline.segments.filter { segment in
            switch (lane, segment.owner) {
            case let (.item(id), .item(owner)): id == owner
            case (.mixed, .mixed): true
            case (.unexplained, .unexplained): true
            default: false
            }
        }
        let title: AnyView = switch lane {
        case let .item(id): AnyView(ItemName(item: items[id]))
        case .mixed: AnyView(Text("Mixed (fast switching)"))
        case .unexplained: AnyView(Text("Other / short uses"))
        }
        let color: Color = switch lane {
        case .item: tint
        case .mixed: .purple
        case .unexplained: .gray
        }
        VStack(alignment: .leading, spacing: 2) {
            title.font(.caption)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 14)
                    ForEach(segments) { segment in
                        bar(start: segment.start, end: segment.end, width: geometry.size.width)
                            .fill(color.opacity(opacity(segment.confidence)))
                            .frame(height: 14)
                            .onTapGesture { selected = segment }
                    }
                }
            }
            .frame(height: 14)
        }
    }

    private func lane(title: Text, bars: [(Date, Date, Double)], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            title.font(.caption)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary).frame(height: 8)
                    ForEach(Array(bars.enumerated()), id: \.offset) { _, bar in
                        self.bar(start: bar.0, end: bar.1, width: geometry.size.width)
                            .fill(color.opacity(bar.2))
                            .frame(height: 8)
                    }
                }
            }
            .frame(height: 8)
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

    private func bar(start: Date, end: Date, width: CGFloat) -> some Shape {
        let left = x(start, width: width)
        let right = max(left + 1.5, x(end, width: width))
        return Rectangle().path(in: CGRect(x: left, y: 0, width: right - left, height: 14))
    }

    private func x(_ date: Date, width: CGFloat) -> CGFloat {
        let fraction = date.timeIntervalSince(span.start) / span.duration
        return CGFloat(min(max(fraction, 0), 1)) * width
    }

    private func opacity(_ confidence: Confidence) -> Double {
        switch confidence {
        case .high: 1
        case .mixed: 0.65
        case .low: 0.35
        }
    }

    private func detail(_ segment: Segment) -> some View {
        HStack {
            switch segment.owner {
            case let .item(id): ItemName(item: items[id], showIcon: false)
            case let .mixed(ids): Text(ids.compactMap { items[$0]?.nickname ?? items[$0]?.fallbackName }.joined(separator: ", "))
            case .unexplained: Text("Other / short uses")
            }
            Spacer()
            Text("\(Format.time(segment.start))–\(Format.time(segment.end)) · \(Format.minutes(segment.minutes))")
                .monospacedDigit()
        }
        .font(.footnote)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .onTapGesture { selected = nil }
    }
}
