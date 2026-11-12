import Foundation
import UIKit

/**
 Демо-режим (App Review, снимки App Store): выдуманный Redmine в памяти. Подставляется транспортом
 URLSession (URLProtocol) — RedmineAPI и экраны о демо не знают, в сеть не уходит ни один запрос.
 Правки (комментарий, статус, исполнитель, время, звезда, новая задача) живут до перезапуска.
 Язык данных — язык интерфейса (русский или английский).
 */
final class DemoServer: URLProtocol {
    static let base = URL(string: "https://redmine.example.com")!

    private static let lock = NSLock()
    nonisolated(unsafe) private static var db = DemoDB()

    static func reset() { lock.withLock { db = DemoDB.make() } }
    static var me: User { lock.withLock { db.user(DemoDB.meId) } }
    static var favoriteIds: [Int] { lock.withLock { Array(db.favorites) } }
    static func setFavorite(_ id: Int, _ on: Bool) {
        lock.withLock { if on { db.favorites.insert(id) } else { db.favorites.remove(id) } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let req = request
        let body = req.httpBody ?? req.httpBodyStream.map(Self.read) ?? Data()
        let (code, type, data) = Self.lock.withLock { Self.db.handle(req, body: body) }
        var headers = ["Content-Type": type, "X-Request-Id": "demo"]
        // ответ веб-формы: 302, адрес — в теле (redirect)
        if code == 302 { headers["Location"] = String(decoding: data, as: UTF8.self) }
        let resp = HTTPURLResponse(url: req.url ?? Self.base, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ s: InputStream) -> Data {
        s.open()
        defer { s.close() }
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 16384)
        while s.hasBytesAvailable {
            let n = s.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }
}

// MARK: - Данные и «сервер»

private struct Upload { var filename: String; var type: String?; var data: Data }
/// Сохранённый запрос (spec 17): поля веб-формы — условия и сортировка.
private struct DemoQuery { var id: Int; var name: String; var isPublic: Bool; var projectId: Int?; var form: [(String, String)] }

private struct DemoDB {
    static let meId = 1
    var ru = false
    var people: [Person] = []
    var projects: [Project] = []
    var statuses: [IssueStatus] = []
    var priorities: [Priority] = []
    var trackers: [Tracker] = []
    var activities: [TimeEntryActivity] = []
    var versions: [Int: [Version]] = [:]
    /// Вики: проект → страницы (имя → родитель, текст).
    var wiki: [Int: [(title: String, parent: String?, text: String)]] = [:]
    var projectFiles: [Int: [Attachment]] = [:]
    var issues: [Int: Issue] = [:]
    var relations: [Relation] = []
    var time: [TimeEntry] = []
    var favorites: Set<Int> = []
    var files: [Int: Upload] = [:]
    var uploads: [String: Upload] = [:]
    var queries: [DemoQuery] = []
    var nextId = 2000

    mutating func newId() -> Int { nextId += 1; return nextId }
    func t(_ en: String, _ ru: String) -> String { self.ru ? ru : en }

    func user(_ id: Int) -> User {
        let p = person(id)
        return decode(["id": id, "login": p.login ?? "", "firstname": p.first, "lastname": p.last, "mail": p.mailAddr ?? "", "admin": true])
    }
    /// «@логин» для упоминания.
    func at(_ id: Int) -> String { "@" + (person(id).login ?? "") }
    func person(_ id: Int) -> Person { people.first { $0.id == id } ?? Person(id: id, firstname: "#\(id)") }
    func named(_ id: Int) -> Named { Named(id: id, name: person(id).shortName) }
    func status(_ id: Int) -> IssueStatus { statuses.first { $0.id == id } ?? statuses[0] }
    func priority(_ id: Int) -> Named { Named(id: id, name: priorities.first { $0.id == id }?.name ?? "") }
    func tracker(_ id: Int) -> Named { Named(id: id, name: trackers.first { $0.id == id }?.name ?? "") }
    func project(_ id: Int) -> Named { Named(id: id, name: projects.first { $0.id == id }?.name ?? "") }
    func role(_ person: Int) -> [String: Any] {
        switch person {
        case 2, 8: ["id": 1, "name": t("Manager", "Менеджер")]
        case 4: ["id": 4, "name": t("Designer", "Дизайнер")]
        case 5: ["id": 5, "name": t("Tester", "Тестировщик")]
        case 6: ["id": 6, "name": t("Support", "Поддержка")]
        default: ["id": 3, "name": t("Developer", "Разработчик")]
        }
    }

    // MARK: маршруты

    mutating func handle(_ req: URLRequest, body: Data) -> (Int, String, Data) {
        guard let url = req.url, let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return notFound }
        let q = c.queryItems ?? []
        func p(_ name: String) -> String? { q.first { $0.name == name }?.value }
        let parts = url.path.split(separator: "/").map(String.init)
        let m = req.httpMethod ?? "GET"
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let id = parts.count > 1 ? Int(parts[1].replacingOccurrences(of: ".json", with: "")) : nil

        switch (m, parts.first ?? "") {
        case ("GET", "users"):
            if parts.count > 1, parts[1] == "current.json" {
                var u = (try? JSONSerialization.jsonObject(with: JSON.encoder().encode(user(Self.meId)))) as? [String: Any] ?? [:]
                u["memberships"] = []
                return raw(["user": u])
            }
            return id.map { ok(UserResponse(user: user($0))) } ?? notFound
        case ("GET", "roles"): return raw(["role": ["id": id ?? 0, "name": "Developer", "permissions": []]])
        case ("GET", "roles.json"): return raw(["roles": [1, 3, 4, 5, 6].map { role(roleHolder[$0] ?? 1) }])
        case ("GET", "queries.json"):
            let list: [[String: Any]] = queries.map { ["id": $0.id, "name": $0.name, "is_public": $0.isPublic, "project_id": $0.projectId.map { $0 as Any } ?? NSNull()] }
            return raw(["queries": list, "total_count": list.count, "offset": 0, "limit": 100])
        case ("GET", "queries") where parts.count > 1 && parts[1] == "new": return queryFormPage
        case ("POST", "queries"): return saveQuery(parts.count > 1 ? id : nil, projectKey: nil, form(body))
        case ("POST", "projects") where parts.count == 3 && parts[2] == "queries": return saveQuery(nil, projectKey: parts[1], form(body))
        case ("GET", "issues") where parts.count == 1: return catalogPage
        case ("GET", "issue_statuses.json"): return ok("issue_statuses", statuses)
        case ("GET", "trackers.json"): return ok("trackers", trackers)
        case ("GET", "enumerations"):
            if parts.last == "issue_priorities.json" { return ok("issue_priorities", priorities) }
            return ok("time_entry_activities", activities)
        case ("GET", "custom_fields.json"): return (403, "application/json", Data(#"{"errors":[]}"#.utf8))
        case ("GET", "projects"), ("GET", "projects.json"):
            if parts.count == 1 || parts[1] == "projects.json" { return ok("projects", projects, total: projects.count) }
            let key = parts[1].replacingOccurrences(of: ".json", with: "")
            guard let pr = projects.first(where: { String($0.id) == key || $0.identifier == key }) else { return notFound }
            switch parts.count > 2 ? parts[2] : "" {
            case "versions.json": return ok("versions", versions[pr.id] ?? [])
            case "issue_categories.json": return raw(["issue_categories": []])
            case "memberships.json":
                let ms: [[String: Any]] = people.map { ["id": $0.id, "user": ["id": $0.id, "name": $0.shortName], "roles": [role($0.id)]] }
                return raw(["memberships": ms, "total_count": ms.count])
            case "files.json": return ok("files", projectFiles[pr.id] ?? [])
            case "issues": return catalogPage
            case "queries" where parts.count > 3 && parts[3] == "new": return queryFormPage
            case "wiki":
                guard let pages = wiki[pr.id] else { return (403, "application/json", Data(#"{"errors":[]}"#.utf8)) }
                let name = parts.count > 3 ? parts[3].replacingOccurrences(of: ".json", with: "") : ""
                if name == "index" {
                    let list: [[String: Any]] = pages.map { p in
                        var d: [String: Any] = ["title": p.title, "version": 1, "created_on": iso(9000), "updated_on": iso(600)]
                        if let parent = p.parent { d["parent"] = ["title": parent] }
                        return d
                    }
                    return raw(["wiki_pages": list])
                }
                guard let p = pages.first(where: { $0.title == name }) else { return notFound }
                return raw(["wiki_page": ["title": p.title, "text": p.text, "version": 3, "author": ["id": 8, "name": person(8).shortName],
                                          "created_on": iso(9000), "updated_on": iso(600), "attachments": []] as [String: Any]])
            case "": return ok(ProjectResponse(project: pr))
            default: return notFound
            }
        case ("GET", "issues.json"):
            // сохранённый запрос: его условия и сортировка вместо параметров
            if let qid = p("query_id").flatMap(Int.init) {
                guard let sq = queries.first(where: { $0.id == qid }) else { return notFound }
                var items = q.filter { ["project_id", "limit", "offset"].contains($0.name) } + [URLQueryItem(name: "set_filter", value: "1")]
                items += sq.form.filter { !$0.0.hasPrefix("query[") }.map { URLQueryItem(name: $0.0, value: $0.1) }
                let sc = sq.form.filter { $0.0.hasPrefix("query[sort_criteria]") }.map { $0.1 }
                if sc.count >= 2 { items.append(URLQueryItem(name: "sort", value: "\(sc[0]):\(sc[1])")) }
                return list({ n in items.first { $0.name == n }?.value }, items)
            }
            return list(p, q)
        case ("GET", "issues"):
            guard let id, let i = issues[id] else { return notFound }
            return ok(IssueResponse(issue: full(i)))
        case ("PUT", "issues"):
            guard let id, issues[id] != nil else { return notFound }
            update(id, json["issue"] as? [String: Any] ?? [:])
            return noContent
        case ("POST", "issues.json"):
            return ok(IssueResponse(issue: full(create(json["issue"] as? [String: Any] ?? [:]))))
        case ("POST", "issues") where parts.count > 2 && parts[2] == "watchers.json":
            if let id, let u = int(json["user_id"]), issues[id]?.watchers.contains(where: { $0.id == u }) == false { let n = named(u); issues[id]?.watchers.append(n) }
            return noContent
        case ("DELETE", "issues") where parts.count > 3 && parts[2] == "watchers":
            let u = Int(parts[3].replacingOccurrences(of: ".json", with: ""))
            if let id { issues[id]?.watchers.removeAll { $0.id == u } }
            return noContent
        case ("POST", "issues") where parts.count > 2 && parts[2] == "relations.json":
            let r = json["relation"] as? [String: Any] ?? [:]
            guard let id, let to = int(r["issue_to_id"]), issues[to] != nil else { return unprocessable(t("Related issue not found", "Связанная задача не найдена")) }
            var rel: Relation = decode(["id": newId(), "issue_id": id, "issue_to_id": to, "relation_type": r["relation_type"] as? String ?? "relates"])
            rel.delay = int(r["delay"])
            relations.append(rel)
            return noContent
        case ("DELETE", "relations"): relations.removeAll { $0.id == id }; return noContent
        case ("PUT", "journals"):
            let j = json["journal"] as? [String: Any] ?? [:]
            editJournal(id ?? 0, notes: j["notes"] as? String ?? "", priv: j["private_notes"] as? Bool)
            return noContent
        case ("GET", "time_entries.json"):
            var list = time
            if let i = p("issue_id").flatMap(Int.init) { list = list.filter { $0.issue?.id == i } }
            if let from = p("from") { list = list.filter { $0.spentOn >= from } }
            list.sort { $0.createdOn > $1.createdOn }
            let off = p("offset").flatMap(Int.init) ?? 0, lim = p("limit").flatMap(Int.init) ?? 25
            return ok("time_entries", Array(list.dropFirst(off).prefix(lim)), total: list.count)
        case ("POST", "time_entries.json"):
            let e = json["time_entry"] as? [String: Any] ?? [:]
            guard let iid = int(e["issue_id"]), let issue = issues[iid] else { return unprocessable("Issue is invalid") }
            time.append(entry(id: newId(), issue: issue, user: Self.meId, hours: double(e["hours"]) ?? 0, activity: int(e["activity_id"]) ?? 8,
                              comments: e["comments"] as? String ?? "", spentOn: e["spent_on"] as? String ?? day(0), ago: 0))
            recountTime(iid)
            return (201, "application/json", Data("{}".utf8))
        case ("PUT", "time_entries"):
            let e = json["time_entry"] as? [String: Any] ?? [:]
            guard let k = time.firstIndex(where: { $0.id == id }) else { return notFound }
            if let h = double(e["hours"]) { time[k].hours = h }
            if let a = int(e["activity_id"]) { time[k].activity = Named(id: a, name: activities.first { $0.id == a }?.name ?? "") }
            if let s = e["comments"] as? String { time[k].comments = s }
            if let s = e["spent_on"] as? String { time[k].spentOn = s }
            if let iid = time[k].issue?.id { recountTime(iid) }
            return noContent
        case ("DELETE", "time_entries"):
            let iid = time.first { $0.id == id }?.issue?.id
            time.removeAll { $0.id == id }
            if let iid { recountTime(iid) }
            return noContent
        case ("GET", "search.json"):
            let s = (p("q") ?? "").lowercased()
            let found = issues.values.filter { s.isEmpty || $0.subject.lowercased().contains(s) || ($0.description ?? "").lowercased().contains(s) }
                .sorted { $0.updatedOn > $1.updatedOn }
            let rs: [[String: Any]] = found.map { i in
                ["id": i.id, "title": "\(i.tracker.name) #\(i.id) (\(i.status.name)): \(i.subject)", "type": i.status.isClosed ? "issue-closed" : "issue",
                 "url": Self.baseURL + "/issues/\(i.id)", "description": String((i.description ?? "").prefix(200)), "datetime": i.updatedOn]
            }
            let off = p("offset").flatMap(Int.init) ?? 0, lim = p("limit").flatMap(Int.init) ?? 25
            return raw(["results": Array(rs.dropFirst(off).prefix(lim)), "total_count": rs.count])
        case ("GET", "attachments"):
            if parts.count > 3, parts[1] == "thumbnail" || parts[1] == "download", let aid = Int(parts[2]), let f = files[aid] {
                if parts[1] == "thumbnail" && !(f.type ?? "").hasPrefix("image/") { return notFound }
                return (200, f.type ?? "application/octet-stream", f.data)
            }
            guard let id, let a = issues.values.flatMap(\.attachments).first(where: { $0.id == id }) else { return notFound }
            return ok(AttachmentResponse(attachment: a))
        case ("DELETE", "attachments"):
            for k in issues.keys { issues[k]?.attachments.removeAll { $0.id == id } }
            return noContent
        case ("POST", "uploads.json"):
            let token = "demo-\(newId())"
            uploads[token] = Upload(filename: p("filename") ?? "file", type: nil, data: body)
            return (201, "application/json", Data(#"{"upload":{"token":"\#(token)"}}"#.utf8))
        case ("GET", "people.json"):
            let s = (p("search") ?? "").lowercased()
            let found = people.filter { pp in s.isEmpty || [pp.first, pp.last, pp.login ?? ""].contains { $0.lowercased().hasPrefix(s) } }
            return ok("people", Array(found.prefix(p("limit").flatMap(Int.init) ?? 25)))
        case ("GET", "people") where parts.count > 1 && parts[1].hasSuffix(".json"):
            guard let id, people.contains(where: { $0.id == id }) else { return notFound }
            return ok(PeopleResponse(person: person(id)))
        default:
            // HTML-страницы (аватар People, веб-форма, CSV) — «нет»: экраны берут запасной путь (инициалы и т. п.)
            return notFound
        }
    }

    // MARK: ответы

    static var baseURL: String { DemoServer.base.absoluteString }
    var notFound: (Int, String, Data) { (404, "application/json", Data(#"{"errors":["Not found"]}"#.utf8)) }
    var noContent: (Int, String, Data) { (204, "application/json", Data()) }
    func unprocessable(_ msg: String) -> (Int, String, Data) { raw(["errors": [msg]], code: 422) }
    /// Конверт {"key": значение[, "total_count": N]} — модели кодируются тем же JSON, что и разбираются.
    func ok<T: Encodable>(_ key: String, _ v: T, total: Int? = nil) -> (Int, String, Data) {
        let inner = (try? JSON.encoder().encode(v)).flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
        var d: [String: Any] = [key: inner ?? NSNull()]
        if let total { d["total_count"] = total }
        return raw(d)
    }
    func ok<T: Encodable>(_ v: T) -> (Int, String, Data) { (200, "application/json; charset=utf-8", (try? JSON.encoder().encode(v)) ?? Data()) }
    func raw(_ v: Any, code: Int = 200) -> (Int, String, Data) {
        (code, "application/json; charset=utf-8", (try? JSONSerialization.data(withJSONObject: v)) ?? Data())
    }

    func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? String).flatMap(Int.init) }
    func double(_ v: Any?) -> Double? { (v as? Double) ?? (v as? Int).map(Double.init) ?? (v as? String).flatMap(Double.init) }

    // MARK: фильтры и запросы (spec 17)

    /// Чья роль — для roles.json по id роли.
    var roleHolder: [Int: Int] { [1: 2, 3: 1, 4: 4, 5: 5, 6: 6] }

    /// Страница задач: каталог фильтров (availableFilters, operatorByType, operatorLabels) — порядок как задан.
    var catalogPage: (Int, String, Data) {
        func js(_ v: Any) -> String { String(decoding: (try? JSONSerialization.data(withJSONObject: v, options: .fragmentsAllowed)) ?? Data(), as: UTF8.self) }
        let defs: [(String, [String: Any])] = [
            ("status_id", ["type": "list_status", "name": t("Status", "Статус"), "remote": true]),
            ("tracker_id", ["type": "list", "name": t("Tracker", "Трекер"), "values": trackers.map { [$0.name, String($0.id)] }]),
            ("priority_id", ["type": "list", "name": t("Priority", "Приоритет"), "values": priorities.map { [$0.name, String($0.id)] }]),
            ("assigned_to_id", ["type": "list_optional", "name": t("Assignee", "Назначена"), "remote": true]),
            ("author_id", ["type": "list", "name": t("Author", "Автор"), "remote": true]),
            ("subject", ["type": "text", "name": t("Subject", "Тема")]),
            ("updated_on", ["type": "date_past", "name": t("Updated", "Обновлена")]),
            ("created_on", ["type": "date_past", "name": t("Created", "Создана")]),
        ]
        let filters = "{" + defs.map { "\(js($0.0)):\(js($0.1))" }.joined(separator: ",") + "}"
        let ops: [String: [String]] = ["list_status": ["o", "=", "!", "c", "*"], "list": ["=", "!"], "list_optional": ["=", "!", "!*", "*"],
                                       "text": ["~", "!~", "!*", "*"], "date_past": [">t-", "t", "ld", "w", "lw", "m", "!*", "*"]]
        let labels: [String: String] = [
            "o": t("open", "открыта"), "c": t("closed", "закрыта"), "=": t("is", "соответствует"), "!": t("is not", "не соответствует"),
            "*": t("any", "любой"), "!*": t("none", "отсутствует"), "~": t("contains", "содержит"), "!~": t("doesn’t contain", "не содержит"),
            ">t-": t("less than days ago", "менее чем дней назад"), "t": t("today", "сегодня"), "ld": t("yesterday", "вчера"),
            "w": t("this week", "на этой неделе"), "lw": t("last week", "на прошлой неделе"), "m": t("this month", "в этом месяце"),
        ]
        let html = "<html><body><script>\n//<![CDATA[\nvar availableFilters = \(filters);\nvar operatorLabels = \(js(labels));\nvar operatorByType = \(js(ops));\n//]]>\n</script></body></html>"
        return (200, "text/html; charset=utf-8", Data(html.utf8))
    }

    /// Страница «новый запрос»: вход на сайте есть, токен формы — в meta.
    var queryFormPage: (Int, String, Data) {
        (200, "text/html; charset=utf-8", Data(#"<html><head><meta name="csrf-token" content="demo-token" /></head><body><div id="loggedas">demo</div></body></html>"#.utf8))
    }

    func form(_ body: Data) -> [(String, String)] {
        var c = URLComponents()
        c.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        return (c.queryItems ?? []).map { ($0.name, $0.value ?? "") }
    }

    func redirect(_ path: String) -> (Int, String, Data) { (302, "text/html; charset=utf-8", Data((Self.baseURL + path).utf8)) }

    /// Веб-форма запроса: новый (id nil), _method=patch — правка, _method=delete — удаление. Успех — 302 на задачи с query_id.
    mutating func saveQuery(_ id: Int?, projectKey: String?, _ f: [(String, String)]) -> (Int, String, Data) {
        func v(_ k: String) -> String? { f.first { $0.0 == k }?.1 }
        let old = id.flatMap { i in queries.firstIndex { $0.id == i } }
        if id != nil && old == nil { return notFound }
        if v("_method") == "delete" {
            queries.removeAll { $0.id == id }
            return redirect("/issues")
        }
        let name = (v("query[name]") ?? "").trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else {
            let e = t("Name cannot be blank", "Название не может быть пустым")
            return (200, "text/html; charset=utf-8", Data(#"<div id="errorExplanation"><ul><li>\#(e)</li></ul></div>"#.utf8))
        }
        let pr = projectKey.flatMap { k in projects.first { String($0.id) == k || $0.identifier == k } }
        let scope = v("query_is_for_all") == "1" ? nil : (old.map { queries[$0].projectId } ?? pr?.id)
        let crit = f.filter { $0.0 == "f[]" || $0.0.hasPrefix("op[") || $0.0.hasPrefix("v[") || $0.0.hasPrefix("query[sort_criteria]") }
        let q = DemoQuery(id: id ?? newId(), name: name, isPublic: v("query[visibility]") != "0", projectId: scope, form: crit)
        if let old { queries[old] = q } else { queries.append(q) }
        let key = projects.first { $0.id == scope }?.identifier
        return redirect(key.map { "/projects/\($0)/issues?query_id=\(q.id)" } ?? "/issues?query_id=\(q.id)")
    }

    // MARK: задачи

    /// Задача с include: подзадачи, связи, разрешённые статусы.
    func full(_ i: Issue) -> Issue {
        var i = i
        i.children = issues.values.filter { $0.parent?.id == i.id }.sorted { $0.id < $1.id }
            .map { c -> ChildIssue in var ch: ChildIssue = decode(["id": c.id]); ch.tracker = c.tracker; ch.subject = c.subject; return ch }
        i.relations = relations.filter { $0.issueId == i.id || $0.issueToId == i.id }
        i.allowedStatuses = statuses
        return i
    }

    /// Как в списке Redmine: без журналов и вложений.
    func brief(_ i: Issue) -> Issue {
        var i = i
        i.journals = []; i.attachments = []; i.watchers = []
        return i
    }

    func list(_ p: (String) -> String?, _ q: [URLQueryItem]) -> (Int, String, Data) {
        var all = Array(issues.values)
        let fields = q.filter { $0.name == "f[]" }.compactMap(\.value)
        func op(_ f: String) -> String { p("op[\(f)]") ?? "" }
        func val(_ f: String) -> String { p("v[\(f)][]") ?? "" }
        func vals(_ f: String) -> [String] { q.filter { $0.name == "v[\(f)][]" }.compactMap(\.value) }
        func idOf(_ i: Issue, _ f: String) -> Int? {
            switch f {
            case "tracker_id": i.tracker.id
            case "priority_id": i.priority.id
            case "status_id": i.status.id
            case "assigned_to_id": i.assignedTo?.id
            case "author_id": i.author.id
            default: i.fixedVersion?.id
            }
        }
        // статус: короткая форма или фильтр
        let st = fields.contains("status_id") ? ["o": "open", "c": "closed"][op("status_id")] ?? "*" : (p("status_id") ?? "open")
        if st == "open" { all = all.filter { !$0.status.isClosed } } else if st == "closed" { all = all.filter { $0.status.isClosed } }
        else if let n = Int(st) { all = all.filter { $0.status.id == n } }
        if let s = p("project_id"), let pr = projects.first(where: { String($0.id) == s || $0.identifier == s }) { all = all.filter { $0.project.id == pr.id } }
        if let s = p("parent_id").flatMap(Int.init) { all = all.filter { $0.parent?.id == s } }
        if let s = p("fixed_version_id").flatMap(Int.init) { all = all.filter { $0.fixedVersion?.id == s } }
        if p("assigned_to_id") == "me" { all = all.filter { $0.assignedTo?.id == Self.meId } }
        if p("author_id") == "me" { all = all.filter { $0.author.id == Self.meId } }
        if p("watcher_id") == "me" { all = all.filter { $0.watchers.contains { $0.id == Self.meId } } }
        if let s = p("subject") { let n = s.hasPrefix("~") ? String(s.dropFirst()) : s; all = all.filter { $0.subject.localizedCaseInsensitiveContains(n) } }
        if let s = p("issue_id") { let ids = Set(s.split(separator: ",").compactMap { Int($0) }); all = all.filter { ids.contains($0.id) } }
        if let s = p("updated_on"), s.hasPrefix(">="), let d = parseRedmineDate(String(s.dropFirst(2))) {
            all = all.filter { (parseRedmineDate($0.updatedOn) ?? .distantPast) >= d }
        }
        for f in fields {
            switch f {
            case "favourite_state": all = all.filter { favorites.contains($0.id) }
            case "subject": all = all.filter { $0.subject.localizedCaseInsensitiveContains(val(f)) }
            case "notes": all = all.filter { $0.journals.contains { ($0.notes ?? "").localizedCaseInsensitiveContains(val(f)) } }
            case "tracker_id", "priority_id", "status_id", "assigned_to_id", "author_id", "fixed_version_id":
                let ids = Set(vals(f).compactMap { $0 == "me" ? Self.meId : Int($0) })
                switch op(f) {
                case "=": all = all.filter { idOf($0, f).map(ids.contains) ?? false }
                case "!": all = all.filter { !(idOf($0, f).map(ids.contains) ?? false) }
                case "!*": all = all.filter { idOf($0, f) == nil }
                case "*" where f != "status_id": all = all.filter { idOf($0, f) != nil }
                default: break
                }
            case "updated_on", "created_on":
                let days = op(f) == ">t-" ? Int(val(f)) : nil
                guard let d = days.map({ Date().addingTimeInterval(-Double($0) * 86400) }) ?? parseRedmineDate(val(f)) else { continue }
                all = all.filter { (parseRedmineDate(f == "updated_on" ? $0.updatedOn : $0.createdOn) ?? .distantPast) >= d }
            default: break // project_id=mine — участник всех проектов
            }
        }
        // первый критерий из «поле:dir,поле:dir»
        let sort = (p("sort") ?? "updated_on:desc").split(separator: ",").first?.split(separator: ":") ?? []
        let desc = sort.count > 1 && sort[1] == "desc"
        all.sort { a, b in
            let r: Bool
            switch sort.first ?? "" {
            case "id": r = a.id < b.id
            case "created_on": r = a.createdOn < b.createdOn
            case "priority": r = a.priority.id < b.priority.id
            default: r = a.updatedOn < b.updatedOn
            }
            return desc ? !r && a.id != b.id : r
        }
        let off = p("offset").flatMap(Int.init) ?? 0, lim = p("limit").flatMap(Int.init) ?? 25
        return ok("issues", all.dropFirst(off).prefix(lim).map { brief($0) }, total: all.count)
    }

    mutating func update(_ id: Int, _ f: [String: Any]) {
        guard var i = issues[id] else { return }
        var details: [JournalDetail] = []
        func attr(_ name: String, _ old: String?, _ new: String?) {
            if old != new { details.append(jd("attr", name: name, oldValue: old, newValue: new)) }
        }
        func ref(_ key: String) -> Int?? { f[key].map { int($0) } }
        if let v = int(f["status_id"]) {
            attr("status_id", String(i.status.id), String(v))
            i.status = status(v)
            if i.status.isClosed { i.closedOn = iso(0); if i.status.kind == .done { i.doneRatio = 100 } }
        }
        if let v = ref("assigned_to_id") { attr("assigned_to_id", i.assignedTo.map { String($0.id) }, v.map(String.init)); i.assignedTo = v.map { named($0) } }
        if let v = int(f["priority_id"]) { attr("priority_id", String(i.priority.id), String(v)); i.priority = priority(v) }
        if let v = int(f["tracker_id"]) { attr("tracker_id", String(i.tracker.id), String(v)); i.tracker = tracker(v) }
        if let v = int(f["done_ratio"]) { attr("done_ratio", String(i.doneRatio), String(v)); i.doneRatio = v }
        if let v = f["subject"] as? String { attr("subject", i.subject, v); i.subject = v }
        if let v = f["description"] as? String { if v != i.description { details.append(jd("attr", name: "description")) }; i.description = v }
        if let v = f["due_date"] as? String { attr("due_date", i.dueDate, v.isEmpty ? nil : v); i.dueDate = v.isEmpty ? nil : v }
        if let v = f["start_date"] as? String { i.startDate = v.isEmpty ? nil : v }
        if f["estimated_hours"] != nil { i.estimatedHours = double(f["estimated_hours"]) }
        if let v = f["is_private"] as? Bool { i.isPrivate = v }
        if let v = ref("fixed_version_id") {
            i.fixedVersion = v.flatMap { vid in versions.values.joined().first { $0.id == vid }.map { Named(id: $0.id, name: $0.name) } }
        }
        if let v = ref("parent_issue_id") { i.parent = v.map(IDRef.init) }
        for u in f["uploads"] as? [[String: Any]] ?? [] {
            guard let token = u["token"] as? String, var up = uploads.removeValue(forKey: token) else { continue }
            up.type = u["content_type"] as? String ?? up.type
            let a = attach(newId(), up, by: Self.meId, ago: 0, description: u["description"] as? String)
            i.attachments.append(a)
            details.append(jd("attachment", name: String(a.id), newValue: a.filename))
        }
        let notes = f["notes"] as? String ?? ""
        if !notes.isEmpty || !details.isEmpty {
            i.journals.append(decode(["id": newId(), "user": ["id": Self.meId, "name": person(Self.meId).shortName], "notes": notes,
                                      "created_on": iso(0), "private_notes": f["private_notes"] as? Bool ?? false]))
            i.journals[i.journals.count - 1].details = details
        }
        i.updatedOn = iso(0)
        issues[id] = i
    }

    mutating func create(_ f: [String: Any]) -> Issue {
        let id = newId()
        let pid = int(f["project_id"]) ?? 1
        var i: Issue = decode([
            "id": id, "project": ["id": pid, "name": project(pid).name], "tracker": ["id": 1, "name": ""], "status": ["id": 1, "name": ""],
            "priority": ["id": 2, "name": ""], "author": ["id": Self.meId, "name": person(Self.meId).shortName],
            "subject": f["subject"] as? String ?? "", "created_on": iso(0), "updated_on": iso(0),
        ])
        i.tracker = tracker(int(f["tracker_id"]) ?? 3)
        i.status = status(1)
        i.priority = priority(int(f["priority_id"]) ?? 2)
        issues[id] = i
        var rest = f
        rest["notes"] = nil
        update(id, rest)
        issues[id]?.journals = [] // поля при создании — не журнал
        let meNamed = named(Self.meId)
        issues[id]?.watchers = [meNamed]
        return issues[id]!
    }

    mutating func editJournal(_ jid: Int, notes: String, priv: Bool?) {
        for (k, i) in issues {
            guard let n = i.journals.firstIndex(where: { $0.id == jid }) else { continue }
            if notes.isEmpty && i.journals[n].details.isEmpty { issues[k]?.journals.remove(at: n); return }
            issues[k]?.journals[n].notes = notes
            let now = iso(0)
            issues[k]?.journals[n].updatedOn = now
            if let priv { issues[k]?.journals[n].privateNotes = priv }
            return
        }
    }

    mutating func recountTime(_ id: Int) {
        let h = time.filter { $0.issue?.id == id }.compactMap(\.hours).reduce(0, +)
        issues[id]?.spentHours = h
        issues[id]?.totalSpentHours = h
    }

    // MARK: помощники построения

    func iso(_ minutesAgo: Double) -> String { redmineISO(Date().addingTimeInterval(-minutesAgo * 60)) }
    func day(_ offset: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: offset, to: Date())!
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    func entry(id: Int, issue: Issue, user: Int, hours: Double, activity: Int, comments: String, spentOn: String, ago: Double) -> TimeEntry {
        decode(["id": id, "user": ["id": user, "name": person(user).shortName],
                "activity": ["id": activity, "name": activities.first { $0.id == activity }?.name ?? ""],
                "hours": hours, "comments": comments, "spent_on": spentOn, "project": ["id": issue.project.id, "name": issue.project.name],
                "issue": ["id": issue.id], "created_on": iso(ago)])
    }

    mutating func attach(_ id: Int, _ u: Upload, by user: Int, ago: Double, description: String? = nil) -> Attachment {
        files[id] = u
        return decode(["id": id, "filename": u.filename, "filesize": u.data.count, "content_type": u.type ?? "application/octet-stream",
                       "content_url": Self.baseURL + "/attachments/download/\(id)/\(u.filename)",
                       "author": ["id": user, "name": person(user).shortName], "created_on": iso(ago), "description": description ?? ""])
    }
}

private func jd(_ property: String, name: String, oldValue: String? = nil, newValue: String? = nil) -> JournalDetail {
    var d: JournalDetail = decode(["property": property, "name": name])
    d.oldValue = oldValue
    d.newValue = newValue
    return d
}

private func decode<T: Decodable>(_ dict: [String: Any]) -> T {
    let d = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSON.decoder().decode(T.self, from: d)
}

// MARK: - Наполнение

private extension DemoDB {
    static func make() -> DemoDB {
        var db = DemoDB()
        db.ru = Bundle.main.preferredLocalizations.first?.hasPrefix("ru") == true
        db.fill()
        return db
    }

    mutating func fill() {
        // люди — выдуманные; аватары — инициалы на цвете (People-страниц нет)
        let ppl: [(Int, String, String, String, String, String, String, String, Int?)] = [
            (1, "Alex", "Morgan", "Алексей", "Морозов", "amorgan", t("iOS Developer", "iOS-разработчик"), t("Mobile Team", "Мобильная разработка"), 2),
            (2, "Maria", "Chen", "Мария", "Соколова", "mchen", t("Head of Engineering", "Руководитель разработки"), t("Engineering", "Разработка"), nil),
            (3, "David", "Okafor", "Дмитрий", "Орлов", "dokafor", t("Backend Developer", "Бэкенд-разработчик"), t("Platform", "Платформа"), 2),
            (4, "Sofia", "Rossi", "Анна", "Кузнецова", "srossi", t("Product Designer", "Дизайнер интерфейсов"), t("Design", "Дизайн"), 2),
            (5, "Liam", "Novak", "Илья", "Волков", "lnovak", t("QA Engineer", "Инженер по тестированию"), t("Quality", "Качество"), 2),
            (6, "Emma", "Larsen", "Екатерина", "Лебедева", "elarsen", t("Support Lead", "Руководитель поддержки"), t("Customer Support", "Поддержка клиентов"), 2),
            (7, "Noah", "Fischer", "Никита", "Зайцев", "nfischer", t("DevOps Engineer", "DevOps-инженер"), t("Platform", "Платформа"), 3),
            (8, "Olivia", "Park", "Ольга", "Белова", "opark", t("Project Manager", "Менеджер проектов"), t("Engineering", "Разработка"), 2),
        ]
        let bios = [
            1: t("Builds the iPhone and iPad apps. Loves small diffs and fast builds.", "Делает приложения для iPhone и iPad. Любит маленькие диффы и быстрые сборки."),
            2: t("Leads product engineering across mobile, web and platform teams.", "Руководит разработкой продукта: мобильная команда, сайт и платформа."),
        ]
        people = ppl.map { id, fe, le, fr, lr, login, job, dept, mgr in
            var p = Person(id: id, login: ru ? Self.translit(fr, lr) : login, firstname: ru ? fr : fe, lastname: ru ? lr : le)
            p.email = "\(p.login!)@example.com"
            p.jobTitle = job
            p.department = Named(id: 100 + id, name: dept)
            p.managerId = mgr
            p.personnelNumber = String(1040 + id * 7)
            p.background = bios[id]
            return p
        }
        statuses = [
            (1, t("New", "Новая"), false), (2, t("In Progress", "В работе"), false), (3, t("Feedback", "Обратная связь"), false),
            (4, t("Resolved", "Решена"), true), (5, t("Closed", "Закрыта"), true), (6, t("Rejected", "Отклонена"), true),
        ].map { decode(["id": $0.0, "name": $0.1, "is_closed": $0.2]) }
        priorities = [t("Low", "Низкий"), t("Normal", "Нормальный"), t("High", "Высокий"), t("Urgent", "Срочный"), t("Immediate", "Немедленный")]
            .enumerated().map { decode(["id": $0.offset + 1, "name": $0.element, "is_default": $0.offset == 1, "active": true]) }
        trackers = [t("Bug", "Ошибка"), t("Feature", "Функция"), t("Task", "Задача"), t("Support", "Поддержка")]
            .enumerated().map { Tracker(id: $0.offset + 1, name: $0.element) }
        activities = [t("Development", "Разработка"), t("Design", "Дизайн"), t("Testing", "Тестирование"), t("Meeting", "Совещание")]
            .enumerated().map { decode(["id": $0.offset + 8, "name": $0.element, "is_default": $0.offset == 0, "active": true]) }
        projects = [(1, t("Mobile App", "Мобильное приложение"), "mobile"), (2, t("Website", "Сайт"), "website"),
                    (3, t("Infrastructure", "Инфраструктура"), "infra"), (4, t("Customer Support", "Поддержка клиентов"), "support")]
            .map { var p = Project(id: $0.0, name: $0.1); p.identifier = $0.2; p.trackers = trackers; return p }
        let modules: [Int: [String]] = [1: ["issue_tracking", "wiki", "files"], 2: ["issue_tracking", "wiki"], 3: ["issue_tracking", "files"], 4: ["issue_tracking"]]
        for k in projects.indices {
            projects[k].enabledModules = (modules[projects[k].id] ?? []).enumerated().map { Named(id: $0.offset + 1, name: $0.element) }
        }
        projects[0].description = t("The iPhone and iPad app. Release notes and the team guide are in the *Wiki*.",
                                    "Приложение для iPhone и iPad. Заметки к выпускам и правила команды — в *Вики*.")
        projects[0].homepage = "https://redmine.example.com/mobile"
        projects[1].description = t("Marketing site and checkout.", "Сайт и оформление заказа.")
        func version(_ id: Int, _ project: Int, _ name: String, _ status: String, due: Int?, _ desc: String) -> Version {
            var v: Version = decode(["id": id, "name": name, "status": status, "description": desc, "project": ["id": project, "name": self.project(project).name]])
            v.dueDate = due.map { day($0) }
            return v
        }
        versions = [1: [version(31, 1, "1.4", "closed", due: -20, t("Sharing and context menus", "Общий доступ и контекстные меню")),
                        version(32, 1, "1.5", "open", due: 12, t("Offline mode and crash fixes", "Офлайн-режим и исправления падений")),
                        version(34, 1, "1.6", "open", due: nil, t("Widgets", "Виджеты"))],
                    2: [version(33, 2, t("Spring release", "Весенний релиз"), "locked", due: 20, t("New pricing page", "Новая страница тарифов"))]]

        let me = 1
        //   id, проект, трекер, статус, приоритет, автор, исполнитель, тема, срок (дни от сегодня), готовность, изменена (мин назад), создана (дни назад)
        add(1240, 1, 1, 2, 4, 5, me, t("Crash when opening a notification while the app is in the background", "Падение при открытии уведомления, когда приложение в фоне"), due: 0, done: 60, upd: 12, cre: 3, watch: [5, 3, 2], ver: 32, est: 6)
        add(1238, 1, 2, 2, 3, 8, me, t("Offline mode for the issue list", "Офлайн-режим для списка задач"), due: 5, done: 40, upd: 45, cre: 9, watch: [8, 2], ver: 32, est: 24)
        add(1239, 1, 3, 1, 2, me, me, t("Cache issue snapshots on disk", "Кэш снимков задач на диске"), due: 3, done: 0, upd: 190, cre: 8, parent: 1238, ver: 32, est: 8)
        add(1241, 1, 3, 2, 2, 8, 3, t("Sync queue for offline edits", "Очередь синхронизации офлайн-правок"), due: 6, done: 20, upd: 260, cre: 8, parent: 1238, watch: [me], ver: 32)
        add(1236, 1, 1, 3, 3, 6, me, t("Dark mode: status badges have low contrast", "Тёмная тема: у плашек статуса низкий контраст"), due: -2, done: 80, upd: 125, cre: 6, watch: [6])
        add(1233, 1, 2, 1, 1, 4, me, t("Haptic feedback on swipe actions", "Тактильный отклик на свайп-действиях"), done: 0, upd: 1500, cre: 12)
        add(1230, 2, 1, 1, 5, 6, me, t("Checkout page returns 500 for some coupon codes", "Страница оплаты отдаёт 500 для части промокодов"), due: 0, done: 0, upd: 25, cre: 1, watch: [6, 8])
        add(1228, 2, 3, 2, 2, 8, me, t("Update the privacy policy page", "Обновить страницу политики конфиденциальности"), due: 10, done: 50, upd: 300, cre: 14, ver: 33)
        add(1225, 3, 3, 3, 2, 7, me, t("Rotate TLS certificates on staging", "Обновить TLS-сертификаты на стенде"), due: -1, done: 90, upd: 1440, cre: 10, watch: [7])
        add(1222, 4, 4, 1, 3, 6, me, t("Customer can’t reset the password from the mobile app", "Клиент не может сбросить пароль из мобильного приложения"), due: 1, done: 0, upd: 170, cre: 2, watch: [6])
        add(1219, 1, 1, 4, 2, 5, me, t("Typo on the onboarding screen", "Опечатка на экране онбординга"), done: 100, upd: 2900, cre: 15)
        add(1215, 1, 2, 5, 2, 8, me, t("Share the issue link from the context menu", "Поделиться ссылкой на задачу из контекстного меню"), done: 100, upd: 5800, cre: 20, ver: 31)
        add(1212, 2, 1, 6, 1, 5, me, t("Footer overlaps the content in old Safari", "Подвал перекрывает контент в старом Safari"), done: 0, upd: 8700, cre: 21)
        add(1243, 3, 3, 1, 2, 3, 7, t("Move CI runners to the new cluster", "Перенести CI-раннеры на новый кластер"), due: 7, done: 0, upd: 30, cre: 1, watch: [me, 3])
        add(1242, 2, 2, 2, 3, 8, 4, t("Redesign the pricing page", "Новый дизайн страницы тарифов"), due: 9, done: 30, upd: 55, cre: 5, watch: [me, 8], ver: 33)
        add(1235, 3, 1, 2, 4, 7, 3, t("Nightly backups fail on the reporting database", "Не проходят ночные бэкапы базы отчётов"), due: -3, done: 50, upd: 400, cre: 7, watch: [me])
        add(1231, 4, 4, 3, 2, 6, 6, t("Export invoices to CSV", "Выгрузка счетов в CSV"), done: 70, upd: 720, cre: 9)
        add(1229, 4, 4, 1, 1, 6, 5, t("Question about notification settings", "Вопрос о настройках уведомлений"), done: 0, upd: 1300, cre: 3)
        add(1226, 2, 3, 5, 2, 8, 4, t("Prepare banners for the spring campaign", "Подготовить баннеры для весенней кампании"), done: 100, upd: 4300, cre: 18)
        add(1224, 3, 2, 1, 2, 2, 7, t("Dashboard for API latency", "Дашборд задержек API"), due: 14, done: 0, upd: 2000, cre: 11)
        add(1220, 1, 3, 2, 2, 2, 5, t("Regression test plan for release 1.5", "План регрессионного тестирования релиза 1.5"), due: 4, done: 35, upd: 600, cre: 6, watch: [me], ver: 32)
        add(1217, 3, 1, 6, 1, 7, 7, t("Disk alert fires on empty volumes", "Ложные алерты о диске на пустых томах"), done: 0, upd: 7000, cre: 16)
        add(1214, 4, 4, 5, 2, 6, 6, t("Customer asks for a dark theme", "Клиент просит тёмную тему"), done: 100, upd: 9000, cre: 25)
        add(1210, 1, 2, 1, 2, 4, nil, t("Widgets for the Home Screen", "Виджеты для экрана «Домой»"), done: 0, upd: 3000, cre: 13, watch: [me, 4], ver: 34)
        add(1208, 2, 1, 2, 3, 5, 3, t("Search results ignore diacritics", "Поиск не находит слова с «ё»"), done: 40, upd: 900, cre: 8)
        add(1205, 3, 3, 1, 1, me, 7, t("Clean up old Docker images", "Почистить старые Docker-образы"), done: 0, upd: 2400, cre: 10)
        favorites = [1240, 1238, 1242]
        queries = [
            DemoQuery(id: 51, name: t("Open bugs", "Открытые ошибки"), isPublic: true, projectId: 1,
                      form: [("f[]", "status_id"), ("op[status_id]", "o"), ("f[]", "tracker_id"), ("op[tracker_id]", "="), ("v[tracker_id][]", "1")]),
            DemoQuery(id: 52, name: t("Urgent and above", "Срочные и выше"), isPublic: true, projectId: nil,
                      form: [("f[]", "status_id"), ("op[status_id]", "o"), ("f[]", "priority_id"), ("op[priority_id]", "="),
                             ("v[priority_id][]", "4"), ("v[priority_id][]", "5")]),
            DemoQuery(id: 53, name: t("Reported by me", "Созданные мной"), isPublic: false, projectId: nil,
                      form: [("f[]", "author_id"), ("op[author_id]", "="), ("v[author_id][]", "me"),
                             ("query[sort_criteria][0][]", "priority"), ("query[sort_criteria][0][]", "desc")]),
        ]

        let crash = crashDescription, offline = offlineDescription
        issues[1240]?.description = crash
        issues[1238]?.description = offline
        let d1236 = t("Badges use the status color at 14% opacity — in dark mode the text is hard to read. See the screenshot in #1240 for comparison.",
                                      "Плашки берут цвет статуса с прозрачностью 14% — в тёмной теме текст читается плохо. Для сравнения — снимок в #1240.")
        issues[1236]?.description = d1236
        let d1230 = t("Coupons with a percent discount over *50%* fail with HTTP 500. Reported by three customers today.",
                                      "Промокоды со скидкой больше *50%* падают с HTTP 500. Сегодня написали три клиента.")
        issues[1230]?.description = d1230
        let d1243 = t("# Drain the old runners\n# Register the new ones\n# Update the pipeline tags\n\nKeep the old cluster for a week as a fallback.",
                                      "# Вывести старые раннеры\n# Зарегистрировать новые\n# Обновить теги в пайплайнах\n\nСтарый кластер держим неделю как запасной.")

        issues[1243]?.description = d1243
        let shot = attach(501, Upload(filename: "crash-screenshot.png", type: "image/png", data: Self.picture(symbol: "exclamationmark.triangle.fill", tint: .systemRed)), by: 3, ago: 180)
        let log = attach(502, Upload(filename: "crash.log", type: "text/plain", data: Data("Thread 0 Crashed:\n0 RedTask NotificationRouter.open(_:) + 132\n".utf8)), by: 3, ago: 180)
        issues[1240]?.attachments = [shot, log]
        // комментарий с картинкой — превью в уведомлении и в колокольчике
        let mock = attach(503, Upload(filename: "pricing-mockup.png", type: "image/png", data: Self.picture(symbol: "rectangle.3.group.fill", tint: .systemIndigo)), by: 4, ago: 55)
        issues[1242]?.attachments = [mock]

        note(1240, 5, 2900, t("Reproduced on iOS 18.2 and 18.3. Steps are in the description.", "Воспроизвёл на iOS 18.2 и 18.3, шаги — в описании."), [("status_id", "1", "2")])
        note(1240, me, 1500, t("Looks like the deep link handler runs before the scene is ready. The offline cache from #1238 makes it more likely.",
                               "Похоже, обработчик ссылки срабатывает раньше, чем готова сцена. Офлайн-кэш из #1238 делает это вероятнее."))
        note(1240, 3, 180, t("\(at(me)) the crash log from TestFlight is attached, the stack points to @NotificationRouter.open(_:)@.",
                             "\(at(me)) приложил крэш-лог из TestFlight, стек указывает на @NotificationRouter.open(_:)@."), [("done_ratio", "30", "60")], files: [shot, log])
        note(1240, 2, 12, t("Let’s ship the fix in 1.5. Please add a regression test — \(at(5)) will verify it on devices.",
                            "Выпускаем исправление в 1.5. Добавь, пожалуйста, регрессионный тест — \(at(5)) проверит на устройствах."), [("priority_id", "3", "4")])
        note(1238, 8, 2000, t("Agreed on the scope with the team, see the table in the description.", "Согласовали объём с командой, таблица — в описании."))
        note(1238, me, 900, t("Split into #1239 and #1241.", "Разбил на #1239 и #1241."))
        note(1238, 8, 45, t("Moved the due date — design review takes one more day.", "Сдвинула срок: дизайн-ревью займёт ещё день."), [("due_date", day(4), day(5))])
        note(1230, 6, 25, t("Two more customers reported this today. \(at(me)) could you take a look first?",
                            "Сегодня ещё два клиента написали. \(at(me)), посмотришь в первую очередь?"))
        note(1243, 3, 30, t("\(at(me)) please check the iOS build job after the move — it uses the macOS runners.",
                            "\(at(me)), проверь, пожалуйста, сборку iOS после переезда — она на macOS-раннерах."))
        note(1242, 4, 55, t("New mockups are attached. Feedback welcome!", "Приложила новые макеты. Жду замечаний!"), files: [mock])

        projectFiles[1] = [attach(601, Upload(filename: "app-icon.png", type: "image/png", data: Self.picture(symbol: "app.badge.fill", tint: .systemBlue)), by: 4, ago: 20000),
                           attach(602, Upload(filename: t("release-checklist.txt", "чеклист-выпуска.txt"), type: "text/plain",
                                              data: Data(t("1. Bump the version\n2. TestFlight\n3. Submit for review\n", "1. Поднять версию\n2. TestFlight\n3. Отправить на проверку\n").utf8)), by: 8, ago: 9000),
                           attach(604, Upload(filename: t("roadmap.odt", "план-развития.odt"), type: "application/vnd.oasis.opendocument.text",
                                              data: Self.odt(thumbnail: Self.picture(symbol: "map.fill", tint: .systemOrange))), by: 2, ago: 15000)]
        projectFiles[3] = [attach(603, Upload(filename: "network-diagram.png", type: "image/png", data: Self.picture(symbol: "network", tint: .systemTeal)), by: 7, ago: 30000)]
        let release = t("Release_process", "Выпуск_версии"), style = t("Code_style", "Стиль_кода"), r15 = t("Release_1.5", "Выпуск_1.5")
        wiki[1] = [
            ("Wiki", nil, t("""
            h1. Mobile App

            Start here. The team works in two-week iterations, see [[\(release)|how we ship]] and [[\(style)]].

            * Current version: [[\(r15)]]
            * Open bugs: #1240, #1236
            """, """
            h1. Мобильное приложение

            Начните отсюда. Команда работает двухнедельными итерациями: [[\(release)|как мы выпускаем]] и [[\(style)]].

            * Текущая версия: [[\(r15)]]
            * Открытые ошибки: #1240, #1236
            """)),
            (release, "Wiki", t("""
            h2. Release process

            # Freeze the branch on Monday
            # QA pass — \(at(5))
            # Submit to App Review

            bq. Never ship on Friday.
            """, """
            h2. Выпуск версии

            # Заморозка ветки в понедельник
            # Проверка — \(at(5))
            # Отправка в App Review

            bq. В пятницу не выпускаем.
            """)),
            (r15, release, t("Offline mode and crash fixes. Back to [[Wiki]].", "Офлайн-режим и исправления падений. Назад — [[Wiki]].")),
            (style, "Wiki", t("Swift 6, strict concurrency, *small diffs*.", "Swift 6, строгая конкурентность, *маленькие диффы*.")),
        ]
        #if DEBUG
        // -RTWikiFile <путь> — длинная страница «Long» в вики первого проекта (проверка прокрутки)
        if let f = UserDefaults.standard.string(forKey: "RTWikiFile"), let text = try? String(contentsOfFile: f, encoding: .utf8) {
            wiki[1]?.append(("Long", nil, text))
        }
        #endif
        wiki[2] = [("Wiki", nil, t("h1. Website\n\nSee also the [[mobile:Wiki|Mobile App wiki]].", "h1. Сайт\n\nСм. также [[mobile:Wiki|вики мобильного приложения]]."))]
        note(1236, 6, 400, t("The customer confirmed it on iPhone 15 Pro, iOS 18.3.", "Клиент подтвердил на iPhone 15 Pro, iOS 18.3."))
        note(1236, me, 125, t("Fixed in build 1.5 (512), please check.", "Исправлено в сборке 1.5 (512), проверьте, пожалуйста."), [("status_id", "2", "3"), ("done_ratio", "50", "80")])
        note(1225, 7, 1440, t("Staging is done, production is scheduled for Monday.", "Стенд готов, прод — в понедельник."))
        note(1222, 6, 170, t("The reset link opens Safari instead of the app.", "Ссылка сброса открывает Safari вместо приложения."))
        note(1235, 3, 400, t("Disk on the backup host is full, cleaning up.", "Закончилось место на хосте бэкапов, чищу."))

        relations = [decode(["id": 801, "issue_id": 1240, "issue_to_id": 1236, "relation_type": "relates"]),
                     decode(["id": 802, "issue_id": 1235, "issue_to_id": 1224, "relation_type": "blocks"])]

        for (iid, user, h, act, en, ruT, d, ago) in [
            (1240, me, 1.5, 8, "Investigating crash logs", "Разбор крэш-логов", -1, 1500.0),
            (1240, 3, 0.5, 10, "Reproduced on devices", "Воспроизведение на устройствах", -1, 1400.0),
            (1240, me, 2.0, 8, "Fix and regression test", "Исправление и регрессионный тест", 0, 60.0),
            (1238, me, 3.0, 8, "Snapshot cache prototype", "Прототип кэша снимков", -2, 2900.0),
            (1238, 4, 1.0, 9, "Offline state mockups", "Макеты офлайн-состояния", -1, 1300.0),
            (1236, me, 1.25, 8, "Contrast fix", "Исправление контраста", 0, 130.0),
        ] as [(Int, Int, Double, Int, String, String, Int, Double)] {
            guard let issue = issues[iid] else { continue }
            time.append(entry(id: newId(), issue: issue, user: user, hours: h, activity: act, comments: t(en, ruT), spentOn: day(d), ago: ago))
            recountTime(iid)
        }
    }

    mutating func add(_ id: Int, _ project: Int, _ tracker: Int, _ status: Int, _ priority: Int, _ author: Int, _ assignee: Int?, _ subject: String,
                      due: Int? = nil, done: Int, upd: Double, cre: Int, parent: Int? = nil, watch: [Int] = [], ver: Int? = nil, est: Double? = nil) {
        var i: Issue = decode([
            "id": id, "project": ["id": project, "name": self.project(project).name], "tracker": ["id": tracker, "name": ""],
            "status": ["id": status, "name": ""], "priority": ["id": priority, "name": ""], "author": ["id": author, "name": ""],
            "subject": subject, "done_ratio": done, "created_on": iso(Double(cre) * 1440), "updated_on": iso(upd), "start_date": day(-cre),
        ])
        i.tracker = self.tracker(tracker)
        i.status = self.status(status)
        i.priority = self.priority(priority)
        i.author = named(author)
        i.assignedTo = assignee.map { named($0) }
        i.dueDate = due.map { day($0) }
        i.parent = parent.map(IDRef.init)
        i.watchers = watch.map { named($0) }
        i.estimatedHours = est
        i.fixedVersion = ver.flatMap { v in versions.values.joined().first { $0.id == v }.map { Named(id: $0.id, name: $0.name) } }
        if i.status.isClosed { i.closedOn = i.updatedOn }
        issues[id] = i
    }

    mutating func note(_ id: Int, _ user: Int, _ ago: Double, _ text: String, _ details: [(String, String, String)] = [], files: [Attachment] = []) {
        var j: Journal = decode(["id": newId(), "user": ["id": user, "name": person(user).shortName], "notes": text, "created_on": iso(ago)])
        j.details = details.map { jd("attr", name: $0.0, oldValue: $0.1, newValue: $0.2) }
            + files.map { jd("attachment", name: String($0.id), newValue: $0.filename) }
        issues[id]?.journals.append(j)
        issues[id]?.journals.sort { $0.createdOn < $1.createdOn }
    }

    var crashDescription: String {
        t("""
        h2. Steps to reproduce

        # Put the app in the background
        # Receive a push about a new comment
        # Tap the notification

        h2. Expected

        The issue opens scrolled to the new comment.

        h2. Actual

        The app crashes on *iOS 18.2+*, roughly *1 in 5* attempts. Related: #1238, #1236. Reported by @\(person(6).login ?? "").

        |_. Device |_. iOS |_. Reproduced |
        | iPhone 15 Pro | 18.3 | yes |
        | iPhone 13 | 18.2 | yes |
        | iPad Air | 18.3 | no |

        bq. Users mostly hit it after the phone has been locked for a while.

        <pre>
        Thread 0 Crashed:
        0  RedTask  NotificationRouter.open(_:) + 132
        1  RedTask  AppDelegate.userNotificationCenter(_:didReceive:) + 88
        </pre>

        !crash-screenshot.png!
        """, """
        h2. Как воспроизвести

        # Свернуть приложение
        # Получить пуш о новом комментарии
        # Нажать на уведомление

        h2. Ожидается

        Открывается задача на новом комментарии.

        h2. На деле

        Приложение падает на *iOS 18.2+*, примерно *в одном случае из пяти*. Связано: #1238, #1236. Сообщила @\(person(6).login ?? "").

        |_. Устройство |_. iOS |_. Воспроизводится |
        | iPhone 15 Pro | 18.3 | да |
        | iPhone 13 | 18.2 | да |
        | iPad Air | 18.3 | нет |

        bq. Чаще всего — после того, как телефон какое-то время был заблокирован.

        <pre>
        Thread 0 Crashed:
        0  RedTask  NotificationRouter.open(_:) + 132
        1  RedTask  AppDelegate.userNotificationCenter(_:didReceive:) + 88
        </pre>

        !crash-screenshot.png!
        """)
    }

    var offlineDescription: String {
        t("""
        The list and the last opened issues should work without a network.

        h3. Scope

        * Cached lists: *My*, *Watching*, *Favorites*
        * Issue snapshots — #1239
        * Edits queue and sync — #1241
        ** comments
        ** status and assignee

        |_. Screen |_. Offline |_. Notes |
        | Issue list | read | stale badge |
        | Issue | read | last snapshot |
        | Comment | write | queued |

        Design: @\(person(4).login ?? ""), review by @\(person(2).login ?? "").
        """, """
        Список и последние открытые задачи должны работать без сети.

        h3. Объём

        * Кэш списков: *Мои*, *Отслеживаемые*, *Избранное*
        * Снимки задач — #1239
        * Очередь правок и синхронизация — #1241
        ** комментарии
        ** статус и исполнитель

        |_. Экран |_. Офлайн |_. Примечание |
        | Список задач | чтение | плашка «устарело» |
        | Задача | чтение | последний снимок |
        | Комментарий | запись | в очередь |

        Дизайн — @\(person(4).login ?? ""), ревью — @\(person(2).login ?? "").
        """)
    }

    /// Логин для русских имён: «Алексей Морозов» → «amorozov».
    static func translit(_ first: String, _ last: String) -> String {
        let map: [Character: String] = ["а": "a", "б": "b", "в": "v", "г": "g", "д": "d", "е": "e", "ё": "e", "ж": "zh", "з": "z", "и": "i", "й": "i",
                                        "к": "k", "л": "l", "м": "m", "н": "n", "о": "o", "п": "p", "р": "r", "с": "s", "т": "t", "у": "u", "ф": "f",
                                        "х": "kh", "ц": "ts", "ч": "ch", "ш": "sh", "щ": "sch", "ы": "y", "э": "e", "ю": "yu", "я": "ya"]
        let s = String(first.lowercased().prefix(1)) + last.lowercased()
        return s.map { map[$0] ?? "" }.joined()
    }

    /// Документ ODF со встроенной миниатюрой (без текста): строка вложения покажет её после первого открытия.
    static func odt(thumbnail: Data) -> Data {
        let mime = "application/vnd.oasis.opendocument.text"
        let content = #"<?xml version="1.0" encoding="UTF-8"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" office:version="1.2"><office:body><office:text/></office:body></office:document-content>"#
        return storedZip([("mimetype", Data(mime.utf8)), ("content.xml", Data(content.utf8)), ("Thumbnails/thumbnail.png", thumbnail)])
    }

    /// Zip без сжатия: локальные заголовки, центральный каталог, конец каталога.
    static func storedZip(_ entries: [(String, Data)]) -> Data {
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
        func crc32(_ d: Data) -> Int {
            var c: UInt32 = 0xFFFF_FFFF
            for b in d { c ^= UInt32(b); for _ in 0..<8 { c = c & 1 == 1 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 } }
            return Int(~c)
        }
        var out = Data(), dir = Data()
        for (name, d) in entries {
            let n = Data(name.utf8), common = le(0, 2) + le(0, 2) + le(0, 4) + le(crc32(d), 4) + le(d.count, 4) + le(d.count, 4) + le(n.count, 2) + le(0, 2)
            dir += le(0x02014b50, 4) + le(20, 2) + le(20, 2) + common + le(0, 6) + le(0, 4) + le(out.count, 4) + n
            out += le(0x04034b50, 4) + le(20, 2) + common + n + d
        }
        let cd = out.count
        return out + dir + le(0x06054b50, 4) + le(0, 4) + le(entries.count, 2) + le(entries.count, 2) + le(dir.count, 4) + le(cd, 4) + le(0, 2)
    }

    /// Картинка-заглушка вложения: «окно приложения» с символом.
    static func picture(symbol: String, tint: UIColor) -> Data {
        let size = CGSize(width: 900, height: 560)
        return UIGraphicsImageRenderer(size: size).pngData { ctx in
            let g = ctx.cgContext
            let colors = [tint.withAlphaComponent(0.85).cgColor, tint.withAlphaComponent(0.35).cgColor] as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                g.drawLinearGradient(grad, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
            let card = CGRect(x: 90, y: 70, width: 720, height: 420)
            UIColor.white.setFill()
            UIBezierPath(roundedRect: card, cornerRadius: 28).fill()
            UIColor.systemGray5.setFill()
            UIBezierPath(roundedRect: CGRect(x: card.minX, y: card.minY, width: card.width, height: 56), byRoundingCorners: [.topLeft, .topRight],
                         cornerRadii: CGSize(width: 28, height: 28)).fill()
            for (k, c) in [UIColor.systemRed, .systemYellow, .systemGreen].enumerated() {
                c.setFill()
                UIBezierPath(ovalIn: CGRect(x: card.minX + 26 + CGFloat(k) * 30, y: card.minY + 19, width: 18, height: 18)).fill()
            }
            UIColor.systemGray4.setFill()
            for (k, w) in [420.0, 520, 360, 470].enumerated() {
                UIBezierPath(roundedRect: CGRect(x: card.minX + 260, y: card.minY + 120 + CGFloat(k) * 56, width: CGFloat(w) - 120, height: 22), cornerRadius: 11).fill()
            }
            if let img = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 130, weight: .semibold))?
                .withTintColor(tint, renderingMode: .alwaysOriginal) {
                img.draw(in: CGRect(x: card.minX + 50, y: card.minY + 130, width: 160, height: 150 * img.size.height / img.size.width * 1.05))
            }
        }
    }
}
