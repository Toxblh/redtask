import Foundation

// MARK: - Терпимый разбор JSON

/// Значение по умолчанию для поля, которого нет в ответе (или оно null, или другого типа).
protocol Defaultable { static var defaultValue: Self { get } }
extension Array: Defaultable { static var defaultValue: Self { [] } }
extension String: Defaultable { static var defaultValue: String { "" } }
extension Bool: Defaultable { static var defaultValue: Bool { false } }
extension Int: Defaultable { static var defaultValue: Int { 0 } }
extension Dictionary: Defaultable { static var defaultValue: Self { [:] } }

/// Поле со значением по умолчанию: сервер разных версий отдаёт разный набор полей,
/// а падение разбора из‑за одного отсутствующего ключа — это пустой экран.
@propertyWrapper
struct D<T: Codable & Sendable & Hashable & Defaultable>: Codable, Sendable, Hashable {
    var wrappedValue: T
    init(wrappedValue: T) { self.wrappedValue = wrappedValue }
    init() { wrappedValue = T.defaultValue }
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        wrappedValue = (try? c.decode(T.self)) ?? T.defaultValue
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    func decode<T>(_ type: D<T>.Type, forKey key: Key) throws -> D<T> {
        try decodeIfPresent(type, forKey: key) ?? D()
    }
}

/// Произвольное значение JSON — настраиваемые поля бывают строкой, массивом строк или null.
enum JSONValue: Codable, Sendable, Hashable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// Значения строками: одиночное — 0..1 элемент, массив — сколько выбрано.
    var strings: [String] {
        switch self {
        case .string(let s): return s.isEmpty ? [] : [s]
        case .number(let n): return [n.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(n)) : String(n)]
        case .bool(let b): return [b ? "1" : "0"]
        case .array(let a): return a.flatMap(\.strings).filter { !$0.isEmpty }
        default: return []
        }
    }

    var isArray: Bool { if case .array = self { return true } else { return false } }

    var display: String { strings.joined(separator: ", ") }
}

// MARK: - Модели Redmine

struct Named: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    init(id: Int, name: String = "") { self.id = id; self.name = name }
}

struct IssueStatus: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var isClosed: Bool
}

/// Вид статуса для цвета — как на Android (три слоя, от точного к общему).
enum StatusKind: String, Sendable { case todo, inProgress = "in_progress", done, rejected }

extension IssueStatus {
    /// Точечные исключения по полному имени — побеждают эвристику.
    private static let overrides: [String: StatusKind] = [
        "Заявка обработана": .inProgress, "Заявка согласована": .inProgress,
        "Отчислен с курса": .rejected, "Заблокирован": .rejected, "Прекращено": .rejected,
    ]
    private static let rejectedRe = "отклон|отказ|reject|cancel|аннул|закрыт без|не принят|недейств|упущено|неуспешно"
    private static let todoRe = "^(нов|созд|черновик|драфт|бэклог|backlog|to.?do|open|new|лид|1% лид|заявка|ожидание приёма)"

    var kind: StatusKind {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let k = Self.overrides[n] { return k }
        func has(_ re: String) -> Bool { n.range(of: re, options: [.regularExpression, .caseInsensitive]) != nil }
        if has(Self.rejectedRe) { return .rejected }
        if isClosed { return .done }
        if has(Self.todoRe) { return .todo }
        return .inProgress
    }
}

struct Priority: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var isDefault: Bool
    var active: Bool?
}

struct Tracker: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
}

struct Project: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var identifier: String
    var description: String?
    var parent: Named?
    var status: Int?
    var homepage: String?
    @D var trackers: [Tracker]
    /// Только с include=enabled_modules; nil — не спрашивали.
    var enabledModules: [Named]?
    @D var issueCustomFields: [Named]
    init(id: Int, name: String = "") { self.id = id; self.name = name }
}

struct Version: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    var status: String?
    var dueDate: String?
    var description: String?
    var project: Named?
}

struct CustomField: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    var value: JSONValue?
    @D var multiple: Bool
    var values: [String] { value?.strings ?? [] }
}

