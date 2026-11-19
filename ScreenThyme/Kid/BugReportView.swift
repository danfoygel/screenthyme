import PhotosUI
import SwiftUI
import ThymeCore

/// Report a problem (PLAN.md §18): the kid's words and up to five screenshots from Photos. The phone files it as an
/// issue on GitHub, now or when it next can.
struct BugReportView: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var picked: [PhotosPickerItem] = []
    @State private var screenshots: [Screenshot] = []
    @State private var loadingScreenshots = false
    @State private var thanks = false
    @FocusState private var writing: Bool

    static let maxScreenshots = 5

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
                if !screenshots.isEmpty {
                    ScrollView(.horizontal) {
                        HStack(spacing: 12) {
                            ForEach(screenshots.indices, id: \.self) { index in
                                thumbnail(screenshots[index].image) { remove(at: index) }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
                PhotosPicker(selection: $picked, maxSelectionCount: Self.maxScreenshots, selectionBehavior: .ordered,
                             matching: .images) {
                    Label(screenshots.isEmpty ? "Add screenshots" : "Change screenshots", systemImage: "photo.on.rectangle")
                }
                if loadingScreenshots { ProgressView() }
            } header: {
                Text("Screenshots")
            } footer: {
                Text("Optional, up to \(Self.maxScreenshots). To take one, press the side button and volume up together.")
            }
            Section {
                Button("Send") { send() }
                    .disabled(model.config.kid == nil || loadingScreenshots
                              || (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && screenshots.isEmpty))
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
        guard let kid = model.config.kid else { return }
        do {
            try model.bugReports.add(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                     screenshots: screenshots.map(\.jpeg), kid: kid,
                                     details: model.bugReportDetails(), log: AppModel.bugReportLog())
        } catch {
            return model.show(error)
        }
        text = ""
        picked = []
        screenshots = []
        writing = false
        thanks = true
        Task { await model.bugReports.send(store: model.store) }
    }
}

/// A picked image, made small enough to upload quickly: at most 2000 pixels on its long side, as JPEG.
private struct Screenshot {
    let jpeg: Data
    let image: UIImage

    static let maxSide: CGFloat = 2000

    init?(_ data: Data) {
        guard let original = UIImage(data: data) else { return nil }
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
