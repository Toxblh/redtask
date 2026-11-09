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

    var isProject: Bool { if case .project = self { true } else { false } }
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
    private var generation = 0
    private var loadedEpoch = -1
    private var shownKey = ""

    /// Хоть раз сходили в сеть (успешно или нет) — до этого пустой список значит «ещё грузим».
    private(set) var loadedOnce = false
    private var loadedAt = Date.distantPast
    /// Обновлялись меньше 30 с назад — при переходе на страницу не перезапрашиваем.
    var freshLoad: Bool { Date().timeIntervalSince(loadedAt) < 30 }

    init(kind: ListKind, filter: StatusFilter) { self.kind = kind; self.filter = filter }

    /// Сохранённая выдача без сети — сразу при построении страницы.
    func showCached(_ app: AppModel) async {
        guard issues.isEmpty, query.isEmpty, let cached = await ListCache.load(app.account, cacheKey), issues.isEmpty else { return }
        issues = cached
        shownKey = cacheKey
    }

    private var cacheKey: String { "\(kind.key)-\(filter.rawValue == "*" ? "all" : filter.rawValue)" }
    var canLoadMore: Bool { issues.count < total && !loadingMore }

    private func query(offset: Int) -> IssueQuery {
        var q = IssueQuery(statusFilter: filter.rawValue, limit: 50, offset: offset)
        switch kind {
        case .mine: q.assignedToMe = true
        case .watched: q.watchedByMe = true
        case .project(let id, _): q.projectId = id
        case .favorites: q.favorites = true
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
        defer { if gen == generation { loading = false; loadedOnce = true } }
        do {
            if kind == .favorites && filter == .open { Task { await app.refreshFavorites() } }
            let page = try await api.issues(query(offset: 0))
            let fresh = page.issues
            total = page.totalCount
            guard gen == generation else { return }
            issues = fresh
            shownKey = cacheKey
            loadedAt = Date()
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

/// Список с фильтрами Открытые/Закрытые/Все — как папки чатов в Telegram (ChatListContainerNode):
/// все три списка построены и лежат рядом, свайп двигает их за пальцем, в конце — пружина к соседу.
/// Свайп от края строки — действия над задачей.
struct IssueListView: View {
    let kind: ListKind
    @Binding var selection: Int?
    @State private var models: [StatusFilter: IssueListModel]
    @State private var filter: StatusFilter = .open
    /// Сдвиг страниц пальцем, pt; 0 — покой.
    @State private var drag: CGFloat = 0
    @State private var query = ""
    @State private var openSwipe: Int?

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

    private static let all = StatusFilter.allCases
    private var index: Int { Self.all.firstIndex(of: filter)! }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Status", selection: Binding(get: { filter }, set: { f in withAnimation(.spring(duration: 0.45)) { filter = f } })) {
                ForEach(Self.all) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.bottom, 8)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack {
                    ForEach(Self.all) { f in
                        let d = CGFloat(Self.all.firstIndex(of: f)! - index)
                        IssueListPage(model: models[f]!, query: query, active: f == filter, selection: $selection, openSwipe: $openSwipe)
                            .offset(x: d * w + drag)
                            .allowsHitTesting(d == 0)
                            .accessibilityHidden(d != 0)
                    }
                }
                .frame(width: w, height: geo.size.height)
                .clipped()
                .middleSwipe { dx in
                    openSwipe = nil
                    drag = banded(dx, w: w)
                } ended: { dx, vx in
                    finish(dx, vx, w: w)
                }
            }
        }
        .navigationTitle(title)
        // вкладки — крупный, как у «Проектов» и «Поиска»; в проекте — мелкий: на нём меню разделов (toolbarTitleMenu)
        .navigationBarTitleDisplayMode(kind.isProject ? .inline : .large)
        .searchable(text: $query, prompt: Text("Search in this list"))
    }

    /// За крайними фильтрами — «резинка», как у Telegram.
    private func banded(_ dx: CGFloat, w: CGFloat) -> CGFloat {
        let over: CGFloat = dx > 0 ? (index == 0 ? dx : 0) : (index == Self.all.count - 1 ? -dx : 0)
        guard over > 0 else { return dx }
        let range: CGFloat = 600, k: CGFloat = 0.4
        let b = (1 - 1 / (over * k / range + 1)) * range
        return dx > 0 ? b : -b
    }

    /// Направление — по скорости (если палец ещё двигался), иначе — дальше ли половины ширины.
    private func finish(_ dx: CGFloat, _ vx: CGFloat, w: CGFloat) {
        var step = 0
        if abs(vx) > 10 {
            if dx < 0 && vx < 0 { step = 1 } else if dx > 0 && vx > 0 { step = -1 }
        } else if abs(dx) > w / 2 {
            step = dx < 0 ? 1 : -1
        }
        let i = min(max(index + step, 0), Self.all.count - 1)
        if i != index { UISelectionFeedbackGenerator().selectionChanged() }
        withAnimation(.spring(duration: 0.45)) {
            filter = Self.all[i]
            drag = 0
        }
    }
}

