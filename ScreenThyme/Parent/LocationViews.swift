import MapKit
import SwiftUI
import ThymeCore

/// A kid's day by location, in the kid's day on a parent's phone (PLAN.md §19).
struct DayLocationsSection: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    let day: DayKey
    let timeline: DayTimeline

    var body: some View {
        let location = model.locationDay(kid: kid.id, day: day, timeline: timeline)
        if location != nil || model.tracksLocation(kid.id) {
            Section {
                if let location {
                    ForEach(location.locations(), id: \.whereabouts) { whereabouts, seconds in
                        NavigationLink {
                            LocationDayView(kid: kid, day: day, whereabouts: whereabouts)
                        } label: {
                            LabeledContent {
                                Text(Format.minutes(Int((seconds / 60).rounded()))).monospacedDigit()
                            } label: {
                                Label(model.name(of: whereabouts), systemImage: whereabouts.systemImage)
                            }
                        }
                    }
                    if location.locations().isEmpty {
                        Text("No use this day").foregroundStyle(.secondary)
                    }
                } else {
                    Text("\(kid.displayName)'s phone didn't say where it was this week.").foregroundStyle(.secondary)
                }
                NavigationLink { RawLocationView(kid: kid, day: day) } label: {
                    Label("Raw location", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("Where")
            } footer: {
                Text("Apps' use by where the phone was: at one of the family's places, during a visit somewhere else (other locations), or outside any visit (while moving). Name places in the Places tab.")
            }
        }
    }
}

/// One location in a kid's day: when the phone was there, and each app's use there.
struct LocationDayView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    let day: DayKey
    let whereabouts: Whereabouts

    var body: some View {
        let location = model.locationDay(kid: kid.id, day: day)
        let items = model.data.items(for: kid.id)
        let apps = (location?.usage[whereabouts] ?? [:]).filter { $0.value >= 1 }.sorted { $0.value > $1.value }
        let stays = location?.stays.filter { $0.whereabouts == whereabouts } ?? []
        List {
            Section {
                LabeledContent("Day", value: day.start().formatted(date: .complete, time: .omitted))
                LabeledContent("Use (Apple's count)",
                               value: Format.minutes(Int((apps.reduce(0) { $0 + $1.value } / 60).rounded())))
            }
            // A browser's time on a website is the site's (`UsageBlock.ownSeconds`).
            Section("Apps and websites") {
                ForEach(apps, id: \.key) { id, seconds in
                    ItemDetailsLink(item: items[id]) {
                        LabeledContent { Text(RawUsageView.duration(seconds)).monospacedDigit() } label: { ItemName(item: items[id]) }
                    }
                }
            }
            if whereabouts != .unknown {
                Section {
                    ForEach(stays, id: \.self) { stay in
                        Text("\(Format.time(stay.start))–\(stay.isOpen ? "now" : Format.time(stay.end))").monospacedDigit()
                    }
                } header: {
                    Text("Times there")
                } footer: {
                    Text("Use that straddles arriving or leaving is shared out by the minutes on each side.")
                }
            }
        }
        .navigationTitle(model.name(of: whereabouts))
        .bugButton(help: .locationDay)
        .refreshable { await model.refresh() }
    }
}

/// One app's use by where the kid's phone was, today and over the last week, in its details on a parent's phone.
struct AppLocationsSection: View {
    @Environment(AppModel.self) private var model
    let kid: UUID
    let ids: Set<UUID>
    @State private var week = false

    var body: some View {
        let today = DayKey(Date())
        let days = (0..<(week ? 7 : 1)).compactMap { model.locationDay(kid: kid, day: today.adding(days: -$0)) }
        if !days.isEmpty || model.tracksLocation(kid) {
            let rows = LocationDay.locations(days, items: ids)
            Section {
                Picker("Period", selection: $week) {
                    Text("Today").tag(false)
                    Text("Last 7 days").tag(true)
                }
                .pickerStyle(.segmented)
                ForEach(rows, id: \.whereabouts) { whereabouts, total in
                    LabeledContent {
                        Text(Format.minutes(Int((total / 60).rounded()))).monospacedDigit()
                    } label: {
                        Label(model.name(of: whereabouts), systemImage: whereabouts.systemImage)
                    }
                }
                if rows.isEmpty {
                    Text(days.isEmpty ? "No location reported" : "Not used").foregroundStyle(.secondary)
                }
            } header: {
                Text("Where")
            } footer: {
                Text("Other locations: visits no place covers. While moving: outside any visit.")
            }
        }
    }
}

/// Everything a kid's phone said about where it was on a day: each visit and fence crossing as reported, how late,
/// and the stays made from them.
struct RawLocationView: View {
    @Environment(AppModel.self) private var model
    let kid: Kid
    @State var day: DayKey

