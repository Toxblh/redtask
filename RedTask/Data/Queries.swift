import Foundation

// MARK: - Фильтры и сохранённые запросы (spec 17)

/// Фильтр из каталога страницы задач (spec 17.1).
struct FilterDef: Codable, Sendable, Hashable, Identifiable {
    var field: String
    var name: String
    var type: String
    /// Операторы — operatorByType[type].
    var ops: [String]
    /// Пары [подпись, id].
    var values: [[String]]
    /// Значения сервер отдаёт отдельно.
    var remote: Bool
    var id: String { field }

    /// Значения — люди: выбор из п. 8.2 плюс «я». Поля-пользователи (cf_*) приходят remote без values.
    var isPeople: Bool {
        ["author_id", "assigned_to_id", "watcher_id", "updated_by", "last_updated_by"].contains(field) || (remote && field.hasPrefix("cf_"))
    }

    /// Операторы, которые можно предложить: у прочих remote значений в первой версии нет — только операторы без значений.
    var usableOps: [String] { remote && !isPeople ? ops.filter(noValueOps.contains) : ops }
}

/// Каталог фильтров проекта: фильтры по порядку страницы и подписи операторов сервера.
struct FilterCatalog: Codable, Sendable, Hashable {
    var filters: [FilterDef] = []
    var opLabels: [String: String] = [:]

    init(filters: [FilterDef] = [], opLabels: [String: String] = [:]) { self.filters = filters; self.opLabels = opLabels }
    init(html: String) {
        filters = filterCatalog(html)
        let labels = jsObject(html, "operatorLabels").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
        opLabels = labels as? [String: String] ?? [:]
    }

    func def(_ field: String) -> FilterDef? { filters.first { $0.field == field } }
}

/// Операторы без значений.
let noValueOps: Set<String> = ["o", "c", "*", "!*", "t", "ld", "w", "lw", "l2w", "m", "lm", "y", "nd", "nw", "nm", "*o", "!o"]
/// Операторы с числом дней.
let dayOps: Set<String> = ["t+", "t-", ">t-", "<t-", "><t-", ">t+", "<t+", "><t+"]

/// Сколько значений просит оператор: 0, 2 (`><`) или 1 и больше.
func opArity(_ op: String) -> Int { noValueOps.contains(op) ? 0 : op == "><" ? 2 : 1 }

/// Каталог из HTML страницы задач (набор filter_catalog): `var availableFilters = {…};` и `var operatorByType = {…};`.
func filterCatalog(_ html: String) -> [FilterDef] {
    guard let obj = jsObject(html, "availableFilters"),
          let dict = (try? JSONSerialization.jsonObject(with: Data(obj.utf8))) as? [String: Any] else { return [] }
    let opsJSON = jsObject(html, "operatorByType").flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) }
    let ops = opsJSON as? [String: [String]] ?? [:]
    func str(_ v: Any) -> String { v as? String ?? "\(v)" }
    return jsonKeys(obj).compactMap { k in
        guard let f = dict[k] as? [String: Any] else { return nil }
        let type = f["type"] as? String ?? ""
        let values: [[String]] = (f["values"] as? [Any] ?? []).compactMap { v in
            guard let a = v as? [Any], a.count >= 2 else { return nil }
            return [str(a[0]), str(a[1])]
        }
        return FilterDef(field: k, name: f["name"] as? String ?? k, type: type, ops: ops[type] ?? [], values: values,
                         remote: f["remote"] as? Bool ?? false)
    }
}

/// Текст объекта JS-переменной `var name = {…};` (скобки считаются вне строк).
func jsObject(_ html: String, _ name: String) -> String? {
    guard let m = html.range(of: #"var\s+\#(name)\s*=\s*"#, options: .regularExpression) else { return nil }
    let s = html[m.upperBound...]
    guard s.first == "{" else { return nil }
    var depth = 0, inStr = false, esc = false
    for i in s.indices {
        let c = s[i]
        if inStr {
            if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr = false }
            continue
        }
        switch c {
        case "\"": inStr = true
        case "{", "[": depth += 1
        case "}", "]":
            depth -= 1
            if depth == 0 { return String(s[...i]) }
        default: break
        }
    }
    return nil
}

