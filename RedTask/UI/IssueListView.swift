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
    var filter: StatusFilter = .open
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

    init(kind: ListKind) { self.kind = kind }

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

struct IssueListView: View {
    @Environment(AppModel.self) private var app
    @State private var model: IssueListModel
    @Binding var selection: Int?
    @State private var actionError: String?

    init(kind: ListKind, selection: Binding<Int?>) {
        _model = State(initialValue: IssueListModel(kind: kind))
        _selection = selection
    }

    private var title: String {
        switch model.kind {
        case .mine: String(localized: "My Issues")
        case .watched: String(localized: "Watching")
        case .favorites: String(localized: "Favorites")
        case .project(_, let name): name
        }
    }

    var body: some View {
        @Bindable var model = model
        List(selection: $selection) {
            Section {
                ForEach(model.issues) { issue in
                    IssueRow(issue: issue, showProject: !isProject)
                        .tag(issue.id)
                        .edgeSwipe(leading: favoriteAction(issue), trailing: takeAction(issue))
                        .contextMenu { IssueMenu(issue: issue, onAssign: { assign(issue) }) }
                        .onAppear {
                            if issue.id == model.issues.last?.id { Task { await model.loadMore(app) } }
                        }
                }
                if model.loadingMore {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Status", selection: $model.filter) {
                        ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
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
                .textCase(nil)
                .padding(.bottom, 4)
            }
        }
        .listStyle(.plain)
        .middleSwipe { step in
            // свайп из середины — соседний фильтр, как на Android; от края строки — действие над задачей
            let all = StatusFilter.allCases, i = all.firstIndex(of: model.filter)! + step
            guard all.indices.contains(i) else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.snappy) { model.filter = all[i] }
        }
        .navigationTitle(title)
        .searchable(text: $model.query, prompt: Text("Search in this list"))
        .refreshable { await model.load(app) }
        .overlay {
            if model.issues.isEmpty {
                if let e = model.error {
                    LoadErrorView(message: e) { Task { await model.load(app) } }
                } else if model.loading {
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
        .task(id: "\(model.filter.rawValue)|\(model.query)") {
            // поиск — после паузы в наборе; смена фильтра — сразу
            if !model.query.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            if !Task.isCancelled { await model.load(app) }
        }
        .onChange(of: app.listEpoch) { Task { await model.reloadIfStale(app) } }
        .onChange(of: app.settings.favorites) { if model.kind == .favorites { Task { await model.load(app) } } }
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

/// Строка задачи — как карточка на Android: статус, трекер и номер, тема (закрытые зачёркнуты и приглушены),
/// проект, приоритет, срок, исполнитель с аватаром и прогресс.
struct IssueRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dynamicTypeSize) private var typeSize
    let issue: Issue
    var showProject = true
    var showAssignee = true

    var body: some View {
        let ax = typeSize.isAccessibilitySize
        let closed = issue.status.isClosed
        VStack(alignment: .leading, spacing: 4) {
            let head = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2)) : AnyLayout(HStackLayout(spacing: 6))
            head {
                StatusPill(status: issue.status, compact: true)
                HStack(spacing: 4) {
                    Text(verbatim: "\(issue.tracker.name) #\(issue.id)").lineLimit(1)
                    if app.isFavorite(issue.id) {
                        Image(systemName: "star.fill").foregroundStyle(.yellow).accessibilityLabel("Favorite")
                    }
                    if issue.isPrivate {
                        Image(systemName: "lock.fill").accessibilityLabel("Private")
                    }
                }
                if !ax { Spacer(minLength: 4) }
                Text(Fmt.relative(issue.updatedOn)).fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(issue.subject)
                .font(.headline)
                .strikethrough(closed, color: .secondary)
                .lineLimit(ax ? 4 : 2)
            if showProject {
                Text(issue.project.name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }

            let foot = ax ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 10))
            foot {
                HStack(spacing: 3) { Image(systemName: "flag"); Text(issue.priority.name) }
                    .foregroundStyle(priorityTint(issue.priority.name))
                if let due = issue.dueDate {
                    let overdue = Fmt.isOverdue(due) && !closed
                    HStack(spacing: 3) { Image(systemName: overdue ? "exclamationmark.circle" : "calendar"); Text(Fmt.date(due)) }
                        .foregroundStyle(overdue ? .red : .secondary)
                }
                if !ax { Spacer(minLength: 4) }
                if showAssignee, let a = issue.assignedTo {
                    HStack(spacing: 6) {
                        Text(a.name).lineLimit(1).foregroundStyle(.secondary)
                        Avatar(name: a.name, userId: a.id, size: 24)
                    }
                }
            }
            .font(.footnote)
            .padding(.top, 2)

            if issue.doneRatio > 0 {
                HStack(spacing: 6) {
                    ProgressView(value: Double(issue.doneRatio), total: 100)
                    Text("\(issue.doneRatio)%").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .opacity(closed ? 0.6 : 1)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Цвет приоритета — как на Android: срочные красным, высокий акцентом, низкий приглушённо.
func priorityTint(_ name: String) -> Color {
    let n = name.lowercased()
    if n.contains("immediate") || n.contains("немедл") || n.contains("urgent") || n.contains("срочн") { return .red }
    if n.contains("high") || n.contains("высок") { return .accentColor }
    if n.contains("low") || n.contains("низк") { return Color(.tertiaryLabel) }
    return .secondary
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
