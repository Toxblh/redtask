import SwiftUI

/// Редактор Textile: системный TextEditor, панель разметки над клавиатурой и предпросмотр.
struct TextileEditor: View {
    @Environment(AppModel.self) private var app
    @Binding var text: String
    var attachments: [Attachment] = []
    /// Файлы черновика — их тоже можно вставить картинкой по имени.
    var pendingNames: [String] = []
    var placeholder: LocalizedStringKey = "Comment"
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
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if focused { formatBar }
                    }
            }
        }
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
            switch p {
            case .mention: PeoplePicker { person in
                if let l = person.login { MentionStore.shared.remember(l, id: person.id, name: person.shortName) }
                apply { TextileEdit.insert($0, $1, "@\(person.login ?? "user#\(person.id)") ") }
            }
            case .issue: IssuePicker(title: "Link to issue") { issue in apply { TextileEdit.insert($0, $1, "#\(issue.id) ") } }
            }
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

/// Поиск человека для упоминания: People ищет по началу имени/фамилии/логина.
struct PeoplePicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let onPick: (Person) -> Void
    @State private var query = ""
    @State private var people: [Person] = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List(people) { p in
                Button {
                    onPick(p)
                    dismiss()
                } label: {
                    HStack {
                        Avatar(name: p.shortName, userId: p.id)
                        VStack(alignment: .leading) {
                            Text(p.displayName.isEmpty ? (p.login ?? "") : p.displayName)
                            if let l = p.login { Text(verbatim: "@\(l)").font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .overlay {
                if people.isEmpty {
                    if let error { ContentUnavailableView("Couldn’t load", systemImage: "exclamationmark.triangle", description: Text(error)) }
                    else if !query.isEmpty { ContentUnavailableView.search(text: query) }
                }
            }
            .navigationTitle("Mention someone")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Name or login"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { SheetCancelButton { dismiss() } } }
            .task(id: query) {
                guard query.count >= 2, let api = app.api else { people = []; return }
                try? await Task.sleep(for: .milliseconds(300))
                do { people = try await api.searchPeople(query, limit: 20); error = nil } catch { if !(error is CancellationError) { self.error = error.localizedDescription } }
            }
        }
        .presentationDetents([.medium, .large])
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
                        Text(verbatim: "#\(i.id) · \(i.status.name)").font(.caption).foregroundStyle(.secondary)
                        Text(i.subject).lineLimit(2)
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
        .presentationDetents([.medium, .large])
    }
}
