import SwiftUI
import UIKit

/// The bug at the top right of every screen, kid and parent (PLAN.md §18): opens Report a problem with a picture of the
/// screen it was pressed on, and the source file and line of that screen for the developer.
private struct BugButton: ViewModifier {
    let screen: String
    @State private var report: BugReportSheet?

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        report = BugReportSheet(capture: Self.captureScreen())
                    } label: {
                        Image(systemName: "ladybug")
                    }
                    .accessibilityLabel("Report a problem")
                }
            }
            .sheet(item: $report) { sheet in
                NavigationStack {
                    BugReportView(screen: screen, capture: sheet.capture)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { report = nil } }
                        }
                }
            }
    }

    /// The key window as it looks now, sheets included.
    private static func captureScreen() -> UIImage? {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard let window else { return nil }
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }
    }
}

private struct BugReportSheet: Identifiable {
    let id = UUID()
    let capture: UIImage?
}

extension View {
    /// Adds the bug button. Put it next to a screen's `navigationTitle`, so the report names that screen's source.
    func bugButton(file: String = #fileID, line: Int = #line) -> some View {
        modifier(BugButton(screen: "\(file.split(separator: "/").last ?? Substring(file)):\(line)"))
    }
}
