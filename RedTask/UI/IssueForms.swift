import SwiftUI
import PhotosUI

/// Дата «может не быть»: переключатель + календарь. Значение — «yyyy-MM-dd» или "".
struct OptionalDateRow: View {
    let title: LocalizedStringKey
    @Binding var value: String

    var body: some View {
        Toggle(title, isOn: Binding(get: { !value.isEmpty }, set: { value = $0 ? Fmt.day(Date()) : "" }))
        if !value.isEmpty {
            DatePicker(title, selection: Binding(get: { Fmt.dayDate(value) ?? Date() }, set: { value = Fmt.day($0) }), displayedComponents: .date)
                .datePickerStyle(.compact)
        }
    }
}

/// Ввод настраиваемого поля по его формату; без описания — свободный текст (проверит сервер).
struct CustomFieldInput: View {
    let field: FormField
    @Binding var values: [String]
    var options: [FormField.Option] = []
    var error = false

    private var label: String { field.name + (field.required ? " *" : "") }
    private var one: Binding<String> { Binding(get: { values.first ?? "" }, set: { values = $0.isEmpty ? [] : [$0] }) }

    var body: some View {
        let opts = field.options.isEmpty ? options : field.options
        Group {
            if field.format == "bool" {
                Picker(label, selection: one) {
                    Text("—").tag("")
                    Text("Yes").tag("1")
                    Text("No").tag("0")
                }
            } else if field.format == "date" {
                OptionalDateRow(title: LocalizedStringKey(label), value: one)
            } else if !opts.isEmpty && field.multiple {
                NavigationLink {
                    List(opts, id: \.value) { o in
                        Button {
                            if values.contains(o.value) { values.removeAll { $0 == o.value } } else { values.append(o.value) }
                        } label: {
                            HStack {
                                Text(o.label).foregroundStyle(.primary)
                                Spacer()
                                if values.contains(o.value) { Image(systemName: "checkmark").foregroundStyle(.tint) }
                            }
                        }
                    }
                    .navigationTitle(field.name)
                } label: {
                    LabeledContent(label, value: opts.filter { values.contains($0.value) }.map(\.label).joined(separator: ", "))
                }
            } else if !opts.isEmpty {
                Picker(label, selection: one) {
                    Text("—").tag("")
                    ForEach(opts, id: \.value) { Text($0.label).tag($0.value) }
                }
            } else if field.format == "text" {
                VStack(alignment: .leading) {
                    Text(label).font(.subheadline).foregroundStyle(.secondary)
                    TextField(label, text: one, axis: .vertical).lineLimit(3...8)
                }
            } else {
                TextField(label, text: one)
                    .keyboardType(field.format == "int" ? .numberPad : field.format == "float" ? .decimalPad : field.format == "link" ? .URL : .default)
            }
        }
        .foregroundStyle(error ? Color.red : Color.primary)
    }
}

/// Варианты для полей «пользователь» и «версия», если веб-форма их не дала.
private func extraOptions(_ f: FormField, members: [Named], versions: [Version]) -> [FormField.Option] {
    switch f.format {
    case "user": members.map { .init(value: String($0.id), label: $0.name) }
    case "version": versions.map { .init(value: String($0.id), label: $0.name) }
    default: []
    }
}

// MARK: - Правка задачи