struct CustomFieldOption: Codable, Sendable, Hashable {
    @D var value: String
    @D var label: String
}

/// Описание настраиваемого поля из /custom_fields.json (не-админу обычно 403).
struct CustomFieldDef: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var customizedType: String
    @D var fieldFormat: String
    @D var isRequired: Bool
    @D var multiple: Bool
    @D var possibleValues: [CustomFieldOption]
    var defaultValue: String?
    @D var trackers: [Named]
}

struct JournalDetail: Codable, Sendable, Hashable {
    @D var property: String
    @D var name: String
    var oldValue: String?
    var newValue: String?
}

struct Journal: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var user: Named?
    var notes: String?
    @D var createdOn: String
    var updatedOn: String?
    @D var privateNotes: Bool
    @D var details: [JournalDetail]
}

struct Attachment: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var filename: String
    @D var filesize: Int
    var contentType: String?
    @D var contentUrl: String
    var author: Named?
    @D var createdOn: String
    var description: String?
    var thumbnailUrl: String?

    var isImage: Bool {
        if let t = contentType, t.hasPrefix("image/") { return true }
        let ext = (filename as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "heic", "bmp"].contains(ext)
    }
}

struct ChildIssue: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var tracker: Named?
    @D var subject: String
}

struct Relation: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var issueId: Int
    var issueToId: Int
    @D var relationType: String
    var delay: Int?
}

struct IDRef: Codable, Sendable, Hashable { var id: Int }

struct Issue: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var project: Named
    var tracker: Named
    var status: IssueStatus
    var priority: Named
    var author: Named
    var assignedTo: Named?
    var category: Named?
    var fixedVersion: Named?
    var parent: IDRef?
    @D var subject: String
    var description: String?
    var startDate: String?
    var dueDate: String?
    @D var doneRatio: Int
    @D var isPrivate: Bool
    var estimatedHours: Double?
    var totalEstimatedHours: Double?
    var spentHours: Double?
    var totalSpentHours: Double?
    @D var customFields: [CustomField]
    @D var createdOn: String
    @D var updatedOn: String
    var closedOn: String?
    @D var journals: [Journal]
    @D var attachments: [Attachment]
    @D var children: [ChildIssue]
    @D var relations: [Relation]
    @D var watchers: [Named]
    var allowedStatuses: [IssueStatus]?
}

struct User: Codable, Sendable, Hashable {
    var id: Int
    @D var login: String
    @D var firstname: String
    @D var lastname: String
    var mail: String?
    var apiKey: String?
    @D var admin: Bool
    var displayName: String {
        let n = [firstname, lastname].filter { !$0.isEmpty }.joined(separator: " ")
        return n.isEmpty ? login : n
    }
}

struct Membership: Codable, Sendable, Hashable {
    var id: Int
    var user: Named?
    var group: Named?
    @D var roles: [Named]
    var project: Named?
}

/// Мои роли в компактном виде для кэша: проект → id ролей (сырой ответ — больше мегабайта).
struct MyRoles: Codable, Sendable, Hashable {
    var admin: Bool
    var roles: [Int: [Int]]
}

struct Role: Codable, Sendable, Hashable { @D var id: Int; @D var name: String; @D var permissions: [String] }

struct TimeEntryActivity: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var isDefault: Bool
    var active: Bool?
}

struct TimeEntry: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var user: Named?
    var activity: Named?
    var hours: Double?
    @D var comments: String
    @D var spentOn: String
    var project: Named?
    var issue: IDRef?
    @D var createdOn: String
}

/// Загруженный файл: токен для вложения к задаче/комментарию.
struct UploadRef: Sendable, Hashable {
    var token: String
    var filename: String
    var contentType: String?
    var description: String?
}

