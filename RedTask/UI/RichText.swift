import SwiftUI
import UIKit

/// Внутренние ссылки текста: задача, комментарий этой задачи, человек.
enum RichLink {
    static let scheme = "redtask-app"
    static func issue(_ id: Int, note: Int?) -> URL { URL(string: "\(scheme)://issue/\(id)" + (note.map { "?note=\($0)" } ?? ""))! }
    static func note(_ n: Int) -> URL { URL(string: "\(scheme)://note/\(n)")! }
    static func user(_ id: Int) -> URL { URL(string: "\(scheme)://user/\(id)")! }

    enum Target { case issue(Int, Int?), note(Int), user(Int) }
    static func parse(_ url: URL) -> Target? {
        guard url.scheme == scheme, let host = url.host, let n = Int(url.lastPathComponent) else { return nil }
        switch host {
        case "issue":
            let note = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "note" }?.value.flatMap(Int.init)
            return .issue(n, note)
        case "note": return .note(n)
        case "user": return .user(n)
        default: return nil
        }
    }
}

/// Упоминания: логин → (id, имя). Разрешаются лениво через People и запоминаются на сессию.
@MainActor @Observable
final class MentionStore {
    static let shared = MentionStore()
    private(set) var known: [String: (Int, String)] = [:]
    private var tried = Set<String>()

    func remember(_ login: String, id: Int, name: String) { known[login.lowercased()] = (id, name) }

    func resolve(_ logins: [String], refs: RefData?) async {
        guard let refs else { return }
        for l in logins where known[l] == nil && !tried.contains(l) {
            tried.insert(l)
            if let p = await refs.personByLogin(l) {
                known[l] = (p.id, p.shortName.isEmpty ? l : p.shortName)
            } else {
                // сбой сети или капча — попробуем при следующем показе; честный «нет такого» RefData помнит сам
                tried.remove(l)
            }
        }
    }

    func clear() { known = [:]; tried = [] }
}

/// Аватары упоминаний для вставки в текст: маленькие круглые картинки, нарисованные заранее.
@MainActor @Observable
final class InlineAvatars {
    static let shared = InlineAvatars()
    private(set) var images: [Int: UIImage] = [:]
    private var loading = Set<Int>()

    func load(_ ids: [Int], app: AppModel) async {
        guard let api = app.api else { return }
        for id in ids where images[id] == nil && !loading.contains(id) {
            loading.insert(id)
            if let img = await ImageStore.shared.avatar(id, api: api, account: app.account) {
                let side: CGFloat = 18
                images[id] = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
                    UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
                    // по короткой стороне, как scaledToFill: неквадратное фото не сплющивается
                    let k = side / max(1, min(img.size.width, img.size.height))
                    let w = img.size.width * k, h = img.size.height * k
                    img.draw(in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
                }
            }
        }
    }
}

/// Окружение текста: вложения задачи (для картинок по имени) и сервер (для относительных ссылок).
struct RichContext {
    var attachments: [Attachment] = []
    var baseURL: URL?
    var onOpenAttachment: (Attachment) -> Void = { _ in }
}

/// Рендер Textile блоками. Ссылки уходят в openURL окружения; внутренние — схема redtask-app.
struct RichText: View {
    @Environment(AppModel.self) private var app
    let text: String
    var context = RichContext()
    var muted = false
    private var mentions: MentionStore { .shared }

    var body: some View {
        BlocksView(blocks: groupBlocks(parseTextile(text)), ctx: context, muted: muted)
            .task(id: text) {
                let logins = mentionLogins(text)
                await mentions.resolve(logins, refs: app.refs)
                let ids = logins.compactMap { mentions.known[$0]?.0 }
                await InlineAvatars.shared.load(ids, app: app)
            }
    }
}

