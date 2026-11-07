import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Комментарий: новый, ответ с цитатой или правка своего. Только .large — как compose в Mail.
struct CommentSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: IssueDetailModel
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var importing = false
    @State private var confirmDiscard = false

    private var editing: Journal? { model.editingJournal }
    private var text: Binding<String> { editing != nil ? $model.editText : $model.draft }
    private var dirty: Bool { editing != nil ? model.editText != (editing?.notes ?? "") : false }

    @State private var preview = false

    var body: some View {
        NavigationStack {
            // как compose в Mail: служебный ряд сверху, под ним текст во весь лист; разметка — над клавиатурой
            VStack(spacing: 0) {
                options
                Divider()
                TextileEditor(text: text, attachments: model.issue?.attachments ?? [],
                              pendingNames: model.draftFiles.map(\.name), participants: model.issue.map(issueParticipants) ?? [], previewMode: $preview, fills: true)
                    .padding(.top, 8)
                    // приватная (spec 13) — поле с янтарным фоном
                    .background(model.commentPrivate ? Color.privateFill.opacity(0.09) : .clear)
                if editing == nil && !model.draftFiles.isEmpty { files }
                if let note = privacyNote {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(lockedPrivate ? Color.secondary : Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.vertical, 8)
                }
            }
            .navigationTitle(editing != nil ? "Edit comment" : "Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    SheetCancelButton {
                        if dirty { confirmDiscard = true } else { if editing != nil { model.editingJournal = nil }; dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton(editing != nil ? "Save" : "Send", systemImage: editing != nil ? "checkmark" : "arrow.up") {
                        Task { if await model.sendComment(app) { dismiss() } }
                    }
                    .disabled(model.busy || blocked || (text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && model.draftFiles.isEmpty && editing == nil))
                }
            }
            .overlay { if model.busy { ProgressView().controlSize(.large) } }
            .confirmationDialog("Discard changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { model.editingJournal = nil; dismiss() }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { r in
                if case .success(let urls) = r { model.draftFiles += urls.compactMap(readFile) }
            }
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                Task { model.draftFiles += await loadPhotos(items); photoItems = [] }
            }
            .errorAlert($model.actionError)
        }
        .interactiveDismissDisabled(dirty || model.busy)
        .presentationDetents([.large])
    }

    /// Приватность, файлы, предпросмотр — кнопки-переключатели одним рядом, видны и при открытой клавиатуре.
    private var options: some View {
        HStack(spacing: 8) {
            privacy
            if editing == nil {
                Menu {
                    PhotosPicker(selection: $photoItems, matching: .any(of: [.images, .videos])) { Label("Photo Library", systemImage: "photo.on.rectangle") }
                    Button { importing = true } label: { Label("Choose File", systemImage: "folder") }
                } label: { Label("Attach files", systemImage: "paperclip").labelStyle(.iconOnly) }
                .buttonStyle(.bordered)
            }
            Spacer()
            Toggle(isOn: $preview) { Label("Preview", systemImage: "eye").labelStyle(.iconOnly) }
                .toggleStyle(.button)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var files: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.draftFiles) { f in
                    HStack(spacing: 4) {
                        Image(systemName: "doc").accessibilityHidden(true)
                        Text(f.name).lineLimit(1)
                        Button { model.draftFiles.removeAll { $0 == f } } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Remove \(f.name)"))
                    }
                    .font(.footnote)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color(.secondarySystemFill), in: Capsule())
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
    }

    // пометку «приватно» сервер принимает только с правом set_notes_private и молча отбрасывает без него
    private var mayPrivate: Bool? { model.perms.state("set_notes_private") }
    private var lockedPrivate: Bool { editing?.privateNotes == true && mayPrivate == false }
    private var blocked: Bool { editing == nil && model.draftPrivate && mayPrivate == false }

    @ViewBuilder
    private var privacy: some View {
        if !lockedPrivate && (model.perms.has("set_notes_private") || model.commentPrivate) {
            Toggle(isOn: $model.commentPrivate) { Label("Private note", systemImage: "lock.fill") }
                .toggleStyle(.button)
                .tint(model.commentPrivate ? Color.privateInk : nil)
        } else if lockedPrivate {
            Label("Private note", systemImage: "lock.fill").foregroundStyle(.secondary)
        }
    }

    private var privacyNote: String? {
        if lockedPrivate { return String(localized: "Private comment. You can’t change this flag: it stays private.") }
        if blocked { return String(localized: "You can’t write private notes: the server would publish this comment openly. Remove what must stay private and clear “Private note” to send.") }
        if editing == nil && model.quoteRefused { return String(localized: "The private comment wasn’t quoted: you can’t write private notes, so a reply containing it would be visible to everyone. You can still reply without the quote.") }
        if editing != nil && mayPrivate == nil && (model.editPrivate || editing?.privateNotes == true) { return String(localized: "Couldn’t check whether you may change the “private” flag. If not, the server keeps it as it was.") }
        if editing == nil && mayPrivate == nil && model.draftPrivate { return String(localized: "Couldn’t check whether you may write private notes. If not, the server will publish this comment openly.") }
        return nil
    }
}

