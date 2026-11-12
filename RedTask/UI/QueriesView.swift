import SwiftUI

// MARK: - Фильтры и сохранённые запросы (spec 17)

/// Оператор и значения условия: «соответствует Ошибка, Задача».
func condText(_ c: FilterCond, catalog: FilterCatalog?) -> String {
    let def = catalog?.def(c.field)
    let op = catalog?.opLabels[c.op] ?? c.op
    guard opArity(c.op) > 0 else { return op }
    let values = c.values.filter { !$0.isEmpty }.map { v -> String in
        if v == "me" { return String(localized: "me") }
        if let l = c.labels?[v] { return l }
        return def?.values.first(where: { $0[1] == v })?[0].trimmingCharacters(in: .whitespaces) ?? v
    }
    return "\(op) \(values.joined(separator: ", "))"
}

/// Условия кратко: «Статус открыта · Трекер соответствует Ошибка».
func filterSummary(_ filters: [FilterCond], catalog: FilterCatalog?) -> String {
    guard !filters.isEmpty else { return String(localized: "No conditions") }
    return filters.map { "\(catalog?.def($0.field)?.name ?? $0.field) \(condText($0, catalog: catalog))" }.joined(separator: " · ")
}

private func visibilityIcon(_ v: Int) -> String { v == 2 ? "globe" : v == 1 ? "person.2" : "lock" }

private enum QuerySheet: Identifiable {
    case filter(IssueFilter, LocalQuery?)
    case save(IssueFilter)
    var id: String {
        switch self {
        case .filter(let f, let q): "filter-\(f.key)-\(q?.localId ?? "")"
        case .save(let f): "save-\(f.key)"
        }
    }
}

/// Раздел «Запросы» проекта (projectId nil — «Все запросы»): «Фильтр», недавние фильтры, «Мои» (свои и серверные
/// личные) и «Общие» (spec 17.2–17.4). Строка открывает задачи запроса в колонке детали.
struct ProjectQueries: View {
    @Environment(AppModel.self) private var app
    let projectId: Int?
    @Binding var page: ProjectPage?
    @State private var server: [ServerQuery]?
    @State private var error: String?
    @State private var catalog: FilterCatalog?
    @State private var sheet: QuerySheet?
    @State private var undeleted: LocalQuery?

    /// Свои запросы этого проекта и «для всех проектов».
    private var locals: [LocalQuery] { app.settings.localQueries.filter { projectId == nil || $0.scope == nil || $0.scope == projectId } }
    /// Серверные этого проекта и «для всех проектов»; у которых есть своя копия — одной (своей) строкой.
    private var serverHere: [ServerQuery] {
        let mine = Set(app.settings.localQueries.compactMap(\.serverId))
        return (server ?? []).filter { (projectId == nil || $0.projectId == nil || $0.projectId == projectId) && !mine.contains($0.id) }
    }
    private var recent: [IssueFilter] { app.settings.recentFilters.filter { $0.projectId == projectId } }

