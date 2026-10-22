import Foundation

/// Лента задачи: журналы Redmine раскладываются на события — создание, комментарии и действия (правки полей).
enum ActivityEvent: Identifiable, Hashable, Sendable {
    case created(Issue)
    case comment(Journal, seq: Int)
    case action(Journal, JournalDetail, seq: Int)
    case worklog(TimeEntry, seq: Int)

    var id: String {
        switch self {
        case .created: "created"
        case .comment(let j, _): "comment-\(j.id)"
        case .action(let j, _, let seq): "action-\(j.id)-\(seq)"
        case .worklog(let t, _): "worklog-\(t.id)"
        }
    }

    var dateISO: String {
        switch self {
        case .created(let i): i.createdOn
        case .comment(let j, _), .action(let j, _, _): j.createdOn
        case .worklog(let t, _): t.spentOn
        }
    }

    var seq: Int {
        switch self {
        case .created: 0
        case .comment(_, let s), .action(_, _, let s), .worklog(_, let s): s
        }
    }

    var journalId: Int? {
        switch self {
        case .comment(let j, _), .action(let j, _, _): j.id
        default: nil
        }
    }
}

/// Журналы + трудозатраты → единый хронологический поток (по дате, при равенстве — по порядку в ответе).
func normalizeActivity(_ issue: Issue, timeEntries: [TimeEntry] = []) -> [ActivityEvent] {
    var events: [ActivityEvent] = [.created(issue)]
    var seq = 1
    for j in issue.journals {
        if let n = j.notes, !n.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { events.append(.comment(j, seq: seq)); seq += 1 }
        for d in j.details where !d.name.isEmpty || !d.property.isEmpty { events.append(.action(j, d, seq: seq)); seq += 1 }
    }
    for t in timeEntries { events.append(.worklog(t, seq: seq)); seq += 1 }
    let time = { (e: ActivityEvent) in parseRedmineDate(e.dateISO)?.timeIntervalSince1970 ?? 0 }
    return events.sorted { (time($0), $0.seq) < (time($1), $1.seq) }
}

/**
 Тип связи глазами задачи viewerId. Сервер отдаёт тип «от issue_id к issue_to_id» и для второй стороны
 его не переворачивает: A blocks B, открытая из B, — это «blocked».
 */
func relationType(_ r: Relation, viewer: Int) -> String {
    guard r.issueToId == viewer else { return r.relationType }
    switch r.relationType {
    case "blocks": return "blocked"
    case "blocked": return "blocks"
    case "precedes": return "follows"
    case "follows": return "precedes"
    case "duplicates": return "duplicated"
    case "duplicated": return "duplicates"
    case "copied_to": return "copied_from"
    case "copied_from": return "copied_to"
    default: return r.relationType
    }
}

/**
 Права в проекте задачи. known = false — ещё не спрашивали: действия скрыты (не мигаем кнопкой,
 которую тут же уберём). set = nil — сервер прав не сообщил: показываем и разбираем отказ по факту.
 */
struct IssuePerms: Equatable, Sendable {
    var known = false
    var set: Set<String>?

    func has(_ p: String) -> Bool { known && (set == nil || set!.contains("*") || set!.contains(p)) }
    /// nil — права не спрашивали или сервер их не сообщил.
    func state(_ p: String) -> Bool? {
        guard known, let set else { return nil }
        return set.contains("*") || set.contains(p)
    }
    /// Право «на любое» или «на своё»; когда права неизвестны, решает unknown.
    func hasOwn(_ any: String, _ own: String, mine: Bool, unknown: Bool? = nil) -> Bool {
        known && (set == nil ? (unknown ?? mine) : has(any) || (mine && has(own)))
    }
    func editIssue(_ i: Issue, me: Int) -> Bool { hasOwn("edit_issues", "edit_own_issues", mine: i.author.id == me, unknown: true) }
    func editNote(_ j: Journal, me: Int) -> Bool { hasOwn("edit_issue_notes", "edit_own_issue_notes", mine: j.user?.id == me) }
    func editTime(_ e: TimeEntry, me: Int) -> Bool { hasOwn("edit_time_entries", "edit_own_time_entries", mine: e.user?.id == me) }
}
