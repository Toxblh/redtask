import Foundation
import SwiftUI

/// Файл, выбранный для загрузки: имя известно сразу — по нему картинка вставляется в текст как !имя!.
struct PickedFile: Identifiable, Hashable, Sendable {
    let id = UUID()
    var name: String
    var data: Data
    var mime: String?
}

/// Сырые id из журнала → имена.
struct FieldNames {
    var statuses: [Int: String] = [:]
    var priorities: [Int: String] = [:]
    var trackers: [Int: String] = [:]
    var users: [Int: String] = [:]
    var versions: [Int: String] = [:]
    var categories: [Int: String] = [:]
    var customFields: [Int: String] = [:]

    func resolve(_ field: String, _ v: String?) -> String {
        guard let v, !v.isEmpty else { return "—" }
        let map: [Int: String]
        switch field {
        case "status_id": map = statuses
        case "priority_id": map = priorities
        case "tracker_id": map = trackers
        case "assigned_to_id", "watcher": map = users
        case "fixed_version_id": map = versions
        case "category_id": map = categories
        case "parent_id": return "#\(v)"
        case "done_ratio": return "\(v)%"
        default: return String(v.prefix(200))
        }
        return Int(v).flatMap { map[$0] } ?? v
    }

    func label(_ d: JournalDetail) -> String {
        switch d.property {
        case "attachment": return String(localized: "File")
        case "relation": return String(localized: "Relation")
        case "cf": return Int(d.name).flatMap { customFields[$0] } ?? String(localized: "Field")
        default: break
        }
        switch d.name {
        case "status_id": return String(localized: "Status")
        case "priority_id": return String(localized: "Priority")
        case "assigned_to_id": return String(localized: "Assignee")
        case "tracker_id": return String(localized: "Tracker")
        case "fixed_version_id": return String(localized: "Version")
        case "category_id": return String(localized: "Category")
        case "done_ratio": return String(localized: "Progress")
        case "due_date": return String(localized: "Due date")
        case "start_date": return String(localized: "Start date")
        case "estimated_hours": return String(localized: "Estimate")
        case "subject": return String(localized: "Subject")
        case "description": return String(localized: "Description")
        case "parent_id": return String(localized: "Parent issue")
        case "project_id": return String(localized: "Project")
        case "is_private": return String(localized: "Private")
        default: return d.name
        }
    }
}

/**
 Экран задачи: задача открывается мгновенно из кэша и сверяется с сервером в фоне; действия по правам роли.
 Черновик комментария живёт здесь и переживает обновления задачи.
 */
@MainActor @Observable
final class IssueDetailModel {
    let issueId: Int
    private(set) var issue: Issue?
    private(set) var timeEntries: [TimeEntry] = []
    private(set) var perms = IssuePerms()
    private(set) var loading = false
    private(set) var error: String?
    /// Не удалось сверить с сервером — показан кэш.
    private(set) var refreshError: String?
    var busy = false
    var actionError: String?
    /// Статусы/приоритеты/участники/версии — для подписей журналов и форм.
    private(set) var names = FieldNames()
    private(set) var priorities: [Priority] = []
    private(set) var activities: [TimeEntryActivity] = []
    private(set) var members: [Named] = []
    private(set) var cfLabels: [Int: String] = [:]
    /// Состояние подзадач и связанных задач — для подписей (тема, статус).
    private(set) var related: [Int: Issue] = [:]
    /// Комментарии, править которые сервер отказал.
    private(set) var notesRefused = Set<Int>()

    // черновик комментария
    var draft = ""
    var draftPrivate = false
    var draftFiles: [PickedFile] = []
    var editingJournal: Journal?
    var editText = ""
    var editPrivate = false
    /// Приватный комментарий не процитирован: права нет, ответ ушёл бы публично вместе с цитатой.
    private(set) var quoteRefused = false

    init(issueId: Int) { self.issueId = issueId }

    var activity: [ActivityEvent] { issue.map { normalizeActivity($0, timeEntries: timeEntries) } ?? [] }

    // MARK: загрузка