    var body: some View {
        let mineServer = serverHere.filter { !$0.isPublic }, shared = serverHere.filter(\.isPublic)
        List(selection: $page) {
            Section {
                Button { sheet = .filter(IssueFilter(projectId: projectId), nil) } label: {
                    Label("New filter", systemImage: "line.3.horizontal.decrease")
                }
            }
            if !recent.isEmpty {
                Section("Recent filters") { ForEach(recent, id: \.key) { recentRow($0) } }
            }
            if !locals.isEmpty || !mineServer.isEmpty {
                Section("Mine") {
                    ForEach(locals) { localRow($0) }
                    ForEach(mineServer) { serverRow($0) }
                }
            }
            if !shared.isEmpty {
                Section("Shared") { ForEach(shared) { serverRow($0) } }
            }
            if let error {
                Section {
                    Label { Text("Couldn’t load queries from the server: \(error)") } icon: { Image(systemName: "wifi.exclamationmark") }
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if server == nil && error == nil && locals.isEmpty && recent.isEmpty { ProgressView() }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $sheet) { s in
            Group {
                switch s {
                case .filter(let f, let q):
                    FilterEditor(initial: f, editing: q) { f in
                        page = .query(QueryRun(id: "recent:\(f.key)", name: filterSummary(f.filters, catalog: catalog), filter: f))
                    }
                case .save(let f): SaveQuerySheet(filter: f)
                }
            }
            .environment(app)
        }
        .alert(Text("Couldn’t delete on the server"), isPresented: Binding(get: { undeleted != nil }, set: { if !$0 { undeleted = nil } }),
               presenting: undeleted) { q in
            Button("Delete only on device", role: .destructive) { Task { _ = await app.deleteQuery(q, localOnly: true) } }
            Button("Cancel", role: .cancel) {}
        } message: { _ in Text("Delete only on device?") }
    }

    private func load() async {
        guard let api = app.api else { return }
        if let refs = app.refs {
            if catalog == nil { catalog = await refs.staleFilterCatalog(projectId) }
            // каталог — для подписей условий; свежий фоном (сутки, «Справочники»)
            Task { if let c = try? await refs.filterCatalog(projectId) { catalog = c } }
        }
        do {
            let s = try await api.queries()
            server = s
            error = nil
            app.syncQueries(s)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func favoriteButton(_ run: QueryRun) -> some View {
        let fav = app.isFavoriteQuery(run.id)
        return Button { app.toggleFavoriteQuery(run) } label: {
            Label(fav ? "Remove from Favorites" : "Add to Favorites", systemImage: fav ? "star.slash" : "star")
        }
    }

    private func star(_ run: QueryRun) -> some View {
        Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
            .opacity(app.isFavoriteQuery(run.id) ? 1 : 0)
            .accessibilityHidden(!app.isFavoriteQuery(run.id))
            .accessibilityLabel(Text("Favorite"))
    }

    /// Недавний: условия кратко, «★» и «Сохранить».
    private func recentRow(_ f: IssueFilter) -> some View {
        let run = QueryRun(id: "recent:\(f.key)", name: filterSummary(f.filters, catalog: catalog), filter: f)
        let fav = app.isFavoriteQuery(run.id)
        return HStack(spacing: 14) {
            Text(run.name).font(.subheadline).lineLimit(3)
            Spacer(minLength: 4)
            Button { app.toggleFavoriteQuery(run) } label: { Image(systemName: fav ? "star.fill" : "star").foregroundStyle(.yellow) }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(fav ? "Remove from Favorites" : "Add to Favorites"))
            Button("Save") { sheet = .save(f) }.buttonStyle(.borderless)
        }
        .tag(ProjectPage.query(run))
        .contextMenu {
            favoriteButton(run)
            Button { sheet = .filter(f, nil) } label: { Label("Edit", systemImage: "pencil") }
        }
    }

    /// Свой запрос: имя, условия, состояние «Только на устройстве» с причиной и «Сохранить на сервере».
    private func localRow(_ q: LocalQuery) -> some View {
        var run = q.run
        if let projectId { run.filter.projectId = projectId } // «для всех проектов» — запускается в этом
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(q.name)
                star(run)
                Spacer(minLength: 4)
                Image(systemName: visibilityIcon(q.visibility)).font(.caption).foregroundStyle(.secondary)
            }
            Text(filterSummary(q.filters, catalog: catalog)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if app.pushingQueries.contains(q.localId) {
                Label("Saving on the server…", systemImage: "arrow.up.circle").font(.caption).foregroundStyle(.secondary)
            } else if !q.onServer {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Only on device", systemImage: "iphone").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        if let e = q.error { Text(e).font(.caption2).foregroundStyle(.secondary).lineLimit(3) }
                    }
                    Spacer(minLength: 4)
                    Button("Save on the server") { Task { await app.pushQuery(q.localId, interactive: true) } }
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
        .tag(ProjectPage.query(run))
        .contextMenu {
            favoriteButton(run)
            Button { sheet = .filter(run.filter, q) } label: {
                Label("Edit", systemImage: "pencil")
            }
            Button(role: .destructive) { Task { if !(await app.deleteQuery(q)) { undeleted = q } } } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }

    /// Серверный запрос: только запуск и избранное — условий REST не отдаёт.
    private func serverRow(_ s: ServerQuery) -> some View {
        let run = QueryRun(id: "server:\(s.id)", name: s.name, filter: IssueFilter(projectId: projectId ?? s.projectId, queryId: s.id))
        return HStack(spacing: 6) {
            Text(s.name)
            star(run)
            Spacer(minLength: 4)
            Image(systemName: s.isPublic ? "globe" : "lock").font(.caption).foregroundStyle(.secondary)
        }
        .tag(ProjectPage.query(run))
        .contextMenu { favoriteButton(run) }
    }
}

// MARK: - Фильтр

/// Экран «Фильтр»: условия «поле · оператор · значения», «+ Условие» с поиском по каталогу, сортировка (spec 17.2).
struct FilterEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let initial: IssueFilter
    var editing: LocalQuery?
    let onApply: (IssueFilter) -> Void
    @State private var conds: [FilterCond]
    @State private var sort: [SortCrit]
    @State private var catalog: FilterCatalog?
    @State private var error: String?
    @State private var adding = false
    @State private var saving = false

    init(initial: IssueFilter, editing: LocalQuery? = nil, onApply: @escaping (IssueFilter) -> Void) {
        self.initial = initial
        self.editing = editing
        self.onApply = onApply
        // новый фильтр — как на сайте: открытые, свежие сверху
        let fresh = initial.filters.isEmpty && editing == nil
        _conds = State(initialValue: fresh ? [FilterCond(field: "status_id", op: "o")] : initial.filters)
        _sort = State(initialValue: fresh && initial.sort.isEmpty ? [SortCrit(field: "updated_on", dir: "desc")] : initial.sort)
    }

    /// Условия, которым хватает значений.
    private var valid: [FilterCond] { conds.filter { opArity($0.op) == 0 || $0.values.contains { !$0.isEmpty } } }
    private var result: IssueFilter { IssueFilter(projectId: initial.projectId, filters: valid, sort: sort) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach($conds, id: \.field) { $c in
                        let def = catalog?.def(c.field) ?? FilterDef(field: c.field, name: c.field, type: "", ops: [c.op], values: [], remote: false)
                        NavigationLink {
                            ConditionEditor(def: def, cond: $c, catalog: catalog).environment(app)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(def.name)
                                Text(condText(c, catalog: catalog)).font(.caption)
                                    .foregroundStyle(valid.contains(c) ? Color.secondary : Color.red)
                            }
                        }
                    }
                    .onDelete { conds.remove(atOffsets: $0) }
                    Button { adding = true } label: { Label("Condition", systemImage: "plus") }
                        .disabled(catalog == nil)
                } header: {
                    Text("Conditions")
                } footer: {
                    if catalog == nil, let error { Text(error) }
                }
                Section("Sort") {
                    ForEach($sort, id: \.field) { $s in
                        Picker(sortFieldName(s.field), selection: $s.dir) {
                            Text("Ascending").tag("asc")
                            Text("Descending").tag("desc")
                        }
                    }
                    .onDelete { sort.remove(atOffsets: $0) }
                    let free = Self.sortFields.filter { f in !sort.contains { $0.field == f } }
                    if sort.count < 3 && !free.isEmpty {
                        Menu {
                            ForEach(free, id: \.self) { f in Button(sortFieldName(f)) { sort.append(SortCrit(field: f, dir: "desc")) } }
                        } label: { Label("Sort by", systemImage: "plus") }
                    }
                }
                Section {
                    Button { saving = true } label: { Label("Save…", systemImage: "square.and.arrow.down") }
                        .disabled(valid.isEmpty && sort.isEmpty)
                }
            }
            .navigationTitle("Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton("Apply") {
                        app.addRecentFilter(result)
                        onApply(result)
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $adding) {
                FilterFieldPicker(catalog: catalog ?? FilterCatalog(), used: Set(conds.map(\.field))) { def in
                    conds.append(FilterCond(field: def.field, op: def.usableOps.first ?? "="))
                }
                .environment(app)
            }
            .sheet(isPresented: $saving) {
                SaveQuerySheet(filter: result, editing: editing) { dismiss() }.environment(app)
            }
            .task {
                guard let refs = app.refs else { return }
                if catalog == nil { catalog = await refs.staleFilterCatalog(initial.projectId) }
                do { catalog = try await refs.filterCatalog(initial.projectId) }
                catch { if catalog == nil { self.error = error.localizedDescription } }
            }
        }
    }

    static let sortFields = ["id", "updated_on", "created_on", "priority", "status", "tracker", "subject", "assigned_to", "due_date"]

    private func sortFieldName(_ f: String) -> String {
        switch f {
        case "id": "#"
        case "updated_on": String(localized: "Updated")
        case "created_on": String(localized: "Created")
        case "priority": String(localized: "Priority")
        case "status": String(localized: "Status")
        case "tracker": String(localized: "Tracker")
        case "subject": String(localized: "Subject")
        case "assigned_to": String(localized: "Assignee")
        case "due_date": String(localized: "Due date")
        default: f
        }
    }
}

