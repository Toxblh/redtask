import SwiftUI

/// Разделы экрана проекта (spec 2.2) — в этом порядке; модуль nil — раздел есть всегда.
enum ProjectSection: String, CaseIterable, Identifiable {
    case issues, overview, versions, wiki, files
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .issues: "Issues"
        case .overview: "Overview"
        case .versions: "Versions"
        case .wiki: "Wiki"
        case .files: "Files"
        }
    }
    var icon: String {
        switch self {
        case .issues: "checklist"
        case .overview: "info.circle"
        case .versions: "flag.checkered"
        case .wiki: "book.closed"
        case .files: "doc.on.doc"
        }
    }
    var module: String? {
        switch self {
        case .issues, .versions: "issue_tracking"
        case .overview: nil
        case .wiki: "wiki"
        case .files: "files"
        }
    }
}

/// Проект: задачи, обзор, вехи, вики, файлы — по включённым модулям. Отключённый модуль или 403 — раздела нет.
/// Веха и страница вики открываются в колонке детали (page), задача — как из обычного списка (selection).
struct ProjectView: View {
    @Environment(AppModel.self) private var app
    let project: Project
    @Binding var selection: Int?
    @Binding var page: ProjectPage?
    @State private var full: Project?
    @State private var hidden = Set<ProjectSection>()
    @State private var section: ProjectSection = .issues

    private var sections: [ProjectSection] {
        ProjectSection.allCases.filter { s in
            guard !hidden.contains(s) else { return false }
            guard let m = s.module else { return true }
            // модули ещё не пришли — задачи по-старому, остальное после ответа
            guard let modules = full?.enabledModules else { return s == .issues }
            return modules.contains { $0.name == m }
        }
    }

