import Foundation

/*
 Разбор Redmine Textile, блоками как на сайте: абзацы, заголовки, списки `*`/`#`, цитаты `>`/`bq.`
 (вложенность — вложенными блоками), блоки кода, таблицы, картинки, `{{collapse}}`; инлайн — жирный,
 курсив, подчёркнутый, зачёркнутый, код, #задача, #note-N, @упоминание, user#N, ссылки.
 Чистая логика без UI — покрыта тестами (порт RichText.kt из Android-версии).
 */

// MARK: - Регулярные выражения

/// Обёртка NSRegularExpression (ICU): нужны lookbehind и \p{L}, которых нет у Swift Regex.
struct RE: @unchecked Sendable {
    let re: NSRegularExpression
    init(_ pattern: String, caseInsensitive: Bool = false) {
        re = try! NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    struct Match {
        let ns: NSString
        let r: NSTextCheckingResult
        var range: NSRange { r.range }
        var value: String { ns.substring(with: r.range) }
        /// Группа или "" — как groupValues в Kotlin.
        func g(_ i: Int) -> String {
            let gr = r.range(at: i)
            return gr.location == NSNotFound ? "" : ns.substring(with: gr)
        }
    }

    func all(_ s: String) -> [Match] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { Match(ns: ns, r: $0) }
    }
    func first(_ s: String) -> Match? {
        let ns = s as NSString
        return re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)).map { Match(ns: ns, r: $0) }
    }
    func matches(_ s: String) -> Bool {
        guard let m = first(s) else { return false }
        return m.range.location == 0 && m.range.length == (s as NSString).length
    }
    func contains(_ s: String) -> Bool { first(s) != nil }
    func replace(_ s: String, _ template: String) -> String {
        let ns = s as NSString
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }
}

enum Textile {
    // «Буква» — явным юникод-классом; каждый маркер — только на границе слова:
    // URL, почта, пути, «2 + 3 + 4», «C++», my_var остаются как есть.
    static let W = #"\p{L}\p{N}_"#
    static let login = #"[a-zA-Z0-9_](?:[a-zA-Z0-9_.\-]*[a-zA-Z0-9_])?"#