/// «+ Условие»: поиск по каталогу; уже взятые поля и фильтры без доступных операторов не предлагаются.
private struct FilterFieldPicker: View {
    @Environment(\.dismiss) private var dismiss
    let catalog: FilterCatalog
    let used: Set<String>
    let onPick: (FilterDef) -> Void
    @State private var query = ""

    var body: some View {
        let list = catalog.filters.filter { d in
            !used.contains(d.field) && !d.usableOps.isEmpty && (query.isEmpty || d.name.localizedCaseInsensitiveContains(query))
        }
        NavigationStack {
            List(list) { d in
                Button {
                    onPick(d)
                    dismiss()
                } label: { Text(d.name) }
                .foregroundStyle(.primary)
            }
            .overlay { if list.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) } }
            .navigationTitle("Add condition")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Field"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } } }
        }
        .halfSheet()
    }
}

/// Условие: оператор и значения по типу фильтра — список, люди (выбор из п. 8.2 и «я»), текст, число дней, два значения.
private struct ConditionEditor: View {
    @Environment(AppModel.self) private var app
    let def: FilterDef
    @Binding var cond: FilterCond
    let catalog: FilterCatalog?
    @State private var picking = false
    @State private var search = MentionSearch()

    var body: some View {
        Form {
            Section {
                Picker("Operator", selection: $cond.op) {
                    ForEach(def.usableOps, id: \.self) { Text(catalog?.opLabels[$0] ?? $0).tag($0) }
                }
            }
            if opArity(cond.op) == 2 {
                Section("Values") {
                    TextField("From", text: value(0))
                    TextField("To", text: value(1))
                }
            } else if opArity(cond.op) == 1 {
                if def.isPeople {
                    Section("Values") {
                        ForEach(cond.values, id: \.self) { v in
                            Text(v == "me" ? String(localized: "me") : cond.labels?[v] ?? "#\(v)")
                        }
                        .onDelete { cond.values.remove(atOffsets: $0) }
                        if !cond.values.contains("me") {
                            Button { add("me", nil) } label: { Label("Me", systemImage: "person.crop.circle") }
                        }
                        Button { picking = true } label: { Label("Choose person…", systemImage: "person.badge.plus") }
                    }
                } else if !def.values.isEmpty {
                    Section("Values") {
                        ForEach(def.values, id: \.self) { pair in
                            let on = cond.values.contains(pair[1])
                            Button {
                                if on { cond.values.removeAll { $0 == pair[1] } } else { cond.values.append(pair[1]) }
                            } label: {
                                HStack {
                                    Text(pair[0])
                                    Spacer()
                                    if on { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
                                }
                            }
                            .foregroundStyle(.primary)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                } else if dayOps.contains(cond.op) {
                    Section("Value") { TextField("Days", text: value(0)).keyboardType(.numberPad) }
                } else {
                    Section("Value") { TextField("Value", text: value(0)) }
                }
            }
        }
        .navigationTitle(def.name)
        .navigationBarTitleDisplayMode(.inline)
        // смена оператора: значения другого вида не тащим
        .onChange(of: cond.op) { old, new in if opArity(new) == 0 || (opArity(old) == 2) != (opArity(new) == 2) { cond.values = [] } }
        .sheet(isPresented: $picking) {
            PeoplePicker(search: search, title: "Choose person") { p in add(String(p.id), p.name) }.environment(app)
        }
    }

    private func value(_ i: Int) -> Binding<String> {
        Binding(get: { i < cond.values.count ? cond.values[i] : "" }, set: { v in
            while cond.values.count <= i { cond.values.append("") }
            cond.values[i] = v
        })
    }

    private func add(_ id: String, _ name: String?) {
        guard !cond.values.contains(id) else { return }
        cond.values.append(id)
        if let name { cond.labels = (cond.labels ?? [:]).merging([id: name]) { $1 } }
    }
}

// MARK: - Сохранение

/// «Сохранить»: имя, описание, видимость (только мне / всем / ролям из /roles.json), «Для всех проектов» (spec 17.3).
/// Сохраняется у себя сразу, на сервер — фоном.
struct SaveQuerySheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let filter: IssueFilter
    let editing: LocalQuery?
    let onSaved: () -> Void
    @State private var name: String
    @State private var details: String
    @State private var visibility: Int
    @State private var roleIds: Set<Int>
    @State private var forAll: Bool
    @State private var roles: [Named]?

    init(filter: IssueFilter, editing: LocalQuery? = nil, onSaved: @escaping () -> Void = {}) {
        self.filter = filter
        self.editing = editing
        self.onSaved = onSaved
        _name = State(initialValue: editing?.name ?? "")
        _details = State(initialValue: editing?.description ?? "")
        _visibility = State(initialValue: editing?.visibility ?? 0)
        _roleIds = State(initialValue: Set(editing?.roleIds ?? []))
        _forAll = State(initialValue: editing?.forAll ?? (filter.projectId == nil))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Description", text: $details, axis: .vertical).lineLimit(1...4)
                }
                Section {
                    Picker("Visible", selection: $visibility) {
                        Text("To me only").tag(0)
                        Text("To any users").tag(2)
                        Text("To these roles only").tag(1)
                    }
                    if visibility == 1 {
                        if let roles {
                            ForEach(roles) { r in
                                Toggle(r.name, isOn: Binding(get: { roleIds.contains(r.id) },
                                                             set: { if $0 { roleIds.insert(r.id) } else { roleIds.remove(r.id) } }))
                            }
                        } else {
                            ProgressView()
                        }
                    }
                    Toggle("For all projects", isOn: $forAll).disabled((editing?.projectId ?? filter.projectId) == nil)
                } footer: {
                    Text("Saved on this device right away, then on the server the way the website does it.")
                }
            }
            .navigationTitle(editing == nil ? "Save query" : "Edit query")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .task(id: visibility) {
                if visibility == 1 && roles == nil { roles = (try? await app.refs?.roles()) ?? [] }
            }
        }
    }

    private func save() {
        var q = editing ?? LocalQuery(name: "", projectId: filter.projectId)
        q.name = name.trimmingCharacters(in: .whitespaces)
        q.description = details
        q.forAll = forAll
        q.filters = filter.filters
        q.sort = filter.sort
        q.visibility = visibility
        q.roleIds = visibility == 1 ? roleIds.sorted() : []
        q.error = nil
        app.saveQuery(q)
        dismiss()
        onSaved()
    }
}

