import PhotosUI
import SwiftUI
import ThymeCore

/// Report a problem (PLAN.md §18): whether it's a bug, an idea or a question (it must be chosen), what happened, and up
/// to five pictures: the screen it was opened from (`BugButton`) and screenshots from Photos, each of which can be drawn
/// on in red (`MarkupView`). The phone files it as an issue on GitHub, labeled by its kind, now or when it next can.
/// Send (top right) queues it and closes the screen: the bug button's sheet, or back to the kid's home.
struct BugReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Where it was opened from, for the developer.
    let screen: String?
    /// Opened by the bug button: a sheet with Cancel, which asks before throwing away a draft.
    let inSheet: Bool
    /// None until the reporter chooses; Send waits for it.
    @State private var kind: BugReport.Kind?
    @State private var text = ""
    /// The screen the bug button was pressed on.
    @State private var captured: Screenshot?
    @State private var picked: [PhotosPickerItem] = []
    /// The pictures chosen in Photos, in `picked`'s order.
    @State private var screenshots: [PickedScreenshot] = []
    @State private var loadingScreenshots = false
    /// The picture being drawn on.
    @State private var marking: Marking?
    @State private var confirmingDiscard = false
    @FocusState private var writing: Bool

    static let maxScreenshots = 5

    init(screen: String? = nil, capture: UIImage? = nil, inSheet: Bool = false) {
        self.screen = screen
        self.inSheet = inSheet
        _captured = State(initialValue: capture.flatMap(Screenshot.init))
    }

    var body: some View {
        let queue = model.bugReports
        let shown = kind ?? .bug
        Form {
            Section {
                Picker("Kind", selection: $kind) {
                    ForEach(BugReport.Kind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(Optional(kind))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } header: {
                Text("What are you sending?")
            } footer: {
                if kind == nil { Text("Choose one to send.") }
            }
            Section {
                TextField(shown.prompt, text: $text, axis: .vertical)
                    .lineLimit(4...12)
                    .focused($writing)
            } header: {
                Text(shown.header)
            } footer: {
                Text(shown.footer)
            }
            Section {
                if captured != nil || !screenshots.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            if let captured {
                                thumbnail(captured.image) { marking = .captured } remove: { self.captured = nil }
                            }
                            ForEach(screenshots, id: \.item) { picked in
                                thumbnail(picked.screenshot.image) { marking = .picked(picked.item) } remove: {
                                    self.picked.removeAll { $0 == picked.item }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                let pickLabel = screenshots.isEmpty ? "Add screenshots" : "Change screenshots"
                PhotosPicker(selection: $picked, maxSelectionCount: Self.maxScreenshots - (captured == nil ? 0 : 1),
                             selectionBehavior: .ordered, matching: .images) {
                    Label(pickLabel, systemImage: "photo.on.rectangle")
                }
                if loadingScreenshots { ProgressView() }
            } header: {
                Text("Screenshots")
            } footer: {
                if captured != nil {
                    Text("The first picture is the screen you were on. Tap a picture to draw on it. "
                         + "Optional, up to \(Self.maxScreenshots) in all.")
                } else if !screenshots.isEmpty {
                    Text("Tap a picture to draw on it. Optional, up to \(Self.maxScreenshots).")
                } else {
                    Text("Optional, up to \(Self.maxScreenshots). To take one, press the side button and volume up together.")
                }
            }
            if !queue.reports.isEmpty {
                Section("Your reports") {
                    ForEach(queue.reports) { report in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.summary).lineLimit(2)
                            Text("\(Format.relative(report.at)) · \(queue.status(of: report))")
                                .font(.caption)
                                .foregroundStyle(report.resolution == .fixed ? .green
                                                 : report.isFiled ? Color.secondary : .orange)
                        }
                        .swipeActions {
                            if !report.isFiled {
                                Button("Delete", role: .destructive) { queue.remove(report) }
                            }
                        }
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .navigationTitle("Report a problem")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Send") { send() }
                    .disabled(kind == nil || loadingScreenshots
                              || (trimmedText.isEmpty && screenshots.isEmpty && captured == nil))
            }
            if inSheet {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasDraft { confirmingDiscard = true } else { dismiss() }
                    }
                    .confirmationDialog("Discard this report?", isPresented: $confirmingDiscard,
                                        titleVisibility: .visible) {
                        Button("Discard", role: .destructive) { dismiss() }
                        Button("Keep Writing", role: .cancel) {}
                    }
                }
            }
            // A kid may not know to scroll the keyboard away. An icon, so "Done" never means anything but sending.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button { writing = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                    .accessibilityLabel("Hide keyboard")
            }
        }
        .interactiveDismissDisabled(inSheet && hasDraft)
        .fullScreenCover(item: $marking) { marking in
            if let screenshot = screenshot(marking) {
                MarkupView(screenshot: screenshot) { setMarks($0, on: marking) }
            }
        }
        .task(id: picked) { await load(picked) }
        .task { await queue.sync(store: model.store) }
        .refreshable { await queue.sync(store: model.store, checkNow: true) }
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Something the kid wrote, added or drew. The bug button's own picture of the screen doesn't count, nor the kind.
    private var hasDraft: Bool {
        !trimmedText.isEmpty || !screenshots.isEmpty || captured?.marks.isEmpty == false
    }

    private func thumbnail(_ image: UIImage, mark: @escaping () -> Void,
                           remove: @escaping () -> Void) -> some View {
        Button(action: mark) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Screenshot")
        .accessibilityHint("Draw on it")
        .overlay(alignment: .bottomLeading) {
            Image(systemName: "pencil.tip.crop.circle.fill")
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, .red)
                .font(.title3)
                .padding(4)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.6))
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .padding(4)
                .accessibilityLabel("Remove screenshot")
            }
    }

    private func screenshot(_ marking: Marking) -> Screenshot? {
        switch marking {
        case .captured: captured
        case let .picked(item): screenshots.first { $0.item == item }?.screenshot
        }
    }

    private func setMarks(_ marks: [[CGPoint]], on marking: Marking) {
        switch marking {
        case .captured:
            captured?.marks = marks
        case let .picked(item):
            guard let index = screenshots.firstIndex(where: { $0.item == item }) else { return }
            screenshots[index].screenshot.marks = marks
        }
    }

    private func load(_ items: [PhotosPickerItem]) async {
        loadingScreenshots = true
        defer { loadingScreenshots = false }
        var loaded: [PickedScreenshot] = []
        for item in items {
            // A picture still chosen keeps what was drawn on it.
            if let kept = screenshots.first(where: { $0.item == item }) {
                loaded.append(kept)
                continue
            }
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let screenshot = Screenshot(data) else { continue }
            loaded.append(PickedScreenshot(item: item, screenshot: screenshot))
        }
        guard !Task.isCancelled else { return }
        screenshots = loaded
    }

    private func send() {
        guard let kind else { return }
        let reporter = model.bugReporter
        let pictures = (captured.map { [$0] } ?? []) + screenshots.map(\.screenshot)
        do {
            try model.bugReports.add(kind: kind, text: trimmedText, screenshots: pictures.compactMap(\.jpeg),
                                     reporter: reporter.name, kidID: reporter.kidID,
                                     details: model.bugReportDetails(screen: screen), log: AppModel.bugReportLog())
        } catch {
            return model.show(error)
        }
        writing = false
        dismiss()
        Task {
            // The fix comes as a push (`Tools/BugPush`); kids' phones haven't asked before.
            await Notifier.requestPermission()
            await model.bugReports.sync(store: model.store)
        }
    }
}

