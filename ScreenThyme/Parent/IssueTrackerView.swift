import SwiftUI
import ThymeCore

/// The GitHub repository the family's bug reports go to, and the token phones file them with (PLAN.md §18).
struct IssueTrackerView: View {
    @Environment(AppModel.self) private var model
    @State private var saved: IssueTracker?
    @State private var repository = ""
    @State private var token = ""
    @State private var loading = true
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("owner/repository", text: $repository)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                SecureField(saved == nil ? "Token" : "Token (leave empty to keep it)", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } header: {
                Text("GitHub")
            } footer: {
                Text("Each phone files its reports as issues in this repository, with its screenshots committed under reports/. Use a private repository, and a fine-grained token for that repository only, with Issues and Contents set to Read and write. Every phone in the family can read the token.")
            }
            Section {
                Button(saving ? "Saving…" : "Save") { Task { await save() } }
                    .disabled(saving || loading || !canSave)
            } footer: {
                if let saved {
                    Text("Saved: \(saved.repository), \(Format.relative(saved.updatedAt)).")
                } else if !loading {
                    Text("Not set up: reports wait on each phone until it is.")
                }
            }
        }
        .navigationTitle("Bug reports")
        .bugButton(help: .bugReports)
        .task { await load() }
    }

    private var canSave: Bool {
        IssueTracker.isValidRepository(repository.trimmingCharacters(in: .whitespaces))
            && !(token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && saved == nil)
    }

    private func load() async {
        defer { loading = false }
        guard let store = model.store else { return }
        do {
            saved = try await IssueTrackerService.fetch(store: store)
            repository = saved?.repository ?? ""
        } catch {
            model.showUnlessOffline(error)
        }
    }

    private func save() async {
        guard let store = model.store else { return }
        saving = true
        defer { saving = false }
        let newToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let tracker = IssueTracker(repository: repository, token: newToken.isEmpty ? saved?.token ?? "" : newToken,
                                   updatedAt: Date())
        do {
            try await IssueTrackerService.save(tracker, store: store)
            saved = tracker
            token = ""
        } catch {
            model.show(error)
        }
    }
}