private struct BlocksView: View {
    let blocks: [TBlock]
    let ctx: RichContext
    var muted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                BlockView(block: b, ctx: ctx, muted: muted)
                    .padding(.top, i == 0 ? 0 : gap(blocks[i - 1], b))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Абзац — 10, вокруг «коробок» (цитата, код, collapse, линия) — 6, иначе вплотную.
    private func gap(_ prev: TBlock, _ cur: TBlock) -> CGFloat {
        let boxed: Set<BlockKind> = [.code, .quote, .collapse, .rule]
        if cur.gap { return 10 }
        return boxed.contains(prev.kind) || boxed.contains(cur.kind) ? 6 : 0
    }
}

private struct BlockView: View {
    let block: TBlock
    let ctx: RichContext
    let muted: Bool

    var body: some View {
        switch block.kind {
        case .text:
            InlineText(lines: block.lines, ctx: ctx, muted: muted)
        case .list:
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(block.lines.enumerated()), id: \.offset) { _, l in
                    if case .item(let depth, let number, let text) = l {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(number.map { "\($0)." } ?? "•").frame(minWidth: 16, alignment: .trailing)
                            InlineText(lines: [.plain(text)], ctx: ctx, muted: muted)
                        }
                        .padding(.leading, CGFloat(4 + 16 * depth))
                        .foregroundStyle(muted ? .secondary : .primary)
                    }
                }
            }
        case .quote:
            if case .quote(let lines) = block.lines.first {
                // полоса — накладкой: высоту задаёт только текст (в HStack List давал пустоту сверху и снизу)
                BlocksView(blocks: groupBlocks(lines), ctx: ctx, muted: true)
                    .padding(.vertical, 6).padding(.leading, 13).padding(.trailing, 8)
                    .overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 3) }
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        case .collapse:
            if case .collapse(let title, let lines) = block.lines.first {
                DisclosureGroup(title.isEmpty ? String(localized: "Show details") : title) {
                    BlocksView(blocks: groupBlocks(lines), ctx: ctx, muted: muted).padding(.top, 4)
                }
            }
        case .code:
            ScrollView(.horizontal) {
                Text(unraw(block.lines.map { if case .code(let s) = $0 { s } else { "" } }.joined(separator: "\n")))
                    .font(.system(.footnote, design: .monospaced))
                    .fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        case .rule:
            Divider().padding(.vertical, 4)
        case .image:
            if case .image(let ref) = block.lines.first { InlineImage(ref: ref, ctx: ctx) }
        case .table:
            TableBlock(rows: block.lines.compactMap { if case .row(let c) = $0 { c } else { nil } }, ctx: ctx)
        }
    }
}

/// Таблица сеткой; шире 4 колонок — прокрутка вбок.
private struct TableBlock: View {
    let rows: [[TCell]]
    let ctx: RichContext

    var body: some View {
        // До 4 колонок — по ширине экрана; шире — прокрутка вбок с колонками фиксированной ширины
        // (Grid в горизонтальной прокрутке не учитывает перенос текста в высоте строки).
        // Заливки строк нет: в Grid фон ложится на каждую ячейку по высоте её текста.
        let wide = (rows.map { $0.reduce(0) { $0 + $1.span } }.max() ?? 0) > 4
        let grid = Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                        InlineText(lines: [.plain(cell.text)], ctx: ctx, muted: false, bold: cell.header)
                            .frame(width: wide ? 160 * CGFloat(cell.span) : nil, alignment: .leading)
                            .frame(maxWidth: wide ? nil : .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .gridCellColumns(cell.span)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(.separator)))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        if wide { ScrollView(.horizontal) { grid } } else { grid }
    }
}

/// Текстовый блок: строки абзаца/заголовки с инлайн-разметкой, ссылками и аватарами упоминаний.
struct InlineText: View {
    let lines: [TLine]
    let ctx: RichContext
    let muted: Bool
    var bold = false
    private var mentions: MentionStore { .shared }
    private var avatars: InlineAvatars { .shared }