private extension BugReport.Kind {
    var title: String {
        switch self {
        case .bug: "Bug"
        case .feature: "Feature"
        case .question: "Question"
        }
    }

    var header: String {
        switch self {
        case .bug: "The problem"
        case .feature: "Your idea"
        case .question: "Your question"
        }
    }

    var prompt: String {
        switch self {
        case .bug: "What happened?"
        case .feature: "What should ScreenThyme do?"
        case .question: "What do you want to know?"
        }
    }

    var footer: String {
        switch self {
        case .bug: "What you were doing, what you expected, and what happened instead. "
            + "You'll get a notification when it's fixed."
        case .feature: "What it would do, and how it would help. You'll get a notification when it's done."
        case .question: "You'll get a notification when it's answered."
        }
    }
}

private enum Marking: Hashable, Identifiable {
    case captured
    case picked(PhotosPickerItem)

    var id: Self { self }
}

private struct PickedScreenshot {
    let item: PhotosPickerItem
    var screenshot: Screenshot
}

/// A picture for a report, made small enough to upload quickly: at most 2000 pixels on its long side, as JPEG, with
/// whatever the reporter drew on it.
private struct Screenshot {
    /// Shrunk, without the marks.
    let original: UIImage
    /// Red pen strokes in the picture's pixels, oldest first.
    var marks: [[CGPoint]] = [] {
        didSet { image = Self.marked(original, with: marks) }
    }
    /// The picture as it's sent: with its marks.
    private(set) var image: UIImage

