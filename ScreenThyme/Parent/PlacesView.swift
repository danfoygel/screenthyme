import MapKit
import SwiftUI
import ThymeCore

/// The family's places (PLAN.md §19): a map of where kids' phones stayed over the last 60 days, the places named so
/// far, and the spots not named yet. Visits to one spot are one circle (`VisitClusters`); a parent names it, and kids'
/// phones then watch it with a fence.
struct PlacesView: View {
    @Environment(AppModel.self) private var model
    @State private var kidFilter: UUID?
    @State private var editing: PlaceEditor.Subject?
    @State private var position = MapCameraPosition.automatic

    var body: some View {
        let places = model.data.places
        let visits = model.visits(kid: kidFilter)
        let clusters = VisitClusters.build(visits, excluding: places)
        let counts = Dictionary(grouping: visits.compactMap { VisitClusters.place(of: $0, in: places)?.id }, by: { $0 })
            .mapValues(\.count)
        NavigationStack {
            List {
                Section {
                    Map(position: $position) {
                        ForEach(places) { place in
                            MapCircle(center: place.coordinate, radius: place.radius)
                                .foregroundStyle(.blue.opacity(0.18))
                                .stroke(.blue, lineWidth: 2)
                            Annotation(place.name, coordinate: place.coordinate) {
                                Button { editing = .place(place) } label: {
                                    Image(systemName: "mappin.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.white, .blue)
                                }
                            }
                        }
                        ForEach(clusters) { cluster in
                            MapCircle(center: cluster.coordinate, radius: max(cluster.accuracy, 25))
                                .foregroundStyle(.orange.opacity(0.18))
                                .stroke(.orange, lineWidth: 1.5)
                            Annotation("", coordinate: cluster.coordinate) {
                                Button { editing = .cluster(cluster) } label: {
                                    Text("\(cluster.visits.count)")
                                        .font(.caption.bold())
                                        .foregroundStyle(.white)
                                        .frame(minWidth: 24, minHeight: 24)
                                        .background(Circle().fill(.orange))
                                }
                            }
                        }
                    }
                    .frame(height: 320)
                    .listRowInsets(EdgeInsets())
                    // Fits what's shown whenever it changes (`.automatic` framed the wrong spot).
                    .onChange(of: places.map(\.id) + clusters.map(\.id), initial: true) {
                        if let region = MKCoordinateRegion(fitting: places.map(\.coordinate) + clusters.map(\.coordinate)) {
                            position = .region(region)
                        }
                    }
                } footer: {
                    Text("Blue: the family's places. Orange: where a kid's phone stayed that no place covers, with the number of visits; tap one to name it. Each circle is as wide as iOS's guess of where the phone was is uncertain.")
                }
                if model.data.sortedKids.count > 1 {
                    Picker("Kid", selection: $kidFilter) {
                        Text("All kids").tag(UUID?.none)
                        ForEach(model.data.sortedKids) { Text($0.displayName).tag(UUID?.some($0.id)) }
                    }
                }
                Section {
                    ForEach(places) { place in
                        Button { editing = .place(place) } label: {
                            LabeledContent {
                                Text("\(counts[place.id] ?? 0) visits")
                            } label: {
                                Label {
                                    Text(place.name)
                                    Text("\(Int(place.radius)) m fence")
                                } icon: {
                                    Image(systemName: "mappin.circle.fill").foregroundStyle(.blue)
                                }
                            }
                        }
                        .tint(.primary)
                    }
                    if places.isEmpty {
                        Text("No places yet. Name a spot below or on the map.").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Places")
                } footer: {
                    Text("Use at a place counts there when a visit was inside its fence, or the phone's own fence said it was inside. Kids' phones watch \(FamilyPlaces.limit) places at most.")
                }
                Section {
                    ForEach(clusters) { cluster in
                        Button { editing = .cluster(cluster) } label: { ClusterRow(cluster: cluster) }
                            .tint(.primary)
                    }
                    if clusters.isEmpty {
                        Text(visits.isEmpty ? "No visits reported in the last \(AppModel.placesMapDays) days." : "Every visit is at a named place.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Not named yet")
                } footer: {
                    Text("Visits whose centers are within their accuracy of each other count as one spot. Use during these visits shows as \u{201C}Other locations\u{201D}; use outside any visit as \u{201C}While moving\u{201D}.")
                }
            }
            .navigationTitle("Places")
            .bugButton()
            .refreshable { await model.refresh() }
            .sheet(item: $editing) { subject in
                PlaceEditor(subject: subject)
            }
        }
    }
}

/// A spot not named yet: its address, visits and accuracy.
private struct ClusterRow: View {
    @Environment(AppModel.self) private var model
    let cluster: VisitCluster
    @State private var address: String?

    var body: some View {
        Label {
            Text(address ?? String(format: "%.5f, %.5f", cluster.latitude, cluster.longitude))
            Text(summary)
        } icon: {
            Image(systemName: "mappin.and.ellipse").foregroundStyle(.orange)
        }
        .task(id: cluster.id) { address = await Addresses.lookUp(latitude: cluster.latitude, longitude: cluster.longitude) }
    }

    private var summary: String {
        let kids = cluster.kids.compactMap { model.data.kids[$0]?.displayName }.sorted().joined(separator: ", ")
        let last = cluster.lastVisit.map { " · last \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
        return "\(cluster.visits.count) \(cluster.visits.count == 1 ? "visit" : "visits") · ±\(Int(cluster.accuracy)) m\(last)"
            + (kids.isEmpty ? "" : " · \(kids)")
    }
}

/// Names a spot, or renames, resizes or removes a place.
struct PlaceEditor: View {
    enum Subject: Identifiable {
        case cluster(VisitCluster)
        case place(Place)

        var id: UUID {
            switch self {
            case let .cluster(cluster): cluster.id
            case let .place(place): place.id
            }
        }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let subject: Subject
    @State private var name = ""
    @State private var radius = Place.defaultRadius
    @State private var address: String?
    @State private var confirmingDelete = false
    /// Every kid's visits over the map's days, read once rather than at each keystroke.
    @State private var allVisits: [PlaceEvent] = []

    var body: some View {
        let place = draft
        let visits = allVisits.filter { visit in
            switch subject {
            case let .cluster(cluster): cluster.visits.contains { $0.id == visit.id }
            case .place: VisitClusters.place(of: visit, in: [place]) != nil
            }
        }
        NavigationStack {
            Form {
                Section {
                    Map(initialPosition: .region(MKCoordinateRegion(center: place.coordinate,
                                                                    latitudinalMeters: max(radius * 5, 600),
                                                                    longitudinalMeters: max(radius * 5, 600)))) {
                        MapCircle(center: place.coordinate, radius: radius)
                            .foregroundStyle(.blue.opacity(0.18))
                            .stroke(.blue, lineWidth: 2)
                        ForEach(visits) { visit in
                            if let coordinate = visit.coordinate {
                                MapCircle(center: coordinate, radius: max(visit.accuracy ?? 0, 5))
                                    .foregroundStyle(.orange.opacity(0.1))
                                    .stroke(.orange, lineWidth: 1)
                            }
                        }
                    }
                    .frame(height: 220)
                    .listRowInsets(EdgeInsets())
                } footer: {
                    if let address { Text(address) }
                }
                Section {
                    TextField("Name (like Home or School)", text: $name)
                    VStack(alignment: .leading) {
                        LabeledContent("Fence", value: "\(Int(radius)) m")
                        Slider(value: $radius, in: Place.minimumRadius...Place.maximumRadius, step: 25)
                    }
                } footer: {
                    Text("Use during a visit inside the fence counts here. Kids' phones also watch the fence and note arriving and leaving; iOS misses crossings of fences under \(Int(Place.minimumRadius)) m.")
                }
                Section("Visits · \(visits.count)") {
                    ForEach(visits.prefix(30)) { visit in
                        VisitRow(visit: visit, showsKid: true)
                    }
                }
                if case .place = subject {
                    Section {
                        Button("Remove place", role: .destructive) { confirmingDelete = true }
                    }
                }
            }
            .navigationTitle(isNew ? "Name this place" : place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(place) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || isNew && model.data.places.count >= FamilyPlaces.limit)
                }
            }
            .confirmationDialog("Remove \(place.name)?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { remove(place) }
            } message: {
                Text("Its visits show as other locations again. Kids' phones stop watching it.")
            }
        }
        .onAppear(perform: load)
        .task { address = await Addresses.lookUp(latitude: place.latitude, longitude: place.longitude) }
    }

    private var isNew: Bool {
        if case .cluster = subject { true } else { false }
    }

    private var draft: Place {
        switch subject {
        case let .cluster(cluster):
            Place(id: cluster.id, name: name, latitude: cluster.latitude, longitude: cluster.longitude, radius: radius)
        case let .place(place):
            Place(id: place.id, name: name, latitude: place.latitude, longitude: place.longitude, radius: radius)
        }
    }

    private func load() {
        allVisits = model.visits(kid: nil).sorted { $0.at > $1.at }
        switch subject {
        case let .cluster(cluster):
            radius = cluster.suggestedRadius
        case let .place(place):
            name = place.name
            radius = place.radius
        }
    }

    private func save(_ place: Place) {
        var place = place
        place.name = name.trimmingCharacters(in: .whitespaces)
        var places = model.data.places
        if let index = places.firstIndex(where: { $0.id == place.id }) {
            places[index] = place
        } else {
            // A new id: the cluster's is its first visit's.
            place.id = UUID()
            places.append(place)
        }
        Task { await model.save(places: places) }
        dismiss()
    }

    private func remove(_ place: Place) {
        let places = model.data.places.filter { $0.id != place.id }
        Task { await model.save(places: places) }
        dismiss()
    }
}

/// One visit: when, how precise, and (on the map's lists) whose.
struct VisitRow: View {
    @Environment(AppModel.self) private var model
    let visit: PlaceEvent
    var showsKid = false

    var body: some View {
        HStack {
            VStack(alignment: .leading) {
                Text(times).monospacedDigit()
                if showsKid, let kid = visit.kidID.flatMap({ model.data.kids[$0] }) {
                    Text(kid.displayName).font(.caption).foregroundStyle(kid.color)
                }
            }
            Spacer()
            if let accuracy = visit.accuracy {
                Text("±\(Int(accuracy)) m").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var times: String {
        let day = visit.at.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day), \(Format.time(visit.at))–\(visit.departure.map(Format.time) ?? "now")"
    }
}

extension MKCoordinateRegion {
    /// Around every coordinate, with a margin, and at least 1 km across; nil without any.
    init?(fitting coordinates: [CLLocationCoordinate2D]) {
        guard let first = coordinates.first else { return nil }
        var (minLat, maxLat, minLon, maxLon) = (first.latitude, first.latitude, first.longitude, first.longitude)
        for c in coordinates {
            (minLat, maxLat) = (min(minLat, c.latitude), max(maxLat, c.latitude))
            (minLon, maxLon) = (min(minLon, c.longitude), max(maxLon, c.longitude))
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        // About 1 km of latitude; the same width at this latitude.
        let minimum = 0.009
        self.init(center: center, span: MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, minimum),
            longitudeDelta: max((maxLon - minLon) * 1.4, minimum / max(cos(center.latitude * .pi / 180), 0.1))))
    }
}

extension Place {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

extension VisitCluster {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

extension PlaceEvent {
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
