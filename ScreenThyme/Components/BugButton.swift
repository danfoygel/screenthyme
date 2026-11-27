import SwiftUI
import UIKit

/// The question mark and the bug at the top right of every screen, kid and parent. The question mark opens the screen's
/// help; the bug (PLAN.md §18) opens Report a problem with a picture of the screen it was pressed on, and the source file
/// and line of that screen for the developer.
private struct BugButton: ViewModifier {
    let screen: String
    let help: ScreenHelp
    @State private var report: BugReportSheet?
    @State private var showingHelp = false

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        showingHelp = true
                    } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .accessibilityLabel("Help")
                    Button {
                        report = BugReportSheet(capture: Self.captureScreen())
                    } label: {
                        Image(systemName: "ladybug")
                    }
                    .accessibilityLabel("Report a problem")
                }
            }
            .sheet(isPresented: $showingHelp) {
                NavigationStack {
                    ScreenHelpView(help: help)
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $report) { sheet in
                NavigationStack {
                    BugReportView(screen: screen, capture: sheet.capture, inSheet: true)
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
    /// Adds the help and bug buttons. Put it next to a screen's `navigationTitle`, so the report names that screen's source.
    func bugButton(help: ScreenHelp, file: String = #fileID, line: Int = #line) -> some View {
        modifier(BugButton(screen: "\(file.split(separator: "/").last ?? Substring(file)):\(line)", help: help))
    }
}