    var jpeg: Data? { image.jpegData(compressionQuality: 0.8) }

    static let maxSide: CGFloat = 2000
    static let pen = UIColor.systemRed

    init?(_ data: Data) {
        guard let original = UIImage(data: data) else { return nil }
        self.init(original)
    }

    init?(_ original: UIImage) {
        let pixels = CGSize(width: original.size.width * original.scale, height: original.size.height * original.scale)
        guard pixels.width > 0, pixels.height > 0 else { return nil }
        let scale = min(1, Self.maxSide / max(pixels.width, pixels.height))
        let size = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            original.draw(in: CGRect(origin: .zero, size: size))
        }
        self.original = resized
        image = resized
    }

    /// The pen's width in a picture's pixels: as thick, for its size, on every picture.
    static func penWidth(for size: CGSize) -> CGFloat {
        max(size.width, size.height) / 160
    }

    /// The strokes, scaled from the picture's pixels. A tap is a dot.
    static func path(of marks: [[CGPoint]], scale: CGFloat = 1) -> Path {
        var path = Path()
        for stroke in marks {
            guard !stroke.isEmpty else { continue }
            let points = stroke.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
            path.move(to: points[0])
            path.addLines(points.count == 1 ? [points[0], points[0]] : points)
        }
        return path
    }

    private static func marked(_ original: UIImage, with marks: [[CGPoint]]) -> UIImage {
        guard !marks.isEmpty else { return original }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: original.size, format: format).image { context in
            original.draw(at: .zero)
            let cg = context.cgContext
            cg.addPath(path(of: marks).cgPath)
            cg.setStrokeColor(pen.cgColor)
            cg.setLineWidth(penWidth(for: original.size))
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.strokePath()
        }
    }
}

/// Draws on a report's picture with a red pen, to show where the problem is. Done keeps the marks; Cancel drops the
/// ones drawn since it opened.
private struct MarkupView: View {
    @Environment(\.dismiss) private var dismiss
    let original: UIImage
    let done: ([[CGPoint]]) -> Void
    @State private var marks: [[CGPoint]]
    /// The stroke under the finger, in the picture's pixels.
    @State private var stroke: [CGPoint] = []

    init(screenshot: Screenshot, done: @escaping ([[CGPoint]]) -> Void) {
        original = screenshot.original
        self.done = done
        _marks = State(initialValue: screenshot.marks)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                let scale = min(proxy.size.width / original.size.width, proxy.size.height / original.size.height)
                Image(uiImage: original)
                    .resizable()
                    .frame(width: original.size.width * scale, height: original.size.height * scale)
                    .overlay {
                        Canvas { context, _ in
                            context.stroke(Screenshot.path(of: marks + [stroke], scale: scale),
                                           with: .color(Color(uiColor: Screenshot.pen)),
                                           style: StrokeStyle(lineWidth: Screenshot.penWidth(for: original.size) * scale,
                                                              lineCap: .round, lineJoin: .round))
                        }
                    }
                    .clipped()
                    .shadow(color: .black.opacity(0.3), radius: 6)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            stroke.append(CGPoint(x: drag.location.x / scale, y: drag.location.y / scale))
                        }
                        .onEnded { _ in
                            if !stroke.isEmpty { marks.append(stroke) }
                            stroke = []
                        })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding()
            .navigationTitle("Draw on it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        done(marks)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Undo", systemImage: "arrow.uturn.backward") { marks.removeLast() }
                        .disabled(marks.isEmpty)
                }
            }
        }
    }
}