/// Черновик правки: сравнение со снимком — на сервер уходит только изменённое.
struct EditIssueView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let issue: Issue
    let perms: IssuePerms
    var onSaved: () -> Void

    @State private var subject = ""
    @State private var description = ""
    @State private var trackerId = 0
    @State private var statusId = 0
    @State private var priorityId = 0
    @State private var assigneeId = 0
    @State private var categoryId = 0
    @State private var versionId = 0
    @State private var parent = ""
    @State private var pickParent = false
    @State private var startDate = ""
    @State private var dueDate = ""
    @State private var estimate = ""
    @State private var doneRatio = 0
    @State private var isPrivate = false
    @State private var custom: [Int: [String]] = [:]

    @State private var trackers: [Tracker] = []
    @State private var priorities: [Priority] = []
    @State private var members: [Named] = []
    @State private var versions: [Version] = []
    @State private var categories: [Named] = []
    @State private var fields: [FormField] = []
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDiscard = false
    @State private var loaded = false

    private var parentId: Int? {
        let s = parent.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        return s.isEmpty ? 0 : Int(s)
    }
    private var estimateText: String { estimate.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".") }
    private var valid: Bool { !subject.trimmingCharacters(in: .whitespaces).isEmpty && parentId != nil && (estimateText.isEmpty || Double(estimateText) != nil) }

    var body: some View {
        NavigationStack {
            Form {
                Section("Subject") {
                    TextField("Subject", text: $subject, axis: .vertical)
                }
                Section("Description") {
                    TextileEditor(text: $description, attachments: issue.attachments, placeholder: "Description", participants: issueParticipants(issue))
                }
                Section {
                    if !trackers.isEmpty {
                        Picker("Tracker", selection: $trackerId) { ForEach(trackers) { Text($0.name).tag($0.id) } }
                    }
                    if let st = issue.allowedStatuses, !st.isEmpty {
                        Picker("Status", selection: $statusId) { ForEach(st) { statusLabel($0).tag($0.id) } }
                    }
                    if !priorities.isEmpty {
                        Picker("Priority", selection: $priorityId) { ForEach(priorities) { Text($0.name).tag($0.id) } }
                    }
                    Picker("Assignee", selection: $assigneeId) {
                        Text("Not assigned").tag(0)
                        ForEach(membersWithCurrent) { Text($0.name).tag($0.id) }
                    }
                    if !categories.isEmpty || categoryId != 0 {
                        Picker("Category", selection: $categoryId) {
                            Text("—").tag(0)
                            ForEach(categoriesWithCurrent) { Text($0.name).tag($0.id) }
                        }
                    }
                    Picker("Version", selection: $versionId) {
                        Text("—").tag(0)
                        ForEach(versionsWithCurrent) { Text($0.name).tag($0.id) }
                    }
                    // подпись остаётся видна и у заполненного поля (HIG → Text fields: плейсхолдер — не подпись)
                    LabeledContent("Parent issue") {
                        HStack(spacing: 8) {
                            TextField("None", text: $parent)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(parentId == nil ? Color.red : Color.primary)
                            Button { pickParent = true } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel(Text("Find parent issue"))
                        }
                    }
                }
                Section {
                    OptionalDateRow(title: "Start date", value: $startDate)
                    OptionalDateRow(title: "Due date", value: $dueDate)
                    LabeledContent("Estimate, h") {
                        TextField("None", text: $estimate).keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .foregroundStyle(estimateText.isEmpty || Double(estimateText) != nil ? Color.primary : Color.red)
                    }
                    Picker("Progress", selection: $doneRatio) {
                        ForEach(Array(Set(stride(from: 0, through: 100, by: 10)).union([doneRatio])).sorted(), id: \.self) { Text("\($0)%").tag($0) }
                    }
                    if perms.has("set_issues_private") || perms.has("set_own_issues_private") || isPrivate {
                        Toggle("Private issue", isOn: $isPrivate)
                    }
                }
                if !issue.customFields.isEmpty {
                    Section("Custom fields") {
                        ForEach(editableFields) { f in
                            CustomFieldInput(field: f, values: Binding(get: { custom[f.id] ?? [] }, set: { custom[f.id] = $0 }),
                                             options: extraOptions(f, members: members, versions: versions))
                        }
                    }
                }
            }
            .navigationTitle("Edit issue")
            .sheet(isPresented: $pickParent) {
                IssuePicker(title: "Parent issue", exclude: [issue.id]) { parent = String($0.id) }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { if dirty { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton("Save") { Task { await save() } }.disabled(!valid || busy || !dirty)
                }
            }
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
            }
            .errorAlert($error)
            .task { await load() }
        }
        .interactiveDismissDisabled(dirty || busy)
    }

    /// Поля задачи с форматом из веб-формы (если удалось её прочитать), иначе — свободный текст.
    private var editableFields: [FormField] {
        issue.customFields.map { cf in
            var f = fields.first { $0.id == cf.id } ?? FormField(id: cf.id, name: cf.name)
            if cf.multiple || cf.value?.isArray == true { f.multiple = true }
            return f
        }
    }

    private var membersWithCurrent: [Named] {
        var m = members
        if let a = issue.assignedTo, !m.contains(where: { $0.id == a.id }) { m.insert(a, at: 0) }
        return m
    }
    private var categoriesWithCurrent: [Named] {
        var c = categories
        if let x = issue.category, !c.contains(where: { $0.id == x.id }) { c.insert(x, at: 0) }
        return c
    }
    private var versionsWithCurrent: [Named] {
        var v = versions.filter { $0.status != "closed" }.map { Named(id: $0.id, name: $0.name) }
        if let x = issue.fixedVersion, !v.contains(where: { $0.id == x.id }) { v.insert(x, at: 0) }
        return v
    }

    private var dirty: Bool {
        guard loaded else { return false }
        let b = issue
        return subject != b.subject || description != (b.description ?? "") || trackerId != b.tracker.id || statusId != b.status.id ||
            priorityId != b.priority.id || assigneeId != (b.assignedTo?.id ?? 0) || categoryId != (b.category?.id ?? 0) ||
            versionId != (b.fixedVersion?.id ?? 0) || parent != (b.parent.map { String($0.id) } ?? "") ||
            startDate != (b.startDate ?? "") || dueDate != (b.dueDate ?? "") || estimate != plain(b.estimatedHours) ||
            doneRatio != b.doneRatio || isPrivate != b.isPrivate || b.customFields.contains { (custom[$0.id] ?? []) != $0.values }
    }

    private func plain(_ d: Double?) -> String {
        guard let d else { return "" }
        return d.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(d)) : String(d)
    }

    private func load() async {
        guard !loaded else { return }
        let b = issue
        subject = b.subject; description = b.description ?? ""; trackerId = b.tracker.id; statusId = b.status.id
        priorityId = b.priority.id; assigneeId = b.assignedTo?.id ?? 0; categoryId = b.category?.id ?? 0
        versionId = b.fixedVersion?.id ?? 0; parent = b.parent.map { String($0.id) } ?? ""
        startDate = b.startDate ?? ""; dueDate = b.dueDate ?? ""; estimate = plain(b.estimatedHours)
        doneRatio = b.doneRatio; isPrivate = b.isPrivate
        for f in b.customFields { custom[f.id] = f.values }
        loaded = true
        guard let api = app.api, let refs = app.refs else { return }
        async let t = try? api.project(b.project.id).trackers
        async let p = try? refs.priorities()
        async let m = try? refs.members(b.project.id)
        async let v = try? refs.versions(b.project.id)
        async let c = try? api.issueCategories(b.project.id)
        async let f = fetchFormFields(api: api, projectId: b.project.id, trackerId: b.tracker.id)
        trackers = await t ?? [Tracker(id: b.tracker.id, name: b.tracker.name)]
        if !trackers.contains(where: { $0.id == trackerId }) { trackers.insert(Tracker(id: b.tracker.id, name: b.tracker.name), at: 0) }
        priorities = await p ?? []
        if !priorities.contains(where: { $0.id == priorityId }) { priorities.insert(Priority(id: b.priority.id, name: b.priority.name), at: 0) }
        members = await m ?? []
        versions = await v ?? []
        categories = await c ?? []
        fields = await f
    }

    /// Отправляет только изменённые поля; сброс — пустая строка / id 0 → "".
    private func save() async {
        guard let api = app.api else { return }
        let b = issue
        var d: [String: Any] = [:]
        if subject != b.subject { d["subject"] = subject }
        if description != (b.description ?? "") { d["description"] = description }
        if trackerId != b.tracker.id { d["tracker_id"] = trackerId }
        if statusId != b.status.id { d["status_id"] = statusId }
        if priorityId != b.priority.id { d["priority_id"] = priorityId }
        let ids: [(String, Int, Int)] = [
            ("assigned_to_id", assigneeId, b.assignedTo?.id ?? 0), ("category_id", categoryId, b.category?.id ?? 0),
            ("fixed_version_id", versionId, b.fixedVersion?.id ?? 0), ("parent_issue_id", parentId ?? (b.parent?.id ?? 0), b.parent?.id ?? 0),
        ]
        for (key, v, old) in ids where v != old { d[key] = v == 0 ? "" as Any : v as Any }
        if startDate != (b.startDate ?? "") { d["start_date"] = startDate }
        if dueDate != (b.dueDate ?? "") { d["due_date"] = dueDate }
        if estimate != plain(b.estimatedHours) { d["estimated_hours"] = Double(estimateText).map { $0 as Any } ?? "" as Any }
        if doneRatio != b.doneRatio { d["done_ratio"] = doneRatio }
        if isPrivate != b.isPrivate { d["is_private"] = isPrivate }
        let cf: [[String: Any]] = b.customFields.compactMap { f in
            let now = (custom[f.id] ?? []).filter { !$0.isEmpty }
            guard now != f.values else { return nil }
            let multi = f.multiple || f.value?.isArray == true || fields.first { $0.id == f.id }?.multiple == true
            return ["id": f.id, "value": multi ? now as Any : (now.first ?? "") as Any]
        }
        if !cf.isEmpty { d["custom_fields"] = cf }
        busy = true
        defer { busy = false }
        do {
            try await api.updateIssue(b.id, d)
            onSaved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Новая задача

struct NewIssueView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var projectId: Int?
    var parent: Int?

    @State private var project: Project?
    @State private var trackers: [Tracker] = []
    @State private var trackerId: Int?
    @State private var subject = ""
    @State private var description = ""
    @State private var priorities: [Priority] = []
    @State private var priorityId: Int?
    @State private var members: [Named] = []
    @State private var assigneeId: Int?
    @State private var versions: [Version] = []
    @State private var versionId: Int?
    @State private var categories: [Named] = []
    @State private var categoryId: Int?
    @State private var startDate = ""
    @State private var dueDate = ""
    @State private var estimate = ""
    @State private var isPrivate = false
    @State private var fields: [FormField] = []
    @State private var values: [Int: [String]] = [:]
    @State private var files: [PickedFile] = []
    @State private var uploaded: [UUID: UploadRef] = [:]
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var busy = false
    @State private var tried = false
    @State private var error: String?
    @State private var confirmDiscard = false
    /// Проект последней созданной задачи — по умолчанию для следующей.
    @AppStorage("lastProjectId") private var lastProjectId = 0

    private var missing: [FormField] { fields.filter { f in f.required && (values[f.id] ?? []).allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } } }
    private var dirty: Bool { !subject.isEmpty || !description.isEmpty || !files.isEmpty }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink {
                        ProjectPicker { p in select(p) }
                    } label: {
                        LabeledContent("Project", value: project?.name ?? String(localized: "Choose…"))
                    }
                    if !trackers.isEmpty {
                        Picker("Tracker", selection: $trackerId) { ForEach(trackers) { Text($0.name).tag(Optional($0.id)) } }
                    }
                    if let parent { LabeledContent("Parent issue", value: "#\(parent)") }
                }
                Section("Subject") {
                    TextField("Subject", text: $subject, axis: .vertical)
                        .foregroundStyle(tried && subject.trimmingCharacters(in: .whitespaces).isEmpty ? Color.red : Color.primary)
                }
                Section("Description") {
                    TextileEditor(text: $description, pendingNames: files.map(\.name), placeholder: "Description")
                }
                Section {
                    if !priorities.isEmpty {
                        Picker("Priority", selection: $priorityId) { ForEach(priorities) { Text($0.name).tag(Optional($0.id)) } }
                    }
                    Picker("Assignee", selection: $assigneeId) {
                        Text("Not assigned").tag(Int?.none)
                        if app.settings.userId != 0 { Text("Me").tag(Optional(app.settings.userId)) }
                        ForEach(members.filter { $0.id != app.settings.userId }) { Text($0.name).tag(Optional($0.id)) }
                    }
                    if !versions.isEmpty {
                        Picker("Version", selection: $versionId) {
                            Text("—").tag(Int?.none)
                            ForEach(versions) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    if !categories.isEmpty {
                        Picker("Category", selection: $categoryId) {
                            Text("—").tag(Int?.none)
                            ForEach(categories) { Text($0.name).tag(Optional($0.id)) }
                        }
                    }
                    OptionalDateRow(title: "Start date", value: $startDate)
                    OptionalDateRow(title: "Due date", value: $dueDate)
                    LabeledContent("Estimate, h") {
                        TextField("None", text: $estimate).keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                    Toggle("Private issue", isOn: $isPrivate)
                }
                if !fields.isEmpty {
                    Section("Custom fields") {
                        ForEach(fields) { f in
                            CustomFieldInput(field: f, values: Binding(get: { values[f.id] ?? [] }, set: { values[f.id] = $0 }),
                                             options: extraOptions(f, members: members, versions: versions),
                                             error: tried && missing.contains(f))
                        }
                    }
                }
                Section("Files") {
                    ForEach(files) { f in LabeledContent(f.name, value: Fmt.size(f.data.count)) }
                        .onDelete { if !busy { files.remove(atOffsets: $0) } }
                    PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    Button { importing = true } label: { Label("Choose File", systemImage: "folder") }
                }
            }
            .navigationTitle(parent != nil ? "New subtask" : "New issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton { if dirty { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton("Create") { Task { await create() } }
                        .disabled(busy || project == nil || trackerId == nil)
                }
            }
            .overlay { if busy { ProgressView().controlSize(.large) } }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { files += urls.compactMap(readFile) }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { files += await loadPhotos(items); photoItems = [] }
            }
            .onChange(of: trackerId) { Task { await loadFields() } }
            .errorAlert($error)
            .task { await initial() }
        }
        .interactiveDismissDisabled(dirty || busy)
    }

    private func initial() async {
        guard let refs = app.refs else { return }
        if let list = try? await refs.priorities() {
            priorities = list
            if priorityId == nil { priorityId = list.first(where: \.isDefault)?.id }
        }
        if let projectId = projectId ?? (lastProjectId > 0 ? lastProjectId : nil), project == nil {
            let known = (try? await refs.projects())?.first { $0.id == projectId }
            select(known ?? Project(id: projectId, name: "#\(projectId)"))
        }
    }

    /// Смена проекта: исполнитель, версия и категория прежнего новый не примет (422).
    private func select(_ p: Project) {
        if p.id != project?.id {
            assigneeId = nil; versionId = nil; categoryId = nil
            trackers = []; members = []; versions = []; categories = []; fields = []
        }
        project = p
        Task {
            guard let api = app.api, let refs = app.refs else { return }
            async let m = try? refs.members(p.id)
            async let v = try? refs.versions(p.id)
            async let c = try? api.issueCategories(p.id)
            var list = (try? await api.project(p.id).trackers) ?? []
            if list.isEmpty { list = (try? await refs.trackers()) ?? [] }
            guard project?.id == p.id else { return }
            trackers = list
            if !list.contains(where: { $0.id == trackerId }) { trackerId = list.first?.id }
            members = await m ?? []
            versions = (await v ?? []).filter { $0.status == nil || $0.status == "open" }
            categories = await c ?? []
            await loadFields()
        }
    }

    private func loadFields() async {
        guard let api = app.api, let p = project?.id, let t = trackerId else { return }
        let list = await fetchFormFields(api: api, projectId: p, trackerId: t)
        guard project?.id == p, trackerId == t else { return }
        fields = list
        // значения по умолчанию — как в веб-форме; уже введённое не трогаем
        for f in list where !f.defaults.isEmpty && values[f.id] == nil { values[f.id] = f.defaults }
    }

    private func create() async {
        guard let api = app.api, let p = project, let t = trackerId else { return }
        tried = true
        if subject.trimmingCharacters(in: .whitespaces).isEmpty { return }
        if !missing.isEmpty {
            error = String(localized: "Fill in the required fields: \(missing.map(\.name).joined(separator: ", "))")
            return
        }
        // снимок формы до первой приостановки: пока грузятся файлы, проект можно сменить
        var form = issuePayload(projectId: p.id, trackerId: t, subject: subject, description: description, priorityId: priorityId,
                                assigneeId: assigneeId, versionId: versionId, categoryId: categoryId, parentId: parent,
                                estimate: estimate, startDate: startDate, dueDate: dueDate, isPrivate: isPrivate,
                                fields: fields, values: values)
        let picked = files
        busy = true
        defer { busy = false }
        do {
            // загруженное помним: повтор после отказа сервера не шлёт файлы второй раз
            var uploads: [UploadRef] = []
            for f in picked {
                if let u = uploaded[f.id] { uploads.append(u); continue }
                let u = try await api.upload(f.data, filename: f.name, contentType: f.mime)
                uploaded[f.id] = u
                uploads.append(u)
            }
            if !uploads.isEmpty { form["uploads"] = RedmineAPI.uploadsJSON(uploads) }
            let created = try await api.createIssue(form)
            app.listEpoch += 1
            lastProjectId = p.id
            dismiss()
            app.open(created.id)
        } catch { self.error = error.localizedDescription }
    }
}