    var body: some View {
        let shown = sections.contains(section) ? section : sections.first ?? .overview
        Group {
            switch shown {
            case .issues: IssueListView(kind: .project(project.id, project.name), selection: $selection)
            case .overview: ProjectOverview(project: full ?? project)
            case .versions: VersionsList(project: project, page: $page) { hidden.insert(.versions) }
            case .wiki: WikiIndex(project: project, page: $page) { hidden.insert(.wiki) }
            case .files: ProjectFiles(project: project) { hidden.insert(.files) }
            }
        }
        // разделы — меню заголовка, а не сегменты: пять подписей в узкой колонке iPad обрезались,
        // а на iPhone сегменты разделов стояли стопкой с Открытые/Закрытые/Все под полем поиска (docs/HIG-notes.md)
        .navigationTitle(project.name)
        .navigationSubtitleIfAvailable(shown.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarTitleMenu {
            if sections.count > 1 {
                Picker("Section", selection: $section) {
                    ForEach(sections) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
            }
        }
        .task { full = try? await app.api?.projectModules(project.id) }
    }
}

extension View {
    /// Подзаголовок навбара — с iOS 26; раньше раздел виден только галочкой в меню заголовка.
    @ViewBuilder func navigationSubtitleIfAvailable(_ text: LocalizedStringKey) -> some View {
        if #available(iOS 26, *) { navigationSubtitle(Text(text)) } else { self }
    }
}

/// Отказ 403 по разделу — раздел скрывается (onForbidden), прочие сбои — ошибкой с повтором.
private func isForbidden(_ e: Error) -> Bool { (e as? RedmineError)?.code == 403 }

// MARK: - Обзор

private struct ProjectOverview: View {
    @Environment(AppModel.self) private var app
    let project: Project
    @State private var members: [Membership] = []
    @State private var person: Named?

    /// Участники по ролям, роли — в порядке появления.
    private var byRole: [(String, [Named])] {
        var order: [String] = []
        var by: [String: [Named]] = [:]
        for m in members {
            guard let who = m.user ?? m.group else { continue }
            for r in m.roles {
                if by[r.name] == nil { order.append(r.name) }
                if by[r.name]?.contains(who) != true { by[r.name, default: []].append(who) }
            }
        }
        return order.map { ($0, by[$0]!.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) }
    }

    var body: some View {
        List {
            Section {
                if let d = project.description, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    RichText(text: d, context: RichContext(baseURL: app.api?.baseURL)).padding(.vertical, 4)
                }
                if let h = project.homepage, !h.isEmpty, let url = URL(string: h) {
                    LabeledContent("Homepage") { Link(h, destination: url).lineLimit(1).truncationMode(.middle) }
                }
                if let parent = project.parent { LabeledContent("Parent project", value: parent.name) }
                LabeledContent("Identifier", value: project.identifier)
            }
            ForEach(byRole, id: \.0) { role, people in
                Section(role) {
                    ForEach(people) { p in
                        // карточка — только у людей; у группы её нет
                        let isUser = members.contains { $0.user?.id == p.id }
                        Button { if isUser { person = p } } label: { PersonLine(person: p) }
                            .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .task { if members.isEmpty { members = (try? await app.api?.memberships(project.id)) ?? [] } }
        .refreshable { members = (try? await app.api?.memberships(project.id)) ?? members }
        .sheet(item: $person) { PersonCard(userId: $0.id).environment(app) }
    }
}

// MARK: - Вехи

/// Чьи задачи на доске: вехи (spec 3.2) или прямые подзадачи (spec 3.3).
enum BoardScope: Hashable {
    case version(Int), parent(Int)
}

/// Переход к подзадачам доской из задачи.
struct SubtaskBoardLink: Hashable {
    var id: Int
    var subject: String
}

/// Задачи доски — один раз на веху или родителя: и для прогресса в списке вех, и для экрана.
@MainActor @Observable
final class VersionIssueStore {
    static let shared = VersionIssueStore()
    private var cache: [String: [Issue]] = [:]
    private var errors: [String: String] = [:]
    private(set) var loading = Set<String>()

    private func key(_ s: BoardScope, _ app: AppModel) -> String { "\(app.account)-\(s)" }
    func issues(_ s: BoardScope, _ app: AppModel) -> [Issue]? { cache[key(s, app)] }
    func error(_ s: BoardScope, _ app: AppModel) -> String? { errors[key(s, app)] }
    func isLoading(_ s: BoardScope, _ app: AppModel) -> Bool { loading.contains(key(s, app)) }

    func load(_ s: BoardScope, _ app: AppModel, force: Bool = false) async {
        let k = key(s, app)
        guard force || cache[k] == nil, !loading.contains(k), let api = app.api else { return }
        loading.insert(k)
        defer { loading.remove(k) }
        do {
            switch s {
            case .version(let id): cache[k] = try await api.boardIssues(version: id)
            case .parent(let id): cache[k] = try await api.boardIssues(parent: id)
            }
            errors[k] = nil
        } catch {
            errors[k] = error.localizedDescription
        }
    }
}

private struct VersionsList: View {
    @Environment(AppModel.self) private var app
    let project: Project
    @Binding var page: ProjectPage?
    var onForbidden: () -> Void
    @State private var versions: [Version]?
    @State private var error: String?
    @State private var showClosed = false

    var body: some View {
        let groups = versionGroups(versions ?? [])
        List(selection: $page) {
            ForEach(groups.open) { VersionRow(version: $0).tag(ProjectPage.version($0)) }
            if !groups.closed.isEmpty {
                DisclosureGroup(isExpanded: $showClosed) {
                    ForEach(groups.closed) { VersionRow(version: $0).tag(ProjectPage.version($0)) }
                } label: {
                    Text("Closed (\(groups.closed.count))")
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if versions?.isEmpty ?? true {
                if let error { LoadErrorView(message: error) { Task { await load() } } }
                else if versions == nil { ProgressView() }
                else { ContentUnavailableView("No versions", systemImage: "flag.checkered") }
            }
        }
        .refreshable { await load() }
        .task { if versions == nil { await load() } }
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            // общие вехи других проектов тоже приходят — показываем все, как сайт
            versions = try await api.versions(project.id)
            error = nil
        } catch {
            if isForbidden(error) { onForbidden() } else { self.error = error.localizedDescription }
        }
    }
}

private struct VersionRow: View {
    @Environment(AppModel.self) private var app
    let version: Version
    private var store: VersionIssueStore { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(version.name).font(.headline)
                Spacer()
                if let s = version.status { Text(versionStatusTitle(s)).font(.caption).foregroundStyle(.secondary) }
            }
            if let d = version.dueDate {
                Label(Fmt.date(d), systemImage: "calendar").font(.subheadline)
                    .foregroundStyle(Fmt.isOverdue(d) && version.status != "closed" ? .red : .secondary)
            }
            VersionProgressLine(issues: store.issues(.version(version.id), app))
        }
        .padding(.vertical, 2)
        .task { await store.load(.version(version.id), app) }
    }
}

func versionStatusTitle(_ s: String) -> String {
    switch s {
    case "open": String(localized: "open")
    case "locked": String(localized: "locked")
    case "closed": String(localized: "closed")
    default: s
    }
}

/// «N из M закрыто» с полосой; задач ещё нет — тонкая пустая полоса.
private struct VersionProgressLine: View {
    let issues: [Issue]?
    var body: some View {
        let p = VersionProgress(closed: (issues ?? []).map(\.status.isClosed))
        HStack(spacing: 8) {
            ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
            if issues != nil {
                Text("\(p.done) of \(p.total) closed").font(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
            }
        }
    }
}

/// Экран вехи (spec 3.2) и подзадач доской (spec 3.3): шапка, фильтры статуса, исполнителей (аватары) и поиск
/// по доске — локально; список или доска.
struct VersionView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.horizontalSizeClass) private var sizeClass
    let scope: BoardScope
    let title: String
    var version: Version?
    @State private var filter: StatusFilter = .open
    @State private var assignees = Set<String>()
    @State private var query = ""
    @State private var statusOrder: [Int] = []
    @State private var pulling = false
    private var store: VersionIssueStore { .shared }

    init(version: Version) { scope = .version(version.id); title = version.name; self.version = version }
    init(parent: SubtaskBoardLink) { scope = .parent(parent.id); title = "#\(parent.id) \(parent.subject)" }

    var body: some View {
        @Bindable var app = app
        let all = store.issues(scope, app)
        let byStatus = (all ?? []).filter { filter == .all || (filter == .closed) == $0.status.isClosed }
        // порядок — по числу задач на доске после фильтра статуса (spec 3.2, assignee_avatars)
        let options = assigneeAvatars(all ?? [], me: app.settings.userId, status: filter == .all ? "all" : filter.rawValue)
        let shown = boardFilter(byStatus, me: app.settings.userId, assignees: assignees, query: query)
        VStack(spacing: 0) {
            header(all, options: options)
            if all != nil, let e = store.error(scope, app) {
                Label { Text("Couldn’t refresh: \(e)") } icon: { Image(systemName: "exclamationmark.triangle") }
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).padding(.bottom, 6)
            }
            if let all {
                if all.isEmpty {
                    ContentUnavailableView(version == nil ? "No subtasks" : "No issues in this version", systemImage: "tray").frame(maxHeight: .infinity)
                } else if app.settings.versionBoard {
                    board(shown)
                } else {
                    List(shown) { i in
                        NavigationLink(value: IssueLink(id: i.id)) { IssueRow(issue: i, showProject: version.map { i.project.id != $0.project?.id } ?? false) }
                    }
                    .listStyle(.plain)
                    .refreshable { pulling = true; await store.load(scope, app, force: true); pulling = false }
                }
            } else if let e = store.error(scope, app) {
                LoadErrorView(message: e) { Task { await store.load(scope, app, force: true) } }.frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // spec 12: обновление без жеста (после правки задачи) — индикатор на месте кнопки, доска на экране
                if store.isLoading(scope, app) && !pulling && all != nil {
                    ProgressView()
                } else {
                    // одна кнопка панели: сегменты внутри стеклянной капсулы iOS 26 выглядят пилюлей в пилюле
                    Button { app.settings.versionBoard.toggle() } label: {
                        app.settings.versionBoard
                            ? Label("List", systemImage: "list.bullet")
                            : Label("Board", systemImage: "rectangle.split.3x1")
                    }
                }
            }
        }
        // задачу поправили (статус, исполнитель) — доска перечитывается тихо
        .onChange(of: app.listEpoch) { Task { await store.load(scope, app, force: true) } }
        .task {
            await store.load(scope, app)
            statusOrder = (try? await app.refs?.statuses())?.map(\.id) ?? []
        }
    }

    private var avatarsMax: Int {
        #if DEBUG
        let n = UserDefaults.standard.integer(forKey: "RTAvatarsMax") // -RTAvatarsMax <n> — «+N» и на демо-вехе
        if n > 0 { return n }
        #endif
        return sizeClass == .regular ? 10 : 5
    }

    @ViewBuilder
    private func header(_ all: [Issue]?, options: [AssigneeOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let version {
                HStack(spacing: 12) {
                    if let d = version.dueDate { Label(Fmt.date(d), systemImage: "calendar") }
                    if let s = version.status { Text(versionStatusTitle(s)).foregroundStyle(.secondary) }
                }
                .font(.subheadline)
                if let d = version.description, !d.isEmpty { Text(d).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
            }
            VersionProgressLine(issues: all)
            Picker("Status", selection: $filter) {
                ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search on board", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                            .accessibilityLabel(Text("Clear"))
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 7)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                AssigneeAvatars(options: options, selected: $assignees, max: avatarsMax)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
        // выбранного исполнителя не осталось (сменили фильтр статуса) — не держим пустую доску
        .onChange(of: options.map(\.key)) { _, keys in assignees.formIntersection(keys) }
    }

    /// Доска: колонки статусов вбок, внутри колонки — вертикальная прокрутка.
    private func board(_ issues: [Issue]) -> some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(boardColumns(issues, statusOrder: statusOrder)) { col in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            StatusPill(status: col.status, compact: true)
                            Text("\(col.issues.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            LazyVStack(spacing: 8) {
                                ForEach(col.issues) { i in
                                    NavigationLink(value: IssueLink(id: i.id)) { BoardCard(issue: i) }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    .padding(8)
                    .frame(width: 280)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }
}

/// Фильтр исполнителей рядом аватаров, как в Jira: нажатие включает и выключает, можно несколько; ничего — все.
/// «Без исполнителя» — серый кружок. Не поместилось — «+N» со списком с аватарами и галочками.
private struct AssigneeAvatars: View {
    @Environment(AppModel.self) private var app
    let options: [AssigneeOption]
    @Binding var selected: Set<String>
    let max: Int
    private let size: CGFloat = 32
    @State private var more = false

    var body: some View {
        let fits = options.count <= max
        let visible = fits ? options : Array(options.prefix(max - 1))
        HStack(spacing: -6) { // шаг 26 при аватаре 32 — как на Android и GNOME (spec 3.2)
            ForEach(visible, id: \.key) { o in
                Button { toggle(o.key) } label: { avatar(o) }
                    .buttonStyle(.plain)
                    .help(hint(o))
                    .accessibilityLabel(Text(hint(o)))
                    .accessibilityAddTraits(selected.contains(o.key) ? .isSelected : [])
            }
            if !fits {
                Button { more = true } label: {
                    let hidden = options.dropFirst(visible.count).filter { selected.contains($0.key) }.count
                    Text(verbatim: "+\(options.count - visible.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(hidden > 0 ? Color.white : Color.primary)
                        .frame(width: size, height: size)
                        .background(hidden > 0 ? Color.accentColor : Color(.systemGray5), in: Circle())
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("More assignees"))
                // список с аватарами и галочками; не закрывается при выборе — можно отметить несколько
                .popover(isPresented: $more) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(options) { o in
                                Button { toggle(o.key) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selected.contains(o.key) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(o.key) ? Color.accentColor : Color.secondary)
                                        rowAvatar(o)
                                        Text(verbatim: "\(name(o)) · \(o.count)").lineLimit(1)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(selected.contains(o.key) ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(minWidth: 260, maxHeight: 420)
                    .presentationCompactAdaptation(.popover)
                    .environment(app)
                }
            }
        }
        .fixedSize()
        #if DEBUG
        // -RTAssigneesMore — список «+N» открыт сразу (снимки)
        .task(id: fits) { if !fits, UserDefaults.standard.bool(forKey: "RTAssigneesMore") { try? await Task.sleep(for: .seconds(1)); more = true } }
        #endif
    }

    private func avatar(_ o: AssigneeOption) -> some View {
        let on = selected.contains(o.key)
        return Group {
            if o.key == "none" {
                Image(systemName: "person.fill.questionmark").font(.system(size: size * 0.4)).foregroundStyle(.white)
                    .frame(width: size, height: size).background(Color(.systemGray3), in: Circle())
            } else {
                Avatar(name: name(o), userId: o.key == "me" ? app.settings.userId : Int(o.key.dropFirst(5)), size: size)
            }
        }
        .overlay(Circle().stroke(on ? Color.accentColor : Color(.systemBackground), lineWidth: on ? 3 : 2))
    }

    @ViewBuilder private func rowAvatar(_ o: AssigneeOption) -> some View {
        if o.key == "none" {
            Circle().fill(Color(.systemGray3)).frame(width: 24, height: 24)
        } else {
            Avatar(name: name(o), userId: o.key == "me" ? app.settings.userId : Int(o.key.dropFirst(5)), size: 24)
        }
    }

    private func name(_ o: AssigneeOption) -> String {
        switch o.key {
        // как в задачах — тем же именем идёт сортировка (spec 3.2)
        case "me": o.name.flatMap { $0.isEmpty ? nil : $0 } ?? (app.settings.userName.isEmpty ? String(localized: "Me") : app.settings.userName)
        case "none": String(localized: "Not assigned")
        default: o.name ?? o.key
        }
    }

    private func hint(_ o: AssigneeOption) -> String { "\(name(o)) — \(o.count)" }

    private func toggle(_ k: String) { if selected.remove(k) == nil { selected.insert(k) } }
}

/// Карточка на доске — компактная: номер и трекер, тема, приоритет, исполнитель.
private struct BoardCard: View {
    let issue: Issue
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // статус — цветом и на карточке (spec 0), название — в заголовке колонки
            HStack(spacing: 5) {
                Circle().fill(statusTint(issue.status)).frame(width: 7, height: 7)
                Text(verbatim: "\(issue.tracker.name) #\(issue.id)").font(.caption).foregroundStyle(.secondary)
            }
            Text(issue.subject).font(.subheadline.weight(.medium)).lineLimit(3)
                .strikethrough(issue.status.isClosed, color: .secondary)
            HStack(spacing: 6) {
                Text(issue.priority.name).foregroundStyle(priorityTint(issue.priority.name)).lineLimit(1)
                Spacer(minLength: 4)
                if let a = issue.assignedTo { Avatar(name: a.name, userId: a.id, size: 20) }
            }
            .font(.caption)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Вики

private struct WikiIndex: View {
    @Environment(AppModel.self) private var app
    let project: Project
    @Binding var page: ProjectPage?
    var onForbidden: () -> Void
    @State private var pages: [WikiPageInfo]?
    @State private var error: String?

    var body: some View {
        List(selection: $page) {
            ForEach(wikiTree(pages ?? []), id: \.page.title) { p, depth in
                Text(p.title.replacingOccurrences(of: "_", with: " "))
                    .padding(.leading, CGFloat(depth) * 16)
                    .tag(ProjectPage.wiki(WikiRef(project: project.identifier, title: p.title)))
            }
        }
        .listStyle(.plain)
        .overlay {
            if pages?.isEmpty ?? true {
                if let error { LoadErrorView(message: error) { Task { await load() } } }
                else if pages == nil { ProgressView() }
                else { ContentUnavailableView("No wiki pages", systemImage: "book.closed") }
            }
        }
        .refreshable { await load() }
        .task { if pages == nil { await load() } }
    }

    private func load() async {
        guard let api = app.api else { return }
        do { pages = try await api.wikiIndex(project.identifier); error = nil }
        catch { if isForbidden(error) { onForbidden() } else { self.error = error.localizedDescription } }
    }
}

/// Страница вики: тот же Textile-рендер; [[ссылки]] открывают страницы здесь же.
struct WikiPageView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.navigate) private var navigate
    let ref: WikiRef
    @State private var page: WikiPage?
    @State private var error: String?
    @State private var person: Named?
    @State private var scroll = ScrollPosition()

    private var webURL: URL? { app.api?.url("projects/\(ref.project)/wiki/\(ref.title)") }

    var body: some View {
        Group {
            if let page {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(page.title.replacingOccurrences(of: "_", with: " ")).font(.title2.bold())
                        Text("\(page.author?.name ?? "—") · \(Fmt.dateTime(page.updatedOn)) · version \(page.version ?? 1)")
                            .font(.footnote).foregroundStyle(.secondary)
                        RichText(text: page.text, context: RichContext(attachments: page.attachments, baseURL: app.api?.baseURL, onOpenAttachment: { a in
                            guard let api = app.api else { return }
                            Task { do { try await previewAttachment(a, api: api) } catch { self.error = error.localizedDescription } }
                        }))
                    }
                    .padding()
                    .frame(maxWidth: 900, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await load() }
                .scrollPosition($scroll)
                #if DEBUG
                // -RTScrollY <pt> — снимки середины длинной страницы
                .task { try? await Task.sleep(for: .milliseconds(800)); scroll.scrollTo(y: CGFloat(UserDefaults.standard.integer(forKey: "RTScrollY"))) }
                #endif
            } else if let error {
                LoadErrorView(message: error) { Task { await load() } }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(ref.title.replacingOccurrences(of: "_", with: " "))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let webURL, !app.isDemo {
                ToolbarItem(placement: .topBarTrailing) { Link(destination: webURL) { Label("Open in Safari", systemImage: "safari") } }
            }
        }
        .environment(\.openURL, OpenURLAction { handle($0) })
        .sheet(item: $person) { PersonCard(userId: $0.id).environment(app) }
        .task { if page == nil { await load() } }
    }

    private func load() async {
        guard let api = app.api else { return }
        do { page = try await api.wikiPage(ref.project, ref.title); error = nil }
        catch { if page == nil { self.error = error.localizedDescription } }
    }

    private func handle(_ url: URL) -> OpenURLAction.Result {
        switch RichLink.parse(url) {
        case .wiki(let project, let title): navigate(WikiRef(project: project ?? ref.project, title: title))
        case .issue(let id, let note): navigate(IssueLink(id: id, fragment: note.map { "note-\($0)" }))
        case .user(let id): person = Named(id: id)
        case .note: break
        case nil:
            if let base = app.api?.baseURL, url.host == base.host, url.path.contains("/issues/"), let id = Int(url.lastPathComponent) {
                navigate(IssueLink(id: id, fragment: url.fragment))
            } else {
                return .systemAction
            }
        }
        return .handled
    }
}

// MARK: - Файлы

private struct ProjectFiles: View {
    @Environment(AppModel.self) private var app
    let project: Project
    var onForbidden: () -> Void
    @State private var files: [Attachment]?
    @State private var error: String?
    @State private var actionError: String?

    var body: some View {
        List(files ?? []) { a in
            Button {
                guard let api = app.api else { return }
                Task { do { try await previewAttachment(a, api: api) } catch { actionError = error.localizedDescription } }
            } label: { AttachmentRow(attachment: a) }
            .buttonStyle(.plain)
            .contextMenu { Button { copyToPasteboard(a.contentUrl) } label: { Label("Copy link", systemImage: "link") } }
        }
        .listStyle(.plain)
        .overlay {
            if files?.isEmpty ?? true {
                if let error { LoadErrorView(message: error) { Task { await load() } } }
                else if files == nil { ProgressView() }
                else { ContentUnavailableView("No files", systemImage: "doc") }
            }
        }
        .refreshable { await load() }
        .task { if files == nil { await load() } }
        .errorAlert($actionError)
    }

    private func load() async {
        guard let api = app.api else { return }
        do { files = try await api.projectFiles(project.id); error = nil }
        catch { if isForbidden(error) { onForbidden() } else { self.error = error.localizedDescription } }
    }
}
