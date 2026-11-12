import SwiftUI

/// Редактор Textile: системный TextEditor, панель разметки над клавиатурой и предпросмотр.
struct TextileEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var text: String
    var attachments: [Attachment] = []
    /// Файлы черновика — их тоже можно вставить картинкой по имени.
    var pendingNames: [String] = []
    var placeholder: LocalizedStringKey = "Comment"
    /// Люди задачи — первыми в подсказке «@» (spec 8.1).
    var participants: [Named] = []
    /// Режим предпросмотра снаружи (лист комментария держит переключатель у себя); nil — свой сегмент сверху.
    var previewMode: Binding<Bool>? = nil
    /// Во весь лист (комментарий) — без минимальной высоты строки формы, фокус сразу.
    var fills = false
    @State private var selection: TextSelection?
    @State private var ownPreview = false
    private var preview: Bool { previewMode?.wrappedValue ?? ownPreview }
    @State private var linkAlert = false
    @State private var linkURL = ""
    @State private var linkText = ""
    @State private var picker: Lookup?
    @FocusState private var focused: Bool
    @State private var mentions = MentionSearch()

    #if targetEnvironment(macCatalyst)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    enum Lookup: String, Identifiable { case mention, issue; var id: String { rawValue } }

    var body: some View {
        VStack(spacing: 8) {
            if previewMode == nil {
                SwiftUI.Picker("Mode", selection: $ownPreview) {
                    Text("Write").tag(false)
                    Text("Preview").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if preview {
                ScrollView {
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("Nothing to preview yet").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    } else {
                        RichText(text: text, context: RichContext(attachments: attachments, baseURL: app.api?.baseURL))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: fills ? nil : 160, maxHeight: fills ? .infinity : nil, alignment: .topLeading)
            } else {
                TextEditor(text: $text, selection: $selection)
                    .scrollContentBackground(.hidden) // фон — снаружи (приватная заметка, spec 13)
                    .focused($focused)
                    // ширину — явно: в строке формы редактор иначе сжимается до ширины пары букв
                    .frame(maxWidth: .infinity, minHeight: fills ? nil : 160, maxHeight: fills ? .infinity : nil)
                    .padding(.horizontal, fills ? 12 : 0)
                    // курсор в конце: цитата дописана к черновику — продолжаем после неё
                    .onAppear { if fills { focused = true; setCursor(text.count..<text.count) } }
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(placeholder).foregroundStyle(.tertiary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .onChange(of: text) { old, new in
                        guard new.count == old.count + 1, let c = cursor, let (t, pos) = TextileEdit.continueList(new, cursor: c) else { return }
                        text = t
                        setCursor(pos..<pos)
                    }
                    // панель разметки — полосой над клавиатурой, пока поле в фокусе. Не .toolbar(.keyboard):
                    // прокручиваемый ряд там сжимается до пары кнопок или не показывается вовсе
                    // на Mac панель и подсказка не зависят от фокуса и не меняют размер поля: иначе вставка
                    // сжимает редактор, тот теряет фокус, панель пропадает — и так по кругу (мерцание)
                    .overlay(alignment: .bottom) {
                        if Self.isMac, let q = mentionQ { suggestions(q) }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if Self.isMac || focused {
                            VStack(spacing: 0) {
                                if !Self.isMac, let q = mentionQ { suggestions(q) }
                                formatBar
                            }
                        }
                    }
                    .task(id: mentionQ) { if let q = mentionQ { await mentions.search(q, app: app) } }
            }
        }
        .task(id: participants) { await mentions.resolve(participants, app: app) }
        .alert("Link", isPresented: $linkAlert) {
            TextField("Address", text: $linkURL).keyboardType(.URL).textInputAutocapitalization(.never)
            TextField("Link text (optional)", text: $linkText)
            Button("Insert") {
                let u = linkURL.trimmingCharacters(in: .whitespaces)
                guard !u.isEmpty else { return }
                apply { TextileEdit.insert($0, $1, linkText.isEmpty ? u : "\"\(linkText)\":\(u)") }
                linkURL = ""; linkText = ""
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $picker) { p in
            Group { switch p {
            case .mention: PeoplePicker(search: mentions) { person in
                apply { TextileEdit.insert($0, $1, mentionText(person)) }
            }
            case .issue: IssuePicker(title: "Link to issue") { issue in apply { TextileEdit.insert($0, $1, "#\(issue.id) ") } }
            } }
            .environment(app)
        }
    }

    /// Запрос «@…» у курсора (spec 8.1); в предпросмотре и без курсора — нет.
    private var mentionQ: String? {
        guard !preview, case .selection(let r)? = selection?.indices, r.isEmpty, r.upperBound <= text.endIndex else { return nil }
        return mentionQuery(text, cursor: text.utf16.distance(from: text.startIndex, to: r.upperBound))
    }

    /// Подсказка над клавиатурой: выбор заменяет «@запрос» на «@login ».
    @ViewBuilder
    private func suggestions(_ q: String) -> some View {
        let list = mentions.candidates(q)
        if !list.isEmpty {
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(list) { p in
                        Button {
                            guard let c = cursor else { return }
                            apply { t, _ in TextileEdit.insert(t, (c - q.count - 1)..<c, mentionText(p)) }
                        } label: { MentionRow(person: p).padding(.horizontal, 16).padding(.vertical, 6) }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(list.count) * 44, 180))
            .background(.bar)
        }
    }

    private var formatBar: some View {
        VStack(spacing: 0) {
            Divider()
            toolbarButtons
                .frame(height: 44)
        }
        .background(.bar)
    }

    @ViewBuilder
    private var toolbarButtons: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                tool("Bold", "bold") { TextileEdit.wrap($0, $1, "*", "*") }
                tool("Italic", "italic") { TextileEdit.wrap($0, $1, "_", "_") }
                tool("Strikethrough", "strikethrough") { TextileEdit.wrap($0, $1, "-", "-") }
                tool("Inline code", "chevron.left.forwardslash.chevron.right") { TextileEdit.wrap($0, $1, "@", "@") }
                tool("Code block", "curlybraces") { TextileEdit.wrap($0, $1, "<pre>\n", "\n</pre>") }
                tool("Quote", "text.quote") { TextileEdit.prefixLines($0, $1, "> ") }
                tool("Bulleted list", "list.bullet") { TextileEdit.prefixLines($0, $1, "* ") }
                tool("Numbered list", "list.number") { TextileEdit.prefixLines($0, $1, "# ") }
                tool("Heading", "textformat.size") { TextileEdit.prefixLines($0, $1, "h3. ") }
                Button { linkAlert = true } label: { Label("Link", systemImage: "link") }
                Button { picker = .issue } label: { Label("Link to issue", systemImage: "number") }
                Button { picker = .mention } label: { Label("Mention someone", systemImage: "at") }
                tool("Table", "tablecells") { TextileEdit.insert($0, $1, "\n|_. \(String(localized: "Column")) 1 |_. \(String(localized: "Column")) 2 |\n| | |\n") }
                let images = attachments.filter(\.isImage).map(\.filename) + pendingNames
                if !images.isEmpty {
                    Menu {
                        ForEach(images, id: \.self) { n in
                            Button(n) { apply { TextileEdit.insert($0, $1, "!\(n)!") } }
                        }
                    } label: { Label("Insert image", systemImage: "photo") }
                }
            }
            .labelStyle(.iconOnly)
            .imageScale(.large)
            .frame(minHeight: 44)
            .padding(.horizontal, 12)
        }
    }

    private func tool(_ title: LocalizedStringKey, _ icon: String, _ f: @escaping (String, Range<Int>) -> (String, Range<Int>)) -> some View {
        Button { apply(f) } label: { Label(title, systemImage: icon) }
    }

    /// Выделение в символах (Character) — правки идут массивом символов.
    private var range: Range<Int> {
        guard case .selection(let r)? = selection?.indices,
              r.lowerBound >= text.startIndex, r.upperBound <= text.endIndex else { return text.count..<text.count }
        return text.distance(from: text.startIndex, to: r.lowerBound)..<text.distance(from: text.startIndex, to: r.upperBound)
    }

    private var cursor: Int? {
        guard case .selection(let r)? = selection?.indices, r.upperBound <= text.endIndex else { return nil }
        return text.distance(from: text.startIndex, to: r.upperBound)
    }

    private func apply(_ f: (String, Range<Int>) -> (String, Range<Int>)) {
        let (t, sel) = f(text, range)
        text = t
        setCursor(sel)
        focused = true
    }

    private func setCursor(_ r: Range<Int>) {
        let lo = text.index(text.startIndex, offsetBy: min(r.lowerBound, text.count))
        let hi = text.index(text.startIndex, offsetBy: min(r.upperBound, text.count))
        selection = TextSelection(range: lo..<hi)
    }
}

