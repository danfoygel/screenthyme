import SwiftUI
import ThymeCore

/// A kid's day as a calendar (`UsageCalendar`), with day paging and zoom: on a parent's phone from the family's data,
/// on the kid's own phone from its App Group (as Debug's "Today as parents see it").
struct KidTimelineView: View {
    enum Source {
        case family(Kid)
        case thisPhone
    }

    @Environment(AppModel.self) private var model
    let source: Source
    @State var day: DayKey
    @AppStorage("timelineScale") private var scale = 120.0
    @AppStorage("timelineWebsites") private var showWebsites = false
    @AppStorage("timelineHideShort") private var hideShort = true

    var body: some View {
        let (timeline, items) = data
        VStack(spacing: 0) {
            HStack {
                Button { day = day.adding(days: -1) } label: { Image(systemName: "chevron.left") }
                Spacer()
                Text(day.start().formatted(date: .complete, time: .omitted)).font(.subheadline)
                Spacer()
                Button { day = day.adding(days: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(day >= DayKey(Date()))
            }
            .padding(.horizontal)
            .padding(.top, 8)
            legend
                .padding(.horizontal)
                .padding(.vertical, 6)
            Divider()
            UsageCalendar(timeline: timeline, items: items, dayStart: day.start(),
                          showWebsites: showWebsites, hideShort: hideShort, scale: $scale)
        }
        .navigationTitle("Timeline")
        .bugButton()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup {
                Button("Zoom out", systemImage: "minus.magnifyingglass") { zoom(by: 0.5) }
                    .disabled(scale <= UsageCalendar.scales.lowerBound)
                Button("Zoom in", systemImage: "plus.magnifyingglass") { zoom(by: 2) }
                    .disabled(scale >= UsageCalendar.scales.upperBound)
                Menu("Options", systemImage: "ellipsis") {
                    Toggle("Show websites", isOn: $showWebsites)
                    Toggle("Hide short use (under 2 min)", isOn: $hideShort)
                }
            }
        }
        .refreshable {
            switch source {
            case .family: await model.refresh()
            case .thisPhone: await model.sampleNow()
            }
        }
    }

    private var data: (DayTimeline, [UUID: TrackedItem]) {
        switch source {
        case .family(let kid):
            return (model.timeline(kid: kid.id, day: day).timeline, model.data.items(for: kid.id))
        case .thisPhone:
            let items = Dictionary(AppGroup.loadItems().map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return (Reconstructor.build(model.config.dayInput(day)), items)
        }
    }

    /// What the line beside the hours means.
    private var legend: some View {
        HStack(spacing: 12) {
            ForEach([(Coverage.placed, "Placed"), (.quiet, "Idle"), (.blind, "No check-ins"), (.burst, "Burst")],
                    id: \.1) { coverage, name in
                HStack(spacing: 4) {
                    Capsule().fill(UsageCalendar.color(for: coverage)).frame(width: 3, height: 12)
                    Text(name)
                }
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
    }

    private func zoom(by factor: Double) {
        scale = min(max(scale * factor, UsageCalendar.scales.lowerBound), UsageCalendar.scales.upperBound)
    }
}