/// Профиль: плагин People (должность/отдел), иначе /users. Имена полей на разных серверах разные.
struct Person: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var login: String?
    var email: String?
    var mail: String?
    @D var firstname: String
    var middlename: String?
    @D var lastname: String
    var firstName: String?
    var lastName: String?
    var jobTitle: String?
    var department: Named?
    var personnelNumber: String?
    var managerId: Int?
    var linkedin: String?
    var background: String?

    init(id: Int, login: String? = nil, firstname: String = "", lastname: String = "") {
        self.id = id; self.login = login; self.firstname = firstname; self.lastname = lastname
    }

    var first: String { firstname.isEmpty ? (firstName ?? "") : firstname }
    var last: String { lastname.isEmpty ? (lastName ?? "") : lastname }
    var mailAddr: String? { email ?? mail }
    var displayName: String { [first, middlename ?? "", last].filter { !$0.isEmpty }.joined(separator: " ") }
    /// «Имя Фамилия» — для упоминаний, без отчества.
    var shortName: String { [first, last].filter { !$0.isEmpty }.joined(separator: " ") }
}

struct SearchResult: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var title: String
    @D var type: String
    @D var url: String
    @D var description: String
    @D var datetime: String
}

extension SearchResult {
    /// «Ошибка #123 (В работе): тема» → «Ошибка #123», статус, тема; у задачи в выдаче поиска статус — только в заголовке.
    var issueParts: (head: String, status: IssueStatus, subject: String)? {
        guard type.hasPrefix("issue"), let m = title.firstMatch(of: /^(.*?#\d+) \((.+?)\): (.*)$/) else { return nil }
        var st = IssueStatus(id: 0, name: D(), isClosed: D())
        st.name = String(m.2)
        st.isClosed = type == "issue-closed"
        return (String(m.1), st, String(m.3))
    }
}

struct WikiParent: Codable, Sendable, Hashable { @D var title: String }

struct WikiPageInfo: Codable, Sendable, Hashable, Identifiable {
    @D var title: String
    var parent: WikiParent?
    var version: Int?
    @D var updatedOn: String
    var id: String { title }
}

struct WikiPage: Codable, Sendable, Hashable {
    @D var title: String
    @D var text: String
    var version: Int?
    var author: Named?
    @D var updatedOn: String
    @D var attachments: [Attachment]
}

/// Страницы вики деревом по parent: корни и дети по имени, с глубиной. Страница с неизвестным родителем — корень.
func wikiTree(_ pages: [WikiPageInfo]) -> [(page: WikiPageInfo, depth: Int)] {
    let titles = Set(pages.map(\.title))
    let kids = Dictionary(grouping: pages) { p in p.parent.map(\.title).flatMap { titles.contains($0) ? $0 : nil } ?? "" }
    var out: [(page: WikiPageInfo, depth: Int)] = []
    var seen = Set<String>()
    func walk(_ parent: String, _ depth: Int) {
        for p in (kids[parent] ?? []).sorted(by: { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) where seen.insert(p.title).inserted {
            out.append((p, depth))
            walk(p.title, depth + 1)
        }
    }
    walk("", 0)
    return out
}

// MARK: - Конверты ответов

struct IssuesResponse: Codable, Sendable { @D var issues: [Issue]; @D var totalCount: Int }
struct IssueResponse: Codable, Sendable { var issue: Issue }
struct AttachmentResponse: Codable, Sendable { var attachment: Attachment }
struct ProjectsResponse: Codable, Sendable { @D var projects: [Project]; @D var totalCount: Int }
struct ProjectResponse: Codable, Sendable { var project: Project }
struct UserResponse: Codable, Sendable { var user: User }
struct StatusesResponse: Codable, Sendable { @D var issueStatuses: [IssueStatus] }
struct PrioritiesResponse: Codable, Sendable { @D var issuePriorities: [Priority] }
struct TrackersResponse: Codable, Sendable { @D var trackers: [Tracker] }
struct VersionsResponse: Codable, Sendable { @D var versions: [Version] }
struct WikiIndexResponse: Codable, Sendable { @D var wikiPages: [WikiPageInfo] }
struct WikiPageResponse: Codable, Sendable { var wikiPage: WikiPage }
struct FilesResponse: Codable, Sendable { @D var files: [Attachment] }
struct MembershipsResponse: Codable, Sendable { @D var memberships: [Membership]; @D var totalCount: Int }
struct ActivitiesResponse: Codable, Sendable { @D var timeEntryActivities: [TimeEntryActivity] }
struct TimeEntriesResponse: Codable, Sendable { @D var timeEntries: [TimeEntry]; @D var totalCount: Int }
struct SearchResponse: Codable, Sendable { @D var results: [SearchResult]; @D var totalCount: Int }
struct CategoriesResponse: Codable, Sendable { @D var issueCategories: [Named] }
struct CustomFieldsResponse: Codable, Sendable { @D var customFields: [CustomFieldDef] }
struct ErrorsResponse: Codable, Sendable { @D var errors: [String] }
struct RoleResponse: Codable, Sendable { var role: Role }
struct PeopleResponse: Codable, Sendable { var person: Person }
struct PeopleListResponse: Codable, Sendable { @D var people: [Person] }
struct MeWithMemberships: Codable, Sendable { @D var admin: Bool; @D var memberships: [Membership] }
struct MeWithMembershipsResponse: Codable, Sendable { var user: MeWithMemberships }
struct UploadResponse: Codable, Sendable { struct U: Codable, Sendable { var token: String }; var upload: U }

// MARK: - Общий JSON

enum JSON {
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }
}

extension Tracker { init(id: Int, name: String) { self.id = id; self.name = name } }
extension Priority { init(id: Int, name: String) { self.id = id; self.name = name } }

// MARK: - Правила спецификации (spec/PARITY.md, наборы spec/vectors.json)

/// Номер комментария N — позиция журнала в issue.journals с 1 (как #note-N на сайте).
func noteUrl(server: URL, issue: Int, journals: [Int], journalId: Int) -> URL? {
    guard let n = journals.firstIndex(of: journalId) else { return nil }
    return URL(string: server.appendingPathComponent("issues").appendingPathComponent(String(issue)).absoluteString + "#note-\(n + 1)")
}

/// Фрагмент ссылки → id журнала: note-N — по позиции, change-ID — по id.
func journalForFragment(_ journals: [Int], _ fragment: String) -> Int? {
    if fragment.hasPrefix("note-"), let n = Int(fragment.dropFirst(5)), n >= 1, n <= journals.count { return journals[n - 1] }
    if fragment.hasPrefix("change-"), let id = Int(fragment.dropFirst(7)), journals.contains(id) { return id }
    return nil
}

/// Избранные проекты: существующие закреплённые, по имени без учёта регистра.
func pinnedProjects(_ projects: [Project], pins: [Int]) -> [Project] {
    let set = Set(pins)
    return projects.filter { set.contains($0.id) }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
}

/// Вехи проекта: открытые (open, затем locked) по сроку, без срока — в конце; закрытые отдельно.
func versionGroups(_ versions: [Version]) -> (open: [Version], closed: [Version]) {
    let open = versions.filter { $0.status != "closed" }.sorted {
        ($0.status == "locked" ? 1 : 0, $0.dueDate ?? "9999", $0.name) < ($1.status == "locked" ? 1 : 0, $1.dueDate ?? "9999", $1.name)
    }
    return (open, versions.filter { $0.status == "closed" })
}

/// Прогресс вехи по числу закрытых задач.
struct VersionProgress: Sendable, Hashable {
    var done: Int, total: Int
    var percent: Int { total == 0 ? 0 : done * 100 / total }
    init(closed: [Bool]) { done = closed.filter { $0 }.count; total = closed.count }
}

/// Вариант фильтра «Исполнитель»: all, me, user:ID (с именем), none.
struct AssigneeOption: Sendable, Hashable, Identifiable {
    var key: String
    var name: String?
    var count: Int
    var id: String { key }
}

func assigneeOptions(_ issues: [Issue], me: Int) -> [AssigneeOption] {
    var out = [AssigneeOption(key: "all", count: issues.count)]
    let mine = issues.filter { $0.assignedTo?.id == me }.count
    if mine > 0 { out.append(AssigneeOption(key: "me", count: mine)) }
    var people: [Int: (String, Int)] = [:]
    for i in issues { if let a = i.assignedTo, a.id != me { people[a.id] = (a.name, (people[a.id]?.1 ?? 0) + 1) } }
    out += people.sorted { $0.value.0.localizedCaseInsensitiveCompare($1.value.0) == .orderedAscending }
        .map { AssigneeOption(key: "user:\($0.key)", name: $0.value.0, count: $0.value.1) }
    let none = issues.filter { $0.assignedTo == nil }.count
    if none > 0 { out.append(AssigneeOption(key: "none", count: none)) }
    return out
}

func filterByAssignee(_ issues: [Issue], key: String, me: Int) -> [Issue] {
    switch key {
    case "me": return issues.filter { $0.assignedTo?.id == me }
    case "none": return issues.filter { $0.assignedTo == nil }
    case let k where k.hasPrefix("user:"): return issues.filter { $0.assignedTo.map { "user:\($0.id)" } == k }
    default: return issues
    }
}

struct BoardColumn: Sendable, Identifiable {
    var status: IssueStatus
    var issues: [Issue]
    var id: Int { status.id }
}

/// Доска: колонка на каждый статус с задачами, в порядке статусов сервера; незнакомые статусы — в конце.
func boardColumns(_ issues: [Issue], statusOrder: [Int]) -> [BoardColumn] {
    var cols: [BoardColumn] = []
    for i in issues {
        if let k = cols.firstIndex(where: { $0.status.id == i.status.id }) { cols[k].issues.append(i) }
        else { cols.append(BoardColumn(status: i.status, issues: [i])) }
    }
    func rank(_ c: BoardColumn) -> Int { statusOrder.firstIndex(of: c.status.id) ?? Int.max }
    return cols.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
}

/// Поиск без регистра и с ё = е — для доски и упоминаний.
func searchFold(_ s: String) -> String { s.lowercased().replacingOccurrences(of: "ё", with: "е") }

/// Фильтр доски и списка вехи/подзадач (набор board_filter): выбранные аватары (me, none, user:N; пусто — все)
/// и поиск — номер с начала (можно с «#») или начало слова темы. Описание набора говорит «подстрока», но случай «ел»
/// (не находит «Релиз») требует начала слова — прав набор.
func boardFilter(_ issues: [Issue], me: Int, assignees: Set<String>, query: String) -> [Issue] {
    let q = searchFold(query.trimmingCharacters(in: .whitespaces))
    let digits = q.hasPrefix("#") ? String(q.dropFirst()) : q
    let byNumber = !digits.isEmpty && digits.allSatisfy(\.isASCII) && digits.allSatisfy(\.isNumber)
    return issues.filter { i in
        let key = i.assignedTo.map { $0.id == me ? "me" : "user:\($0.id)" } ?? "none"
        guard assignees.isEmpty || assignees.contains(key) else { return false }
        if q.isEmpty { return true }
        return (byNumber && String(i.id).hasPrefix(digits)) || fromWordStarts(i.subject).contains { $0.hasPrefix(byNumber ? digits : q) }
    }
}

/// Хвосты темы с начала каждого слова («Релиз 11.1» → «релиз 11.1», «11.1», «1»): запрос может быть из нескольких слов.
private func fromWordStarts(_ s: String) -> [Substring] {
    let f = Substring(searchFold(s))
    var prev: Character = " "
    return f.indices.compactMap { i in
        defer { prev = f[i] }
        let w = { (c: Character) in c.isLetter || c.isNumber }
        return w(f[i]) && !w(prev) ? f[i...] : nil
    }
}

/// Недавние в поиске (набор recent_opened): открытая задача — первой, без повторов, не больше 10.
func recentOpened(_ list: [Int], _ id: Int) -> [Int] { Array(([id] + list.filter { $0 != id }).prefix(10)) }

/// Кандидат упоминания.
struct MentionPerson: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    var name: String
    var login: String
}

/// Запрос упоминания по тексту до курсора (набор mention_query); cursor — в UTF-16.
/// «@» не после буквы, цифры, «_» или «@»; дальше [буквы цифры _ . -]*.
func mentionQuery(_ text: String, cursor: Int) -> String? {
    let u = Array(text.utf16.prefix(cursor))
    func word(_ c: UInt16) -> Bool {
        guard let s = Unicode.Scalar(c) else { return true } // половинка суррогатной пары — буква не-BMP
        return CharacterSet.letters.contains(s) || CharacterSet.decimalDigits.contains(s) || c == 0x5F
    }
    var i = u.count
    while i > 0, word(u[i - 1]) || u[i - 1] == 0x2E || u[i - 1] == 0x2D { i -= 1 }
    guard i > 0, u[i - 1] == 0x40 else { return nil }
    if i > 1, word(u[i - 2]) || u[i - 2] == 0x40 { return nil }
    return String(utf16CodeUnits: Array(u[i...]), count: u.count - i)
}

/// Кандидаты упоминания (набор mention_candidates): люди задачи, потом остальные известные; в каждой группе
/// сначала совпадение по началу логина или слова имени, потом по подстроке. Пустой запрос — только люди задачи.
func mentionCandidates(participants: [MentionPerson], people: [MentionPerson], query: String, limit: Int) -> [MentionPerson] {
    let q = searchFold(query.trimmingCharacters(in: .whitespaces))
    var groups: [[MentionPerson]]
    if q.isEmpty { groups = [participants] } else {
        func prefix(_ p: MentionPerson) -> Bool {
            searchFold(p.login).hasPrefix(q) || searchFold(p.name).split(whereSeparator: \.isWhitespace).contains { $0.hasPrefix(q) }
        }
        func sub(_ p: MentionPerson) -> Bool { searchFold(p.name).contains(q) || searchFold(p.login).contains(q) }
        groups = [participants.filter(prefix), participants.filter { !prefix($0) && sub($0) },
                  people.filter(prefix), people.filter { !prefix($0) && sub($0) }]
    }
    var seen = Set<Int>(), out: [MentionPerson] = []
    for p in groups.joined() where out.count < limit && seen.insert(p.id).inserted { out.append(p) }
    return out
}

/// Люди задачи для упоминаний (spec 8.1): исполнитель, автор, авторы комментариев от свежих к старым, наблюдатели.
func issueParticipants(_ issue: Issue) -> [Named] {
    var seen = Set<Int>()
    return ([issue.assignedTo, issue.author] + issue.journals.reversed().map(\.user) + issue.watchers.map { Optional($0) })
        .compactMap { $0 }.filter { seen.insert($0.id).inserted }
}

/// Аватары исполнителей доски (набор assignee_avatars): все исполнители загруженных задач; count — задач на доске
/// после фильтра статуса (open, closed, all), без аватаров и поиска. Больше задач — левее, равные — по имени, «none» последним.
func assigneeAvatars(_ issues: [Issue], me: Int, status: String) -> [AssigneeOption] {
    func key(_ i: Issue) -> String { i.assignedTo.map { $0.id == me ? "me" : "user:\($0.id)" } ?? "none" }
    var names: [String: String] = [:], counts: [String: Int] = [:]
    for i in issues {
        let k = key(i)
        if names[k] == nil { names[k] = i.assignedTo?.name ?? "" }
        let shown = status == "open" ? !i.status.isClosed : status == "closed" ? i.status.isClosed : true
        counts[k, default: 0] += shown ? 1 : 0
    }
    return names.keys.map { AssigneeOption(key: $0, name: $0.hasPrefix("user:") ? names[$0] : nil, count: counts[$0] ?? 0) }
        .sorted { a, b in
            if (a.key == "none") != (b.key == "none") { return b.key == "none" }
            if a.count != b.count { return a.count > b.count }
            return names[a.key]!.localizedCaseInsensitiveCompare(names[b.key]!) == .orderedAscending
        }
}