/// Одна страница-фильтр. Сеть — когда страница видна (соседние догружаются фоном чуть позже),
/// сохранённое показывается сразу, так что при быстром перелистывании список уже «есть».
private struct IssueListPage: View {
    @Environment(AppModel.self) private var app
    let model: IssueListModel
    let query: String
    let active: Bool
    @Binding var selection: Int?
    @Binding var openSwipe: Int?
    @State private var actionError: String?
    /// Обновление жестом: у него свой системный индикатор (spec 12).
    @State private var pulling = false

    var body: some View {
        List(selection: $selection) {
            if model.stale || (model.kind == .favorites && !app.settings.favoritesPending.isEmpty) {
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
                    if model.kind == .favorites && !app.settings.favoritesPending.isEmpty {
                        // избранное прежних версий жило только на устройстве — переносится, как только есть веб-сессия
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Favorites saved on this device (\(app.settings.favoritesPending.count)) will move to the server once you sign in via website.")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Sign in via website") { app.showWebLogin = true }
                                .buttonStyle(.bordered).font(.footnote)
                        }
                    }
                }
            }
            Section {
                ForEach(model.issues) { issue in
                    IssueRow(issue: issue, showProject: !isProject)
                        .edgeSwipe(id: issue.id, open: $openSwipe, leading: favoriteAction(issue), trailing: takeAction(issue))
                        .listRowInsets(EdgeInsets())
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
        .refreshable { pulling = true; await model.load(app); pulling = false }
        // spec 12: обновление без жеста (после правки, возврат на страницу) — индикатор в панели, список на месте
        .toolbar {
            if active && model.loading && !pulling && !model.issues.isEmpty {
                ToolbarItem(placement: .topBarTrailing) { ProgressView() }
            }
        }
        .overlay {
            if model.issues.isEmpty {
                if let e = model.error {
                    LoadErrorView(message: e) { Task { await model.load(app) } }
                } else if model.loading || !model.loadedOnce {
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
        .task {
            await model.showCached(app)
            // соседние страницы — свежими к моменту, когда до них долистают
            if !active {
                try? await Task.sleep(for: .seconds(1.5))
                if !Task.isCancelled && !model.loadedOnce { await model.load(app) }
            }
        }
        .task(id: "\(active)|\(query)") {
            guard active else { return }
            let typing = model.query != query
            model.query = query
            if typing && !query.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            // только что обновлённую соседнюю страницу не дёргаем повторно
            if !Task.isCancelled && (typing || !model.freshLoad) { await model.load(app) }
        }
        .onChange(of: app.listEpoch) { if active { Task { await model.reloadIfStale(app) } } }
        .onChange(of: app.favoritesEpoch) { if model.kind == .favorites { Task { await model.load(app) } } }
        .errorAlert($actionError)
    }

    private var isProject: Bool { if case .project = model.kind { true } else { false } }

    private func favoriteAction(_ issue: Issue) -> EdgeAction {
        let fav = app.isFavorite(issue.id)
        return EdgeAction(title: fav ? "Unfavorite" : "Favorite", systemImage: fav ? "star.slash.fill" : "star.fill", tint: .orange) {
            app.toggleFavorite(issue.id)
        }
    }

    private func takeAction(_ issue: Issue) -> EdgeAction? {
        guard issue.assignedTo?.id != app.settings.userId && !issue.status.isClosed else { return nil }
        return EdgeAction(title: "Take", systemImage: "person.fill.checkmark", tint: .blue) { assign(issue) }
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
                    .lineLimit(1).layoutPriority(1) // ужимается имя исполнителя, а не приоритет
                if let due = issue.dueDate {
                    let overdue = Fmt.isOverdue(due) && !closed
                    HStack(spacing: 3) { Image(systemName: overdue ? "exclamationmark.circle" : "calendar"); Text(Fmt.shortDate(due)) }
                        .foregroundStyle(overdue ? .red : .secondary)
                        .lineLimit(1).layoutPriority(1)
                }
                if !ax { Spacer(minLength: 4) }
                if showAssignee, let a = issue.assignedTo {
                    // узкая колонка (iPad, русский) — только аватар, без огрызка «Алекс…»
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            Text(a.name).lineLimit(1).fixedSize().foregroundStyle(.secondary)
                            Avatar(name: a.name, userId: a.id, size: 24)
                        }
                        Avatar(name: a.name, userId: a.id, size: 24).accessibilityRepresentation { Text(a.name) }
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
            if !app.isDemo { Button { openURL(url) } label: { Label("Open in Safari", systemImage: "safari") } }
        }
    }
}
