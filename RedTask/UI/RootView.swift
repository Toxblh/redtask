import SwiftUI

enum AppTab: String, Hashable, CaseIterable {
    case mine, watched, favorites, projects, search
}

/// Переход к задаче из детали (подзадачи, связи, #ссылки) — в стек колонки детали.
struct IssueLink: Hashable {
    var id: Int
    var note: Int?
}

/// iPhone — таб-бар, iPad — таб-бар, превращаемый в сайдбар; внутри раздела — split view «список ↔ задача».
struct RootView: View {
    @Environment(AppModel.self) private var app
    @SceneStorage("tab") private var tab: AppTab = .mine
    @State private var sheet: RootSheet?

    var body: some View {
        TabView(selection: $tab) {
            Tab("My", systemImage: "person.crop.circle", value: AppTab.mine) {
                TabSection(tab: .mine, sheet: $sheet) { sel in IssueListView(kind: .mine, selection: sel) }
            }
            Tab("Watching", systemImage: "eye", value: AppTab.watched) {
                TabSection(tab: .watched, sheet: $sheet) { sel in IssueListView(kind: .watched, selection: sel) }
            }
            Tab("Favorites", systemImage: "star", value: AppTab.favorites) {
                TabSection(tab: .favorites, sheet: $sheet) { sel in IssueListView(kind: .favorites, selection: sel) }
            }
            Tab("Projects", systemImage: "folder", value: AppTab.projects) {
                TabSection(tab: .projects, sheet: $sheet, projects: true) { sel in EmptyView() }
            }
            Tab(value: AppTab.search, role: .search) {
                TabSection(tab: .search, sheet: $sheet) { sel in SearchView(selection: sel) }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .sheet(item: $sheet) { s in
            switch s {
            case .bell: NotificationsView()
            case .settings: SettingsView()
            case .newIssue(let project, let parent): NewIssueView(projectId: project, parent: parent)
            }
        }
        .task { await app.refreshUnread() }
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
        @ViewBuilder let content: (Binding<Int?>) -> Content
        @State private var project: Project?
        /// На iPhone переход из уведомления/ссылки показывает сразу задачу, минуя список.
        @State private var compactColumn = NavigationSplitViewColumn.sidebar
        @State private var selection: Int?
        @State private var note: Int?
        @State private var path: [IssueLink] = []
        @SceneStorage("tab") private var current: AppTab = .mine

        var body: some View {
            Group {
                if projects {
                    NavigationSplitView(preferredCompactColumn: $compactColumn) {
                        ProjectsView(selection: $project)
                            .toolbar { RootToolbar(sheet: $sheet) }
                            .toolbar(removing: .sidebarToggle)
                    } content: {
                        if let p = project {
                            IssueListView(kind: .project(p.id, p.name), selection: $selection).id(p.id)
                        } else {
                            ContentUnavailableView("Select a project", systemImage: "folder")
                        }
                    } detail: { detail }
                } else {
                    NavigationSplitView(preferredCompactColumn: $compactColumn) {
                        content($selection)
                            .toolbar { RootToolbar(sheet: $sheet) }
                            // у таб-бара iPad уже есть своя кнопка сайдбара — вторая рядом только путает
                            .toolbar(removing: .sidebarToggle)
                    } detail: { detail }
                }
            }
            .onChange(of: selection) { _, new in
                if new != pendingNoteIssue { note = nil }
                path = []
            }
            .onChange(of: app.openRequest) { _, r in handle(r) }
            .onAppear { handle(app.openRequest) }
        }

        @State private var pendingNoteIssue: Int?

        private var detail: some View {
            NavigationStack(path: $path) {
                if let id = selection {
                    IssueDetailView(issueId: id, note: note, newSubtask: { sheet = .newIssue(project: $0.project.id, parent: $0.id) })
                        .id(id)
                        .navigationDestination(for: IssueLink.self) { l in
                            IssueDetailView(issueId: l.id, note: l.note, newSubtask: { sheet = .newIssue(project: $0.project.id, parent: $0.id) })
                        }
                        .environment(\.navigate, NavigateAction { path.append($0) })
                } else {
                    ContentUnavailableView("Select an issue", systemImage: "checklist")
                }
            }
        }

        private func handle(_ r: OpenRequest?) {
            guard let r, current == tab else { return }
            app.openRequest = nil
            pendingNoteIssue = r.issueId
            note = r.note
            if selection == r.issueId {
                // задача уже открыта: переход к комментарию без пересоздания экрана (черновик цел)
                NotificationCenter.default.post(name: .scrollToNote, object: nil, userInfo: ["issue": r.issueId, "note": r.note ?? 0])
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
