import Foundation

/// Типы событий истории (строки, а не enum — файл другой версии должен читаться).
enum NotifType {
    static let assigned = "assigned"
    static let comment = "comment"
    static let status = "status"
    static let priority = "priority"
    static let due = "due"
    static let attachment = "attachment"
    static let privateNote = "private_note"
    static let other = "other"
    static let reassignedAway = "reassigned_away"
    static let timeLogged = "time_logged"
    static let dueSoon = "due_soon"
    static let newIssue = "new_issue"
    static let mention = "mention"
}

/// Группа категорий — по ней выбирается важность уведомления (в Android это каналы).
enum NotifGroup: Int, CaseIterable, Comparable, Sendable {
    case me, discussion, progress, deadlines, projects
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .me: String(localized: "To me")
        case .discussion: String(localized: "Discussion")
        case .progress: String(localized: "Progress")
        case .deadlines: String(localized: "Deadlines")
        case .projects: String(localized: "Projects")
        }
    }
}

/// Категория уведомлений: ровно одна на каждый тип события, отключается по отдельности.
enum NotifCategory: String, CaseIterable, Sendable {
    case assigned, reassignedAway = "reassigned_away", mention, comment, privateNote = "private_note", status, priority, due,
         attachment, timeLogged = "time_logged", other, dueSoon = "due_soon", newIssue = "new_issue"

    var group: NotifGroup {
        switch self {
        case .assigned, .reassignedAway, .mention: .me
        case .comment, .privateNote: .discussion
        case .status, .priority, .due, .attachment, .timeLogged, .other: .progress
        case .dueSoon: .deadlines
        case .newIssue: .projects
        }
    }

    var defaultOn: Bool { self != .other && self != .newIssue }

    var title: String {
        switch self {
        case .assigned: String(localized: "Assigned to me")
        case .reassignedAway: String(localized: "Left me: reassigned or deleted")
        case .mention: String(localized: "Mentions")
        case .comment: String(localized: "New comment")
        case .privateNote: String(localized: "Private note")
        case .status: String(localized: "Status change")
        case .priority: String(localized: "Priority change")
        case .due: String(localized: "Due date changed")
        case .attachment: String(localized: "Attachments")
        case .timeLogged: String(localized: "Time logged")
        case .other: String(localized: "Other field changes")
        case .dueSoon: String(localized: "Due tomorrow, today or overdue")
        case .newIssue: String(localized: "New issue in my projects")
        }
    }

    var symbol: String {
        switch self {
        case .assigned: "person.crop.circle.badge.checkmark"
        case .reassignedAway: "person.crop.circle.badge.xmark"
        case .mention: "at"
        case .comment: "text.bubble"
        case .privateNote: "lock.fill"
        case .status: "arrow.triangle.2.circlepath"
        case .priority: "flag"
        case .due: "calendar"
        case .attachment: "paperclip"
        case .timeLogged: "clock"
        case .other: "pencil"
        case .dueSoon: "alarm"
        case .newIssue: "plus.square"
        }
    }

    /// Неизвестный тип (запись другой версии) — «прочее», а не падение.
    static func of(_ type: String) -> NotifCategory { NotifCategory(rawValue: type) ?? .other }

    static let defaultMuted: Set<String> = Set(allCases.filter { !$0.defaultOn }.map(\.rawValue))
}

/// Одно уведомление в истории колокольчика.
struct NotifEntry: Codable, Sendable, Hashable, Identifiable {
    var issueId: Int
    var subject: String
    var project: String
    var lines: [String]
    /// миллисекунды эпохи, как в Android
    var at: Int64
    var avatarUserId: Int?
    var type: String = NotifType.other
    /// Ключ события внутри задачи («j123» — журнал, «t45» — списание, «due:2026-01-31»…): по нему дедуп.
    var eventId: String = ""
    var projectId: Int?
    /// Значимое событие внутри типа (задачу закрыли, приоритет повысили) — для подопций «только…».
    var strong: Bool = true
    /// Остальные категории того же события: тип → значимость.
    var alsoTypes: [String: Bool] = [:]
    var author: String = ""

    var key: String { "\(issueId)-" + (eventId.isEmpty ? String(at) : eventId) }
    var id: String { key }
    var journalId: Int? { eventId.hasPrefix("j") ? Int(eventId.dropFirst()) : nil }
    var types: [String] { [type] + alsoTypes.keys.sorted() }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(at) / 1000) }
}

/// Задача внутри дня в виде «По задачам».
struct NotifIssueGroup: Identifiable, Sendable {
    var issueId: Int
    var entries: [NotifEntry]
    var id: String { "\(issueId)-\(entries.first?.key ?? "")" }
    var latest: NotifEntry { entries[0] }
    var types: [String] {
        var seen = Set<String>()
        return entries.flatMap(\.types).filter { seen.insert($0).inserted }
    }
    /// Участники (по записи на человека, новые сначала).
    var people: [NotifEntry] {
        var seen = Set<Int>()
        return entries.filter { e in e.avatarUserId.map { seen.insert($0).inserted } ?? false }
    }
    var journalId: Int? { entries.lazy.compactMap(\.journalId).first }
    func unread(_ keys: Set<String>) -> Bool { entries.contains { keys.contains($0.key) } }
}

struct NotifDay: Identifiable, Sendable {
    var date: Date
    var groups: [NotifIssueGroup]
    var id: Date { date }
}