/// Ключи верхнего уровня объекта JSON в порядке текста (JSONSerialization порядок теряет).
func jsonKeys(_ json: String) -> [String] {
    var keys: [String] = [], depth = 0, inStr = false, esc = false, cur = "", last: String?
    for c in json {
        if inStr {
            if esc { esc = false; cur.append(c) } else if c == "\\" { esc = true } else if c == "\"" { inStr = false; last = cur } else { cur.append(c) }
            continue
        }
        switch c {
        case "\"": inStr = true; cur = ""
        case ":": if depth == 1, let k = last { keys.append(k) }; last = nil
        case "{", "[": depth += 1; last = nil
        case "}", "]": depth -= 1; last = nil
        default: if !c.isWhitespace { last = nil }
        }
    }
    return keys
}

/// Условие фильтра: поле, оператор, значения.
struct FilterCond: Codable, Sendable, Hashable {
    var field: String
    var op: String
    var values: [String] = []
    /// Подписи значений-людей (id → имя): у remote-фильтров каталог их не знает.
    var labels: [String: String]? = nil
}

/// Критерий сортировки: поле и asc/desc.
struct SortCrit: Codable, Sendable, Hashable {
    var field: String
    var dir: String
}

/// Условия → f[], op[поле], v[поле][] по порядку; у операторов без значений v нет.
func filterConditionParams(_ filters: [FilterCond]) -> [(String, String)] {
    filters.flatMap { c -> [(String, String)] in
        [("f[]", c.field), ("op[\(c.field)]", c.op)] + (noValueOps.contains(c.op) ? [] : c.values.map { ("v[\(c.field)][]", $0) })
    }
}

/// Параметры issues.json (набор filter_params): set_filter=1, условия, sort=поле:dir,…
func filterParams(_ filters: [FilterCond], sort: [SortCrit]) -> [(String, String)] {
    [("set_filter", "1")] + filterConditionParams(filters)
        + (sort.isEmpty ? [] : [("sort", sort.map { "\($0.field):\($0.dir)" }.joined(separator: ","))])
}

/// Поля веб-формы сохранения запроса после authenticity_token (набор query_form).
/// visibility: 0 — только мне, 1 — ролям, 2 — всем.
func queryFormFields(name: String, description: String, visibility: Int, roleIds: [Int], forAll: Bool,
                     filters: [FilterCond], sort: [SortCrit]) -> [(String, String)] {
    var p = [("query[name]", name), ("query[description]", description), ("query[visibility]", String(visibility))]
    if visibility == 1 { p += roleIds.map { ("query[role_ids][]", String($0)) } }
    if forAll { p.append(("query_is_for_all", "1")) }
    p += filterConditionParams(filters)
    for (i, s) in sort.enumerated() { p += [("query[sort_criteria][\(i)][]", s.field), ("query[sort_criteria][\(i)][]", s.dir)] }
    return p
}

/// id сохранённого запроса из Location ответа 302 (набор query_saved): только список задач с query_id.
func savedQueryId(_ location: String) -> Int? {
    guard let c = URLComponents(string: location), c.path == "/issues" || c.path.hasSuffix("/issues"),
          let v = c.queryItems?.first(where: { $0.name == "query_id" })?.value else { return nil }
    return Int(v)
}