    func load(_ app: AppModel) async {
        guard let api = app.api else { return }
        if issue == nil, let snap = await IssueCache.load(app.account, issueId) {
            issue = snap.issue
            timeEntries = snap.timeEntries
        }
        loading = true
        defer { loading = false }
        do {
            async let i = api.issue(issueId)
            async let t: [TimeEntry] = (try? await api.timeEntries(issueId: issueId)) ?? []
            let fresh = try await i
            let times = await t
            issue = fresh
            timeEntries = times
            error = nil
            refreshError = nil
            await IssueCache.save(app.account, IssueSnapshot(issue: fresh, timeEntries: times))
            Task { await loadExtras(app, fresh) }
        } catch {
            if (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            // задача уже на экране (кэш) — не модальный алерт, а строка в шапке: обновление фоновое, работать оно не мешает
            if issue == nil { self.error = error.localizedDescription } else { refreshError = error.localizedDescription }
        }
    }

    /// Права, справочники, подписи настраиваемых полей, состояние связанных задач — не мешают показу задачи.
    private func loadExtras(_ app: AppModel, _ i: Issue) async {
        guard let refs = app.refs, let api = app.api else { return }
        async let p = refs.permissions(i.project.id)
        async let st = try? refs.statuses()
        async let pr = try? refs.priorities()
        async let tr = try? refs.trackers()
        async let mem = try? refs.members(i.project.id)
        async let ver = try? refs.versions(i.project.id)
        async let act = try? refs.activities()
        async let labels = api.customFieldLabels(issueId: i.id, fields: i.customFields)
        let relIds = i.children.map(\.id) + i.relations.map { $0.issueId == i.id ? $0.issueToId : $0.issueId } + (i.parent.map { [$0.id] } ?? [])
        async let rel = try? api.issuesByIds(relIds)

        let perms = await p
        self.perms = IssuePerms(known: true, set: perms)
        var n = names
        if let s = await st { n.statuses = Dictionary(s.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }
        if let s = await pr { priorities = s; n.priorities = Dictionary(s.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }
        if let s = await tr { n.trackers = Dictionary(s.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }
        if let s = await ver { n.versions = Dictionary(s.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }) }
        var users: [Int: String] = [:]
        if let m = await mem { members = m; for x in m { users[x.id] = x.name } }
        for x in [i.author] + [i.assignedTo].compactMap({ $0 }) + i.journals.compactMap(\.user) + i.watchers where !x.name.isEmpty { users[x.id] = x.name }
        n.users = users
        if let c = i.category { n.categories[c.id] = c.name }
        for f in i.customFields { n.customFields[f.id] = f.name }
        names = n
        if let a = await act { activities = a }
        cfLabels = await labels
        if let r = await rel { related = Dictionary(r.found.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
    }

    // MARK: действия

    /// Запись на сервер; после — перечитать задачу и пометить списки устаревшими. Отказ — alert.
    func mutate(_ app: AppModel, _ block: @escaping (RedmineAPI) async throws -> Void) async -> Bool {
        guard let api = app.api, !busy else { return false }
        busy = true
        defer { busy = false }
        do {
            try await block(api)
            app.listEpoch += 1
            busy = false
            await load(app)
            return true
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    func setStatus(_ id: Int, _ app: AppModel) async { _ = await mutate(app) { try await $0.updateIssue(self.issueId, ["status_id": id]) } }
    func setPriority(_ id: Int, _ app: AppModel) async { _ = await mutate(app) { try await $0.updateIssue(self.issueId, ["priority_id": id]) } }
    func setDoneRatio(_ v: Int, _ app: AppModel) async { _ = await mutate(app) { try await $0.updateIssue(self.issueId, ["done_ratio": v]) } }
    func assignToMe(_ app: AppModel) async {
        let me = app.settings.userId
        _ = await mutate(app) { try await $0.updateIssue(self.issueId, ["assigned_to_id": me]) }
    }

    func startComment() { editingJournal = nil; quoteRefused = false }

    func startEdit(_ j: Journal) {
        editingJournal = j
        quoteRefused = false
        editText = j.notes ?? ""
        editPrivate = j.privateNotes
    }

    /**
     Цитата дописывается к черновику. Цитата приватного делает приватным и ответ (как веб-версия);
     без права set_notes_private сервер пометку молча отбросит — тогда приватный текст в черновик не попадает.
     */
    func reply(to j: Journal) {
        editingJournal = nil
        quoteRefused = j.privateNotes && perms.state("set_notes_private") == false
        if quoteRefused { return }
        if j.privateNotes { draftPrivate = true }
        let q = quoteReply(author: j.user?.name ?? "—", text: j.notes ?? "")
        let base = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = (base.isEmpty ? "" : base + "\n\n") + q.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
    }

    var commentPrivate: Bool {
        get { editingJournal != nil ? editPrivate : draftPrivate }
        set { if editingJournal != nil { editPrivate = newValue } else { draftPrivate = newValue } }
    }

    /// Отправка черновика или правки. Черновик очищается только после успешного PUT.
    func sendComment(_ app: AppModel) async -> Bool {
        let mayPrivate = perms.state("set_notes_private")
        if let j = editingJournal {
            let text = editText, priv = editPrivate
            let ok = await saveNote(j, text: text, isPrivate: mayPrivate == false ? nil : priv, app)
            if ok { editingJournal = nil }
            return ok
        }
        let text = draft, isPrivate = draftPrivate, files = draftFiles
        // приватный черновик при известном отсутствии права ушёл бы открытым — не шлём
        if isPrivate && mayPrivate == false {
            actionError = String(localized: "You can’t write private notes: the server would publish this comment openly. Remove what must stay private and clear “Private note” to send.")
            return false
        }
        let ok = await mutate(app) { api in
            var uploads: [UploadRef] = []
            for f in files { uploads.append(try await api.upload(f.data, filename: f.name, contentType: f.mime)) }
            var fields: [String: Any] = [:]
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields["notes"] = text }
            if isPrivate { fields["private_notes"] = true }
            try await api.updateIssue(self.issueId, fields, uploads: uploads)
        }
        if ok {
            // уходит только отправленное: добавленное за время запроса остаётся черновиком
            if draft == text { draft = ""; draftPrivate = false }
            draftFiles.removeAll { f in files.contains(f) }
            quoteRefused = false
        }
        return ok
    }

    /// Правка своего комментария; пустой текст удаляет его. 403/404 — правку больше не предлагаем.
    @discardableResult
    func saveNote(_ j: Journal, text: String, isPrivate: Bool?, _ app: AppModel) async -> Bool {
        guard let api = app.api else { return false }
        busy = true
        defer { busy = false }
        do {
            try await api.updateJournal(j.id, notes: text, privateNotes: isPrivate)
            busy = false
            await load(app)
            return true
        } catch let e as RedmineError where e.code == 403 || e.code == 404 {
            notesRefused.insert(j.id)
            if e.code == 404 { busy = false; await load(app) }
            else { actionError = String(localized: "The server doesn’t allow editing comments: \(e.message)") }
            return false
        } catch {
            actionError = error.localizedDescription
            return false
        }
    }

    func saveTime(_ entry: TimeEntry?, hours: Double, activityId: Int?, comment: String, spentOn: String, _ app: AppModel) async -> Bool {
        await mutate(app) { api in
            if let entry { try await api.updateTimeEntry(entry.id, hours: hours, activityId: activityId, comments: comment, spentOn: spentOn) }
            else { try await api.logTime(issueId: self.issueId, hours: hours, activityId: activityId, comments: comment, spentOn: spentOn) }
        }
    }

    func deleteTime(_ e: TimeEntry, _ app: AppModel) async { _ = await mutate(app) { try await $0.deleteTimeEntry(e.id) } }

    func addRelation(type: String, to: Int, delay: Int?, _ app: AppModel) async -> Bool {
        await mutate(app) { try await $0.addRelation(self.issueId, type: type, to: to, delay: delay) }
    }

    func deleteRelation(_ r: Relation, _ app: AppModel) async { _ = await mutate(app) { try await $0.deleteRelation(r.id) } }

    func uploadFiles(_ files: [PickedFile], description: String, _ app: AppModel) async -> Bool {
        await mutate(app) { api in
            var uploads: [UploadRef] = []
            for f in files {
                var u = try await api.upload(f.data, filename: f.name, contentType: f.mime)
                u.description = description
                uploads.append(u)
            }
            try await api.updateIssue(self.issueId, [:], uploads: uploads)
        }
    }

    func deleteAttachment(_ a: Attachment, _ app: AppModel) async { _ = await mutate(app) { try await $0.deleteAttachment(a.id) } }

    var watching: Bool { issue?.watchers.contains { $0.id == AppModel.shared.settings.userId } ?? false }

    /// Наблюдение: на многих серверах REST только для админа — тогда открываем веб-версию.
    func toggleWatch(_ app: AppModel) async -> Bool {
        let me = app.settings.userId, on = watching
        guard let api = app.api else { return false }
        if api.watchersForbidden(issueId) { return false }
        busy = true
        defer { busy = false }
        do {
            if on { try await api.removeWatcher(issueId, userId: me) } else { try await api.addWatcher(issueId, userId: me) }
            busy = false
            await load(app)
            return true
        } catch let e as RedmineError where e.code == 403 || e.code == 401 {
            return false
        } catch {
            actionError = error.localizedDescription
            return true
        }
    }
}
