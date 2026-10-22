import SwiftUI

enum StatusFilter: String, CaseIterable, Identifiable {
    case open, closed, all = "*"
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .open: "Open"
        case .closed: "Closed"
        case .all: "All"
        }
    }
}

enum ListKind: Hashable {
    case mine, watched, favorites
    case project(Int, String)

    var key: String {
        switch self {
        case .mine: "mine"
        case .watched: "watched"
        case .favorites: "favorites"
        case .project(let id, _): "project-\(id)"
        }
    }
}

/// Список задач: кэш мгновенно, сеть освежает (stale-while-revalidate), подгрузка страницами.
@MainActor @Observable
final class IssueListModel {
    let kind: ListKind
    let filter: StatusFilter
    var query = ""
    private(set) var issues: [Issue] = []
    private(set) var total = 0
    private(set) var loading = false
    private(set) var loadingMore = false
    private(set) var error: String?
    /// Не удалось обновить, показан сохранённый список.
    private(set) var stale = false
    private(set) var missingFavorites: [Int] = []
    private var generation = 0
    private var loadedEpoch = -1
    private var shownKey = ""

    init(kind: ListKind, filter: StatusFilter) { self.kind = kind; self.filter = filter }

    private var cacheKey: String { "\(kind.key)-\(filter.rawValue == "*" ? "all" : filter.rawValue)" }
    var canLoadMore: Bool { kind != .favorites && issues.count < total && !loadingMore }

    private func query(offset: Int) -> IssueQuery {
        var q = IssueQuery(statusFilter: filter.rawValue, limit: 50, offset: offset)
        switch kind {
        case .mine: q.assignedToMe = true
        case .watched: q.watchedByMe = true
        case .project(let id, _): q.projectId = id
        case .favorites: break
        }
        let s = query.trimmingCharacters(in: .whitespaces)
        if !s.isEmpty { q.subject = s }
        return q
    }

    /// Сохранённая выдача без сети — для соседних страниц, пока их не открыли.
    func showCached(_ app: AppModel) async {
        guard issues.isEmpty, query.isEmpty, let cached = await ListCache.load(app.account, cacheKey), issues.isEmpty else { return }
        issues = cached
        shownKey = cacheKey
    }

    func reloadIfStale(_ app: AppModel) async {
        if loadedEpoch != app.listEpoch { await load(app) }
    }

    func load(_ app: AppModel) async {
        guard let api = app.api else { return }
        generation += 1
        let gen = generation
        loadedEpoch = app.listEpoch
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        if !searching, let cached = await ListCache.load(app.account, cacheKey), gen == generation {
            // смена фильтра — сразу сохранённая выдача нового фильтра; обновление того же — не трогаем показанное
            if issues.isEmpty || shownKey != cacheKey { issues = cached }
        }
        loading = true
        defer { if gen == generation { loading = false } }
        do {
            let fresh: [Issue]
            if kind == .favorites {
                let r = try await api.issuesByIds(app.settings.favorites)
                missingFavorites = r.missing
                fresh = r.found
                    .filter { filter == .all || (filter == .closed) == $0.status.isClosed }
                    .filter { !searching || $0.subject.localizedCaseInsensitiveContains(query) || "#\($0.id)".contains(query) }
                    .sorted { $0.updatedOn > $1.updatedOn }
                total = fresh.count
            } else {
                let page = try await api.issues(query(offset: 0))
                fresh = page.issues
                total = page.totalCount
            }
            guard gen == generation else { return }
            issues = fresh
            shownKey = cacheKey
            error = nil
            stale = false
            if !searching { await ListCache.save(app.account, cacheKey, fresh) }
        } catch {
            guard gen == generation, !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
            if issues.isEmpty { self.error = error.localizedDescription } else { stale = true }
        }
    }

