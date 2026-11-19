import PhotosUI
import SwiftUI
import ThymeCore

/// Report a problem (PLAN.md §18): what happened, and up to five pictures: the screen it was opened from (`BugButton`)
/// and screenshots from Photos. The phone files it as an issue on GitHub, now or when it next can.
struct BugReportView: View {
    @Environment(AppModel.self) private var model
    /// Where it was opened from, for the developer.
    let screen: String?
    @State private var text = ""
    /// The screen the bug button was pressed on.
    @State private var captured: Screenshot?
    @State private var picked: [PhotosPickerItem] = []
    @State private var screenshots: [Screenshot] = []
    @State private var loadingScreenshots = false
    @State private var thanks = false
    @FocusState private var writing: Bool

    static let maxScreenshots = 5

    init(screen: String? = nil, capture: UIImage? = nil) {
        self.screen = screen
        _captured = State(initialValue: capture.flatMap(Screenshot.init))
    }

    var body: some View {
        let queue = model.bugReports
        Form {
            if thanks {
                Section {
                    Label("Thanks! Your report is on its way.", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                }
            }
            Section {
                TextField("What happened?", text: $text, axis: .vertical)
                    .lineLimit(4...12)
                    .focused($writing)
            } header: {
                Text("The problem")
            } footer: {
                Text("What you were doing, what you expected, and what happened instead.")
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
            Section {
                Button("Send") { send() }
                    .disabled(loadingScreenshots || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                                     && screenshots.isEmpty && captured == nil))
            }
            if !queue.reports.isEmpty {
                Section("Your reports") {
                    ForEach(queue.reports) { report in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(report.summary).lineLimit(2)
                            Text("\(Format.relative(report.at)) · \(queue.status(of: report))")
                                .font(.caption)
                                .foregroundStyle(report.isFiled ? Color.secondary : .orange)
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
            // The keyboard covers Send, and a kid may not know to scroll it away.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { writing = false }
            }
        }
        .task(id: picked) { await load(picked) }
        .task { await queue.send(store: model.store) }
        .refreshable { await queue.send(store: model.store) }
    }

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
            try model.bugReports.add(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                     screenshots: pictures.map(\.jpeg), reporter: reporter.name, kidID: reporter.kidID,
                                     details: model.bugReportDetails(screen: screen), log: AppModel.bugReportLog())
        } catch {
            return model.show(error)
        }
        text = ""
        captured = nil
        picked = []
        screenshots = []
        writing = false
        thanks = true
        Task { await model.bugReports.send(store: model.store) }
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
