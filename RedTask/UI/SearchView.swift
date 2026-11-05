import SwiftUI

/// Поиск по задачам: текст (search.json) или номер «#123» / «123» — сразу эта задача.
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @Binding var selection: Int?
    @State private var query = ""
    @State private var byId: Issue?
    @State private var results: [SearchResult] = []
    @State private var total = 0
    @State private var loading = false
    @State private var error: String?
    private var recent: [RecentIssue] { app.settings.recentIssues }

    var body: some View {
        List(selection: $selection) {
            if query.isEmpty && !recent.isEmpty {
                Section {
                    ForEach(recent) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                StatusPill(status: r.status, compact: true)
                                Text(verbatim: "#\(r.id)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(r.subject).lineLimit(2)
                                .strikethrough(r.status.isClosed, color: .secondary)
                                .foregroundStyle(r.status.isClosed ? .secondary : .primary)
                        }
                        .tag(r.id)
                    }
                } header: {
                    HStack {
                        Text("Recent")
                        Spacer()
                        Button("Clear") { app.settings.recentIssues = [] }.font(.subheadline).textCase(nil)
                    }
                }
            }
            if let i = byId {
                Section("By number") {
                    IssueRow(issue: i).tag(i.id).contextMenu { IssueMenu(issue: i) }
                }
            }
            if !results.isEmpty {
                Section {
                    ForEach(results) { r in
                        VStack(alignment: .leading, spacing: 4) {
                            if let p = r.issueParts {
                                HStack(spacing: 6) {
                                    StatusPill(status: p.status, compact: true)
                                    Text(p.head).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Text(p.subject).font(.headline).lineLimit(3)
                                    .strikethrough(p.status.isClosed, color: .secondary)
                                    .foregroundStyle(p.status.isClosed ? .secondary : .primary)
                            } else {
                                Text(r.title).font(.headline).lineLimit(3)
                            }
                            if !r.description.isEmpty {
                                // в выдаче описание — сырой Textile («h2. …»), показываем как текст
                                Text(notePreview(r.description)).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(Fmt.relative(r.datetime)).font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(r.id)
                        .onAppear { if r.id == results.last?.id { Task { await more() } } }
                    }
                } header: {
                    Text("Found: \(total)")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Search")
        .searchable(text: $query, placement: .automatic, prompt: Text("Text or #number"))
        .onChange(of: selection) { _, id in if let id { remember(id) } }
        .overlay {
            if !query.isEmpty && results.isEmpty && byId == nil {
                if loading { ProgressView() }
                else if let error { LoadErrorView(message: error) { Task { await search() } } }
                else { ContentUnavailableView.search(text: query) }
            } else if query.isEmpty && recent.isEmpty {
                ContentUnavailableView("Search issues", systemImage: "magnifyingglass",
                                       description: Text("Type text from the subject or description, or an issue number."))
            }
        }
        #if DEBUG
        .onAppear { if query.isEmpty, let q = UserDefaults.standard.string(forKey: "RTQuery") { query = q } }
        #endif
        .task(id: query) {
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled { await search() }
        }
    }

    /// Открытая из поиска задача — в «Недавние» (spec 9, recent_opened).
    private func remember(_ id: Int) {
        let item = byId.flatMap { $0.id == id ? RecentIssue(id: id, subject: $0.subject, status: $0.status) : nil }
            ?? results.first { $0.id == id }.flatMap { r in r.issueParts.map { RecentIssue(id: id, subject: $0.subject, status: $0.status) } }
            ?? recent.first { $0.id == id }
        guard let item else { return }
        app.settings.recentIssues = recentOpened(recent.map(\.id), id).compactMap { i in i == id ? item : recent.first { $0.id == i } }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard let api = app.api, !q.isEmpty else { results = []; byId = nil; return }
        loading = true
        defer { loading = false }
        let bare = q.hasPrefix("#") ? String(q.dropFirst()) : q
        do {
            if let id = Int(bare), id > 0 {
                byId = try? await api.issue(id)
                if bare == q || q.hasPrefix("#") { results = []; total = 0; error = nil; return }
            } else { byId = nil }
            let r = try await api.searchPage(q)
            results = r.results
            total = r.totalCount
            error = nil
        } catch {
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    private func more() async {
        guard let api = app.api, results.count < total else { return }
        if let r = try? await api.searchPage(query, offset: results.count) {
            let known = Set(results.map(\.id))
            results += r.results.filter { !known.contains($0.id) }
            if r.results.isEmpty { total = results.count }
        }
    }
}