    var body: some View {
        render()
            .font(.body)
            .fontWeight(bold ? .semibold : nil)
            .foregroundStyle(muted ? .secondary : .primary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func render() -> Text {
        var out = Text("")
        for (i, line) in lines.enumerated() {
            switch line {
            case .heading(let level, let s):
                let t = text(parseInline(s, mentions: mentions.known))
                out = Text("\(out)\(t.font(level == 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline))")
            case .plain(let s):
                out = Text("\(out)\(text(parseInline(s, mentions: mentions.known)))")
            default: break
            }
            if i < lines.count - 1 { out = Text("\(out)\n") }
        }
        return out
    }

    private func text(_ items: [Inline]) -> Text {
        var out = Text("")
        var attr = AttributedString()
        func flush() {
            if !attr.characters.isEmpty { out = Text("\(out)\(Text(attr))"); attr = AttributedString() }
        }
        for item in items {
            switch item {
            case .mention(let id, let name):
                flush()
                var a = AttributedString(" " + name)
                a.link = RichLink.user(id)
                a.inlinePresentationIntent = .stronglyEmphasized
                let icon: Text = avatars.images[id].map { Text(Image(uiImage: $0)).baselineOffset(-3) }
                    ?? Text(Image(systemName: "person.crop.circle.fill"))
                out = Text("\(out)\(icon)\(Text(a))")
            default:
                attr += attributed(item)
            }
        }
        flush()
        return out
    }

    private func attributed(_ item: Inline) -> AttributedString {
        switch item {
        case .text(let s):
            return AttributedString(s)
        case .code(let s):
            var a = AttributedString(s)
            a.inlinePresentationIntent = .code
            a.backgroundColor = Color(.tertiarySystemFill)
            return a
        case .link(let text, let url):
            var a = AttributedString(text)
            a.link = resolve(url)
            a.underlineStyle = .single
            return a
        case .issue(let text, let id, let note):
            var a = AttributedString(text)
            a.link = RichLink.issue(id, note: note)
            return a
        case .note(let text, let n):
            var a = AttributedString(text)
            a.link = RichLink.note(n)
            return a
        case .person(let text, let id):
            var a = AttributedString(text)
            a.link = RichLink.user(id)
            return a
        case .mention(_, let name):
            return AttributedString(name)
        case .macro(let name):
            var a = AttributedString(name)
            a.foregroundColor = .secondary
            return a
        case .styled(let style, let inner):
            var a = inner.map(attributed).reduce(AttributedString(), +)
            switch style {
            case .bold: a.inlinePresentationIntent = .stronglyEmphasized
            case .italic, .cite: a.inlinePresentationIntent = .emphasized
            case .strike: a.strikethroughStyle = .single
            case .underline: a.underlineStyle = .single
            case .sup: a.baselineOffset = 6; a.font = .caption
            case .sub: a.baselineOffset = -3; a.font = .caption
            }
            return a
        }
    }

    /// Относительная ссылка "текст":/путь — от корня сервера.
    private func resolve(_ s: String) -> URL? {
        if s.hasPrefix("/"), let base = ctx.baseURL {
            var c = URLComponents(url: base, resolvingAgainstBaseURL: false)
            c?.path = s.split(separator: "?").first.map(String.init) ?? s
            return c?.url ?? URL(string: s)
        }
        return URL(string: s)
    }
}

/// Картинка из текста: вложение по имени или URL; тап — предпросмотр вложения.
struct InlineImage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    let ref: String
    let ctx: RichContext
    @State private var image: UIImage?
    @State private var failed = false

    private var attachment: Attachment? { resolveAttachment(ref, ctx.attachments) }
    private var url: String? {
        if let a = attachment, !a.contentUrl.isEmpty { return a.contentUrl }
        return ref.lowercased().hasPrefix("http") ? ref : nil
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: min(image.size.width, 900), alignment: .leading)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel(Text(ref))
            } else {
                Label(attachment?.filename ?? ref, systemImage: failed || url == nil ? "photo.badge.exclamationmark" : "photo")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(alignment: .trailing) { if !failed && url != nil { ProgressView().padding(.trailing, -24) } }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let a = attachment { ctx.onOpenAttachment(a) } else if let u = url.flatMap(URL.init(string:)) { openURL(u) }
        }
        .task(id: url) {
            guard let url, let api = app.api else { return }
            image = await ImageStore.shared.image(url, api: api, account: app.account)
            failed = image == nil
        }
    }
}