/// Вид «По задачам»: дни от нового к старому, в дне — карточка на задачу по её последнему событию.
func groupByIssue(_ entries: [NotifEntry], calendar: Calendar = .current) -> [NotifDay] {
    let sorted = entries.sorted { $0.at > $1.at }
    var days: [(Date, [NotifEntry])] = []
    for e in sorted {
        let d = calendar.startOfDay(for: e.date)
        if days.last?.0 == d { days[days.count - 1].1.append(e) } else { days.append((d, [e])) }
    }
    return days.map { day, list in
        var order: [Int] = []
        var by: [Int: [NotifEntry]] = [:]
        for e in list {
            if by[e.issueId] == nil { order.append(e.issueId) }
            by[e.issueId, default: []].append(e)
        }
        return NotifDay(date: day, groups: order.map { NotifIssueGroup(issueId: $0, entries: by[$0]!) })
    }
}

/**
 Память поллера между запусками: «мои» открытые задачи прошлого опроса (id → тема; по разнице видно
 переназначение и удаление) и показанные напоминания о сроке. scope — охват, при котором собран набор.
 mentionSince/mentionOffset — недочитанный хвост поиска упоминаний.
 */
struct PollState: Codable, Sendable {
    var mine: [Int: String] = [:]
    var due: Set<String> = []
    var scope = ""
    var mentionSince: Date?
    var mentionOffset = 0
}

/**
 История уведомлений: файл (кап 500) в Application Support. Живые события дописывает опрос,
 однократный бэкфилл за 7 дней делает колокольчик при первом открытии.
 */
actor NotifStore {
    static let shared = NotifStore()
    private static let cap = 500

    private var dir: URL { Files.dir(Files.support, "notifications") }
    private var file: URL { dir.appendingPathComponent("history.json") }
    private var stateFile: URL { dir.appendingPathComponent("poll-state.json") }
    private var unreadFile: URL { dir.appendingPathComponent("unread.json") }
    private var ownerFile: URL { dir.appendingPathComponent("owner") }
    private var flagFile: URL { dir.appendingPathComponent("backfilled.v1") }

    func load() -> [NotifEntry] { Files.read([NotifEntry].self, file) ?? [] }
    func loadState() -> PollState? { Files.read(PollState.self, stateFile) }
    func saveState(_ s: PollState) throws { try Files.write(s, stateFile) }
    func unread() -> Set<String> { Files.read(Set<String>.self, unreadFile) ?? [] }

    /// Открытие колокольчика: отдаёт непрочитанное и помечает всё прочитанным.
    func takeUnread() -> Set<String> {
        let u = unread()
        try? FileManager.default.removeItem(at: unreadFile)
        return u
    }

    /// Вход: если учётка другая — история прежней стирается (номер задачи с чужого сервера глушил бы событие).
    @discardableResult
    func claim(_ owner: String) -> Bool {
        if (try? String(contentsOf: ownerFile, encoding: .utf8)) == owner { return false }
        clear()
        try? owner.write(to: ownerFile, atomically: true, encoding: .utf8)
        return true
    }

    func clear() {
        for f in [file, stateFile, unreadFile, flagFile] { try? FileManager.default.removeItem(at: f) }
    }

    /**
     Дописывает записи и возвращает только действительно новые: повтор опроса после сбоя и бэкфилл
     не дублируют ни историю, ни уведомления. Сбой записи пробрасывается — вызывающий повторит.
     */
    func appendAll(_ entries: [NotifEntry], unread markUnread: Bool = true) throws -> [NotifEntry] {
        let old = load()
        var known = Set(old.map(\.key))
        let fresh = entries.filter { known.insert($0.key).inserted }
        if fresh.isEmpty { return [] }
        let all = Array((old + fresh).sorted { $0.at > $1.at }.prefix(Self.cap))
        if markUnread { try Files.write(unread().union(fresh.map(\.key)), unreadFile) }
        try Files.write(all, file)
        return fresh
    }

    func needsBackfill() -> Bool { !FileManager.default.fileExists(atPath: flagFile.path) }
    func markBackfilled() { try? Data("1".utf8).write(to: flagFile) }
}

/**
 Категории журнала — все: комментарий вместе со сменой статуса относится к обеим. Первая — главная
 (тип записи истории); упоминание меня — всегда первое.
 */
func journalTypes(_ j: Journal, userId: Int, login: String = "") -> [String] {
    let me = String(userId)
    func attr(_ name: String) -> JournalDetail? { j.details.first { $0.property == "attr" && $0.name == name } }
    let assignee = attr("assigned_to_id")
    let toMe = assignee?.newValue == me
    let fromMe = !toMe && assignee?.oldValue == me
    let other = j.details.contains { d in
        switch d.property {
        case "attachment": return false
        case "attr":
            switch d.name {
            case "status_id", "priority_id", "due_date": return false
            case "assigned_to_id": return !toMe && !fromMe
            default: return true
            }
        default: return true
        }
    }
    let hasNotes = !(j.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    var out: [String] = []
    if textMentions(j.notes, login: login) { out.append(NotifType.mention) }
    if toMe { out.append(NotifType.assigned) }
    if fromMe { out.append(NotifType.reassignedAway) }
    if attr("status_id") != nil { out.append(NotifType.status) }
    if hasNotes { out.append(j.privateNotes ? NotifType.privateNote : NotifType.comment) }
    if attr("priority_id") != nil { out.append(NotifType.priority) }
    if attr("due_date") != nil { out.append(NotifType.due) }
    if j.details.contains(where: { $0.property == "attachment" }) { out.append(NotifType.attachment) }
    if other { out.append(NotifType.other) }
    return out.isEmpty ? [NotifType.other] : out
}