// MARK: - Задачи запроса

/// Задачи по запросу в колонке детали: свои условия или серверный query_id; «★» — в избранное (spec 17.5).
struct FilteredIssuesView: View {
    @Environment(AppModel.self) private var app
    let run: QueryRun
    @State private var issues: [Issue] = []
    @State private var total = 0
    @State private var loaded = false
    @State private var loadingMore = false
    @State private var error: String?

    var body: some View {
        List {
            ForEach(issues) { i in
                NavigationLink(value: IssueLink(id: i.id)) { IssueRow(issue: i, showProject: run.filter.projectId == nil) }
                    .contextMenu { IssueMenu(issue: i) }
                    .onAppear { if i.id == issues.last?.id { Task { await more() } } }
            }
            if loadingMore { ProgressView().frame(maxWidth: .infinity) }
        }
        .listStyle(.plain)
        .overlay {
            if issues.isEmpty {
                if let error { LoadErrorView(message: error) { Task { await load() } } }
                else if !loaded { ProgressView() }
                else { ContentUnavailableView("Nothing here yet", systemImage: "tray") }
            }
        }
        .navigationTitle(run.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                let fav = app.isFavoriteQuery(run.id)
                Button { app.toggleFavoriteQuery(run) } label: {
                    Label(fav ? "Remove from Favorites" : "Add to Favorites", systemImage: fav ? "star.fill" : "star")
                }
            }
        }
        .refreshable { await load() }
        .task { if !loaded { await load() } }
        .onChange(of: app.listEpoch) { Task { await load() } }
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            let page = try await api.issues(run.filter, offset: 0)
            issues = page.issues
            total = page.totalCount
            error = nil
        } catch {
            if issues.isEmpty && !(error is CancellationError) { self.error = error.localizedDescription }
        }
        loaded = true
    }

    private func more() async {
        guard let api = app.api, issues.count < total, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await api.issues(run.filter, offset: issues.count) else { return }
        let known = Set(issues.map(\.id))
        issues += page.issues.filter { !known.contains($0.id) }
        total = page.issues.isEmpty ? issues.count : page.totalCount
    }
}

