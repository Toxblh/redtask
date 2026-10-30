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
        .sheet(item: $person) { PersonCard(userId: $0.id) }
    }
}

// MARK: - Вехи

/// Задачи вех — один раз на веху: и для прогресса в списке, и для экрана вехи.
@MainActor @Observable
final class VersionIssueStore {
    static let shared = VersionIssueStore()
    private var cache: [String: [Issue]] = [:]
    private var errors: [String: String] = [:]
    private var loading = Set<String>()

    private func key(_ id: Int, _ app: AppModel) -> String { "\(app.account)-\(id)" }
    func issues(_ id: Int, _ app: AppModel) -> [Issue]? { cache[key(id, app)] }
    func error(_ id: Int, _ app: AppModel) -> String? { errors[key(id, app)] }

    func load(_ id: Int, _ app: AppModel, force: Bool = false) async {
        let k = key(id, app)
        guard force || cache[k] == nil, !loading.contains(k), let api = app.api else { return }
        loading.insert(k)
        defer { loading.remove(k) }
        do {
            cache[k] = try await api.versionIssues(id)
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
            VersionProgressLine(issues: store.issues(version.id, app))
        }
        .padding(.vertical, 2)
        .task { await store.load(version.id, app) }
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

/// Экран вехи: шапка, фильтры статуса и исполнителя (локально), список или доска.
struct VersionView: View {
    @Environment(AppModel.self) private var app
    let version: Version
    @State private var filter: StatusFilter = .open
    @State private var assignee = "all"
    @State private var statusOrder: [Int] = []
    private var store: VersionIssueStore { .shared }

    var body: some View {
        @Bindable var app = app
        let all = store.issues(version.id, app)
        let byStatus = (all ?? []).filter { filter == .all || (filter == .closed) == $0.status.isClosed }
        let options = assigneeOptions(byStatus, me: app.settings.userId)
        let shown = filterByAssignee(byStatus, key: assignee, me: app.settings.userId)
        VStack(spacing: 0) {
            header(all, options: options)
            if let all {
                if all.isEmpty {
                    ContentUnavailableView("No issues in this version", systemImage: "tray").frame(maxHeight: .infinity)
                } else if app.settings.versionBoard {
                    board(shown)
                } else {
                    List(shown) { i in
                        NavigationLink(value: IssueLink(id: i.id)) { IssueRow(issue: i, showProject: i.project.id != version.project?.id) }
                    }
                    .listStyle(.plain)
                    .refreshable { await store.load(version.id, app, force: true) }
                }
            } else if let e = store.error(version.id, app) {
                LoadErrorView(message: e) { Task { await store.load(version.id, app, force: true) } }.frame(maxHeight: .infinity)
            } else {
                ProgressView().frame(maxHeight: .infinity)
            }
        }
        .navigationTitle(version.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                // одна кнопка панели: сегменты внутри стеклянной капсулы iOS 26 выглядят пилюлей в пилюле
                Button { app.settings.versionBoard.toggle() } label: {
                    app.settings.versionBoard
                        ? Label("List", systemImage: "list.bullet")
                        : Label("Board", systemImage: "rectangle.split.3x1")
                }
            }
        }
        .task {
            await store.load(version.id, app)
            statusOrder = (try? await app.refs?.statuses())?.map(\.id) ?? []
        }
    }

    @ViewBuilder
    private func header(_ all: [Issue]?, options: [AssigneeOption]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                if let d = version.dueDate { Label(Fmt.date(d), systemImage: "calendar") }
                if let s = version.status { Text(versionStatusTitle(s)).foregroundStyle(.secondary) }
            }
            .font(.subheadline)
            if let d = version.description, !d.isEmpty { Text(d).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
            VersionProgressLine(issues: all)
            HStack {
                Picker("Status", selection: $filter) {
                    ForEach(StatusFilter.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Menu {
                    Picker("Assignee", selection: $assignee) {
                        ForEach(options) { o in Text("\(assigneeTitle(o)) (\(o.count))").tag(o.key) }
                    }
                } label: {
                    Label(assigneeTitle(options.first { $0.key == assignee } ?? AssigneeOption(key: "all", count: 0)),
                          systemImage: assignee == "all" ? "person.2" : "person.fill")
                        .lineLimit(1)
                }
                .accessibilityLabel(Text("Assignee"))
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private func assigneeTitle(_ o: AssigneeOption) -> String {
        switch o.key {
        case "all": String(localized: "Everyone")
        case "me": String(localized: "Me")
        case "none": String(localized: "Not assigned")
        default: o.name ?? o.key
        }
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
        .sheet(item: $person) { PersonCard(userId: $0.id) }
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
