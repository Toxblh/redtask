import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case mine, watched, favorites, projects, search
}

/// Переход к задаче из детали (подзадачи, связи, #ссылки) — в стек колонки детали.
struct IssueLink: Hashable {
    var id: Int
    /// «note-N» или «change-ID»
    var fragment: String?
}

/// Страница вики: проект (id или идентификатор) и имя страницы.
struct WikiRef: Hashable {
    var project: String
    var title: String
}

/// Колонка детали: веха (доска/список), страница вики или задачи по запросу (spec 17).
enum ProjectPage: Hashable {
    case version(Version)
    case wiki(WikiRef)
    case query(QueryRun)
}

/// iPhone — таб-бар, iPad — таб-бар, превращаемый в сайдбар; внутри раздела — split view «список ↔ задача».
struct RootView: View {
    @Environment(AppModel.self) private var app
    @SceneStorage("tab") private var tab: AppTab = .mine
    @State private var sheet: RootSheet?

    var body: some View {
        TabView(selection: $tab) {
            Tab("My", systemImage: "person.crop.circle", value: AppTab.mine) {
                TabSection(tab: .mine, sheet: $sheet) { sel, _ in IssueListView(kind: .mine, selection: sel) }
            }
            Tab("Watching", systemImage: "eye", value: AppTab.watched) {
                TabSection(tab: .watched, sheet: $sheet) { sel, _ in IssueListView(kind: .watched, selection: sel) }
            }
            Tab("Favorites", systemImage: "star", value: AppTab.favorites) {
                TabSection(tab: .favorites, sheet: $sheet) { sel, page in IssueListView(kind: .favorites, selection: sel, page: page) }
            }
            Tab("Projects", systemImage: "folder", value: AppTab.projects) {
                TabSection(tab: .projects, sheet: $sheet, projects: true) { _, _ in EmptyView() }
            }
            Tab(value: AppTab.search, role: .search) {
                TabSection(tab: .search, sheet: $sheet) { sel, _ in SearchView(selection: sel) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(item: $sheet) { s in
            Group { switch s {
            case .bell: NotificationsView()
            case .settings: SettingsView()
            case .newIssue(let project, let parent): NewIssueView(projectId: project, parent: parent)
            } }
            // явно: на Mac лист иногда открывается без окружения сцены и падает на @Environment(AppModel.self)
            .environment(app)
        }
        .task { await app.refreshUnread() }
        .alert(Text("Couldn’t change favorites"), isPresented: Binding(get: { app.favoriteError != nil }, set: { if !$0 { app.favoriteError = nil } }),
               presenting: app.favoriteError) { e in
            if e.needsWebLogin {
                Button("Sign in via website") { app.showWebLogin = true }
                Button("Cancel", role: .cancel) { app.cancelPendingFavorite() }
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { e in Text(e.message) }
        .fullScreenCover(isPresented: Binding(get: { app.showWebLogin }, set: { app.showWebLogin = $0 })) {
            if let url = app.api?.baseURL {
                WebLoginView(server: url) { key, agent in
                    Task { await app.webLoginDone(key: key, agent: agent) }
                } onCancel: {
                    app.showWebLogin = false
                    app.cancelPendingFavorite()
                }
                .environment(app)
            }
        }
        #if DEBUG
        .onAppear {
            if let t = UserDefaults.standard.string(forKey: "RTTab").flatMap(AppTab.init) { tab = t }
            switch UserDefaults.standard.string(forKey: "RTSheet") {
            case "bell": sheet = .bell
            case "settings": sheet = .settings
            case "new": sheet = .newIssue(project: nil, parent: nil)
            default: break
            }
        }
        #endif
    }

    /// Раздел: список слева, задача справа (на iPhone — стек).
    private struct TabSection<Content: View>: View {
        @Environment(AppModel.self) private var app
        let tab: AppTab
        @Binding var sheet: RootSheet?
        /// Проекты — три колонки: проекты → задачи проекта → задача (на iPhone — один стек).
        var projects = false
        /// Список вкладки: выбранная задача и страница детали (избранный запрос, spec 17.5).
        @ViewBuilder let content: (Binding<Int?>, Binding<ProjectPage?>) -> Content
        @State private var projectPath: [Project] = []
        /// На iPhone переход из уведомления/ссылки показывает сразу задачу, минуя список.
        @State private var compactColumn = NavigationSplitViewColumn.sidebar
        @State private var selection: Int?
        @State private var page: ProjectPage?
        @State private var fragment: String?
        @State private var path = NavigationPath()
        @SceneStorage("tab") private var current: AppTab = .mine

        var body: some View {
            Group {
                if projects {
                    // две колонки, а не три: рядом с сайдбаром вкладок (iPad, Mac) три дали бы четыре.
                    // В колонке списка — стек «проекты → задачи проекта», как в Почте и Заметках.
                    // колонка списка всегда видна, как в остальных разделах: со стеком внутри split view
                    // в автоматическом режиме прячет её при выборе задачи (Mac, iPad)
                    NavigationSplitView(columnVisibility: .constant(.all), preferredCompactColumn: $compactColumn) {
                        // переход по стеку, а не выделением в списке: выделение в свёрнутом split view (iPhone)
                        // сразу уводит в колонку детали, минуя задачи проекта
                        NavigationStack(path: $projectPath) {
                            ProjectsView(page: $page)
                                .toolbar { RootToolbar(sheet: $sheet) }
                                .toolbar(removing: .sidebarToggle)
                                // фон стека — прозрачный, как у колонки списка в остальных разделах
                                .containerBackground(.clear, for: .navigation)
                                .navigationDestination(for: Project.self) { p in
                                    ProjectView(project: p, selection: $selection, page: $page).id(p.id)
                                        .toolbar(removing: .sidebarToggle)
                                        .containerBackground(.clear, for: .navigation)
                                }
                        }
                    } detail: { detail }
                    .navigationSplitViewStyle(.balanced)
                } else {
                    NavigationSplitView(preferredCompactColumn: $compactColumn) {
                        content($selection, $page)
                            .toolbar { RootToolbar(sheet: $sheet) }
                            // у таб-бара iPad уже есть своя кнопка сайдбара — вторая рядом только путает
                            .toolbar(removing: .sidebarToggle)
                    } detail: { detail }
                }
            }
            .onChange(of: selection) { _, new in
                if new != pendingNoteIssue { fragment = nil }
                if new != nil { page = nil }
                path = NavigationPath()
            }
            .onChange(of: page) { _, new in
                guard new != nil else { return }
                selection = nil
                path = NavigationPath()
                compactColumn = .detail
            }
            .onChange(of: projectPath) { page = nil }
            // iPhone: назад к списку — страница снята, тот же запрос открывается повторным нажатием
            .onChange(of: compactColumn) { _, c in if c == .sidebar { page = nil } }
            .onChange(of: app.openRequest) { _, r in handle(r) }
            .onAppear { handle(app.openRequest) }
            #if DEBUG
            // -RTProject <id> [-RTVersion <id>] — снимки экранов проекта и вехи; -RTWiki проект:Страница
            .task {
                let d = UserDefaults.standard, pid = d.integer(forKey: "RTProject")
                // -RTWiki проект:Страница — страница вики сразу в колонке детали
                if projects, let w = d.string(forKey: "RTWiki")?.split(separator: ":", maxSplits: 1), w.count == 2 {
                    page = .wiki(WikiRef(project: String(w[0]), title: String(w[1])))
                    compactColumn = .detail
                }
                guard projects, pid > 0, let api = app.api, let p = try? await api.projects().first(where: { $0.id == pid }) else { return }
                projectPath = [p]
                let vid = d.integer(forKey: "RTVersion")
                try? await Task.sleep(for: .milliseconds(500))  // onChange(of: projectPath) сбрасывает page
                if vid > 0, let v = try? await api.versions(pid).first(where: { $0.id == vid }) { page = .version(v) }
            }
            #endif
        }

        @State private var pendingNoteIssue: Int?

        private var detail: some View {
            NavigationStack(path: $path) {
                Group {
                    switch page {
                    case .version(let v): VersionView(version: v).id(v.id)
                    case .wiki(let w): WikiPageView(ref: w).id(w)
                    case .query(let r): FilteredIssuesView(run: r).id(r)
                    case nil:
                        if let id = selection {
                            IssueDetailView(issueId: id, fragment: fragment, newSubtask: { sheet = .newIssue(project: $0.project.id, parent: $0.id) })
                                .id(id)
                        } else if projects && projectPath.isEmpty {
                            // в «Проектах» до выбора проекта задачу выбрать неоткуда
                            ContentUnavailableView("Select a project", systemImage: "folder")
                        } else {
                            ContentUnavailableView("Select an issue", systemImage: "checklist")
                        }
                    }
                }
                .navigationDestination(for: IssueLink.self) { l in
                    IssueDetailView(issueId: l.id, fragment: l.fragment, newSubtask: { sheet = .newIssue(project: $0.project.id, parent: $0.id) })
                }
                .navigationDestination(for: WikiRef.self) { WikiPageView(ref: $0) }
                .navigationDestination(for: SubtaskBoardLink.self) { VersionView(parent: $0) }
                .environment(\.navigate, NavigateAction { path.append($0) })
            }
        }

        private func handle(_ r: OpenRequest?) {
            guard let r, current == tab else { return }
            app.openRequest = nil
            pendingNoteIssue = r.issueId
            fragment = r.fragment
            if selection == r.issueId {
                // задача уже открыта: переход к комментарию без пересоздания экрана (черновик цел)
                NotificationCenter.default.post(name: .scrollToNote, object: nil, userInfo: ["issue": r.issueId, "fragment": r.fragment ?? ""])
            } else {
                selection = r.issueId
            }
            compactColumn = .detail
        }
    }
}

extension Notification.Name {
    static let scrollToNote = Notification.Name("RedTask.scrollToNote")
}

enum RootSheet: Identifiable, Hashable {
    case bell, settings
    case newIssue(project: Int?, parent: Int?)
    var id: String {
        switch self {
        case .bell: "bell"
        case .settings: "settings"
        case .newIssue(let p, let i): "new-\(p ?? 0)-\(i ?? 0)"
        }
    }
}

/// Колокольчик, новая задача, настройки — действия, а не вкладки (HIG → Tab bars).
struct RootToolbar: ToolbarContent {
    @Environment(AppModel.self) private var app
    @Binding var sheet: RootSheet?

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { sheet = .settings } label: { Label("Settings", systemImage: "gearshape") }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { sheet = .bell } label: {
                Label(app.unreadCount > 0 ? "Notifications, \(app.unreadCount) new" : "Notifications",
                      systemImage: app.unreadCount > 0 ? "bell.badge" : "bell")
            }
            Button { sheet = .newIssue(project: nil, parent: nil) } label: { Label("New Issue", systemImage: "square.and.pencil") }
        }
    }
}
