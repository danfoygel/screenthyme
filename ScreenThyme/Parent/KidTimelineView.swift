import SwiftUI
import ThymeCore

/// A kid's day as a calendar (`UsageCalendar`), with day paging and zoom.
struct KidTimelineView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    @State var day: DayKey
    @AppStorage("timelineScale") private var scale = 120.0
    @AppStorage("timelineWebsites") private var showWebsites = false

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
            .padding(.vertical, 8)
            Divider()
            UsageCalendar(timeline: timeline, items: model.data.items(for: kid.id), dayStart: day.start(),
                          tint: kid.color, showWebsites: showWebsites, scale: $scale)
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
                }
            }
        }
        .refreshable { await model.refresh() }
    }

    private func zoom(by factor: Double) {
        scale = min(max(scale * factor, UsageCalendar.scales.lowerBound), UsageCalendar.scales.upperBound)
    }
}
