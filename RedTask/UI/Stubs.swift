import SwiftUI

struct NotificationsView: View { var body: some View { Text("Notifications") } }

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
