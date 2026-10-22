import Foundation
import Testing
#if canImport(RedTaskCore)
@testable import RedTaskCore
typealias RMIssue = RedTaskCore.Issue // Testing тоже объявляет Issue
#else
@testable import RedTask
typealias RMIssue = RedTask.Issue
#endif

/// Модели с @D собираются из JSON — как их и получает приложение.
func decode<T: Decodable>(_ json: String) -> T { try! JSON.decoder().decode(T.self, from: Data(json.utf8)) }

func detail(_ property: String, _ name: String, _ old: String?, _ new: String?) -> JournalDetail {
    var d: JournalDetail = decode(#"{"property":"\#(property)","name":"\#(name)"}"#)
    d.oldValue = old; d.newValue = new
    return d
}

func journal(id: Int = 1, user: Int? = nil, notes: String?, created: String = "", priv: Bool = false, details: [JournalDetail] = []) -> Journal {
    var j: Journal = decode(#"{"id":\#(id),"created_on":"\#(created)"}"#)
    j.user = user.map { Named(id: $0) }; j.notes = notes; j.privateNotes = priv; j.details = details
    return j
}

@Suite("Сервер")
struct ServerTests {
    @Test func wafChallengeDetection() {
        #expect(isWafChallenge(accept: "application/json", code: 200, contentType: "text/html; charset=utf-8", requestId: nil))
        #expect(!isWafChallenge(accept: "application/json", code: 200, contentType: "text/html", requestId: "abc"))
        #expect(!isWafChallenge(accept: "application/json", code: 200, contentType: "application/json", requestId: nil))
        #expect(!isWafChallenge(accept: "text/html", code: 200, contentType: "text/html", requestId: nil))
        #expect(!isWafChallenge(accept: "application/json", code: 403, contentType: "text/html", requestId: nil))
    }

    @Test func datesUseWholeSecondsAndZ() {
        let d = Date(timeIntervalSince1970: 1_700_000_000.789)
        #expect(redmineISO(d) == "2023-11-14T22:13:20Z")
        #expect(parseRedmineDate("2023-11-14T22:13:20Z") == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(parseRedmineDate("2023-11-14T22:13:20.5Z") != nil)
        #expect(parseRedmineDate("") == nil)
    }

    @Test func keyGoesOnlyToOwnHost() {
        let base = URL(string: "https://my.example.org")!
        #expect(keyAllowed(base: base, target: URL(string: "https://my.example.org/attachments/1")!))
        #expect(!keyAllowed(base: base, target: URL(string: "http://my.example.org/a")!))
        #expect(!keyAllowed(base: base, target: URL(string: "https://evil.org/a")!))
    }

    @Test func csvWithQuotesAndSemicolons() {
        #expect(parseCSV("#;Поле\n1;\"a;b \"\"c\"\"\"\n") == [["#", "Поле"], ["1", "a;b \"c\""]])
        #expect(parseCSV("\u{FEFF}#,F\r\n2,x") == [["#", "F"], ["2", "x"]])
    }

    @Test func lenientDecoding() throws {
        let json = #"{"issue":{"id":5,"project":{"id":1,"name":"P"},"tracker":{"id":1},"status":{"id":2,"name":"New"},"priority":{"id":3},"author":{"id":4,"name":"A"},"custom_fields":[{"id":9,"name":"F","value":["1","2"],"multiple":true}],"done_ratio":null}}"#
        let i = try JSON.decoder().decode(IssueResponse.self, from: Data(json.utf8)).issue
        #expect(i.subject == "" && i.journals.isEmpty && i.doneRatio == 0)
        #expect(i.customFields[0].values == ["1", "2"])
    }
}

@Suite("Лента задачи")
struct ActivityTests {
    private func issue(_ journals: [Journal]) throws -> RMIssue {
        let base = #"{"id":1,"project":{"id":1},"tracker":{"id":1},"status":{"id":1},"priority":{"id":1},"author":{"id":1},"created_on":"2026-01-01T10:00:00Z"}"#
        var i = try JSON.decoder().decode(RMIssue.self, from: Data(base.utf8))
        i.journals = journals
        return i
    }

    @Test func journalsSplitIntoCommentsAndActionsInOrder() throws {
        let j1 = journal(id: 10, notes: "текст", created: "2026-01-02T10:00:00Z", details: [detail("attr", "status_id", "1", "2")])
        let j2 = journal(id: 11, notes: "", created: "2026-01-01T12:00:00Z")
        let t: TimeEntry = decode(#"{"id":5,"hours":1,"spent_on":"2026-01-03"}"#)
        let events = normalizeActivity(try issue([j1, j2]), timeEntries: [t])
        #expect(events.map(\.id) == ["created", "comment-10", "action-10-2", "worklog-5"])
    }

    @Test func relationTypeFlipsForTheOtherSide() {
        let r: Relation = decode(#"{"id":1,"issue_id":1,"issue_to_id":2,"relation_type":"blocks"}"#)
        #expect(relationType(r, viewer: 1) == "blocks")
        #expect(relationType(r, viewer: 2) == "blocked")
        let rel: Relation = decode(#"{"id":2,"issue_id":1,"issue_to_id":2,"relation_type":"relates"}"#)
        #expect(relationType(rel, viewer: 2) == "relates")
    }

    @Test func permissions() {
        let none = IssuePerms()
        // права ещё не пришли — действия видны, отказ разбирается по факту
        #expect(none.has("add_issue_notes"))
        let unknown = IssuePerms(known: true, set: nil)
        #expect(unknown.has("anything") && unknown.state("set_notes_private") == nil)
        let some = IssuePerms(known: true, set: ["edit_own_issue_notes"])
        let mine = journal(user: 7, notes: "x")
        #expect(some.editNote(mine, me: 7))
        #expect(!some.editNote(mine, me: 8))
        #expect(some.state("set_notes_private") == false)
        #expect(IssuePerms(known: true, set: ["*"]).has("log_time"))
    }
}

@Suite("Уведомления")
struct NotifTests {
    private func j(_ notes: String?, _ details: [JournalDetail] = [], priv: Bool = false) -> Journal {
        journal(notes: notes, priv: priv, details: details)
    }

    @Test func journalCategories() {
        let assign = detail("attr", "assigned_to_id", "5", "7")
        let status = detail("attr", "status_id", "1", "2")
        #expect(journalTypes(j("привет @me", [status]), userId: 7, login: "me") == ["mention", "status", "comment"])
        #expect(journalTypes(j(nil, [assign]), userId: 7) == ["assigned"])
        #expect(journalTypes(j(nil, [assign]), userId: 5) == ["reassigned_away"])
        #expect(journalTypes(j("тайна", priv: true), userId: 1) == ["private_note"])
        #expect(journalTypes(j(nil, [detail("cf", "3", nil, "x")]), userId: 1) == ["other"])
    }

    @Test func mutedIssueOrProjectAndOnlyStrong() {
        var s = AppSettings()
        let e = NotifEntry(issueId: 1, subject: "", project: "P", lines: [], at: 0, type: "status", eventId: "j1", projectId: 9, strong: false,
                           alsoTypes: ["comment": true])
        #expect(s.notifyTypes(e) == ["status", "comment"])
        s.notifFlags.insert(.statusClosedOnly)
        #expect(s.notifyTypes(e) == ["comment"])
        s.notifMuted.insert("comment")
        #expect(!s.notifies(e))
        var m = AppSettings()
        m.mutedProjects[9] = "P"
        #expect(!m.notifies(e))
        #expect(!AppSettings().notifies(NotifEntry(issueId: 1, subject: "", project: "", lines: [], at: 0, type: "new_issue")))
    }

    @Test func groupByIssueKeepsDaysApart() {
        let cal = Calendar(identifier: .gregorian)
        var c = cal
        c.timeZone = .gmt
        func at(_ day: Int, _ h: Int) -> Int64 { Int64(c.date(from: DateComponents(year: 2026, month: 1, day: day, hour: h))!.timeIntervalSince1970 * 1000) }
        let es = [
            NotifEntry(issueId: 1, subject: "", project: "", lines: [], at: at(2, 10), eventId: "a"),
            NotifEntry(issueId: 2, subject: "", project: "", lines: [], at: at(2, 9), eventId: "b"),
            NotifEntry(issueId: 1, subject: "", project: "", lines: [], at: at(2, 8), eventId: "c"),
            NotifEntry(issueId: 1, subject: "", project: "", lines: [], at: at(1, 8), eventId: "d"),
        ]
        let days = groupByIssue(es, calendar: c)
        #expect(days.count == 2)
        #expect(days[0].groups.map(\.issueId) == [1, 2])
        #expect(days[0].groups[0].entries.count == 2)
        #expect(days[1].groups.map(\.issueId) == [1])
    }
}

@Suite("Формы")
struct FormTests {
    @Test func parsesRedmineCustomFieldMarkup() {
        let html = """
        <form id="issue-form">
        <p><label for="issue_custom_field_values_5">Отдел<span class="required"> *</span></label>
        <select name="issue[custom_field_values][5]" class="list_cf"><option value=""></option><option value="a" selected="selected">Альфа</option><option value="b">Бета</option></select></p>
        <p><label>Флаг</label><input type="hidden" name="issue[custom_field_values][6]" value="0"><input type="checkbox" name="issue[custom_field_values][6]" value="1" class="bool_cf"></p>
        <p><label>Заметка</label><textarea name="issue[custom_field_values][7]" class="text_cf">по умолчанию</textarea></p>
        </form>
        """
        let f = parseIssueFormFields(html)
        #expect(f.map(\.id) == [5, 6, 7])
        #expect(f[0].name == "Отдел" && f[0].required && f[0].format == "list")
        #expect(f[0].options.map(\.label) == ["Альфа", "Бета"] && f[0].defaults == ["a"])
        #expect(f[1].format == "bool" && f[1].options.isEmpty)
        #expect(f[2].format == "text" && f[2].defaults == ["по умолчанию"])
    }

    @Test func payloadSkipsEmptyOptionalFields() {
        let fields = [FormField(id: 1, name: "a"), FormField(id: 2, name: "b", multiple: true)]
        let p = issuePayload(projectId: 1, trackerId: 2, subject: " Тема ", estimate: "1,5", fields: fields, values: [2: ["x", ""]])
        #expect(p["subject"] as? String == "Тема")
        #expect(p["estimated_hours"] as? Double == 1.5)
        #expect(p["start_date"] as? String == "")
        let cf = p["custom_fields"] as? [[String: Any]]
        #expect(cf?.count == 1 && cf?[0]["id"] as? Int == 2 && (cf?[0]["value"] as? [String]) == ["x"])
    }
}

@Suite("Статусы")
struct StatusKindTests {
    func st(_ name: String, closed: Bool = false) -> IssueStatus { decode(#"{"id":1,"name":"\#(name)","is_closed":\#(closed)}"#) }

    @Test func layers() {
        #expect(st("Новая").kind == .todo)
        #expect(st("Заявка").kind == .todo)
        #expect(st("Заявка обработана").kind == .inProgress) // исключение побеждает todo
        #expect(st("В работе").kind == .inProgress)
        #expect(st("Закрыта", closed: true).kind == .done)
        #expect(st("Отклонена", closed: true).kind == .rejected)
        #expect(st("Rejected").kind == .rejected)
        #expect(st("Заблокирован").kind == .rejected)
    }
}
