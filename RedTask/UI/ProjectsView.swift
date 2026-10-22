import SwiftUI

/// Проекты (кэш на неделю) → задачи проекта. Внутренний стек живёт в колонке списка.
struct ProjectsView: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: Int?
    @State private var projects: [Project] = []
    @State private var error: String?
    @State private var loading = false
    @State private var query = ""
    @State private var path: [Project] = []

    private var shown: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.identifier.localizedCaseInsensitiveContains(q) }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        NavigationStack(path: $path) {
            List(shown) { p in
                NavigationLink(value: p) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(p.name).font(.body)
                        if let parent = p.parent?.name, !parent.isEmpty {
                            Text(parent).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .contextMenu {
                    Button { copyToPasteboard(p.identifier) } label: { Label("Copy identifier", systemImage: "doc.on.doc") }
                    if let api = app.api {
                        Link(destination: api.baseURL.appendingPathComponent("projects/\(p.identifier)")) {
                            Label("Open in Safari", systemImage: "safari")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Projects")
            .searchable(text: $query, prompt: Text("Filter projects"))
            .refreshable { await load(force: true) }
            .overlay {
                if projects.isEmpty {
                    if let error { LoadErrorView(message: error) { Task { await load(force: true) } } }
                    else if loading { ProgressView() }
                    else { ContentUnavailableView("No projects", systemImage: "folder") }
                } else if shown.isEmpty {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationDestination(for: Project.self) { p in
                IssueListView(kind: .project(p.id, p.name), selection: $selection)
            }
            .task { if projects.isEmpty { await load(force: false) } }
        }
    }

    private func load(force: Bool) async {
        guard let refs = app.refs else { return }
        loading = true
        defer { loading = false }
        do {
            projects = try await refs.projects(force: force)
            error = nil
        } catch {
            if projects.isEmpty { self.error = error.localizedDescription }
        }
    }
}