/// Избранные запросы строками над задачами во вкладке «Избранное» (spec 17.5); порядок — перетаскиванием.
struct FavoriteQueriesSection: View {
    @Environment(AppModel.self) private var app
    let page: Binding<ProjectPage?>

    var body: some View {
        Section("Queries") {
            ForEach(app.settings.favoriteQueries) { saved in
                let run = app.resolved(saved)
                let unread = app.queryBadge(run.id)
                Button { page.wrappedValue = .query(run) } label: {
                    HStack {
                        Label { Text(run.name).lineLimit(2) } icon: { Image(systemName: "line.3.horizontal.decrease.circle") }
                        Spacer(minLength: 4)
                        // непрочитанные задачи запроса (spec 19.3)
                        if unread > 0 {
                            Text(verbatim: unread > 99 ? "99+" : "\(unread)")
                                .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(.white)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.accentColor, in: Capsule())
                                .accessibilityLabel(Text("\(unread) unread"))
                        }
                    }
                }
                .foregroundStyle(.primary)
                .swipeActions {
                    Button(role: .destructive) { app.toggleFavoriteQuery(saved) } label: {
                        Label("Remove from Favorites", systemImage: "star.slash")
                    }
                }
            }
            .onMove { app.settings.favoriteQueries.move(fromOffsets: $0, toOffset: $1) }
        }
        // показ вкладки — пересчёт (не чаще раза в минуту на запрос)
        .task(id: app.settings.favoriteQueries.map(\.id)) { await app.refreshQueryBadges() }
    }
}