/// Проекты с поиском (их бывают тысячи).
struct ProjectPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onPick: (Project) -> Void
    @State private var projects: [Project] = []
    @State private var query = ""

    var body: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let shown = (q.isEmpty ? projects : projects.filter { $0.name.localizedCaseInsensitiveContains(q) })
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        List(shown) { p in
            Button {
                onPick(p)
                dismiss()
            } label: {
                VStack(alignment: .leading) {
                    Text(p.name).foregroundStyle(.primary)
                    if let parent = p.parent?.name { Text(parent).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
        .overlay { if projects.isEmpty { ProgressView() } }
        .navigationTitle("Project")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .task { projects = (try? await app.refs?.projects()) ?? [] }
    }
}

/**
 Поля трекера, по убыванию точности: веб-форма новой задачи под сессией WKWebView (ровно то, что видит
 пользователь, с обязательностью и вариантами); /custom_fields.json (админ) ∩ поля проекта; только имена.
 */
func fetchFormFields(api: RedmineAPI, projectId: Int, trackerId: Int) async -> [FormField] {
    if let host = api.baseURL.host, let cookie = await AppModel.cookieHeader(host: host) {
        let ua = WafGate.shared.browser?.agent ?? UserDefaults.standard.string(forKey: "wafAgent") ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        if let html = try? await api.webPage("projects/\(projectId)/issues/new", cookie: cookie, userAgent: ua, [("issue[tracker_id]", String(trackerId))]),
           html.contains("issue-form") {
            return parseIssueFormFields(html)
        }
    }
    let inProject = (try? await api.projectIssueCustomFields(projectId)) ?? []
    let defs = (try? await api.customFieldDefs()) ?? []
    if defs.isEmpty { return inProject.map { FormField(id: $0.id, name: $0.name) } }
    let ids = Set(inProject.map(\.id))
    return defs
        .filter { d in (ids.isEmpty || ids.contains(d.id)) && (d.trackers.isEmpty || d.trackers.contains { $0.id == trackerId }) }
        .map { d in
            FormField(id: d.id, name: d.name, format: d.fieldFormat.isEmpty ? "string" : d.fieldFormat, required: d.isRequired, multiple: d.multiple,
                      options: d.possibleValues.map { .init(value: $0.value, label: $0.label.isEmpty ? $0.value : $0.label) },
                      defaults: d.defaultValue.map { $0.isEmpty ? [] : [$0] } ?? [])
        }
}

