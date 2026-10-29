import SwiftUI

/// Проекты (кэш на неделю) → задачи проекта. Внутренний стек живёт в колонке списка.
struct ProjectsView: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: Project?
    @State private var projects: [Project] = []
    @State private var error: String?
    @State private var loading = false
    @State private var query = ""

    private var shown: [Project] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = q.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.identifier.localizedCaseInsensitiveContains(q) }
        return list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        Group {
            List(selection: $selection) {
                // избранные — секцией сверху (только при пустом фильтре), общий список не меняется
                let pinned = query.isEmpty ? pinnedProjects(projects, pins: app.projectPins) : []
                if pinned.isEmpty {
                    ForEach(shown) { row($0) }
                } else {
                    Section("Pinned") { ForEach(pinned) { row($0) } }
                    Section("All projects") { ForEach(shown) { row($0) } }
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
            .task { if projects.isEmpty { await load(force: false) } }
        }
    }

    private func row(_ p: Project) -> some View {
        let pinned = app.isPinned(p.id)
        return NavigationLink(value: p) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.name).font(.body)
                    if let parent = p.parent?.name, !parent.isEmpty {
                        Text(parent).font(.caption).foregroundStyle(.secondary)
                    }
                }
                if pinned {
                    Spacer()
                    Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Pinned")
                }
            }
        }
        .swipeActions(edge: .leading) {
            Button { app.togglePin(p.id) } label: {
                Label(pinned ? "Unpin" : "Pin", systemImage: pinned ? "star.slash.fill" : "star.fill")
            }
            .tint(.orange)
        }
        .contextMenu {
            Button { app.togglePin(p.id) } label: {
                Label(pinned ? "Remove from Pinned" : "Add to Pinned", systemImage: pinned ? "star.slash" : "star")
            }
            Button { copyToPasteboard(p.identifier) } label: { Label("Copy identifier", systemImage: "doc.on.doc") }
            if let api = app.api, !app.isDemo {
                Link(destination: api.baseURL.appendingPathComponent("projects/\(p.identifier)")) {
                    Label("Open in Safari", systemImage: "safari")
                }
            }
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