/// Файл из «Файлов» с доступом по security scope.
func readFile(_ url: URL) -> PickedFile? {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    guard let data = try? Data(contentsOf: url) else { return nil }
    return PickedFile(name: url.lastPathComponent, data: data, mime: UTType(filenameExtension: url.pathExtension)?.preferredMIMEType)
}

/// Загрузка файлов в задачу без комментария.
struct UploadSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: IssueDetailModel
    @State var files: [PickedFile]
    @State private var description = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(files) { f in
                        LabeledContent(f.name, value: Fmt.size(f.data.count))
                    }
                    .onDelete { files.remove(atOffsets: $0) }
                }
                Section { TextField("Description (optional)", text: $description) }
            }
            .navigationTitle("Add files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton("Upload (\(files.count))", systemImage: "arrow.up") {
                        Task { if await model.uploadFiles(files, description: description, app) { dismiss() } }
                    }
                    .disabled(files.isEmpty || model.busy)
                }
            }
            .overlay { if model.busy { ProgressView().controlSize(.large) } }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Списание времени: новое или правка своего. Дата выбирается, по умолчанию — сегодня.
struct TimeSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: IssueDetailModel
    let entry: TimeEntry?
    @State private var hours = ""
    @State private var activity: Int?
    @State private var comment = ""
    @State private var date = Date()

    private var value: Double? {
        let s = hours.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        // «1:30» — часы и минуты
        if let colon = s.firstIndex(of: ":"), let h = Double(s[..<colon]), let m = Double(s[s.index(after: colon)...]) { return h + m / 60 }
        return Double(s).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                LabeledContent("Hours") {
                    TextField("0", text: $hours).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
                if !model.activities.isEmpty {
                    Picker("Activity", selection: $activity) {
                        ForEach(model.activities) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
                DatePicker("Date", selection: $date, in: ...Date.distantFuture, displayedComponents: .date)
                TextField("Comment", text: $comment, axis: .vertical)
            }
            .navigationTitle(entry == nil ? "Log time" : "Edit time entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton("Save") {
                        guard let v = value else { return }
                        Task {
                            if await model.saveTime(entry, hours: v, activityId: activity, comment: comment, spentOn: Fmt.day(date), app) { dismiss() }
                        }
                    }
                    .disabled(value == nil || model.busy)
                }
            }
            .onAppear {
                if let e = entry {
                    hours = Fmt.hours(e.hours)
                    activity = e.activity?.id
                    comment = e.comments
                    date = Fmt.dayDate(e.spentOn) ?? Date()
                } else {
                    activity = model.activities.first(where: \.isDefault)?.id ?? model.activities.first?.id
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Новая связь: тип, задача (поиск по номеру или теме), задержка для «предшествует/следует».
struct RelationSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let model: IssueDetailModel
    @State private var type = "relates"
    @State private var target: Issue?
    @State private var delay = ""
    @State private var picking = false
    private let types = ["relates", "duplicates", "duplicated", "blocks", "blocked", "precedes", "follows", "copied_to", "copied_from"]

    var body: some View {
        NavigationStack {
            Form {
                Picker("Type", selection: $type) {
                    ForEach(types, id: \.self) { Text(relationLabel($0)).tag($0) }
                }
                Button {
                    picking = true
                } label: {
                    LabeledContent("Issue") {
                        Text(target.map { "#\($0.id) \($0.subject)" } ?? String(localized: "Choose…")).lineLimit(1)
                    }
                }
                if type == "precedes" || type == "follows" {
                    LabeledContent("Delay, days") {
                        TextField("0", text: $delay).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
            }
            .navigationTitle("Add relation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    SheetConfirmButton("Add") {
                        guard let t = target else { return }
                        Task { if await model.addRelation(type: type, to: t.id, delay: Int(delay), app) { dismiss() } }
                    }
                    .disabled(target == nil || model.busy)
                }
            }
            .sheet(isPresented: $picking) {
                let issue = model.issue
                let related = Set((issue?.relations ?? []).flatMap { [$0.issueId, $0.issueToId] } + [model.issueId])
                IssuePicker(title: "Add relation", exclude: related) { target = $0 }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Карточка человека: People (должность, отдел, руководитель) или /users. Руководитель открывается тут же, со «Назад».
struct PersonCard: View {
    let userId: Int

    var body: some View {
        NavigationStack {
            PersonPage(userId: userId, root: true)
                .navigationDestination(for: Int.self) { PersonPage(userId: $0) }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct PersonPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let userId: Int
    /// «Готово» — только у первой карточки: у открытых из неё есть «Назад».
    var root = false
    @State private var person: Person?
    @State private var manager: Person?
    @State private var error: String?

    var body: some View {
        List {
            if let p = person {
                Section {
                    HStack(spacing: 16) {
                        Avatar(name: p.displayName, userId: p.id, size: 64)
                        VStack(alignment: .leading) {
                            Text(p.displayName).font(.title3.bold())
                            if let j = p.jobTitle, !j.isEmpty { Text(j).foregroundStyle(.secondary) }
                        }
                    }
                }
                Section {
                    if let d = p.department?.name { LabeledContent("Department", value: d) }
                    if let m = manager {
                        NavigationLink(value: m.id) {
                            LabeledContent("Manager") {
                                HStack(spacing: 8) {
                                    Text(m.displayName)
                                    Avatar(name: m.displayName, userId: m.id, size: 24)
                                }
                            }
                        }
                    }
                    if let m = p.mailAddr, let u = URL(string: "mailto:\(m)") { LabeledContent("Email") { Link(m, destination: u) } }
                    // spec 11: нажатие звонит, меню — «Копировать»
                    ForEach(p.phones ?? [], id: \.self) { ph in
                        LabeledContent("Phone") {
                            if let u = URL(string: "tel:\(ph.tel)") { Link(ph.text, destination: u) } else { Text(ph.text) }
                        }
                        .contextMenu { Button { copyToPasteboard(ph.text) } label: { Label("Copy", systemImage: "doc.on.doc") } }
                    }
                    if let l = p.login { LabeledContent("Login", value: l).textSelection(.enabled) }
                    if let n = p.personnelNumber, !n.isEmpty { LabeledContent("Personnel No.", value: n) }
                    if let li = p.linkedin, !li.isEmpty, let u = URL(string: li) {
                        LabeledContent("LinkedIn") { Link(li.replacingOccurrences(of: "https://www.linkedin.com/in/", with: "").trimmingCharacters(in: ["/"]), destination: u) }
                    }
                }
                if let bg = p.background, !bg.isEmpty {
                    Section { Text(bg).font(.callout).foregroundStyle(.secondary) }
                }
            } else if let error {
                Text(error).foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
            if let api = app.api, !app.isDemo {
                Link(destination: api.baseURL.appendingPathComponent("people/\(userId)")) {
                    Label("Open profile in Redmine", systemImage: "safari")
                }
            }
        }
        .navigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { if root { ToolbarItem(placement: .cancellationAction) { SheetCloseButton { dismiss() } } } }
        .task {
            guard let refs = app.refs else { return }
            do { person = try await refs.person(userId) } catch { self.error = error.localizedDescription }
            if let mid = person?.managerId, mid != userId { manager = try? await refs.person(mid) }
        }
    }
}

/**
 Выделение текста комментария или описания (1.3): текст как на экране, без разметки. В системном меню
 выделения рядом с «Скопировать» — «Ответить с цитатой». SwiftUI .textSelection не отдаёт выделенное,
 а долгое нажатие на строку занято контекстным меню, поэтому выделение — в своём листе (UITextView).
 */
struct SelectTextSheet: View {
    @Environment(\.dismiss) private var dismiss
    let text: String
    /// false — нет права add_issue_notes, только системные пункты.
    var canQuote = true
    var onQuote: @MainActor (String) -> Void

    var body: some View {
        NavigationStack {
            SelectableText(text: text, onQuote: canQuote ? onQuote : nil)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Select text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { SheetCloseButton { dismiss() } } }
        }
    }
}

private struct SelectableText: UIViewRepresentable {
    let text: String
    var onQuote: (@MainActor (String) -> Void)?

    func makeUIView(context: Context) -> UITextView {
        let v = UITextView()
        v.isEditable = false
        v.font = .preferredFont(forTextStyle: .body)
        v.adjustsFontForContentSizeCategory = true
        v.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        v.backgroundColor = .clear
        v.text = text
        v.delegate = context.coordinator
        return v
    }

    func updateUIView(_ v: UITextView, context: Context) { context.coordinator.onQuote = onQuote }
    func makeCoordinator() -> Coordinator { Coordinator(onQuote: onQuote) }

    @MainActor final class Coordinator: NSObject, UITextViewDelegate {
        var onQuote: (@MainActor (String) -> Void)?
        init(onQuote: (@MainActor (String) -> Void)?) { self.onQuote = onQuote }

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard let onQuote, range.length > 0 else { return nil }
            let selected = (textView.text as NSString).substring(with: range)
            let quote = UIAction(title: String(localized: "Reply with quote"), image: UIImage(systemName: "arrowshape.turn.up.left")) { _ in
                onQuote(selected)
            }
            return UIMenu(children: [quote] + suggestedActions)
        }
    }
}

/// «Согласовано» — зелёной пилюлей, как решённый статус (spec 10).
let approvedStatus: IssueStatus = {
    var s = IssueStatus(id: 0, name: D(), isClosed: D())
    s.name = "Согласовано"
    s.isClosed = true
    return s
}()

/// Карточка строки листа согласования (spec 10): все колонки («—» для пустых), согласующий — карточка человека,
/// «Открыть на сайте» — строка в веб-просмотре с сессией сайта (история и правка).
struct CustomRowSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let table: CustomTable
    let row: Int
    let openSite: (URL) -> Void

    var body: some View {
        let cells = table.rows[row]
        NavigationStack {
            List {
                Section {
                    ForEach(Array(cells.enumerated()), id: \.offset) { j, cell in
                        let column = j < table.columns.count ? table.columns[j] : ""
                        if let id = cell.userId {
                            NavigationLink(value: id) {
                                LabeledContent(column) { PersonLine(person: Named(id: id, name: cell.text), size: 24) }
                            }
                        } else if cell.text == "Согласовано" {
                            LabeledContent(column) { StatusPill(status: approvedStatus, compact: true) }
                        } else {
                            LabeledContent(column, value: cell.text.isEmpty ? "—" : cell.text).textSelection(.enabled)
                        }
                    }
                }
                if let id = table.rowIds.indices.contains(row) ? table.rowIds[row] : nil, let base = app.api?.baseURL, !app.isDemo {
                    Button("Open on website", systemImage: "safari") { openSite(base.appendingPathComponent("custom_entities/\(id)")) }
                }
            }
            .navigationTitle(table.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Int.self) { PersonPage(userId: $0) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