    func loadMore(_ app: AppModel) async {
        guard let api = app.api, canLoadMore else { return }
        let gen = generation
        loadingMore = true
        defer { loadingMore = false }
        do {
            let page = try await api.issues(query(offset: issues.count))
            guard gen == generation else { return }
            let known = Set(issues.map(\.id))
            issues += page.issues.filter { !known.contains($0.id) }
            total = page.issues.isEmpty ? issues.count : page.totalCount
        } catch { stale = true }
    }

    func assignToMe(_ issue: Issue, _ app: AppModel) async throws {
        guard let api = app.api else { return }
        try await api.updateIssue(issue.id, ["assigned_to_id": app.settings.userId])
        await load(app)
    }
}

/// Список с фильтрами Открытые/Закрытые/Все: страницы листаются свайпом за пальцем (как папки в Telegram),
/// свайп от края карточки — действие над ней.
struct IssueListView: View {
    let kind: ListKind
    @Binding var selection: Int?
    @State private var models: [StatusFilter: IssueListModel]
    @State private var page: StatusFilter? = .open
    @State private var query = ""

    init(kind: ListKind, selection: Binding<Int?>) {
        self.kind = kind
        _selection = selection
        _models = State(initialValue: Dictionary(uniqueKeysWithValues: StatusFilter.allCases.map { ($0, IssueListModel(kind: kind, filter: $0)) }))
    }

    private var title: String {
        switch kind {
        case .mine: String(localized: "My Issues")
        case .watched: String(localized: "Watching")
        case .favorites: String(localized: "Favorites")
        case .project(_, let name): name
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Status", selection: Binding(get: { page ?? .open }, set: { f in withAnimation { page = f } })) {
                ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 8)
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(StatusFilter.allCases) { f in
                        IssueListPage(model: models[f]!, query: query, active: (page ?? .open) == f, selection: $selection)
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(f)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $page)
            .scrollIndicators(.hidden)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: Text("Search in this list"))
    }
}

/// Одна страница-фильтр. Грузит из сети, только пока видна; соседние сразу показывают сохранённое.
private struct IssueListPage: View {
    @Environment(AppModel.self) private var app
    let model: IssueListModel
    let query: String
    let active: Bool
    @Binding var selection: Int?
    @State private var actionError: String?