    /// #123, #123#note-5, #123-5 (группы 1 и 2); #note-5 — комментарий текущей задачи (группа 3).
    static let issueRe = RE(#"(?<![\#(W)/#])#(?:(\d+)(?:(?:#note)?-(\d+))?|note-(\d+))(?![\#(W)])"#)
    /// Логин не кончается на «.»/«-»: «@ivanov.» в конце фразы — это ivanov.
    static let mentionRe = RE(#"(?<![\#(W)@])@(\#(login))"#)
    /// user#10333 (группа 1) и user:login (группа 2).
    static let userRefRe = RE(#"(?<![\#(W)/#:.@-])user(?:#(\d+)|:(\#(login)))(?![\#(W)])"#)
    /// "текст":адрес; адрес — абсолютный, mailto: или путь от корня сервера.
    static let linkRe = RE(#""([^"\n]+)":((?:https?|ftp)://[^\s<>"']+|mailto:[^\s<>"']+|/[^\s<>"']*)"#)
    static let urlRe = RE(#"https?://[^\s<>"']+"#)
    static let boldRe = RE(#"(?<![\#(W)*])(\*\*?)(?![\s*])([^*\n]+?)(?<!\s)\1(?![\#(W)*])"#)
    static let italicRe = RE(#"(?<![\#(W)])_(?!\s)([^_\n]+?)(?<!\s)_(?![\#(W)])"#)
    /// -зачёркнутый-: «well-known», «a - b - c», «--force», «2020-01-01» — не разметка; не больше 20 дефисов внутри.
    static let strikeRe = RE(#"(?<![\#(W)-])-(?![\s-])([^-\n]+?(?:(?<=[\#(W)])-(?=[\#(W)])[^-\n]+?){0,20}?)(?<!\s)-(?![\#(W)-])"#)
    static let underlineRe = RE(#"(?<![\#(W)+])\+(?![\s+])([^+\n]+?)(?<!\s)\+(?![\#(W)+])"#)
    static let citeRe = RE(#"(?<![\#(W)?])\?\?(?![\s?])([^?\n]+?)(?<!\s)\?\?(?![\#(W)?])"#)
    static let supRe = RE(#"(?<![\#(W)^])\^([\p{L}\p{N}+\-]+)\^(?![\#(W)^])"#)
    static let subRe = RE(#"(?<![\#(W)~])~([\p{L}\p{N}+\-]+)~(?![\#(W)~])"#)
    /// @код@ — тоже на границе слова; длина <code> ограничена (иначе квадратичный разбор).
    static let codeRe = RE(#"(?<![\#(W)@])@(?!\s)([^@\n]+?)(?<!\s)@(?![\#(W)@])|`([^`\n]+?)`|<code>(.{1,1000}?)</code>"#)
    /// [[Страница]], [[Страница|Текст]], [[проект:Страница]], [[Страница#якорь]].
    static let wikiRe = RE(#"\[\[([^\[\]|\n]+)(?:\|([^\[\]\n]+))?\]\]"#)
    static let macroRe = RE(#"\{\{([<>]?[a-zA-Z_]\w*)(?:\([^)\n]{0,300}\))?\}\}"#)

    static let hrRe = RE(#"^\s*(?:-{3,}|\*{3,})\s*$"#)
    /// Точка обязательна: «h264 codec» — не заголовок.
    static let headingRe = RE(#"^h([1-6])(?:\([^)]*\)|\{[^}]*\}|[<>=]){0,8}\.\s+(.*)"#)
    /// *, **, #, ## — вложенность числом маркеров; «- », «1.» в Textile Redmine — не списки.
    static let listRe = RE(#"^(\s*)([*#]+)\s+(.*)"#)
    static let bqRe = RE(#"^bq\.\s+(.*)"#)
    static let collapseRe = RE(#"^\{\{collapse(?:\(([^)]*)\))?\s*$"#)
    static let tocRe = RE(#"^\s*\{\{[<>]?toc\}\}\s*$"#)
    static let entityRe = RE(#"&(amp|lt|gt|quot|apos|nbsp|#\d{1,7}|#[xX][0-9a-fA-F]{1,6});"#)
    static let preOpenRe = RE(#"<pre(?:\s[^<>]*)?>"#)
    static let codeTagRe = RE(#"</?code(?:\s[^<>]*)?>"#)
    static let cellModRe = RE(#"^((?:_|\\\d+|/\d+|[<>=^~]|\{[^}]*\}){1,8})\.\s*(.*)"#)
    static let cellSpanRe = RE(#"\\(\d+)"#)
    /// !file.png!, !>file.png!, !{width: Npx}.file.png!, !http://…! — имя обязано кончаться расширением картинки.
    static let imageRe = RE(#"(?<![\p{L}\p{N}_!])![<>=]?(?:\{[^}!]*\}|\([^)!]*\))?\.?\s?(https?://[^\s!()]+|[^\s!()/]+\.(?:png|jpe?g|jpe|gif|bmp|webp))\s?(?:\([^)!]*\))?!(?::https?://\S+)?(?![\p{L}\p{N}_])"#, caseInsensitive: true)

    /// Предел вложенности цитат и collapse вместе.
    static let maxQuoteDepth = 8
    static let maxCells = 64
    /// ponytail: строка длиннее — без инлайн-разметки (это лог или base64 одной строкой).
    static let maxInline = 20_000
}

// MARK: - «Инертные» символы

// Содержимое <notextile> и раскодированные HTML-сущности уводим в Private Use Area: ни одна регулярка их не
// узнаёт. unraw возвращает их при выводе.
// ponytail: настоящие символы U+E021..U+E07E в тексте при выводе станут ASCII.

func inert(_ s: String) -> String {
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        if u.value >= 0x21 && u.value <= 0x7E && !(CharacterSet.alphanumerics.contains(u)) {
            out.append(Unicode.Scalar(u.value + 0xE000)!)
        } else { out.append(u) }
    }
    return String(out)
}

func unraw(_ s: String) -> String {
    guard s.unicodeScalars.contains(where: { $0.value >= 0xE021 && $0.value <= 0xE07E }) else { return s }
    var out = String.UnicodeScalarView()
    for u in s.unicodeScalars {
        out.append(u.value >= 0xE021 && u.value <= 0xE07E ? Unicode.Scalar(u.value - 0xE000)! : u)
    }
    return String(out)
}

/// &amp; &lt; &#NNN; &#xHH; → сам символ, инертный для разметки. Неизвестное остаётся как есть.
func decodeEntities(_ s: String) -> String {
    guard s.contains("&") else { return s }
    var out = ""
    var cur = 0
    let ns = s as NSString
    for m in Textile.entityRe.all(s) {
        out += ns.substring(with: NSRange(location: cur, length: m.range.location - cur))
        let e = m.g(1)
        var rep: String?
        switch e {
        case "amp": rep = "&"
        case "lt": rep = "<"
        case "gt": rep = ">"
        case "quot": rep = "\""
        case "apos": rep = "'"
        case "nbsp": rep = "\u{00A0}"
        default:
            let hex = e.dropFirst().first == "x" || e.dropFirst().first == "X"
            let n = hex ? UInt32(e.dropFirst(2), radix: 16) : UInt32(e.dropFirst())
            if let n, n >= 32, let u = Unicode.Scalar(n) { rep = String(Character(u)) }
        }
        out += rep.map(inert) ?? m.value
        cur = m.range.location + m.range.length
    }
    return out + ns.substring(from: cur)
}

// MARK: - Блоки

struct TCell: Equatable, Sendable {
    var text: String
    var header = false
    var span = 1
}

indirect enum TLine: Equatable, Sendable {
    case plain(String)
    case code(String)
    case rule
    /// Цитата целиком; внутри — обычный разбор, вложенная цитата — quote в строках.
    case quote([TLine])
    /// {{collapse(title) … }}; пустой title — подпись по умолчанию.
    case collapse(String, [TLine])
    case heading(Int, String)
    /// number == nil — маркированный пункт.
    case item(depth: Int, number: Int?, text: String)
    case row([TCell])
    case image(String)
}

enum BlockKind: Sendable { case text, table, image, code, list, quote, collapse, rule }

struct TBlock: Equatable, Sendable {
    var kind: BlockKind
    var lines: [TLine]
    /// Перед блоком в исходнике была пустая строка.
    var gap = false
}

/// ponytail: режем по «|» в лоб — «|» внутри @кода@ разобьёт ячейку.
func parseCells(_ line: String) -> [TCell] {
    var t = line.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("|") { t.removeFirst() }
    if t.hasSuffix("|") { t.removeLast() }
    let parts = t.split(separator: "|", maxSplits: Textile.maxCells - 1, omittingEmptySubsequences: false)
    return parts.map { raw in
        let r = raw.trimmingCharacters(in: .whitespaces)
        guard let m = Textile.cellModRe.first(r) else { return TCell(text: r) }
        let mods = m.g(1)
        let span = Textile.cellSpanRe.first(mods).flatMap { Int($0.g(1)) }.map { min(max($0, 1), 20) } ?? 1
        return TCell(text: m.g(2).trimmingCharacters(in: .whitespaces), header: mods.hasPrefix("_") || mods.hasSuffix("_"), span: span)
    }
}

func parseTextile(_ src: String) -> [TLine] {
    parseBlock(notextile(src.replacingOccurrences(of: "\r\n", with: "\n")).components(separatedBy: "\n"), depth: 0)
}

/// <notextile>…</notextile> → инертный текст. Руками: регулярка на тексте из одних открывающих тегов квадратична.
private func notextile(_ s: String) -> String {
    guard s.contains("<notextile>") else { return s }
    var out = ""
    var rest = Substring(s)
    while let open = rest.range(of: "<notextile>") {
        guard let close = rest.range(of: "</notextile>", range: open.upperBound..<rest.endIndex) else { break }
        out += rest[rest.startIndex..<open.lowerBound]
        out += inert(String(rest[open.upperBound..<close.lowerBound]))
        rest = rest[close.upperBound...]
    }
    return out + rest
}

private func parseBlock(_ src: [String], depth: Int) -> [TLine] {
    var out: [TLine] = []
    func nested(_ q: [String]) -> [TLine] {
        depth < Textile.maxQuoteDepth ? parseBlock(q, depth: depth + 1) : q.map { .plain(decodeEntities($0)) }
    }
    var noClose = false // «}}» ниже нет: не ищем его заново на каждой строке «{{collapse»
    var counters = [Int](repeating: 0, count: 8) // счётчик нумерованного списка на каждый уровень
    var fence = false // внутри ```
    var pre = false // внутри <pre>

    func resetCounters(from: Int = 0) { for i in from..<counters.count { counters[i] = 0 } }

    func block(_ line: String) -> TLine {
        if Textile.hrRe.matches(line) { return .rule }
        if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("|") { return .row(parseCells(line)) }
        if let m = Textile.headingRe.first(line) {
            resetCounters()
            return .heading(Int(m.g(1))!, m.g(2).trimmingCharacters(in: .whitespaces))
        }
        // сервер — Textile: «# пункт» это нумерованный список, а не markdown-заголовок
        if let m = Textile.listRe.first(line) {
            let indent = (m.g(1) as NSString).length, marker = m.g(2), body = m.g(3)
            let d = min(marker.count - 1 + indent / 2, counters.count - 1)
            var number: Int?
            if marker.last == "#" { counters[d] += 1; number = counters[d] } else { counters[d] = 0 }
            resetCounters(from: d + 1)
            return .item(depth: d, number: number, text: body)
        }
        return .plain(line)
    }

    func text(_ raw: String) {
        if raw.trimmingCharacters(in: .whitespaces).isEmpty { // пустая строка завершает список
            resetCounters()
            out.append(.plain(""))
            return
        }
        let line = decodeEntities(raw)
        let imgs = Textile.imageRe.all(line)
        if imgs.isEmpty { out.append(block(line)); return }
        let b = block(Textile.imageRe.replace(line, ""))
        if case .plain = b {} else { // пункт списка / строка таблицы: картинки сразу под ней
            out.append(b)
            imgs.forEach { out.append(.image($0.g(1))) }
            return
        }
        // обычный текст режем по макросам — картинка встаёт ровно там, где написана
        let ns = line as NSString
        var cur = 0
        for m in imgs {
            let before = ns.substring(with: NSRange(location: cur, length: m.range.location - cur)).trimmingCharacters(in: .whitespaces)
            if !before.isEmpty { out.append(.plain(before)) }
            out.append(.image(m.g(1)))
            cur = m.range.location + m.range.length
        }
        let after = ns.substring(from: cur).trimmingCharacters(in: .whitespaces)
        if !after.isEmpty { out.append(.plain(after)) }
    }

    func preLine(_ line: String) {
        let end = line.range(of: "</pre>")
        // <pre><code class="ruby"> — тег подсветки не показываем
        let code = Textile.codeTagRe.replace(end.map { String(line[..<$0.lowerBound]) } ?? line, "")
        if !code.isEmpty || line.isEmpty { out.append(.code(code)) }
        if let end {
            pre = false
            let rest = String(line[end.upperBound...])
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty { text(rest) }
        }
    }

    // один уровень «>» и один пробел за ним: «> > x» и «>> x» → «> x»
    func unquote(_ s: String) -> String {
        if depth >= Textile.maxQuoteDepth { return String(s.drop(while: { $0 == ">" || $0 == " " })) }
        var r = s.dropFirst()
        if r.hasPrefix(" ") { r = r.dropFirst() }
        return String(r)
    }

    var i = 0
    while i < src.count {
        let line = src[i]; i += 1
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        if fence {
            if t.hasPrefix("```") { fence = false } else { out.append(.code(line)) }
        } else if pre {
            preLine(line)
        } else if t.hasPrefix("```") {
            let rest = t.dropFirst(3)
            if let close = rest.range(of: "```") { out.append(.code(String(rest[..<close.lowerBound]))) } else { fence = true }
        } else if line.hasPrefix(">") {
            var q = [unquote(line)]
            while i < src.count && src[i].hasPrefix(">") { q.append(unquote(src[i])); i += 1 }
            resetCounters()
            out.append(.quote(nested(q)))
        } else {
            let bq = Textile.bqRe.first(line)
            let collapse = noClose ? nil : Textile.collapseRe.first(line)
            var close = -1
            if collapse != nil {
                close = (i..<src.count).first { src[$0].hasPrefix("}}") } ?? -1
                if close < 0 { noClose = true }
            }
            if let bq { // «bq.» действует на абзац — до пустой строки
                var q = [bq.g(1)]
                while i < src.count && !src[i].trimmingCharacters(in: .whitespaces).isEmpty { q.append(src[i]); i += 1 }
                resetCounters()
                out.append(.quote(nested(q)))
            } else if close >= 0, let collapse {
                let title = collapse.g(1).split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                resetCounters()
                out.append(.collapse(unraw(decodeEntities(title)), nested(Array(src[i..<close]))))
                let rest = String(src[close].dropFirst(2)).trimmingCharacters(in: .whitespaces)
                i = close + 1
                if !rest.isEmpty { text(rest) }
            } else if Textile.tocRe.matches(line) {
                // оглавление не рисуем
            } else if let open = Textile.preOpenRe.first(line) {
                let ns = line as NSString
                let before = ns.substring(to: open.range.location)
                if !before.trimmingCharacters(in: .whitespaces).isEmpty { text(before) }
                pre = true
                let after = ns.substring(from: open.range.location + open.range.length)
                if !after.isEmpty { preLine(after) }
            } else {
                text(line)
            }
        }
    }
    return out
}

private func kindOf(_ l: TLine) -> BlockKind {
    switch l {
    case .plain, .heading: .text
    case .row: .table
    case .code: .code
    case .item: .list
    case .image: .image
    case .quote: .quote
    case .collapse: .collapse
    case .rule: .rule
    }
}

/// Строки → блоки: абзац, список, таблица, код — подряд идущие строки одного вида; пустые строки рвут
/// абзац и становятся gap следующего блока.
func groupBlocks(_ lines: [TLine]) -> [TBlock] {
    let runKinds: Set<BlockKind> = [.text, .table, .code, .list]
    var out: [TBlock] = []
    var open = false
    var gap = false
    for l in lines {
        if case .plain(let s) = l, s.trimmingCharacters(in: .whitespaces).isEmpty {
            gap = !out.isEmpty
            open = false
            continue
        }
        let k = kindOf(l)
        if open && runKinds.contains(k) && out.last?.kind == k {
            out[out.count - 1].lines.append(l)
        } else {
            out.append(TBlock(kind: k, lines: [l], gap: gap))
            open = true
        }
        gap = false
    }
    return out
}

// MARK: - Инлайн

enum InlineStyle: Sendable { case bold, italic, strike, underline, cite, sup, sub }

indirect enum Inline: Equatable, Sendable {
    case text(String)
    case code(String)
    case link(text: String, url: String)
    case issue(text: String, id: Int, note: Int?)
    case note(text: String, number: Int)
    case mention(id: Int, name: String)
    /// user#N, имени которого не знаем — ссылка как написана.
    case person(text: String, id: Int)
    case macro(String)
    /// [[…]]: project nil — текущий проект; title — имя страницы (пробелы → «_»).
    case wiki(project: String?, title: String, label: String)
    case styled(InlineStyle, [Inline])
}

/// Ширины колонок таблицы как в браузере (spec 7, набор table_columns): min — самое длинное слово,
/// max — самая длинная ячейка; не влезает и по min — колонки по min и прокрутка вбок.
func tableColumns(min: [CGFloat], max: [CGFloat], avail: CGFloat) -> (widths: [CGFloat], scroll: Bool) {
    let sumMin = min.reduce(0, +), sumMax = max.reduce(0, +)
    if sumMin > avail { return (min, true) }
    if sumMax <= avail { return (max.map { sumMax > 0 ? $0 * avail / sumMax : avail / CGFloat(max.count) }, false) }
    return (min.indices.map { min[$0] + (avail - sumMin) * (max[$0] - min[$0]) / (sumMax - sumMin) }, false)
}

/// Содержимое [[…]] → ссылка вики (набор wiki_link).
func wikiLink(_ target: String, label: String?) -> Inline {
    var page = Substring(target.trimmingCharacters(in: .whitespaces))
    if let hash = page.firstIndex(of: "#") { page = page[..<hash] }
    var project: String?
    if let colon = page.firstIndex(of: ":") {
        project = String(page[..<colon]).trimmingCharacters(in: .whitespaces)
        page = page[page.index(after: colon)...]
    }
    let name = page.trimmingCharacters(in: .whitespaces)
    let l = label?.trimmingCharacters(in: .whitespaces) ?? ""
    return .wiki(project: project?.isEmpty == false ? project : nil, title: name.replacingOccurrences(of: " ", with: "_"), label: l.isEmpty ? name : l)
}

/// Хвостовая пунктуация — не часть ссылки; «)» срезаем, только если она непарная.
func trimURL(_ u: String) -> String {
    var s = u
    while let last = s.last, ".,;:!?".contains(last) || (last == ")" && s.filter({ $0 == ")" }).count > s.filter({ $0 == "(" }).count) {
        s.removeLast()
    }
    return s
}

private let styleRes: [(RE, Int, InlineStyle)] = [
    (Textile.boldRe, 2, .bold), (Textile.italicRe, 1, .italic), (Textile.strikeRe, 1, .strike),
    (Textile.underlineRe, 1, .underline), (Textile.citeRe, 1, .cite), (Textile.supRe, 1, .sup), (Textile.subRe, 1, .sub),
]

/**
 Строка → инлайн-элементы. «Атомы» (упоминание, ссылка, код, #задача, макрос) внутри не разбираются;
 стили — обёртки, их содержимое разбирается этой же функцией. Побеждает начавшийся левее; при равенстве — атом.
 mentions: login (нижний регистр) → (id, имя).
 */
func parseInline(_ line: String, mentions: [String: (Int, String)] = [:]) -> [Inline] {
    let ns = line as NSString
    if ns.length > Textile.maxInline { return [.text(unraw(line))] }

    struct Span { var range: NSRange; var item: Inline?; var style: InlineStyle?; var inner = "" }
    var spans: [Span] = []
    func free(_ at: Int) -> Bool { !spans.contains { NSLocationInRange(at, $0.range) } }
    func intersects(_ a: NSRange, _ b: NSRange) -> Bool { NSIntersectionRange(a, b).length > 0 }

    for m in Textile.mentionRe.all(line) {
        if let v = mentions[m.g(1).lowercased()] { spans.append(Span(range: m.range, item: .mention(id: v.0, name: v.1))) }
    }
    for m in Textile.userRefRe.all(line) {
        if let id = Int(m.g(1)) {
            if let known = mentions.values.first(where: { $0.0 == id }) { spans.append(Span(range: m.range, item: .mention(id: id, name: known.1))) }
            else { spans.append(Span(range: m.range, item: .person(text: m.value, id: id))) }
        } else if let v = mentions[m.g(2).lowercased()] {
            spans.append(Span(range: m.range, item: .mention(id: v.0, name: v.1)))
        }
    }
    for m in Textile.linkRe.all(line) {
        let raw = m.g(2), u = trimURL(raw)
        if !u.isEmpty {
            let len = m.range.length - ((raw as NSString).length - (u as NSString).length)
            spans.append(Span(range: NSRange(location: m.range.location, length: len), item: .link(text: unraw(m.g(1)), url: unraw(u))))
        }
    }
    for m in Textile.codeRe.all(line) where !spans.contains(where: { intersects($0.range, m.range) }) {
        let body = [m.g(1), m.g(2), m.g(3)].first { !$0.isEmpty } ?? ""
        spans.append(Span(range: m.range, item: .code(unraw(body))))
    }
    for m in Textile.wikiRe.all(line) where free(m.range.location) {
        spans.append(Span(range: m.range, item: wikiLink(unraw(m.g(1)), label: m.g(2).isEmpty ? nil : unraw(m.g(2)))))
    }
    for m in Textile.urlRe.all(line) where free(m.range.location) {
        let u = trimURL(m.value)
        spans.append(Span(range: NSRange(location: m.range.location, length: (u as NSString).length), item: .link(text: unraw(u), url: unraw(u))))
    }
    for m in Textile.issueRe.all(line) where free(m.range.location) {
        if let n = Int(m.g(3)) { spans.append(Span(range: m.range, item: .note(text: m.value, number: n))) }
        else if let id = Int(m.g(1)) { spans.append(Span(range: m.range, item: .issue(text: m.value, id: id, note: Int(m.g(2))))) }
    }
    for m in Textile.macroRe.all(line) where free(m.range.location) {
        spans.append(Span(range: m.range, item: .macro(m.g(1))))
    }
    for (re, group, style) in styleRes {
        for m in re.all(line) { spans.append(Span(range: m.range, style: style, inner: m.g(group))) }
    }

    var out: [Inline] = []
    func put(_ s: String) {
        guard !s.isEmpty else { return }
        let t = unraw(s)
        if case .text(let prev)? = out.last { out[out.count - 1] = .text(prev + t) } else { out.append(.text(t)) }
    }
    var cursor = 0
    // сортировка устойчивая: при равном начале атом (добавлен раньше) идёт раньше стиля
    for s in spans.enumerated().sorted(by: { ($0.element.range.location, $0.offset) < ($1.element.range.location, $1.offset) }).map(\.element) {
        if s.range.location < cursor { continue }
        put(ns.substring(with: NSRange(location: cursor, length: s.range.location - cursor)))
        if let style = s.style { out.append(.styled(style, parseInline(s.inner, mentions: mentions))) }
        else if let item = s.item {
            // оглавление не рисуем
            if case .macro(let name) = item, name.hasSuffix("toc") {} else { out.append(item) }
        }
        cursor = s.range.location + s.range.length
    }
    if cursor < ns.length { put(ns.substring(from: cursor)) }
    return out
}

/// Логины из @упоминаний и user:login (нижний регистр, без повторов, не больше 20) — кого разрешать.
func mentionLogins(_ text: String) -> [String] {
    var out: [String] = []
    var seen = Set<String>()
    for line in text.components(separatedBy: "\n") {
        let code = Textile.codeRe.all(line).map(\.range)
        for m in Textile.mentionRe.all(line) where !code.contains(where: { NSLocationInRange(m.range.location, $0) }) {
            let l = m.g(1).lowercased()
            if seen.insert(l).inserted { out.append(l) }
        }
        for m in Textile.userRefRe.all(line) where !m.g(2).isEmpty {
            let l = m.g(2).lowercased()
            if seen.insert(l).inserted { out.append(l) }
        }
        if out.count >= 20 { break }
    }
    return Array(out.prefix(20))
}

/// Как Attachment.latest_attach в Redmine: имя без учёта регистра, из тёзок — самое свежее.
func resolveAttachment(_ ref: String, _ attachments: [Attachment]) -> Attachment? {
    let decoded = ref.replacingOccurrences(of: "+", with: "%2B").removingPercentEncoding ?? ref
    return attachments
        .filter { $0.filename.caseInsensitiveCompare(ref) == .orderedSame || $0.filename.caseInsensitiveCompare(decoded) == .orderedSame }
        .max { ($0.createdOn, $0.id) < ($1.createdOn, $1.id) }
}

/**
 Ответ с цитатой, как у веб-версии: «Имя писал(а) в #note-N:» (комментарий) или «Имя писал(а):» (описание),
 «> » на каждой строке. Пустое выделение — nil. lang — «ru» или английский.
 */
func quoteReply(author: String, note: Int?, text: String, lang: String) -> String? {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if body.isEmpty { return nil }
    let ru = lang.hasPrefix("ru")
    let head = note.map { "\(ru ? "писал(а) в" : "wrote in") #note-\($0)" } ?? (ru ? "писал(а)" : "wrote")
    return "\(author) \(head):\n" + body.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? ">" : "> \($0)" }.joined(separator: "\n") + "\n\n"
}

/// Язык шапки цитаты — язык интерфейса.
var quoteLang: String { Bundle.main.preferredLocalizations.first ?? "en" }

/// Текст без разметки, как он виден на экране (для выделения и частичной цитаты): картинки пропускаются.
func plainText(_ src: String, mentions: [String: (Int, String)] = [:]) -> String {
    func inline(_ items: [Inline]) -> String {
        items.map { i -> String in
            switch i {
            case .text(let s), .code(let s), .macro(let s): s
            case .link(let t, _), .issue(let t, _, _), .note(let t, _), .person(let t, _), .wiki(_, _, let t): t
            case .mention(_, let name): name
            case .styled(_, let inner): inline(inner)
            }
        }.joined()
    }
    func lines(_ ls: [TLine]) -> [String] {
        ls.flatMap { l -> [String] in
            switch l {
            case .plain(let s), .heading(_, let s): [inline(parseInline(s, mentions: mentions))]
            case .code(let s): [unraw(s)]
            case .item(let d, let n, let t): [String(repeating: "  ", count: d) + (n.map { "\($0). " } ?? "• ") + inline(parseInline(t, mentions: mentions))]
            case .row(let cells): [cells.map { inline(parseInline($0.text, mentions: mentions)) }.joined(separator: "\t")]
            case .quote(let q): lines(q)
            case .collapse(let title, let q): (title.isEmpty ? [] : [title]) + lines(q)
            case .rule, .image: []
            }
        }
    }
    return lines(parseTextile(src)).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Превью комментария без разметки Textile (для уведомлений): «!img.png!» → «img.png», «bq. текст» → «текст».
func notePreview(_ note: String) -> String {
    var s = RE(#"</?(?:pre|code|notextile)[^>]*>"#).replace(note, "")
    s = RE(#"!(?:\{[^}]*\})?([^!\s]+)!"#).replace(s, "$1")
    s = RE(#""([^"\n]+)":\S+"#).replace(s, "$1")
    s = RE(#"(?m)^\s*(?:(?:bq|p|pre|h[1-6])\.\s+|>+\s?|[*#]+\s+)"#).replace(s, "")
    s = RE(#"(?<![\p{L}\p{N}])([*_@])(\S(?:[^\n]*?\S)?)\1(?![\p{L}\p{N}])"#).replace(s, "$2")
    s = RE(#"\s+"#).replace(s, " ").trimmingCharacters(in: .whitespaces)
    return String(s.prefix(140))
}

/// Упомянут ли login в тексте: «@логин» целиком и без учёта регистра.
func textMentions(_ notes: String?, login: String) -> Bool {
    guard !login.isEmpty, let notes, !notes.isEmpty else { return false }
    return Textile.mentionRe.all(notes).contains { $0.g(1).caseInsensitiveCompare(login) == .orderedSame }
}

// MARK: - Правки в редакторе

/// Правки разметки над выделением — чистая логика (покрыта тестами).
enum TextileEdit {
    /// Обернуть выделение маркерами; пустое выделение — маркеры и курсор между ними.
    static func wrap(_ text: String, _ sel: Range<Int>, _ open: String, _ close: String) -> (String, Range<Int>) {
        var chars = Array(text)
        let inner = chars[sel]
        chars.replaceSubrange(sel, with: Array(open) + inner + Array(close))
        let start = sel.lowerBound + open.count
        return (String(chars), start..<(start + inner.count))
    }

    /// Префикс в начало каждой строки выделения («* », «# », «> », «h3. »).
    static func prefixLines(_ text: String, _ sel: Range<Int>, _ prefix: String) -> (String, Range<Int>) {
        var chars = Array(text)
        var lineStart = sel.lowerBound
        while lineStart > 0 && chars[lineStart - 1] != "\n" { lineStart -= 1 }
        var i = lineStart
        var end = sel.upperBound
        var added = 0
        while true {
            chars.insert(contentsOf: Array(prefix), at: i)
            added += prefix.count
            end += prefix.count
            guard let nl = chars[i..<end].firstIndex(of: "\n"), nl + 1 < end else { break }
            i = nl + 1
        }
        return (String(chars), (sel.lowerBound + prefix.count)..<(sel.upperBound + added))
    }

    /// Вставка в позицию курсора (заменяя выделение).
    static func insert(_ text: String, _ sel: Range<Int>, _ s: String) -> (String, Range<Int>) {
        var chars = Array(text)
        chars.replaceSubrange(sel, with: Array(s))
        let pos = sel.lowerBound + s.count
        return (String(chars), pos..<pos)
    }

    /**
     Enter в пункте списка продолжает список тем же маркером; Enter в пустом пункте — заканчивает список.
     newText — текст после ввода «\n», cursor — позиция сразу после него. nil — список ни при чём.
     */
    static func continueList(_ newText: String, cursor: Int) -> (String, Int)? {
        let chars = Array(newText)
        guard cursor > 0, cursor <= chars.count, chars[cursor - 1] == "\n" else { return nil }
        var start = cursor - 1
        while start > 0 && chars[start - 1] != "\n" { start -= 1 }
        let prev = String(chars[start..<(cursor - 1)])
        guard let m = RE(#"^(\s*(?:[*#]+|>)\s+)(.*)$"#).first(prev) else { return nil }
        let marker = m.g(1)
        var out = chars
        if m.g(2).trimmingCharacters(in: .whitespaces).isEmpty {
            // пустой пункт: убираем маркер и лишний перевод строки
            out.removeSubrange(start..<cursor)
            return (String(out), start)
        }
        out.insert(contentsOf: Array(marker), at: cursor)
        return (String(out), cursor + marker.count)
    }
}

