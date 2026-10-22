import SwiftUI

struct IssueDetailView: View {
    let issueId: Int
    var note: Int?
    var newSubtask: (Issue) -> Void = { _ in }
    var body: some View { Text(verbatim: "#\(issueId)") }
}

struct NotificationsView: View { var body: some View { Text("Notifications") } }
struct NewIssueView: View { var projectId: Int?; var parent: Int?; var body: some View { Text("New Issue") } }

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    LabeledContent("Signed in as", value: app.settings.userName)
                    LabeledContent("Server", value: app.settings.serverURL)
                    Button("Sign Out", role: .destructive) { dismiss(); app.logout() }
                }
            }
            .navigationTitle("Settings")
        }
    }
}