    var body: some View {
        List(selection: $selection) {
            if model.stale || (model.kind == .favorites && !model.missingFavorites.isEmpty) {
                Section {
                    if model.stale {
                        Button {
                            Task { await model.load(app) }
                        } label: {
                            Label("Couldn’t refresh — showing the saved list. Tap to retry.", systemImage: "wifi.exclamationmark")
                                .font(.footnote)
                        }
                        CaptchaButton { Task { await model.load(app) } }
                    }
                    if model.kind == .favorites && !model.missingFavorites.isEmpty {
                        Text("Unavailable (deleted or no access): \(model.missingFavorites.map { "#\($0)" }.joined(separator: ", "))")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                ForEach(model.issues) { issue in
                    IssueRow(issue: issue, showProject: !isProject, showAssignee: model.kind != .mine)
                        .edgeSwipe(leading: favoriteAction(issue), trailing: takeAction(issue))
                        .tag(issue.id)
                        .contextMenu { IssueMenu(issue: issue, onAssign: { assign(issue) }) }
                        .onAppear {
                            if issue.id == model.issues.last?.id { Task { await model.loadMore(app) } }
                        }
                }
                if model.loadingMore {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await model.load(app) }
        .overlay {
            if model.issues.isEmpty {
                if let e = model.error {
                    LoadErrorView(message: e) { Task { await model.load(app) } }
                } else if model.loading || !active {
                    ProgressView()
                } else if model.kind == .favorites && app.settings.favorites.isEmpty {
                    ContentUnavailableView("No favorites yet", systemImage: "star",
                                           description: Text("Tap the star on an issue or swipe right from its edge in a list."))
                } else if !model.query.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                } else {
                    ContentUnavailableView("Nothing here yet", systemImage: "tray")
                }
            }
        }
        .task { await model.showCached(app) }
        .task(id: "\(active)|\(query)") {
            guard active else { return }
            // поиск — после паузы в наборе; переход на страницу — сразу
            let typing = model.query != query && !query.isEmpty
            model.query = query
            if typing { try? await Task.sleep(for: .milliseconds(400)) }
            if !Task.isCancelled { await model.load(app) }
        }
        .onChange(of: app.listEpoch) { if active { Task { await model.reloadIfStale(app) } } }
        .onChange(of: app.settings.favorites) { if active && model.kind == .favorites { Task { await model.load(app) } } }
        .errorAlert($actionError)
    }

    private var isProject: Bool { if case .project = model.kind { true } else { false } }

    private func favoriteAction(_ issue: Issue) -> EdgeAction {
        let fav = app.isFavorite(issue.id)
        return EdgeAction(title: fav ? "Unfavorite" : "Favorite", systemImage: fav ? "star.slash" : "star", tint: .yellow) {
            app.toggleFavorite(issue.id)
        }
    }

    private func takeAction(_ issue: Issue) -> EdgeAction? {
        guard issue.assignedTo?.id != app.settings.userId && !issue.status.isClosed else { return nil }
        return EdgeAction(title: "Take", systemImage: "person.crop.circle.badge.checkmark", tint: .accentColor) { assign(issue) }
    }

    private func assign(_ issue: Issue) {
        Task {
            do { try await model.assignToMe(issue, app) } catch { actionError = error.localizedDescription }
        }
    }
}

/// Строка задачи: номер и трекер, тема, проект/статус/исполнитель; на крупном шрифте — столбиком.
struct IssueRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize
    let issue: Issue
    var showProject = true
    var showAssignee = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            let ax = typeSize.isAccessibilitySize
            let head = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
            head {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(issue.id)").monospacedDigit().fixedSize()
                    Text(issue.tracker.name)
                    if app.isFavorite(issue.id) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favorite")
                    }
                    if issue.isPrivate {
                        Image(systemName: "lock.fill").accessibilityLabel("Private")
                    }
                }
                if !ax { Spacer() }
                Text(Fmt.relative(issue.updatedOn))
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(issue.subject)
                .font(.headline)
                .strikethrough(issue.status.isClosed, color: .secondary)
                .lineLimit(typeSize.isAccessibilitySize ? 4 : 2)

            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
            layout {
                Text(issue.status.name)
                    .foregroundStyle(statusTint(issue.status))
                    .fontWeight(.medium)
                if showProject { Text(issue.project.name).lineLimit(1) }
                if showAssignee, let a = issue.assignedTo { Text(a.name).lineLimit(1) }
                if let due = issue.dueDate, !issue.status.isClosed {
                    let overdue = Fmt.isOverdue(due)
                    Label(Fmt.date(due), systemImage: overdue ? "exclamationmark.circle" : "calendar")
                        .foregroundStyle(overdue ? .red : .secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Контекстное меню задачи — одинаковое в списках, поиске и колокольчике.
struct IssueMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let issue: Issue
    var onAssign: (() -> Void)?

    var body: some View {
        if let api = app.api {
            let url = api.issueWebURL(issue.id)
            Section {
                Button {
                    app.toggleFavorite(issue.id)
                } label: {
                    Label(app.isFavorite(issue.id) ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: app.isFavorite(issue.id) ? "star.slash" : "star")
                }
                if let onAssign, issue.assignedTo?.id != app.settings.userId {
                    Button(action: onAssign) { Label("Assign to me", systemImage: "person.crop.circle.badge.checkmark") }
                }
            }
            Section {
                Button { copyToPasteboard("#\(issue.id)") } label: { Label("Copy issue number", systemImage: "number") }
                Button { copyToPasteboard(url.absoluteString) } label: { Label("Copy link", systemImage: "link") }
                ShareLink(item: url, subject: Text(issue.subject), message: Text("#\(issue.id) \(issue.subject)")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
            Button { openURL(url) } label: { Label("Open in Safari", systemImage: "safari") }
        }
    }
}