/// Текст ошибки формы (#errorExplanation) — пункты списка через перевод строки. nil — ошибки на странице нет.
func formErrors(_ html: String) -> String? {
    guard let block = html.firstMatch(of: /(?s)<div[^>]*id="errorExplanation"[^>]*>(.*?)<\/div>/)?.1 else { return nil }
    func text(_ s: Substring) -> String {
        let bare = String(s).replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        return decodeEntities(bare).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    let items = block.matches(of: /(?s)<li[^>]*>(.*?)<\/li>/).map { text($0.1) }.filter { !$0.isEmpty }
    let out = items.isEmpty ? text(block) : items.joined(separator: "\n")
    return out.isEmpty ? nil : out
}

/// Тело application/x-www-form-urlencoded: всё, кроме ASCII-букв, цифр и -._*, — процентами в UTF-8.
func formEncode(_ p: [(String, String)]) -> Data {
    let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
    func e(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
    return Data(p.map { "\(e($0.0))=\(e($0.1))" }.joined(separator: "&").utf8)
}

/// Что запустить: свои условия или сохранённый на сервере запрос (query_id) — в проекте или по всем.
struct IssueFilter: Codable, Sendable, Hashable {
    var projectId: Int?
    var filters: [FilterCond] = []
    var sort: [SortCrit] = []
    var queryId: Int?

    func params(limit: Int, offset: Int) -> [(String, String)] {
        var p = queryId.map { [("query_id", String($0))] } ?? filterParams(filters, sort: sort)
        if let projectId { p.append(("project_id", String(projectId))) }
        return p + [("limit", String(limit)), ("offset", String(offset))]
    }

    /// Ключ «по параметрам»: недавние с одинаковым ключом схлопываются.
    var key: String { params(limit: 0, offset: 0).map { "\($0.0)=\($0.1)" }.joined(separator: "&") }
}

/// Недавние фильтры (spec 17.2): свежий наверх, одинаковые по параметрам схлопываются, не больше 10.
func recentFilters(_ list: [IssueFilter], _ new: IssueFilter) -> [IssueFilter] {
    Array(([new] + list.filter { $0.key != new.key }).prefix(10))
}

/// Запуск с именем — строка списка и избранного (spec 17.5). id: «local:…», «server:N», «recent:ключ».
struct QueryRun: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var name: String
    var filter: IssueFilter
}

/// Запрос, сохранённый у себя (spec 17.3). На сервере — есть serverId и нет error.
struct LocalQuery: Codable, Sendable, Hashable, Identifiable {
    var localId = UUID().uuidString
    var name: String
    var description = ""
    /// Проект, из которого сохранён (nil — без проекта).
    var projectId: Int?
    var forAll = false
    var filters: [FilterCond] = []
    var sort: [SortCrit] = []
    /// 0 — только мне, 1 — ролям, 2 — всем.
    var visibility = 0
    var roleIds: [Int] = []
    var serverId: Int?
    /// Почему не на сервере («Только на устройстве»); nil — на сервере или ещё не пробовали.
    var error: String?
    /// Удалён на сайте: на сервер заново сам не отправляется.
    var detached = false

    var id: String { localId }
    var onServer: Bool { serverId != nil && error == nil }
    /// Проект запроса или nil — «для всех проектов».
    var scope: Int? { forAll ? nil : projectId }
    var run: QueryRun { QueryRun(id: "local:\(localId)", name: name, filter: IssueFilter(projectId: scope, filters: filters, sort: sort)) }
    var formFields: [(String, String)] {
        queryFormFields(name: name, description: description, visibility: visibility, roleIds: roleIds, forAll: forAll, filters: filters, sort: sort)
    }
}

/// Сохранённый запрос из queries.json.
struct ServerQuery: Codable, Sendable, Hashable, Identifiable {
    var id: Int
    @D var name: String
    @D var isPublic: Bool
    var projectId: Int?
}

struct QueriesResponse: Codable, Sendable { @D var queries: [ServerQuery]; @D var totalCount: Int }
struct RolesResponse: Codable, Sendable { @D var roles: [Named] }

/**
 Сверка с queries.json (spec 17.4): локальный с server_id, которого на сервере нет, — удалён на сайте:
 server_id сбрасывается, «Только на устройстве»; есть на сервере — имя с сервера.
 */
func syncLocalQueries(_ local: [LocalQuery], server: [ServerQuery], deletedReason: String) -> [LocalQuery] {
    let byId = Dictionary(server.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return local.map { q in
        guard let sid = q.serverId else { return q }
        var q = q
        if let s = byId[sid] {
            if !s.name.isEmpty { q.name = s.name }
        } else {
            q.serverId = nil
            q.detached = true
            q.error = deletedReason
        }
        return q
    }
}
