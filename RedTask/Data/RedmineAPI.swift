import Foundation
import Synchronization

struct RedmineError: LocalizedError, Sendable {
    var code: Int
    var message: String
    var errorDescription: String? { message }
}

/// Ответ WAF вместо Redmine: просили JSON, пришёл HTML с 200 и без заголовка Rails.
func isWafChallenge(accept: String?, code: Int, contentType: String?, requestId: String?) -> Bool {
    accept == "application/json" && code == 200 && (contentType ?? "").contains("html") && requestId == nil
}

/// Можно ли отдавать ключ по этому адресу: только хост сервера и без понижения https → http.
func keyAllowed(base: URL, target: URL) -> Bool {
    target.host?.lowercased() == base.host?.lowercased() && (target.scheme == "https" || base.scheme != "https")
}

/// Разбор CSV-экспорта Redmine: разделитель «;» или «,», кавычки с удвоением, переводы строк внутри кавычек.
func parseCSV(_ text: String) -> [[String]] {
    let src = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)
    // разделитель — символ сразу после первой колонки заголовка («#;…» в русской локали, «#,…» в английской)
    let first = src.first { $0 == ";" || $0 == "," || $0 == "\n" || $0 == "\r\n" }
    let sep: Character = (first == ";" || first == ",") ? first! : ";"
    var rows: [[String]] = [], row: [String] = [], cell = ""
    var quoted = false, i = 0
    while i < src.count {
        let c = src[i]
        if quoted && c == "\"" && i + 1 < src.count && src[i + 1] == "\"" { cell.append("\""); i += 1 }
        else if c == "\"" { quoted.toggle() }
        else if !quoted && c == sep { row.append(cell); cell = "" }
        else if !quoted && (c == "\n" || c == "\r" || c == "\r\n") {
            if c == "\r" && i + 1 < src.count && src[i + 1] == "\n" { i += 1 }
            row.append(cell); cell = ""; rows.append(row); row = []
        } else { cell.append(c) }
        i += 1
    }
    if !cell.isEmpty || !row.isEmpty { row.append(cell); rows.append(row) }
    return rows
}

/// Redmine отклоняет updated_on с дробными секундами (422) — всегда целые секунды и Z.
func redmineISO(_ date: Date) -> String {
    let whole = Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    return whole.formatted(Date.ISO8601FormatStyle(timeZone: .gmt))
}

/// ISO-время Redmine («2026-10-22T13:25:35Z», иногда с дробью или смещением) → Date.
func parseRedmineDate(_ s: String?) -> Date? {
    guard let s, !s.isEmpty else { return nil }
    if let d = try? Date(s, strategy: .iso8601) { return d }
    if let d = try? Date(s, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) { return d }
    // «2026-10-22» — день без времени
    if s.count >= 10, let d = try? Date(String(s.prefix(10)), strategy: Date.ISO8601FormatStyle().year().month().day()) { return d }
    return nil
}

/// Капча WAF: последний ответ — проверка, и после решения в WebView — его куки и UA.
final class WafGate: Sendable {
    static let shared = WafGate()
    private struct State { var cookieHeader: String?; var agent: String? }
    private let state = Mutex(State())

    /// UA и куки WebView, в котором решили капчу; nil — ходим как обычно.
    var browser: (cookie: String, agent: String)? {
        state.withLock { s in
            guard let c = s.cookieHeader, let a = s.agent, !c.isEmpty else { return nil }
            return (c, a)
        }
    }

    func setBrowser(cookie: String?, agent: String?) {
        state.withLock { $0 = State(cookieHeader: cookie, agent: agent) }
    }
}

/// Чужой хост (картинка из текста, редирект) ключ не получает.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    let base: URL
    let follow: Bool
    init(base: URL, follow: Bool) { self.base = base; self.follow = follow }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard follow else { return nil }
        var r = request
        if let u = r.url, !keyAllowed(base: base, target: u) {
            r.setValue(nil, forHTTPHeaderField: "X-Redmine-API-Key")
            r.setValue(nil, forHTTPHeaderField: "Authorization")
            r.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        return r
    }
}

