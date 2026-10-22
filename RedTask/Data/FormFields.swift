import Foundation

/// Настраиваемое поле формы: формат, обязательность, варианты (значение → подпись), значение по умолчанию.
struct FormField: Identifiable, Hashable, Sendable {
    struct Option: Hashable, Sendable { var value: String; var label: String }
    var id: Int
    var name: String
    var format = "string"
    var required = false
    var multiple = false
    var options: [Option] = []
    var defaults: [String] = []
}

// MARK: - Разбор веб-формы /projects/:id/issues/new

private let cfTagRe = RE(#"<(input|select|textarea)\b[^>]*\bname="issue\[custom_field_values\]\[(\d+)\](\[\])?"[^>]*>"#)
private let cfLabelRe = RE(#"<label\b[^>]*>([\s\S]*?)</label>"#)
private let cfOptionRe = RE(#"<option\b([^>]*)>([\s\S]*?)</option>"#)
private let cfFormatRe = RE(#"class="[^"]*?\b([a-z_]+?)_cf\b"#)
private let htmlTagRe = RE(#"<[^>]+>"#)

private func attr(_ tag: String, _ name: String) -> String? { RE(#"\b\#(name)="([^"]*)""#).first(tag)?.g(1) }
private func flag(_ tag: String, _ name: String) -> Bool { RE(#"\s\#(name)\b"#).contains(tag) }

private func unhtml(_ s: String) -> String {
    htmlTagRe.replace(s, "")
        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
        .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&")
}

/**
 Поля из разметки Redmine (custom_field_tag_with_label): подпись в <label> перед полем, «*» в
 <span class="required">, формат — класс «<формат>_cf». input — строка/число/ссылка/дата; textarea — текст;
 select — список/пользователь/версия; группы флажков и радиокнопок; одиночный флажок «да/нет».
 ponytail: регэкспы по HTML — разметка штатная и стабильна; сломается на переписанной теме — поля придут из REST.
 */
func parseIssueFormFields(_ html: String) -> [FormField] {
    let ns = html as NSString
    let tags = cfTagRe.all(html)
    var order: [Int] = []
    var groups: [Int: [Int]] = [:] // id поля → индексы тегов
    for (i, t) in tags.enumerated() {
        guard let id = Int(t.g(2)) else { continue }
        if groups[id] == nil { order.append(id) }
        groups[id, default: []].append(i)
    }
    var out: [FormField] = []
    for id in order {
        let idx = groups[id]!
        let from = idx[0] == 0 ? 0 : tags[idx[0] - 1].range.location + tags[idx[0] - 1].range.length
        let group = idx.map { tags[$0] }
        let visible = group.filter { attr($0.value, "type") != "hidden" }
        guard let main = visible.first else { continue }
        let kind = main.g(1)
        let type = attr(main.value, "type")
        let bodyFrom = main.range.location + main.range.length
        var body = ""
        var close = -1
        if kind != "input" {
            let r = ns.range(of: "</\(kind)>", range: NSRange(location: bodyFrom, length: ns.length - bodyFrom))
            if r.location != NSNotFound {
                close = r.location
                let b = ns.substring(with: NSRange(location: bodyFrom, length: close - bodyFrom))
                if !b.contains("<\(kind)") { body = b }
            }
        }
        let labelArea = ns.substring(with: NSRange(location: from, length: group[0].range.location - from))
        let label = cfLabelRe.all(labelArea).last
        let headStart = from + (label?.range.location ?? 0)
        let headEnd = max(group.last!.range.location + group.last!.range.length, close)
        let head = ns.substring(with: NSRange(location: headStart, length: max(0, headEnd - headStart)))
        let multiple = !main.g(3).isEmpty || flag(main.value, "multiple")
        let yesNo = type == "checkbox" && visible.count == 1 && !multiple
        var options: [FormField.Option] = []
        var defaults: [String] = []
        if kind == "select" {
            for o in cfOptionRe.all(body) {
                let text = unhtml(o.g(2)).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = attr(o.g(1), "value").map(unhtml) ?? text
                if value.isEmpty { continue }
                options.append(.init(value: value, label: text))
                if flag(o.g(1), "selected") { defaults.append(value) }
            }
        } else if kind == "textarea" {
            defaults.append(unhtml(body).trimmingCharacters(in: .newlines))
        } else if type == "radio" || type == "checkbox" {
            for t in visible {
                let value = unhtml(attr(t.value, "value") ?? "")
                if value.isEmpty { continue }
                let textFrom = t.range.location + t.range.length
                let lt = ns.range(of: "<", range: NSRange(location: textFrom, length: ns.length - textFrom))
                let textTo = lt.location == NSNotFound ? ns.length : lt.location
                let text = unhtml(ns.substring(with: NSRange(location: textFrom, length: textTo - textFrom))).trimmingCharacters(in: .whitespacesAndNewlines)
                options.append(.init(value: value, label: text.isEmpty ? value : text))
                if flag(t.value, "checked") { defaults.append(value) }
            }
        } else {
            defaults.append(unhtml(attr(main.value, "value") ?? ""))
        }
        var name = unhtml(label?.g(1) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix("*") { name = String(name.dropLast()).trimmingCharacters(in: .whitespaces) }
        out.append(FormField(
            id: id,
            name: name.isEmpty ? "#\(id)" : name,
            format: cfFormatRe.first(head)?.g(1) ?? (yesNo ? "bool" : "string"),
            required: label?.g(1).contains("class=\"required\"") == true,
            multiple: multiple,
            options: yesNo ? [] : options,
            defaults: defaults.filter { !$0.isEmpty }
        ))
    }
    return out
}

/**
 Поля трекера, по убыванию точности: веб-форма новой задачи под сессией WKWebView (ровно то, что видит
 пользователь, с обязательностью и вариантами); /custom_fields.json (админ) ∩ поля проекта; только имена.
 */
func fetchFormFields(api: RedmineAPI, projectId: Int, trackerId: Int) async -> [FormField] {
    if let host = api.baseURL.host, let cookie = await AppModel.cookieHeader(host: host) {
        let ua = WafGate.shared.browser?.agent ?? UserDefaults.standard.string(forKey: "wafAgent") ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"
        if let html = try? await api.webPage("projects/\(projectId)/issues/new", cookie: cookie, userAgent: ua, [("issue[tracker_id]", String(trackerId))]),
           html.contains("issue-form") {
            return parseIssueFormFields(html)
        }
    }
    let inProject = (try? await api.projectIssueCustomFields(projectId)) ?? []
    let defs = (try? await api.customFieldDefs()) ?? []
    if defs.isEmpty { return inProject.map { FormField(id: $0.id, name: $0.name) } }
    let ids = Set(inProject.map(\.id))
    return defs
        .filter { d in (ids.isEmpty || ids.contains(d.id)) && (d.trackers.isEmpty || d.trackers.contains { $0.id == trackerId }) }
        .map { d in
            FormField(id: d.id, name: d.name, format: d.fieldFormat.isEmpty ? "string" : d.fieldFormat, required: d.isRequired, multiple: d.multiple,
                      options: d.possibleValues.map { .init(value: $0.value, label: $0.label.isEmpty ? $0.value : $0.label) },
                      defaults: d.defaultValue.map { $0.isEmpty ? [] : [$0] } ?? [])
        }
}

/**
 Тело «issue» для POST /issues.json. Настраиваемое поле уходит, только если заполнено (или у него стирают
 значение по умолчанию): пустая строка в необязательном поле списка — лишний повод для 422.
 */
func issuePayload(projectId: Int, trackerId: Int, subject: String, description: String = "", priorityId: Int? = nil,
                  assigneeId: Int? = nil, versionId: Int? = nil, categoryId: Int? = nil, parentId: Int? = nil,
                  estimate: String = "", startDate: String = "", dueDate: String = "", isPrivate: Bool = false,
                  fields: [FormField] = [], values: [Int: [String]] = [:]) -> [String: Any] {
    var p: [String: Any] = ["project_id": projectId, "tracker_id": trackerId, "subject": subject.trimmingCharacters(in: .whitespacesAndNewlines)]
    if !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { p["description"] = description }
    if let priorityId { p["priority_id"] = priorityId }
    if let assigneeId { p["assigned_to_id"] = assigneeId }
    if let versionId { p["fixed_version_id"] = versionId }
    if let categoryId { p["category_id"] = categoryId }
    if let parentId { p["parent_issue_id"] = parentId }
    // «1,5» — числом; «1:30», «1h 30m» — строкой: Redmine разберёт сам или вернёт ошибку
    let est = estimate.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
    if let d = Double(est) { p["estimated_hours"] = d } else if !est.isEmpty { p["estimated_hours"] = est }
    p["start_date"] = startDate // пустая строка — «без даты начала»: без поля сервер подставил бы сегодня
    if !dueDate.isEmpty { p["due_date"] = dueDate }
    if isPrivate { p["is_private"] = true }
    let custom: [[String: Any]] = fields.compactMap { f in
        let v = (values[f.id] ?? []).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if v.isEmpty && f.defaults.isEmpty { return nil }
        return ["id": f.id, "value": f.multiple ? v as Any : (v.first ?? "") as Any]
    }
    if !custom.isEmpty { p["custom_fields"] = custom }
    return p
}
