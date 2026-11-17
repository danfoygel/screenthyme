import SwiftUI
import ThymeCore

/// A kid's day as a calendar (`UsageCalendar`), with day paging and zoom.
struct KidTimelineView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    @State var day: DayKey
    @AppStorage("timelineScale") private var scale = 120.0
    @AppStorage("timelineWebsites") private var showWebsites = false
    @AppStorage("timelineHideShort") private var hideShort = true

    var body: some View {
        let (_, timeline) = model.timeline(kid: kid.id, day: day)
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
            UsageCalendar(timeline: timeline, items: model.data.items(for: kid.id), dayStart: day.start(),
                          showWebsites: showWebsites, hideShort: hideShort, scale: $scale)
        }
        .navigationTitle("Timeline")
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
        .refreshable { await model.refresh() }
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
