import PhotosUI
import SwiftUI
import ThymeCore

/// Report a problem (PLAN.md §18): what happened, and up to five pictures: the screen it was opened from (`BugButton`)
/// and screenshots from Photos. The phone files it as an issue on GitHub, now or when it next can. Send (top right)
/// queues it and closes the screen: the bug button's sheet, or back to the kid's home.
struct BugReportView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// Where it was opened from, for the developer.
    let screen: String?
    /// Opened by the bug button: a sheet with Cancel, which asks before throwing away a draft.
    let inSheet: Bool
    @State private var text = ""
    /// The screen the bug button was pressed on.
    @State private var captured: Screenshot?
    @State private var picked: [PhotosPickerItem] = []
    @State private var screenshots: [Screenshot] = []
    @State private var loadingScreenshots = false
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
        Form {
            Section {
                TextField("What happened?", text: $text, axis: .vertical)
                    .lineLimit(4...12)
                    .focused($writing)
            } header: {
                Text("The problem")
            } footer: {
                Text("What you were doing, what you expected, and what happened instead. "
                     + "You'll get a notification when it's fixed.")
            }
            Section {
                if captured != nil || !screenshots.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            if let captured {
                                thumbnail(captured.image) { self.captured = nil }
                            }
                            ForEach(screenshots.indices, id: \.self) { index in
                                thumbnail(screenshots[index].image) { remove(at: index) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                PhotosPicker(selection: $picked, maxSelectionCount: Self.maxScreenshots - (captured == nil ? 0 : 1),
                             selectionBehavior: .ordered, matching: .images) {
                    Label(screenshots.isEmpty ? "Add screenshots" : "Change screenshots", systemImage: "photo.on.rectangle")
                }
                if loadingScreenshots { ProgressView() }
            } header: {
                Text("Screenshots")
            } footer: {
                if captured != nil {
                    Text("The first picture is the screen you were on. Optional, up to \(Self.maxScreenshots) in all.")
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
                    .disabled(loadingScreenshots || (trimmedText.isEmpty && screenshots.isEmpty && captured == nil))
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
        .task(id: picked) { await load(picked) }
        .task { await queue.sync(store: model.store) }
        .refreshable { await queue.sync(store: model.store, checkNow: true) }
    }

    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Something the kid wrote or added. The bug button's own picture of the screen doesn't count.
    private var hasDraft: Bool { !trimmedText.isEmpty || !screenshots.isEmpty }

    private func thumbnail(_ image: UIImage, remove: @escaping () -> Void) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(height: 140)
            .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private func remove(at index: Int) {
        guard picked.indices.contains(index) else { return }
        picked.remove(at: index)
    }

    private func load(_ items: [PhotosPickerItem]) async {
        loadingScreenshots = true
        defer { loadingScreenshots = false }
        var loaded: [Screenshot] = []
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let screenshot = Screenshot(data) else { continue }
            loaded.append(screenshot)
        }
        guard !Task.isCancelled else { return }
        screenshots = loaded
    }

    private func send() {
        let reporter = model.bugReporter
        let pictures = (captured.map { [$0] } ?? []) + screenshots
        do {
            try model.bugReports.add(text: trimmedText,
                                     screenshots: pictures.map(\.jpeg), reporter: reporter.name, kidID: reporter.kidID,
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

/// A picture for a report, made small enough to upload quickly: at most 2000 pixels on its long side, as JPEG.
private struct Screenshot {
    let jpeg: Data
    let image: UIImage

    static let maxSide: CGFloat = 2000

    init?(_ data: Data) {
        guard let original = UIImage(data: data) else { return nil }
        self.init(original)
    }

    init?(_ original: UIImage) {
        let pixels = CGSize(width: original.size.width * original.scale, height: original.size.height * original.scale)
        let scale = min(1, Self.maxSide / max(pixels.width, pixels.height))
        let size = CGSize(width: (pixels.width * scale).rounded(), height: (pixels.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            original.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8) else { return nil }
        self.jpeg = jpeg
        image = resized
    }
}
