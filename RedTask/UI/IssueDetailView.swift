import SwiftUI
import PhotosUI
import QuickLook
import UniformTypeIdentifiers

enum ActivityTab: String, CaseIterable, Identifiable {
    case comments, actions, time, all
    var id: String { rawValue }
    var title: LocalizedStringKey {
        switch self {
        case .comments: "Comments"
        case .actions: "Changes"
        case .time: "Time"
        case .all: "All"
        }
    }
}

enum DetailSheet: Identifiable {
    case comment, time(TimeEntry?), relation, edit, person(Int), upload([PickedFile])
    /// Выделение текста комментария (journal) или описания (nil) для частичной цитаты.
    case select(String, Journal?)
    /// Строка листа согласования (spec 10) и страница сайта с сессией (правка строки, «Добавить»).
    case tableRow(CustomTable, Int), site(URL)
    var id: String {
        switch self {
        case .tableRow(let t, let i): "row-\(t.title)-\(i)"
        case .site(let u): "site-\(u.absoluteString)"
        case .comment: "comment"
        case .select(_, let j): "select-\(j?.id ?? 0)"
        case .time(let e): "time-\(e?.id ?? 0)"
        case .relation: "relation"
        case .edit: "edit"
        case .person(let id): "person-\(id)"
        case .upload: "upload"
        }
    }
}