/// Запрос задач для списков и опроса.
struct IssueQuery: Sendable, Hashable {
    var projectId: Int?
    var assignedToMe = false
    var watchedByMe = false
    var authoredByMe = false
    var statusFilter = "open" // open | closed | *
    var parentId: Int?
    var subject: String?
    var issueIds: [Int]?
    var updatedSince: String?
    var sort = "updated_on:desc"
    var limit = 50
    var offset = 0
}

/**
 Тонкий клиент REST API Redmine (ключ в X-Redmine-API-Key). Один на пару «сервер + ключ»:
 отказы сервера (наблюдатели в задаче, /custom_fields.json, фильтр по комментариям) помнит до смены учётки.
 Разбор JSON — не на главном потоке.
 */
final class RedmineAPI: Sendable {
    let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let noRedirectSession: URLSession

    private struct Memo { var watchersForbidden: Set<Int> = []; var customFieldsForbidden = false; var mentionFilterUnsupported = false }
    private let memo = Mutex(Memo())

    static let userAgent = "RedTask/1.0 (iOS)"
    private static let wafRetries = 3

    init(baseURL: URL, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 40
        cfg.httpShouldSetCookies = false // куки браузера (капча) кладём сами и только на свой хост
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        session = URLSession(configuration: cfg, delegate: RedirectGuard(base: baseURL, follow: true), delegateQueue: nil)
        noRedirectSession = URLSession(configuration: cfg, delegate: RedirectGuard(base: baseURL, follow: false), delegateQueue: nil)
    }

    var mentionFilterUnsupported: Bool {
        get { memo.withLock { $0.mentionFilterUnsupported } }
    }
    func watchersForbidden(_ issueId: Int) -> Bool { memo.withLock { $0.watchersForbidden.contains(issueId) } }

    // MARK: адреса

    func url(_ path: String, _ query: [(String, String?)] = []) -> URL {
        var u = baseURL
        // сохраняем установки в подкаталоге (https://host/redmine)
        for seg in path.split(separator: "/") where !seg.isEmpty { u.appendPathComponent(String(seg)) }
        let items = query.compactMap { k, v in v.map { URLQueryItem(name: k, value: $0) } }
        guard !items.isEmpty, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        c.queryItems = items
        // «+» в запросе сервер прочтёт как пробел
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url ?? u
    }

    func issueWebURL(_ id: Int) -> URL { baseURL.appendingPathComponent("issues").appendingPathComponent(String(id)) }

    /// Свой хост с пониженной схемой (http content_url за TLS-прокси) → схема и порт сервера.
    private func own(_ u: URL) -> URL {
        guard u.host == baseURL.host, baseURL.scheme == "https", u.scheme != "https",
              var c = URLComponents(url: u, resolvingAgainstBaseURL: false) else { return u }
        c.scheme = "https"; c.port = baseURL.port
        return c.url ?? u
    }

