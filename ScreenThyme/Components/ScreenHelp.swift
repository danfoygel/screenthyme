import SwiftUI

/// What one screen is for and what can be done on it, shown by the question mark beside the bug. Each screen's help is a
/// static on `ScreenHelp` in `ScreenThyme/Help/`, passed to `.bugButton(help:)` next to its `navigationTitle`.
struct ScreenHelp {
    struct Topic: Identifiable {
        var id: String { heading }
        let heading: String
        /// One short paragraph each; `**bold**` and other inline Markdown render.
        let points: [String]
    }

    let title: String
    /// A sentence or two: what this screen shows and why.
    let summary: String
    let topics: [Topic]

    init(_ title: String, summary: String, _ topics: [Topic] = []) {
        self.title = title
        self.summary = summary
        self.topics = topics
    }

    static func topic(_ heading: String, _ points: String...) -> Topic {
        Topic(heading: heading, points: points)
    }
}

/// The help sheet: the summary, then each topic's points.
struct ScreenHelpView: View {
    let help: ScreenHelp
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(.init(help.summary))
            }
            ForEach(help.topics) { topic in
                Section(topic.heading) {
                    ForEach(topic.points, id: \.self) { point in
                        Text(.init(point))
                    }
                }
            }
        }
        .navigationTitle(help.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}