    var body: some View {
        let places = model.data.places
        // Events reported today about yesterday, or the other way, too.
        let events = model.data.placeEvents(kid: kid.id, from: day.adding(days: -1), through: day.adding(days: 1))
            .filter { DayKey($0.at) == day || DayKey($0.observedAt) == day || $0.departure.map { DayKey($0) == day } == true }
        let visits = PlaceStays.visits(events)
        let location = model.locationDay(kid: kid.id, day: day)
        List {
            Section {
                HStack {
                    Button { day = day.adding(days: -1) } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Text(day.description).monospacedDigit()
                    Spacer()
                    Button { day = day.adding(days: 1) } label: { Image(systemName: "chevron.right") }
                        .disabled(day >= DayKey(Date()))
                }
                .buttonStyle(.borderless)
            } footer: {
                Text("\(visits.count) visits, \(events.filter { $0.kind != .visit }.count) fence events. iOS reports each visit when the phone arrives and again when it leaves.")
            }
            if !visits.isEmpty {
                Section {
                    Map {
                        ForEach(places) { place in
                            MapCircle(center: place.coordinate, radius: place.radius)
                                .foregroundStyle(.blue.opacity(0.12))
                                .stroke(.blue, lineWidth: 1)
                        }
                        ForEach(Array(visits.enumerated()), id: \.element.id) { index, visit in
                            if let coordinate = visit.coordinate {
                                MapCircle(center: coordinate, radius: max(visit.accuracy ?? 0, 5))
                                    .foregroundStyle(kid.color.opacity(0.2))
                                    .stroke(kid.color, lineWidth: 1.5)
                                Annotation("", coordinate: coordinate) {
                                    Text("\(index + 1)").font(.caption2.bold()).foregroundStyle(.white)
                                        .frame(width: 18, height: 18).background(Circle().fill(kid.color))
                                }
                            }
                        }
                    }
                    .frame(height: 240)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    Text("Numbered visits, each circle as wide as its accuracy; blue are the family's places.")
                }
            }
            if let location, !location.stays.isEmpty {
                Section("Stays") {
                    ForEach(location.stays, id: \.self) { stay in
                        LabeledContent(model.name(of: stay.whereabouts),
                                       value: "\(Format.time(stay.start))–\(stay.isOpen ? "now" : Format.time(stay.end))")
                            .monospacedDigit()
                    }
                }
            }
            Section {
                ForEach(events.reversed()) { event in
                    RawLocationRow(event: event, number: visits.firstIndex { $0.id == event.id }.map { $0 + 1 },
                                   places: places)
                }
                if events.isEmpty {
                    Text("Nothing reported this day").foregroundStyle(.secondary)
                }
            } header: {
                Text("Events · \(events.count)")
            } footer: {
                Text("Newest first, at the time it happened. + is how long after that iOS told ScreenThyme. Region is how the phone watches a fence; monitor marks iOS's other way, in older events only.")
            }
        }
        .navigationTitle("Raw location")
        .bugButton(help: .rawLocation)
        .refreshable { await model.refresh() }
    }
}

private struct RawLocationRow: View {
    let event: PlaceEvent
    /// The visit's number on the map, for the report that stands for it.
    let number: Int?
    let places: [Place]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(event.at.formatted(date: .omitted, time: .standard)).monospacedDigit()
                Text(title).bold()
                Spacer()
                Text("+\(late)").foregroundStyle(.secondary).monospacedDigit()
            }
            if event.kind == .visit {
                Text(details).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.subheadline)
    }

    private var title: String {
        let fence = event.place.map { id in places.first { $0.id == id }?.name ?? "a fence not in Places" } ?? ""
        let source = event.source == .region ? "region" : "monitor"
        switch event.kind {
        case .enter: return "Entered \(fence) (\(source))"
        case .exit: return "Left \(fence) (\(source))"
        case .visit:
            let mark = number.map { "#\($0) " } ?? ""
            return event.departure == nil ? "\(mark)Arrived" : "\(mark)Visit until \(Format.time(event.departure!))"
        }
    }

    private var details: String {
        var parts: [String] = []
        if let latitude = event.latitude, let longitude = event.longitude {
            parts.append(String(format: "%.5f, %.5f", latitude, longitude))
        }
        if let accuracy = event.accuracy { parts.append("±\(Int(accuracy)) m") }
        parts.append(VisitClusters.place(of: event, in: places)?.name ?? "no place")
        return parts.joined(separator: " · ")
    }

    private var late: String {
        let seconds = max(0, Int(event.delay))
        return seconds < 120 ? "\(seconds) s" : seconds < 7200 ? "\(seconds / 60) min" : "\(seconds / 3600) h"
    }
}