struct IssueDetailView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @Environment(\.horizontalSizeClass) private var hSize
    let issueId: Int
    var fragment: String?
    var newSubtask: (Issue) -> Void = { _ in }

    @State private var model: IssueDetailModel
    @State private var tab: ActivityTab = .comments
    /// Обновление жестом: у него свой системный индикатор (spec 12).
    @State private var pulling = false
    @State private var sheet: DetailSheet?
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var confirmDelete: ConfirmDelete?
    @State private var highlighted: Int?
    @State private var webFallback: URL?

    init(issueId: Int, fragment: String? = nil, newSubtask: @escaping (Issue) -> Void = { _ in }) {
        self.issueId = issueId
        self.fragment = fragment
        self.newSubtask = newSubtask
        _model = State(initialValue: IssueDetailModel(issueId: issueId))
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if let issue = model.issue {
                    content(issue)
                } else if let e = model.error {
                    LoadErrorView(message: e) { Task { await model.load(app) } }
                } else {
                    ProgressView()
                }
            }
            .task {
                #if DEBUG
                // -RTFeed all|actions|time — вкладка ленты
                if let f = UserDefaults.standard.string(forKey: "RTFeed").flatMap(ActivityTab.init) { tab = f }
                switch UserDefaults.standard.string(forKey: "RTDetailSheet") {
                case "comment":
                    try? await Task.sleep(for: .milliseconds(600))
                    if let d = UserDefaults.standard.string(forKey: "RTDraft") { model.draft = d }
                    if UserDefaults.standard.bool(forKey: "RTPrivate") { model.draftPrivate = true }
                    sheet = .comment
                case "edit": sheet = .edit
                case "time": sheet = .time(nil)
                case "relation": sheet = .relation
                case "person": sheet = .person(UserDefaults.standard.integer(forKey: "RTPerson"))
                case "row": // первая строка первого листа согласования (spec 10)
                    Task {
                        for _ in 0..<30 where model.customTables.first?.rows.isEmpty ?? true { try? await Task.sleep(for: .milliseconds(500)) }
                        if let t = model.customTables.first, !t.rows.isEmpty { sheet = .tableRow(t, 0) }
                    }
                default: break
                }
                #endif
                await model.load(app)
                if let fragment { scroll(to: fragment, proxy) }
                #if DEBUG
                // снимки: -RTField <id поля> — прокрутить к длинному настраиваемому полю
                let field = UserDefaults.standard.integer(forKey: "RTField")
                if field > 0 { try? await Task.sleep(for: .milliseconds(800)); proxy.scrollTo("cf-\(field)", anchor: .top) }
                // -RTScroll description — к описанию
                if let anchor = UserDefaults.standard.string(forKey: "RTScroll") { try? await Task.sleep(for: .milliseconds(800)); proxy.scrollTo(anchor, anchor: .top) }
                #endif
            }
            .onReceive(NotificationCenter.default.publisher(for: .scrollToNote)) { n in
                guard n.userInfo?["issue"] as? Int == issueId else { return }
                // уведомление по уже открытой задаче: ждём ответа сервера, запрошенного после перехода
                Task {
                    await model.load(app)
                    if let f = n.userInfo?["fragment"] as? String, !f.isEmpty { scroll(to: f, proxy) }
                }
            }
        }
        .navigationTitle("#" + String(issueId))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .toolbar { if let issue = model.issue { bottomActions(issue) } }
        // на iPhone нижний тулбар действий заменяет таб-бар (как у экрана письма в Mail); на iPad таб-бар — это сайдбар, его не трогаем
        .toolbar(hSize == .compact && model.issue != nil ? .hidden : .automatic, for: .tabBar)
        .environment(\.openURL, OpenURLAction { url in handle(url) })
        .sheet(item: $sheet) { s in sheetView(s).environment(app) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
            if case .success(let urls) = r { sheet = .upload(urls.compactMap(readFile)) }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                let files = await loadPhotos(items)
                photoItems = []
                if !files.isEmpty { sheet = .upload(files) }
            }
        }
        .confirmationDialog(confirmDelete?.title ?? "", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmDelete) { c in
            Button("Delete", role: .destructive) { Task { await c.action() } }
        }
        .errorAlert($model.actionError)
        .sheet(item: $webFallback) { url in SafariView(url: url).ignoresSafeArea().environment(app) }
    }

    /// Фрагмент «note-N» / «change-ID» → журнал (journalForFragment), прокрутка и подсветка.
    private func scroll(to fragment: String, _ proxy: ScrollViewProxy) {
        guard let js = model.issue?.journals, let journal = journalForFragment(js.map(\.id), fragment),
              let j = js.first(where: { $0.id == journal }) else { return }
        tab = (j.notes ?? "").isEmpty ? .all : (tab == .actions || tab == .time ? .comments : tab)
        highlighted = journal
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            // якорь — событие ленты этого журнала (комментарий или первое его действие)
            if let target = model.activity.first(where: { $0.journalId == journal && (tab != .comments || { if case .comment = $0 { true } else { false } }($0)) }) {
                withAnimation { proxy.scrollTo(target.id, anchor: .top) }
                // ленивый List досчитывает высоты строк по дороге — второй проход попадает точно
                try? await Task.sleep(for: .milliseconds(400))
                proxy.scrollTo(target.id, anchor: .top)
            }
            try? await Task.sleep(for: .seconds(3))
            withAnimation { highlighted = nil }
        }
    }

    // MARK: - Содержимое

    @ViewBuilder
    private func content(_ issue: Issue) -> some View {
        let me = app.settings.userId
        let ctx = RichContext(attachments: issue.attachments, baseURL: app.api?.baseURL, onOpenAttachment: { open($0) })
        List {
            Section { header(issue) }
            Section { fields(issue) }
            customTables()
            if let d = issue.description, !d.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Description") {
                    RichText(text: d, context: ctx).padding(.vertical, 4)
                        .contextMenu { selectButton(d, nil) }
                }.id("description")
            }
            subtasks(issue)
            relations(issue)
            attachments(issue)
            if !issue.watchers.isEmpty {
                Section("Watchers") {
                    ForEach(issue.watchers) { w in
                        Button { sheet = .person(w.id) } label: { PersonLine(person: w) }.buttonStyle(.plain)
                    }
                }.id("watchers")
            }
            Section {
                activityRows(issue, me: me, ctx: ctx)
            } header: {
                VStack(spacing: 8) {
                    Picker("Activity", selection: $tab) {
                        ForEach(ActivityTab.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    HStack {
                        Spacer()
                        Button {
                            app.settings.newestFirst.toggle()
                        } label: {
                            Label(app.settings.newestFirst ? "Newest first" : "Oldest first",
                                  systemImage: app.settings.newestFirst ? "arrow.down" : "arrow.up")
                                .font(.footnote)
                        }
                    }
                }
                .textCase(nil)
            }
        }
        .listStyle(.insetGrouped)
        .refreshable { pulling = true; await model.load(app); pulling = false }
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
    }

    private func trackerLine(_ issue: Issue, _ layout: some Layout) -> some View {
        layout {
            Text(issue.tracker.name) + Text(verbatim: " ·")
            Text(issue.project.name)
            if issue.isPrivate {
                Label("Private", systemImage: "lock.fill").labelStyle(.titleAndIcon)
            }
        }
    }

    @ViewBuilder
    private func header(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // крупный шрифт: строка переносится, а не обрезает проект («Мобильн…»)
            ViewThatFits(in: .horizontal) {
                trackerLine(issue, HStackLayout(spacing: 6))
                trackerLine(issue, VStackLayout(alignment: .leading, spacing: 2))
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(issue.subject)
                .font(.title2.bold())
                .textSelection(.enabled)
            Text("Created by \(issue.author.name) · \(Fmt.dateTime(issue.createdOn))")
                .font(.footnote).foregroundStyle(.secondary)
            StatusPill(status: issue.status)
            if let e = model.refreshError {
                Label {
                    Text("Couldn’t refresh: \(e)")
                } icon: { Image(systemName: "exclamationmark.triangle") }
                .font(.footnote).foregroundStyle(.secondary)
            }
            CaptchaButton { Task { await model.load(app) } }
        }
        .padding(.vertical, 4)
    }

    /// Главные действия — в нижнем тулбаре (HIG → Toolbars: частые действия у большого пальца, как в Mail):
    /// статус слева, списание времени и комментарий справа. Остальное — в меню «…» навбара.
    @ToolbarContentBuilder
    private func bottomActions(_ issue: Issue) -> some ToolbarContent {
        let me = app.settings.userId
        ToolbarItem(placement: .bottomBar) {
            if model.perms.editIssue(issue, me: me), let statuses = issue.allowedStatuses, !statuses.isEmpty {
                Menu {
                    Picker("Status", selection: Binding(get: { issue.status.id }, set: { id in Task { await model.setStatus(id, app) } })) {
                        ForEach(statuses) { statusLabel($0).tag($0.id) }
                    }
                } label: {
                    // сам статус виден капсулой в шапке, здесь — только смена
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .accessibilityLabel(Text("Change status"))
                .accessibilityValue(Text(issue.status.name))
                .disabled(model.busy)
            }
        }
        if #available(iOS 26, *) { ToolbarSpacer(.flexible, placement: .bottomBar) } else { ToolbarItem(placement: .bottomBar) { Spacer() } }
        ToolbarItem(placement: .bottomBar) {
            if model.perms.has("log_time") {
                Button { sheet = .time(nil) } label: { Image(systemName: "clock") }
                    .accessibilityLabel(Text("Log time"))
            }
        }
        ToolbarItem(placement: .bottomBar) {
            if model.perms.has("add_issue_notes") {
                Button {
                    model.startComment()
                    sheet = .comment
                } label: { Image(systemName: "square.and.pencil") }
                .accessibilityLabel(Text("Comment"))
                .modifier(ProminentToolbarButton())
            }
        }
    }

    @ViewBuilder
    private func fields(_ issue: Issue) -> some View {
        let me = app.settings.userId
        let canEdit = model.perms.editIssue(issue, me: me)
        if canEdit && !model.priorities.isEmpty {
            Picker("Priority", selection: Binding(get: { issue.priority.id }, set: { id in Task { await model.setPriority(id, app) } })) {
                ForEach(model.priorities) { Text($0.name).tag($0.id) }
            }
        } else {
            LabeledContent("Priority", value: issue.priority.name)
        }
        LabeledContent("Assignee") {
            if let a = issue.assignedTo {
                Button { sheet = .person(a.id) } label: { PersonLine(person: a, size: 22) }.buttonStyle(.plain)
            } else { Text("Not assigned").foregroundStyle(.secondary) }
        }
        LabeledContent("Author") {
            Button { sheet = .person(issue.author.id) } label: { PersonLine(person: issue.author, size: 22) }.buttonStyle(.plain)
        }
        if let c = issue.category { LabeledContent("Category", value: c.name) }
        if let v = issue.fixedVersion { LabeledContent("Version", value: v.name) }
        if let p = issue.parent {
            NavigationLink(value: IssueLink(id: p.id)) {
                LabeledContent("Parent issue", value: "#\(p.id) " + (model.related[p.id]?.subject ?? ""))
            }
        }
        if let s = issue.startDate { LabeledContent("Start date", value: Fmt.date(s)) }
        if let d = issue.dueDate {
            LabeledContent("Due date") {
                let overdue = Fmt.isOverdue(d) && !issue.status.isClosed
                HStack(spacing: 4) {
                    if overdue { Image(systemName: "exclamationmark.circle") }
                    Text(Fmt.date(d))
                    if let days = daysLeft(d), !issue.status.isClosed { Text(days).foregroundStyle(.secondary) }
                }
                .foregroundStyle(overdue ? Color.red : Color.primary)
            }
        }
        if canEdit {
            Picker(selection: Binding(get: { issue.doneRatio }, set: { v in Task { await model.setDoneRatio(v, app) } })) {
                // текущее значение — своим тегом: 59% не должно показываться как 50%
                ForEach(Array(Set(stride(from: 0, through: 100, by: 10)).union([issue.doneRatio])).sorted(), id: \.self) { Text("\($0)%").tag($0) }
            } label: {
                progressLabel(issue)
            }
        } else {
            LabeledContent { Text("\(issue.doneRatio)%") } label: { progressLabel(issue) }
        }
        if let e = issue.estimatedHours {
            LabeledContent("Estimate", value: String(localized: "\(Fmt.hours(e)) h") + total(issue.totalEstimatedHours, e))
        }
        if let s = issue.spentHours ?? issue.totalSpentHours, s > 0 {
            LabeledContent("Spent", value: String(localized: "\(Fmt.hours(s)) h") + total(issue.totalSpentHours, s))
        }
        ForEach(issue.customFields.filter { !$0.values.isEmpty }) { f in
            let shown = model.cfLabels[f.id] ?? f.values.joined(separator: ", ")
            if shown.count > 60 || shown.contains("\n") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(f.name).font(.subheadline).foregroundStyle(.secondary)
                    RichText(text: shown, context: RichContext(attachments: issue.attachments, baseURL: app.api?.baseURL))
                }
                .id("cf-\(f.id)")
            } else {
                LabeledContent(f.name) { Text(shown).textSelection(.enabled) }
            }
        }
    }

    /// Листы согласования (spec 10): только чтение; строка — карточка, правка и «Добавить» — на сайте.
    @ViewBuilder
    private func customTables() -> some View {
        ForEach(Array(model.customTables.enumerated()), id: \.offset) { _, t in
            Section {
                ForEach(Array(t.rows.enumerated()), id: \.offset) { i, row in
                    Button { sheet = .tableRow(t, i) } label: { customRow(t, row) }
                        .buttonStyle(.plain)
                }
            } header: {
                HStack {
                    Text(t.title)
                    Spacer()
                    if let tid = t.tableId, !app.isDemo,
                       let u = app.api?.url("custom_entities/new", [("custom_table_id", String(tid)), ("issue_id", String(issueId))]) {
                        Button("Add", systemImage: "plus") { sheet = .site(u) }.labelStyle(.titleAndIcon).font(.subheadline).textCase(nil)
                    }
                }
            }
        }
    }

    private func customRow(_ t: CustomTable, _ row: [CustomTable.Cell]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(row.enumerated()), id: \.offset) { j, cell in
                let column = j < t.columns.count ? t.columns[j] : ""
                if let id = cell.userId {
                    PersonLine(person: Named(id: id, name: cell.text))
                } else if cell.text == "Согласовано" {
                    HStack(spacing: 6) {
                        if !column.isEmpty && column != cell.text { Text(column).foregroundStyle(.secondary) }
                        StatusPill(status: approvedStatus, compact: true)
                    }
                    .font(.subheadline)
                } else if !cell.text.isEmpty {
                    Text(column.isEmpty ? cell.text : "\(column): \(cell.text)").font(.subheadline)
                }
            }
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func progressLabel(_ issue: Issue) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Progress")
            ProgressView(value: Double(issue.doneRatio), total: 100).frame(maxWidth: 160)
        }
    }

    private func total(_ total: Double?, _ own: Double) -> String {
        guard let total, total != own else { return "" }
        return " " + String(localized: "(total \(Fmt.hours(total)))")
    }

    private func daysLeft(_ due: String) -> String? {
        guard let d = Fmt.dayDate(due) else { return nil }
        let n = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: d).day ?? 0
        if n == 0 { return String(localized: "today") }
        return n > 0 ? String(localized: "in \(n) d") : String(localized: "\(-n) d overdue")
    }

    @ViewBuilder
    private func subtasks(_ issue: Issue) -> some View {
        let canAdd = model.perms.has("manage_subtasks") && model.perms.has("add_issues")
        if !issue.children.isEmpty || canAdd {
            Section("Subtasks") {
                ForEach(issue.children) { c in
                    NavigationLink(value: IssueLink(id: c.id)) {
                        RelatedLine(id: c.id, subject: c.subject, issue: model.related[c.id])
                    }
                    .contextMenu { if let i = model.related[c.id] { IssueMenu(issue: i) } }
                }
                if canAdd {
                    Button { newSubtask(issue) } label: { Label("Add subtask", systemImage: "plus") }
                }
                // spec 3.3: подзадачи экраном как у вехи — колонки статусов, аватары, поиск
                if !issue.children.isEmpty {
                    NavigationLink(value: SubtaskBoardLink(id: issue.id, subject: issue.subject)) {
                        Label("As board", systemImage: "rectangle.split.3x1")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func relations(_ issue: Issue) -> some View {
        let canManage = model.perms.has("manage_issue_relations")
        if !issue.relations.isEmpty || canManage {
            Section("Relations") {
                ForEach(issue.relations) { r in
                    let other = r.issueId == issue.id ? r.issueToId : r.issueId
                    NavigationLink(value: IssueLink(id: other)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(relationLabel(relationType(r, viewer: issue.id)) + (r.delay.map { " " + String(localized: "+\($0) d") } ?? ""))
                                .font(.caption).foregroundStyle(.secondary)
                            RelatedLine(id: other, subject: model.related[other]?.subject ?? "", issue: model.related[other])
                        }
                    }
                    .swipeActions {
                        if canManage {
                            Button(role: .destructive) { Task { await model.deleteRelation(r, app) } } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    .contextMenu {
                        if canManage {
                            Button(role: .destructive) {
                                confirmDelete = ConfirmDelete(title: String(localized: "Remove relation with #\(other)?")) { await model.deleteRelation(r, app) }
                            } label: { Label("Remove relation", systemImage: "trash") }
                        }
                    }
                }
                if canManage {
                    Button { sheet = .relation } label: { Label("Add relation", systemImage: "link.badge.plus") }
                }
            }.id("relations")
        }
    }

    @ViewBuilder
    private func attachments(_ issue: Issue) -> some View {
        let me = app.settings.userId
        let canEdit = model.perms.editIssue(issue, me: me)
        if !issue.attachments.isEmpty || canEdit {
            Section("Files") {
                ForEach(issue.attachments) { a in
                    Button { open(a) } label: { AttachmentRow(attachment: a) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button { open(a) } label: { Label("Preview", systemImage: "eye") }
                            Button { copyToPasteboard(a.contentUrl) } label: { Label("Copy link", systemImage: "link") }
                            if canEdit || a.author?.id == me {
                                Button(role: .destructive) {
                                    confirmDelete = ConfirmDelete(title: String(localized: "Delete file “\(a.filename)”?")) { await model.deleteAttachment(a, app) }
                                } label: { Label("Delete", systemImage: "trash") }
                            }
                        }
                }
                if canEdit {
                    Menu {
                        PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) {
                            Label("Photo Library", systemImage: "photo.on.rectangle")
                        }
                        Button { importing = true } label: { Label("Choose File", systemImage: "folder") }
                    } label: {
                        Label("Add files", systemImage: "paperclip")
                    }
                }
            }.id("files")
        }
    }

    // MARK: - Лента

    @ViewBuilder
    private func activityRows(_ issue: Issue, me: Int, ctx: RichContext) -> some View {
        let all = model.activity
        let filtered = all.filter { e in
            switch (tab, e) {
            case (.all, _): true
            case (.comments, .comment): true
            case (.actions, .action), (.actions, .created): true
            case (.time, .worklog): true
            default: false
            }
        }
        let events = app.settings.newestFirst ? filtered.reversed() : filtered
        if events.isEmpty {
            Text(tab == .comments ? "No comments yet" : tab == .time ? "No time logged" : "No changes")
                .foregroundStyle(.secondary)
        }
        if tab == .time && !model.timeEntries.isEmpty {
            LabeledContent("Total", value: String(localized: "\(Fmt.hours(model.timeEntries.reduce(0) { $0 + ($1.hours ?? 0) })) h"))
                .font(.headline)
        }
        ForEach(events) { e in
            switch e {
            case .created(let i):
                Label("Created by \(i.author.name) · \(Fmt.dateTime(i.createdOn))", systemImage: "plus.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            case .comment(let j, _):
                CommentRow(journal: j, number: (issue.journals.firstIndex(of: j) ?? 0) + 1, ctx: ctx,
                           highlighted: highlighted == j.id, onPerson: { sheet = .person($0) })
                    .contextMenu { commentMenu(j, issue: issue, me: me) }
                    .swipeActions(edge: .leading) {
                        if model.perms.has("add_issue_notes") {
                            Button { reply(j) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }.tint(.blue)
                        }
                    }
            case .action(let j, let d, _):
                ActionRow(journal: j, detail: d, names: model.names, highlighted: highlighted == j.id)
            case .worklog(let t, _):
                WorklogRow(entry: t)
                    .contextMenu {
                        if model.perms.editTime(t, me: me) {
                            Button { sheet = .time(t) } label: { Label("Edit", systemImage: "pencil") }
                            Button(role: .destructive) {
                                confirmDelete = ConfirmDelete(title: String(localized: "Delete time entry (\(Fmt.hours(t.hours)) h)?")) { await model.deleteTime(t, app) }
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                    .swipeActions {
                        if model.perms.editTime(t, me: me) {
                            Button(role: .destructive) { Task { await model.deleteTime(t, app) } } label: { Label("Delete", systemImage: "trash") }
                            Button { sheet = .time(t) } label: { Label("Edit", systemImage: "pencil") }
                        }
                    }
            }
        }
    }

    /// Порядок пунктов — по спецификации (1.2), одинаковый на всех платформах.
    @ViewBuilder
    private func commentMenu(_ j: Journal, issue: Issue, me: Int) -> some View {
        if model.perms.has("add_issue_notes") {
            Button { reply(j) } label: { Label("Reply with quote", systemImage: "arrowshape.turn.up.left") }
        }
        Button { copyToPasteboard(j.notes ?? "") } label: { Label("Copy text", systemImage: "doc.on.doc") }
        if let api = app.api, let url = noteUrl(server: api.baseURL, issue: issue.id, journals: issue.journals.map(\.id), journalId: j.id) {
            Button { copyToPasteboard(url.absoluteString) } label: { Label("Copy link to comment", systemImage: "link") }
        }
        if model.perms.editNote(j, me: me) && !model.notesRefused.contains(j.id) {
            Button {
                model.startEdit(j)
                sheet = .comment
            } label: { Label("Edit comment", systemImage: "pencil") }
        }
        if model.perms.editNote(j, me: me) && !model.notesRefused.contains(j.id) {
            Button(role: .destructive) {
                confirmDelete = ConfirmDelete(title: String(localized: "Delete this comment?")) { await model.saveNote(j, text: "", isPrivate: nil, app) }
            } label: { Label("Delete", systemImage: "trash") }
        }
        Section { selectButton(j.notes ?? "", j) }
    }

    /// Частичная цитата: текст открывается в выделяемом виде, в меню выделения — «Ответить с цитатой».
    private func selectButton(_ text: String, _ j: Journal?) -> some View {
        Button { sheet = .select(plainText(text, mentions: MentionStore.shared.known), j) } label: {
            Label("Select text", systemImage: "selection.pin.in.out")
        }
    }

    private func reply(_ j: Journal) {
        model.reply(to: j)
        sheet = .comment
    }

    // MARK: - Тулбар

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            // spec 12: обновление без жеста (после правки и т. п.) — индикатор на месте звезды, задача на экране
            if (model.loading || model.busy) && !pulling && model.issue != nil {
                ProgressView()
            } else {
                Button {
                    app.toggleFavorite(issueId)
                } label: {
                    Label(app.isFavorite(issueId) ? "Remove from Favorites" : "Add to Favorites",
                          systemImage: app.isFavorite(issueId) ? "star.fill" : "star")
                }
                .tint(app.isFavorite(issueId) ? .yellow : nil)
            }
            if let issue = model.issue { moreMenu(issue) }
        }
    }

    private func moreMenu(_ issue: Issue) -> some View {
        let me = app.settings.userId
        let canEdit = model.perms.editIssue(issue, me: me)
        let url = app.api?.issueWebURL(issue.id)
        return Menu {
            Section {
                if canEdit {
                    Button { sheet = .edit } label: { Label("Edit issue", systemImage: "pencil") }
                }
                if canEdit && issue.assignedTo?.id != me {
                    Button { Task { await model.assignToMe(app) } } label: { Label("Assign to me", systemImage: "person.crop.circle.badge.checkmark") }
                }
                if model.perms.has("log_time") {
                    Button { sheet = .time(nil) } label: { Label("Log time", systemImage: "clock.badge.plus") }
                }
                if model.perms.has("manage_subtasks") && model.perms.has("add_issues") {
                    Button { newSubtask(issue) } label: { Label("Add subtask", systemImage: "plus.square.on.square") }
                }
                if model.perms.has("manage_issue_relations") {
                    Button { sheet = .relation } label: { Label("Add relation", systemImage: "link.badge.plus") }
                }
            }
            Section {
                Button {
                    Task {
                        if await !model.toggleWatch(app), let url { webFallback = url }
                    }
                } label: {
                    Label(model.watching ? "Stop watching" : "Watch", systemImage: model.watching ? "eye.slash" : "eye")
                }
                let muted = app.settings.mutedIssues[issue.id] != nil
                Button {
                    if muted { app.settings.mutedIssues[issue.id] = nil } else { app.settings.mutedIssues[issue.id] = issue.subject }
                } label: {
                    Label(muted ? "Notify about this issue" : "Mute this issue", systemImage: muted ? "bell" : "bell.slash")
                }
            }
            Section {
                Button { copyToPasteboard("#\(issue.id)") } label: { Label("Copy issue number", systemImage: "number") }
                if let url {
                    Button { copyToPasteboard(url.absoluteString) } label: { Label("Copy link", systemImage: "link") }
                    ShareLink(item: url, subject: Text(issue.subject), message: Text("#\(issue.id) \(issue.subject)")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    if !app.isDemo { Button { openURL(url) } label: { Label("Open in Safari", systemImage: "safari") } }
                }
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    // MARK: - Листы

    @ViewBuilder
    private func sheetView(_ s: DetailSheet) -> some View {
        switch s {
        case .comment: CommentSheet(model: model)
        case .time(let e): TimeSheet(model: model, entry: e)
        case .relation: RelationSheet(model: model)
        case .edit: if let i = model.issue { EditIssueView(issue: i, perms: model.perms) { Task { app.listEpoch += 1; await model.load(app) } } }
        case .person(let id): PersonCard(userId: id)
        case .upload(let files): UploadSheet(model: model, files: files)
        case .select(let text, let j):
            SelectTextSheet(text: text, canQuote: model.perms.has("add_issue_notes")) { sel in
                if let j { model.reply(to: j, text: sel) } else { model.quoteDescription(sel) }
                sheet = .comment
            }
        case .tableRow(let t, let i):
            CustomRowSheet(table: t, row: i) { url in sheet = .site(url) }
        case .site(let url):
            // правка на сайте — после закрытия задача перечитывается
            SiteWebView(url: url).onDisappear { Task { await model.load(app) } }
        }
    }

    // MARK: - Ссылки и файлы

    private func handle(_ url: URL) -> OpenURLAction.Result {
        guard let target = RichLink.parse(url) else {
            // ссылка на задачу этого сервера — открываем в приложении
            if let base = app.api?.baseURL, url.host == base.host, url.path.contains("/issues/"),
               let id = Int(url.lastPathComponent) {
                open(id, fragment: url.fragment)
                return .handled
            }
            return .systemAction
        }
        switch target {
        case .issue(let id, let note):
            open(id, fragment: note.map { "note-\($0)" })
        case .note(let n):
            open(issueId, fragment: "note-\(n)")
        case .user(let id):
            sheet = .person(id)
        case .wiki(let project, let title):
            navigate(WikiRef(project: project ?? String(model.issue?.project.id ?? 0), title: title))
        }
        return .handled
    }

    /// Эта же задача — прокрутка к журналу; другая — переход сразу к журналу (#123#note-5).
    private func open(_ id: Int, fragment: String?) {
        if id == issueId {
            if let fragment { NotificationCenter.default.post(name: .scrollToNote, object: nil, userInfo: ["issue": id, "fragment": fragment]) }
        } else {
            navigate(IssueLink(id: id, fragment: fragment))
        }
    }

    @Environment(\.navigate) private var navigateAction
    private func navigate(_ link: any Hashable) { navigateAction(link) }

    private func open(_ a: Attachment) {
        guard let api = app.api else { return }
        Task {
            do { try await previewAttachment(a, api: api) } catch { model.actionError = error.localizedDescription }
        }
    }
}

/// Вложение (задачи, страницы вики, файл проекта) — скачать с ключом и показать в Quick Look.
/// Файл остаётся в кэше: повторно не качаем, из него же встроенная миниатюра документа (spec 4.1).
@MainActor func previewAttachment(_ a: Attachment, api: RedmineAPI) async throws {
    let app = AppModel.shared
    let file = Files.attachment(a, account: app.account)
    if !FileManager.default.fileExists(atPath: file.path) {
        let data = try await api.download(a.contentUrl)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        app.downloadsEpoch += 1
    }
    presentQuickLook(file)
}

/// Выбор из медиатеки → файлы (имя по дате и типу).
func loadPhotos(_ items: [PhotosPickerItem]) async -> [PickedFile] {
    var out: [PickedFile] = []
    for (n, item) in items.enumerated() {
        guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
        let type = item.supportedContentTypes.first { $0.conforms(to: .image) || $0.conforms(to: .movie) } ?? .jpeg
        let ext = type.preferredFilenameExtension ?? "jpg"
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", timeZone: .current, calendar: .current))
        out.append(PickedFile(name: "IMG-\(stamp)\(items.count > 1 ? "-\(n + 1)" : "").\(ext)", data: data, mime: type.preferredMIMEType))
    }
    return out
}

struct ConfirmDelete {
    var title: String
    var action: () async -> Void
}

/// Обёртка: замыкание в окружении сравнивается по ссылке и дёргало бы зависимые виды на каждом обновлении.
struct NavigateAction: Equatable {
    /// IssueLink или WikiRef — то, для чего у стека есть navigationDestination.
    var perform: @MainActor (any Hashable) -> Void = { _ in }
    @MainActor func callAsFunction(_ l: any Hashable) { perform(l) }
    static func == (a: Self, b: Self) -> Bool { true }
}

extension EnvironmentValues {
    /// Переход к другой задаче из детали — в стек колонки детали.
    @Entry var navigate = NavigateAction()
}

// MARK: - Строки

struct PersonLine: View {
    let person: Named
    var size: CGFloat = 28
    var body: some View {
        HStack(spacing: 8) {
            Avatar(name: person.name, userId: person.id, size: size)
            Text(person.name)
        }
    }
}

struct RelatedLine: View {
    let id: Int
    let subject: String
    let issue: Issue?
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(verbatim: "#\(id)").monospacedDigit().foregroundStyle(.secondary)
                if let s = issue?.status {
                    Text(s.name).foregroundStyle(statusTint(s)).fontWeight(.medium)
                }
            }
            .font(.caption)
            Text(issue?.subject ?? subject)
                .strikethrough(issue?.status.isClosed == true, color: .secondary)
                .foregroundStyle(issue?.status.isClosed == true ? .secondary : .primary)
                .lineLimit(2)
        }
    }
}

struct CommentRow: View {
    let journal: Journal
    let number: Int
    let ctx: RichContext
    var highlighted = false
    var onPerson: (Int) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button { if let id = journal.user?.id { onPerson(id) } } label: {
                    Avatar(name: journal.user?.name ?? "?", userId: journal.user?.id, size: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(journal.user?.name ?? ""))
                VStack(alignment: .leading, spacing: 0) {
                    Text(journal.user?.name ?? "—").font(.subheadline.weight(.semibold))
                    HStack(spacing: 4) {
                        Text(Fmt.dateTime(journal.createdOn))
                        Text(verbatim: "· #\(number)")
                        if journal.privateNotes { PrivatePill() }
                        if let u = journal.updatedOn, u != journal.createdOn { Text("edited") }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            RichText(text: journal.notes ?? "", context: ctx)
            ForEach(commentAttachments(journal, in: ctx.attachments)) { a in
                Button { ctx.onOpenAttachment(a) } label: { AttachmentRow(attachment: a) }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(highlighted || journal.privateNotes ? background : nil)
    }

    /// Приватная (spec 13): янтарный фон ~9 % поверх фона карточки и полоса 3 pt слева.
    @ViewBuilder private var background: some View {
        if highlighted {
            Color.accentColor.opacity(0.12)
        } else if journal.privateNotes {
            ZStack(alignment: .leading) {
                Color(.secondarySystemGroupedBackground)
                Color.privateFill.opacity(0.09)
                Color.privateInk.frame(width: 3)
            }
        }
    }
}

struct ActionRow: View {
    let journal: Journal
    let detail: JournalDetail
    let names: FieldNames
    var highlighted = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                (statusChange ?? Text(description))
                    .font(.subheadline)
                Text("\(journal.user?.name ?? "—") · \(Fmt.dateTime(journal.createdOn))")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .listRowBackground(highlighted ? Color.accentColor.opacity(0.12) : nil)
        .accessibilityElement(children: .combine)
    }

    private var icon: String {
        switch (detail.property, detail.name) {
        case ("attachment", _): "paperclip"
        case ("relation", _): "link"
        case (_, "status_id"): "arrow.triangle.2.circlepath"
        case (_, "assigned_to_id"): "person"
        case (_, "priority_id"): "flag"
        case (_, "due_date"), (_, "start_date"): "calendar"
        case (_, "done_ratio"): "chart.bar"
        default: "pencil"
        }
    }

    /// «Статус: было → стало» — оба значения цветом статуса (spec 0).
    private var statusChange: Text? {
        guard detail.property == "attr", detail.name == "status_id" else { return nil }
        func status(_ v: String?) -> Text? {
            guard let v, !v.isEmpty else { return nil }
            guard let id = Int(v), let s = names.statusById[id] else { return Text(names.resolve("status_id", v)) }
            return Text(s.name).foregroundStyle(statusTint(s)).fontWeight(.semibold)
        }
        let new = status(detail.newValue) ?? Text(verbatim: "—")
        let head = Text(verbatim: "\(names.label(detail)): ")
        return status(detail.oldValue).map { head + $0 + Text(verbatim: " → ") + new } ?? head + new
    }

    private var description: String {
        let label = names.label(detail)
        switch detail.property {
        case "attachment":
            return detail.newValue.map { String(localized: "File added: \($0)") } ?? String(localized: "File deleted: \(detail.oldValue ?? "")")
        case "relation":
            let t = relationLabel(detail.name)
            return detail.newValue.map { "\(t) #\($0)" } ?? String(localized: "\(t) #\(detail.oldValue ?? "") removed")
        default:
            if detail.name == "description" { return String(localized: "Description changed") }
            let old = detail.oldValue.flatMap { $0.isEmpty ? nil : names.resolve(detail.name, $0) }
            let new = names.resolve(detail.property == "cf" ? "cf" : detail.name, detail.newValue)
            return old.map { "\(label): \($0) → \(new)" } ?? "\(label): \(new)"
        }
    }
}

struct WorklogRow: View {
    let entry: TimeEntry
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "clock").foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("\(Fmt.hours(entry.hours)) h").font(.subheadline.weight(.semibold))
                    if let a = entry.activity?.name { Text(a).font(.subheadline).foregroundStyle(.secondary) }
                }
                if !entry.comments.isEmpty { Text(entry.comments).font(.subheadline) }
                Text("\(entry.user?.name ?? "—") · \(Fmt.date(entry.spentOn))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AttachmentRow: View {
    @Environment(AppModel.self) private var app
    let attachment: Attachment
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill))
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    // значок и расширение, как на Android: odt от docx отличим с первого взгляда
                    VStack(spacing: 1) {
                        Image(systemName: icon).font(.body)
                        if !ext.isEmpty {
                            Text(verbatim: ext.uppercased()).font(.system(size: 9, weight: .bold)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename).lineLimit(2)
                Text("\(Fmt.size(attachment.filesize)) · \(attachment.author?.name ?? "") · \(Fmt.date(attachment.createdOn))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let d = attachment.description, !d.isEmpty { Text(d).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .contentShape(Rectangle())
        .task(id: "\(attachment.id) \(app.downloadsEpoch)") {
            guard thumb == nil, let api = app.api else { return }
            switch thumbnailSource(filename: attachment.filename, contentType: attachment.contentType) {
            case .server: thumb = await ImageStore.shared.thumbnail(attachment.id, api: api, account: app.account)
            case .embedded:
                let file = Files.attachment(attachment, account: app.account)
                thumb = FileManager.default.fileExists(atPath: file.path)
                    ? await ImageStore.shared.embedded(file, id: attachment.id, account: app.account)
                    : await ImageStore.shared.remoteEmbedded(attachment, api: api, account: app.account)
            case .none: break
            }
        }
    }

    private var ext: String { (attachment.filename as NSString).pathExtension }

    private var icon: String {
        let t = UTType(filenameExtension: ext)
        if t?.conforms(to: .image) == true { return "photo" }
        if t?.conforms(to: .pdf) == true { return "doc.richtext" }
        if t?.conforms(to: .archive) == true { return "doc.zipper" }
        if t?.conforms(to: .audio) == true { return "waveform" }
        if t?.conforms(to: .movie) == true { return "film" }
        if t?.conforms(to: .spreadsheet) == true { return "tablecells" }
        if t?.conforms(to: .presentation) == true { return "rectangle.on.rectangle" }
        if t?.conforms(to: .text) == true { return "doc.text" }
        return "doc"
    }
}

/// Статус задачи капсулой: цвет — не единственный признак, название всегда написано.
struct StatusPill: View {
    let status: IssueStatus
    var compact = false
    var body: some View {
        Text(status.name)
            .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(statusTint(status))
            .padding(.horizontal, compact ? 7 : 10).padding(.vertical, compact ? 2 : 4)
            .background(statusTint(status).opacity(0.14), in: Capsule())
            .accessibilityLabel(Text("Status: \(status.name)"))
    }
}

/// Главное действие тулбара — выделенным стеклом на iOS 26+, как «Отправить» в системных приложениях.
struct ProminentToolbarButton: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.buttonStyle(.glassProminent) } else { content.buttonStyle(.borderedProminent) }
    }
}