    private func request(_ url: URL, method: String = "GET", accept: String = "application/json") -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue(accept, forHTTPHeaderField: "Accept")
        if keyAllowed(base: baseURL, target: url) {
            r.setValue(apiKey, forHTTPHeaderField: "X-Redmine-API-Key")
            if let b = WafGate.shared.browser {
                r.setValue(b.cookie, forHTTPHeaderField: "Cookie")
                r.setValue(b.agent, forHTTPHeaderField: "User-Agent")
            } else {
                r.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            }
        }
        return r
    }

    // MARK: исполнение

    /**
     WAF перед сервером случайно (замерено: каждый 4–5-й запрос) отвечает «Security check»:
     200 + HTML, до Redmine запрос не доходит (нет X-Request-Id) — повтор безопасен и для записи.
     */
    private func perform(_ req: URLRequest, session: URLSession? = nil) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            let (data, resp) = try await (session ?? self.session).data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw RedmineError(code: 0, message: "No HTTP response") }
            let captcha = isWafChallenge(accept: req.value(forHTTPHeaderField: "Accept"), code: http.statusCode,
                                         contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                         requestId: http.value(forHTTPHeaderField: "X-Request-Id"))
            if captcha && attempt < Self.wafRetries {
                attempt += 1
                try await Task.sleep(for: .milliseconds(300 * attempt))
                continue
            }
            if req.value(forHTTPHeaderField: "Accept") == "application/json" {
                await WafState.shared.set(captcha)
            }
            return (data, http)
        }
    }

    @discardableResult
    private func exec(_ req: URLRequest) async throws -> Data {
        let (data, http) = try await perform(req)
        let ct = http.value(forHTTPHeaderField: "Content-Type") ?? ""
        let json = req.value(forHTTPHeaderField: "Accept") == "application/json"
        if isWafChallenge(accept: req.value(forHTTPHeaderField: "Accept"), code: http.statusCode, contentType: ct,
                          requestId: http.value(forHTTPHeaderField: "X-Request-Id")) {
            throw RedmineError(code: 200, message: String(localized: "The server asks for a captcha (Security check)"))
        }
        // страница логина вместо JSON: для записи это НЕ успех — иначе комментарий молча пропадёт
        if (200..<300).contains(http.statusCode) && json && ct.contains("html") {
            throw RedmineError(code: 200, message: String(localized: "Unexpected response from server"))
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = ((try? JSON.decoder().decode(ErrorsResponse.self, from: data))?.errors ?? []).joined(separator: ", ")
            let msg: String
            switch http.statusCode {
            case 401: msg = String(localized: "Unauthorized: check the API key")
            case 403: msg = String(localized: "Forbidden") + (detail.isEmpty ? "" : ": \(detail)")
            case 404: msg = String(localized: "Not found")
            case 422: msg = detail.isEmpty ? String(localized: "Validation failed") : detail
            default: msg = "HTTP \(http.statusCode)" + (detail.isEmpty ? "" : ": \(detail)")
            }
            throw RedmineError(code: http.statusCode, message: msg)
        }
        return data
    }

    @concurrent
    private func get<T: Decodable & Sendable>(_ path: String, _ query: [(String, String?)] = []) async throws -> T {
        let data = try await exec(request(url(path, query)))
        do { return try JSON.decoder().decode(T.self, from: data) }
        catch { throw RedmineError(code: 200, message: String(localized: "Unexpected response from server")) }
    }

    @discardableResult
    private func send(_ method: String, _ path: String, _ payload: [String: Any]) async throws -> Data {
        var r = request(url(path), method: method)
        r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONSerialization.data(withJSONObject: payload)
        return try await exec(r)
    }

    private func delete(_ path: String) async throws {
        try await exec(request(url(path), method: "DELETE"))
    }

    // MARK: пользователи и права

    func currentUser() async throws -> User { try await (get("users/current.json") as UserResponse).user }

    /// Мои роли по проектам. Ответ — больше мегабайта: звать редко, результат кэширует RefData.
    func myRoles() async throws -> MyRoles {
        let me = try await (get("users/current.json", [("include", "memberships")]) as MeWithMembershipsResponse).user
        var roles: [Int: Set<Int>] = [:]
        for m in me.memberships { if let p = m.project { roles[p.id, default: []].formUnion(m.roles.map(\.id)) } }
        return MyRoles(admin: me.admin, roles: roles.mapValues { Array($0) })
    }

    func rolePermissions(_ roleId: Int) async throws -> [String] { try await (get("roles/\(roleId).json") as RoleResponse).role.permissions }

    // MARK: справочники

    func statuses() async throws -> [IssueStatus] { try await (get("issue_statuses.json") as StatusesResponse).issueStatuses }
    func priorities() async throws -> [Priority] {
        try await (get("enumerations/issue_priorities.json") as PrioritiesResponse).issuePriorities.filter { $0.active != false }
    }
    func trackers() async throws -> [Tracker] { try await (get("trackers.json") as TrackersResponse).trackers }
    func activities() async throws -> [TimeEntryActivity] {
        try await (get("enumerations/time_entry_activities.json") as ActivitiesResponse).timeEntryActivities.filter { $0.active != false }
    }

    // MARK: проекты

    func projects() async throws -> [Project] {
        var all: [Project] = []
        var offset = 0
        while true {
            let page: ProjectsResponse = try await get("projects.json", [("limit", "100"), ("offset", String(offset))])
            all += page.projects
            offset += 100
            if all.count >= page.totalCount || page.projects.isEmpty || offset >= 2000 { break }
        }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted } // страницы могут перекрыться
    }

    func project(_ id: Int) async throws -> Project { try await (get("projects/\(id).json", [("include", "trackers")]) as ProjectResponse).project }
    func versions(_ projectId: Int) async throws -> [Version] { try await (get("projects/\(projectId)/versions.json") as VersionsResponse).versions }
    func issueCategories(_ projectId: Int) async throws -> [Named] {
        try await (get("projects/\(projectId)/issue_categories.json") as CategoriesResponse).issueCategories
    }

    /// Настраиваемые поля, включённые в проекте: только id и имена, зато доступно не-админу.
    func projectIssueCustomFields(_ projectId: Int) async throws -> [Named] {
        try await (get("projects/\(projectId).json", [("include", "issue_custom_fields")]) as ProjectResponse).project.issueCustomFields
    }

    /// /custom_fields.json на многих серверах только для админа: на 403 — пусто, и больше не спрашиваем.
    func customFieldDefs() async throws -> [CustomFieldDef] {
        if memo.withLock({ $0.customFieldsForbidden }) { return [] }
        do {
            return try await (get("custom_fields.json") as CustomFieldsResponse).customFields.filter { $0.customizedType == "issue" }
        } catch let e as RedmineError where e.code == 403 {
            memo.withLock { $0.customFieldsForbidden = true }
            return []
        }
    }

    /// Участники проекта; группы тоже — задачу можно назначить на группу.
    func members(_ projectId: Int) async throws -> [Named] {
        var out: [Int: Named] = [:]
        var offset = 0
        while true {
            let page: MembershipsResponse = try await get("projects/\(projectId)/memberships.json", [("limit", "100"), ("offset", String(offset))])
            for m in page.memberships { if let n = m.user ?? m.group { out[n.id] = n } }
            offset += 100
            if offset >= page.totalCount || page.memberships.isEmpty || offset >= 1000 { break }
        }
        return out.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: задачи

    func issues(_ q: IssueQuery) async throws -> IssuesResponse {
        try await get("issues.json", [
            ("limit", String(q.limit)), ("offset", String(q.offset)), ("sort", q.sort), ("status_id", q.statusFilter),
            ("project_id", q.projectId.map(String.init)), ("parent_id", q.parentId.map(String.init)),
            ("assigned_to_id", q.assignedToMe ? "me" : nil), ("watcher_id", q.watchedByMe ? "me" : nil),
            ("author_id", q.authoredByMe ? "me" : nil), ("subject", q.subject.map { "~\($0)" }),
            ("issue_id", q.issueIds?.map(String.init).joined(separator: ",")),
            ("updated_on", q.updatedSince.map { ">=\($0)" }),
        ])
    }

    /// Задачи по id (пачками по 100, в порядке запроса) и id, которых сервер не вернул: удалены или недоступны.
    func issuesByIds(_ ids: [Int]) async throws -> (found: [Issue], missing: [Int]) {
        var uniq: [Int] = []
        var seen = Set<Int>()
        for id in ids where seen.insert(id).inserted { uniq.append(id) }
        var found: [Int: Issue] = [:]
        for start in stride(from: 0, to: uniq.count, by: 100) {
            let chunk = Array(uniq[start..<min(start + 100, uniq.count)])
            var q = IssueQuery(statusFilter: "*", issueIds: chunk, limit: 100)
            q.sort = "id:desc"
            for i in try await issues(q).issues { found[i.id] = i }
        }
        return (uniq.compactMap { found[$0] }, uniq.filter { found[$0] == nil })
    }

    func issue(_ id: Int) async throws -> Issue {
        try await (get("issues/\(id).json", [("include", "children,relations,journals,attachments,allowed_statuses,watchers")]) as IssueResponse).issue
    }

    func issueJournals(_ id: Int) async throws -> Issue {
        try await (get("issues/\(id).json", [("include", "journals")]) as IssueResponse).issue
    }

    /// Задачи, созданные не раньше createdSince, в проектах, где я участник (полная форма фильтра:
    /// короткое project_id=mine сервер принял бы за идентификатор проекта).
    func newIssuesInMyProjects(createdSince: String, offset: Int) async throws -> IssuesResponse {
        try await get("issues.json", [
            ("set_filter", "1"),
            ("f[]", "project_id"), ("op[project_id]", "="), ("v[project_id][]", "mine"),
            ("f[]", "created_on"), ("op[created_on]", ">="), ("v[created_on][]", createdSince),
            ("sort", "id:desc"), ("limit", "100"), ("offset", String(offset)),
        ])
    }

    /**
     Задачи любого статуса, изменённые не раньше updatedSince, в комментариях которых есть «@login»:
     search.json журналы не индексирует, а фильтр списка задач по заметкам — читает.
     */
    func issuesMentioning(login: String, updatedSince: String, offset: Int = 0) async throws -> IssuesResponse {
        try await get("issues.json", [
            ("set_filter", "1"),
            ("f[]", "notes"), ("op[notes]", "~"), ("v[notes][]", "@\(login)"),
            ("f[]", "updated_on"), ("op[updated_on]", ">="), ("v[updated_on][]", updatedSince),
            ("status_id", "*"), ("sort", "updated_on:desc"), ("limit", "100"), ("offset", String(offset)),
        ])
    }

    func markMentionFilterUnsupported() { memo.withLock { $0.mentionFilterUnsupported = true } }

    /// PUT задачи; fields — содержимое «issue». Сброс значения — пустая строка (так ждёт Redmine).
    func updateIssue(_ id: Int, _ fields: [String: Any], uploads: [UploadRef] = []) async throws {
        var f = fields
        if !uploads.isEmpty { f["uploads"] = Self.uploadsJSON(uploads) }
        try await send("PUT", "issues/\(id).json", ["issue": f])
    }

    static func uploadsJSON(_ uploads: [UploadRef]) -> [[String: Any]] {
        uploads.map { u in
            var d: [String: Any] = ["token": u.token, "filename": u.filename]
            if let t = u.contentType { d["content_type"] = t }
            if let s = u.description, !s.isEmpty { d["description"] = s }
            return d
        }
    }

    func createIssue(_ fields: [String: Any]) async throws -> Issue {
        let data = try await send("POST", "issues.json", ["issue": fields])
        return try JSON.decoder().decode(IssueResponse.self, from: data).issue
    }

    /// Выбор задачи по тому, что помнит человек: номер (можно с #) первым, плюс совпадения в теме.
    func findIssues(_ query: String, limit: Int = 20) async throws -> [Issue] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        let bare = q.hasPrefix("#") ? String(q.dropFirst()).trimmingCharacters(in: .whitespaces) : q
        let id = Int(bare).flatMap { $0 > 0 ? $0 : nil }
        async let byId: Issue? = {
            guard let id else { return nil }
            do { return try await (self.get("issues/\(id).json") as IssueResponse).issue }
            catch let e as RedmineError where e.code == 404 || e.code == 403 { return nil }
        }()
        let bySubject = try await issues(IssueQuery(statusFilter: "*", subject: id != nil ? bare : q, limit: limit)).issues
        var seen = Set<Int>()
        return ([try await byId].compactMap { $0 } + bySubject).filter { seen.insert($0.id).inserted }
    }

    /// HTML-страница под веб-сессией WebView (для форм, которых нет в REST). Редиректы не идём. nil — не 200.
    func webPage(_ path: String, cookie: String, userAgent: String, _ query: [(String, String?)] = []) async throws -> String? {
        var r = URLRequest(url: url(path, query))
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("text/html", forHTTPHeaderField: "Accept")
        let (data, http) = try await perform(r, session: noRedirectSession)
        return http.statusCode == 200 ? String(decoding: data, as: UTF8.self) : nil
    }

    // MARK: наблюдатели

    private func watchers(_ issueId: Int, _ block: () async throws -> Void) async throws {
        do { try await block() } catch let e as RedmineError where e.code == 403 {
            memo.withLock { _ = $0.watchersForbidden.insert(issueId) }
            throw e
        }
    }

    func addWatcher(_ issueId: Int, userId: Int) async throws {
        try await watchers(issueId) { try await send("POST", "issues/\(issueId)/watchers.json", ["user_id": userId]) }
    }

    func removeWatcher(_ issueId: Int, userId: Int) async throws {
        try await watchers(issueId) { try await delete("issues/\(issueId)/watchers/\(userId).json") }
    }

    // MARK: комментарии

    /// Правка своего комментария; пустой notes удаляет его (журнал без изменений полей исчезает целиком).
    func updateJournal(_ id: Int, notes: String, privateNotes: Bool? = nil) async throws {
        var j: [String: Any] = ["notes": notes]
        if let p = privateNotes { j["private_notes"] = p }
        try await send("PUT", "journals/\(id).json", ["journal": j])
    }

    // MARK: связи

    /// type — с точки зрения issueId; delay — дни, только precedes/follows.
    func addRelation(_ issueId: Int, type: String, to: Int, delay: Int? = nil) async throws {
        var r: [String: Any] = ["relation_type": type, "issue_to_id": to]
        if let delay { r["delay"] = delay }
        try await send("POST", "issues/\(issueId)/relations.json", ["relation": r])
    }

    func deleteRelation(_ id: Int) async throws { try await delete("relations/\(id).json") }

    // MARK: время

    func timeEntries(issueId: Int) async throws -> [TimeEntry] {
        var all: [TimeEntry] = []
        while true {
            let page: TimeEntriesResponse = try await get("time_entries.json", [
                ("issue_id", String(issueId)), ("limit", "100"), ("offset", String(all.count)),
            ])
            all += page.timeEntries
            // ponytail: потолок 5000 записей на задачу (50 запросов)
            if page.timeEntries.isEmpty || all.count >= page.totalCount || all.count >= 5000 { break }
        }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }
    }

    /// Списания с даты (все видимые проекты), свежесозданные первыми — читаем до границы окна.
    func timeEntries(from: String, createdAfter: Date) async throws -> [TimeEntry] {
        var all: [TimeEntry] = []
        while true {
            let page: TimeEntriesResponse = try await get("time_entries.json", [
                ("from", from), ("sort", "created_on:desc"), ("limit", "100"), ("offset", String(all.count)),
            ])
            all += page.timeEntries
            let oldest = parseRedmineDate(page.timeEntries.last?.createdOn)
            // ponytail: страховка от сервера, игнорирующего sort, — 3000 записей
            if page.timeEntries.isEmpty || all.count >= page.totalCount || (oldest.map { $0 <= createdAfter } ?? false) || all.count >= 3000 { break }
        }
        var seen = Set<Int>()
        return all.filter { seen.insert($0.id).inserted }
    }

    private func timePayload(hours: Double, activityId: Int?, comments: String, spentOn: String?) -> [String: Any] {
        var t: [String: Any] = ["hours": hours, "comments": comments]
        if let a = activityId { t["activity_id"] = a }
        if let s = spentOn { t["spent_on"] = s }
        return t
    }

    func logTime(issueId: Int, hours: Double, activityId: Int?, comments: String, spentOn: String?) async throws {
        var t = timePayload(hours: hours, activityId: activityId, comments: comments, spentOn: spentOn)
        t["issue_id"] = issueId
        try await send("POST", "time_entries.json", ["time_entry": t])
    }

    func updateTimeEntry(_ id: Int, hours: Double, activityId: Int?, comments: String, spentOn: String?) async throws {
        try await send("PUT", "time_entries/\(id).json", ["time_entry": timePayload(hours: hours, activityId: activityId, comments: comments, spentOn: spentOn)])
    }

    func deleteTimeEntry(_ id: Int) async throws { try await delete("time_entries/\(id).json") }

    // MARK: поиск

    func searchPage(_ q: String, offset: Int = 0, limit: Int = 30) async throws -> SearchResponse {
        var r: SearchResponse = try await get("search.json", [("q", q), ("issues", "1"), ("limit", String(limit)), ("offset", String(offset))])
        r.results = r.results.filter { $0.type.hasPrefix("issue") }
        return r
    }

    // MARK: файлы

    /// Содержимое вложения с ключом — браузеру это недоступно.
    @concurrent
    func download(_ urlString: String) async throws -> Data {
        guard let u = URL(string: urlString) else { throw RedmineError(code: 0, message: "Bad URL") }
        let (data, http) = try await perform(request(own(u), accept: "*/*"))
        guard (200..<300).contains(http.statusCode) else { throw RedmineError(code: http.statusCode, message: "HTTP \(http.statusCode)") }
        return data
    }

    func attachment(_ id: Int) async throws -> Attachment { try await (get("attachments/\(id).json") as AttachmentResponse).attachment }
    func deleteAttachment(_ id: Int) async throws { try await delete("attachments/\(id).json") }

    /// Миниатюра. nil — определённое «нет» (не картинка, нет прав); исключение — сбой, звать позже.
    @concurrent
    func thumbnail(_ attachmentId: Int, size: Int = 200) async throws -> Data? {
        let (data, http) = try await perform(request(url("attachments/thumbnail/\(attachmentId)/\(size)"), accept: "image/*"))
        let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let ok = (200..<300).contains(http.statusCode)
        if ok && type.hasPrefix("image/") { return data }
        if ok && type.contains("html") { throw RedmineError(code: 200, message: "Unexpected response from server") }
        if ok || [403, 404, 406].contains(http.statusCode) { return nil }
        throw RedmineError(code: http.statusCode, message: "thumbnail: HTTP \(http.statusCode)")
    }

    /// Загрузка файла: POST /uploads.json (только octet-stream, иначе 406) → токен.
    func upload(_ data: Data, filename: String, contentType: String?) async throws -> UploadRef {
        var r = request(url("uploads.json", [("filename", filename)]), method: "POST")
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.httpBody = data
        let body = try await exec(r)
        let token = try JSON.decoder().decode(UploadResponse.self, from: body).upload.token
        return UploadRef(token: token, filename: filename, contentType: contentType)
    }

    /**
     Подписи значений настраиваемых полей, которые REST отдаёт идентификаторами («341» → «Интервью»):
     CSV-экспорт принимает ключ и печатает значения как сайт. id поля → текст; сбой — пусто.
     */
    func customFieldLabels(issueId: Int, fields: [CustomField]) async -> [Int: String] {
        let ids = fields.filter { f in
            let v = f.values
            return !v.isEmpty && v.allSatisfy { $0.count <= 9 && $0.allSatisfy(\.isNumber) }
        }
        guard !ids.isEmpty else { return [:] }
        var q: [(String, String?)] = [("issue_id", String(issueId)), ("status_id", "*"), ("encoding", "UTF-8")]
        q += ids.map { ("c[]", "cf_\($0.id)") }
        guard let data = try? await exec(request(url("issues.csv", q), accept: "text/csv")) else { return [:] }
        let rows = parseCSV(String(decoding: data, as: UTF8.self))
        guard rows.count >= 2 else { return [:] }
        var out: [Int: String] = [:]
        for f in ids {
            guard let col = rows[0].firstIndex(of: f.name), col > 0, col < rows[1].count else { continue }
            let text = rows[1][col].trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && text != f.values.joined(separator: ", ") { out[f.id] = text }
        }
        return out
    }

    // MARK: люди (плагин redmine_people)

    /// HTML-страницы People не принимают ключ в заголовке — только Basic «ключ:x».
    private func htmlRequest(_ path: String) -> URLRequest {
        var r = URLRequest(url: url(path))
        r.setValue("Basic " + Data("\(apiKey):x".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        r.setValue(WafGate.shared.browser?.agent ?? Self.userAgent, forHTTPHeaderField: "User-Agent")
        if let c = WafGate.shared.browser?.cookie { r.setValue(c, forHTTPHeaderField: "Cookie") }
        return r
    }

    /// Имя по id из <title> страницы /people/:id (удалённые и не-участники проекта).
    func personName(_ userId: Int) async throws -> String? {
        let (data, http) = try await perform(htmlRequest("people/\(userId)"))
        guard (200..<300).contains(http.statusCode) else { return nil }
        let page = String(decoding: data, as: UTF8.self)
        guard let m = try? /<title>(.*?)\s*[-–—·|]/.dotMatchesNewlines().firstMatch(in: page) else { return nil }
        let t = String(m.1).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 120 else { return nil }
        // «Сотрудник #123: Отдел…» → «Сотрудник #123»
        let head = t.split(separator: ":", maxSplits: 1).first.map(String.init) ?? t
        return head.isEmpty ? t : head
    }

    /// Поиск по сотрудникам (People): по НАЧАЛУ фамилии/имени/логина, без учёта регистра.
    func searchPeople(_ q: String, limit: Int = 8) async throws -> [Person] {
        try await (get("people.json", [("search", q), ("limit", String(limit))]) as PeopleListResponse).people
    }

    /// Профиль: People → /users/:id → имя со страницы /people/:id.
    func person(_ userId: Int) async throws -> Person {
        do { return try await (get("people/\(userId).json") as PeopleResponse).person }
        catch let e as RedmineError where e.code == 404 || e.code == 403 {
            do {
                let u = try await (get("users/\(userId).json") as UserResponse).user
                var p = Person(id: u.id, login: u.login, firstname: u.firstname, lastname: u.lastname)
                p.mail = u.mail
                return p
            } catch {
                if let n = try await personName(userId) { return Person(id: userId, firstname: n) }
                throw error
            }
        }
    }

    /**
     Аватарка: страница /people/:id → id вложения → метаданные → картинка.
     nil — определённое «нет» (плагина нет, фото нет, нет прав); исключение — сбой, звать позже.
     */
    func avatar(_ userId: Int) async throws -> Data? {
        let (data, http) = try await perform(htmlRequest("people/\(userId)"))
        if [401, 403, 404].contains(http.statusCode) { return nil }
        guard (200..<300).contains(http.statusCode) else { throw RedmineError(code: http.statusCode, message: "people: HTTP \(http.statusCode)") }
        let page = String(decoding: data, as: UTF8.self)
        guard let m = try? /class="avatar"[\s\S]{0,500}?href="[^"]*?\/attachments\/(\d+)"/.firstMatch(in: page),
              let attId = Int(m.1) else { return nil }
        let content: String
        do { content = try await attachment(attId).contentUrl }
        catch let e as RedmineError where e.code == 404 || e.code == 403 { return nil }
        guard !content.isEmpty, let u = URL(string: content) else { return nil }
        let (img, r) = try await perform(request(own(u), accept: "image/*"))
        let type = (r.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if (200..<300).contains(r.statusCode) && type.hasPrefix("image/") { return img }
        if [403, 404].contains(r.statusCode) { return nil }
        throw RedmineError(code: r.statusCode, message: "avatar: HTTP \(r.statusCode)")
    }
}

/// Капча на экране: показываем кнопку «Решить капчу», пока последний ответ — проверка WAF.
@MainActor @Observable
final class WafState {
    static let shared = WafState()
    var blocked = false
    nonisolated func set(_ v: Bool) async {
        await MainActor.run { if self.blocked != v { self.blocked = v } }
    }
}