/// Кнопка «Упомянуть» (spec 8.2): пустое поле — люди задачи, ввод — те же кандидаты, что у подсказки «@».
struct PeoplePicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let search: MentionSearch
    /// Тот же выбор и для «Добавить наблюдателя» (spec 16.1).
    var title: LocalizedStringKey = "Mention someone"
    let onPick: (MentionPerson) -> Void
    @State private var query = ""

    var body: some View {
        let list = search.candidates(query)
        NavigationStack {
            List(list) { p in
                Button {
                    onPick(p)
                    dismiss()
                } label: { MentionRow(person: p) }
                .foregroundStyle(.primary)
            }
            .overlay {
                if list.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Name or login"))
            .textInputAutocapitalization(.never)
            .toolbar { ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } } }
            .task(id: query) { await search.search(query.trimmingCharacters(in: .whitespaces), app: app) }
        }
        .halfSheet()
    }
}

/// Выбор задачи по номеру или теме.
struct IssuePicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    var exclude: Set<Int> = []
    let onPick: (Issue) -> Void
    @State private var query = ""
    @State private var found: [Issue] = []

    var body: some View {
        NavigationStack {
            List(found) { i in
                Button {
                    onPick(i)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            StatusPill(status: i.status, compact: true)
                            Text(verbatim: "#\(i.id)").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(i.subject).lineLimit(2).strikethrough(i.status.isClosed, color: .secondary)
                        if exclude.contains(i.id) { Text("already related").font(.caption).foregroundStyle(.orange) }
                    }
                }
                .foregroundStyle(.primary)
                .disabled(exclude.contains(i.id))
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Issue: number or subject"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } } }
            .task(id: query) {
                guard !query.isEmpty, let api = app.api else { found = []; return }
                try? await Task.sleep(for: .milliseconds(350))
                found = (try? await api.findIssues(query)) ?? []
            }
        }
        .halfSheet()
    }
}
