import Foundation
import BackgroundTasks
import UserNotifications
import UIKit
import Intents

/// Флаг «первый раз» для гонки в Poller.before.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// Необязательный запрос (справочник, имя): сбой — «не знаем».
private func soft<T>(_ block: () async throws -> T) async -> T? {
    do { return try await block() } catch { return nil }
}

/**
 Сборщик событий — один на фоновый опрос, проверку при входе в приложение и бэкфилл колокольчика.
 Сбой обязательного запроса пробрасывается: окно нельзя считать обработанным.
 Упоминания ищутся и вне «моих» задач фильтром списка задач по заметкам (search.json журналы не индексирует).
 Чего нет: упоминаний в описании и упоминания, дописанного правкой старого комментария.
 */
struct PollCollector {
    let api: RedmineAPI
    let refs: RefData
    let s: AppSettings
    /// Потолок страниц на запрос; бэкфилл берёт одну, как на Android — первое открытие не тянет сотни задач.
    var pages = Self.maxPages

    static let page = 100
    // ponytail: потолок 1000 задач на запрос; упёрлись — набор считается неполным
    static let maxPages = 10
    // до 300 задач с упоминаниями за опрос; больше — хвост дочитывают следующие опросы
    static let mentionPages = 3

    /**
     «Мои» задачи — назначенные, отслеживаемые и авторские, все страницы. Выключенный источник не опрашивается,
     «только избранные» отсекает остальное. complete = false — упёрлись в потолок, сравнивать с набором нельзя.
     */
    func myIssues(status: String, updatedSince: String? = nil) async throws -> (issues: [Int: Issue], complete: Bool) {
        var out: [Int: Issue] = [:]
        var complete = true
        let favoritesOnly = s.notifFlags.contains(.favoritesOnly)
        // избранное — на сервере: набор берём оттуда, а не из кэша настроек
        let favorites = favoritesOnly ? Set(try await api.favoriteIds()) : []
        if favoritesOnly && favorites.isEmpty { return (out, true) }
        var queries: [IssueQuery] = []
        if s.notifFlags.contains(.scopeAssigned) { queries.append(IssueQuery(assignedToMe: true)) }
        if s.notifFlags.contains(.scopeWatched) { queries.append(IssueQuery(watchedByMe: true)) }
        if s.notifFlags.contains(.scopeAuthored) { queries.append(IssueQuery(authoredByMe: true)) }
        for base in queries {
            var q = base
            q.statusFilter = status
            q.updatedSince = updatedSince
            q.limit = Self.page
            q.sort = updatedSince != nil ? "updated_on:desc" : "id:desc"
            var done = false
            for _ in 0..<pages {
                let page = try await api.issues(q)
                // сервер не знает author_id и вернул всё подряд — отсекаем чужое
                for i in page.issues where !q.authoredByMe || i.author.id == s.userId { out[i.id] = i }
                q.offset += page.issues.count
                if page.issues.isEmpty || q.offset >= page.totalCount { done = true; break }
            }
            if !done { complete = false }
        }
        if favoritesOnly { out = out.filter { favorites.contains($0.key) } }
        return (out, complete)
    }

    /// Задачи, изменённые после since, с «@login» в комментариях. 400/403/404/422 — сервер фильтра не знает.
    func mentionIssueIds(since: Date, offset start: Int = 0) async throws -> (ids: Set<Int>, more: Int?) {
        let login = s.userLogin
        if login.isEmpty || api.mentionFilterUnsupported { return ([], nil) }
        var out = Set<Int>()
        var next = start
        var done = false
        do {
            for _ in 0..<min(pages, Self.mentionPages) {
                let page = try await api.issuesMentioning(login: login, updatedSince: redmineISO(since), offset: next)
                page.issues.forEach { out.insert($0.id) }
                next += page.issues.count
                if page.issues.isEmpty || next >= page.totalCount { done = true; break }
            }
        } catch let e as RedmineError where [400, 403, 404, 422].contains(e.code) {
            api.markMentionFilterUnsupported()
            return ([], nil)
        }
        return (out, done ? nil : next)
    }

    /**
     Записи по задаче: её создание и каждый чужой журнал после since. nil — задачи нет или недоступна.
     mentionsOnly — задача не из «моих», найдена по упоминанию: только журналы, где упомянут я.
     */
    func issueEntries(_ issueId: Int, since: Date, mentionsOnly: Bool = false) async throws -> [NotifEntry]? {
        let issue: Issue
        do { issue = try await api.issueJournals(issueId) }
        catch let e as RedmineError where e.code == 404 || e.code == 403 { return nil }
        var out: [NotifEntry] = []
        if !mentionsOnly, let c = createdEntry(issue, since: since) { out.append(c) }
        for j in issue.journals {
            // по дате создания: отредактированный старый журнал повторно не уведомляет
            guard let at = parseRedmineDate(j.createdOn), at > since, j.user?.id != s.userId else { continue }
            if mentionsOnly && !textMentions(j.notes, login: s.userLogin) { continue }
            let text = await journalText(issue, j)
            if text.isEmpty { continue }
            let cats = journalTypes(j, userId: s.userId, login: s.userLogin)
            var e = entry(issue, at: at, who: j.user, text: text, type: cats[0], eventId: "j\(j.id)", strong: await strong(j, cats[0]))
            if !(j.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                e.imageId = notificationImage(notes: j.notes, details: j.details, attachments: issue.attachments)
            }
            for c in cats.dropFirst() { e.alsoTypes[c] = await strong(j, c) }
            out.append(e)
        }
        return out
    }

    private func entry(_ issue: Issue, at: Date, who: Named?, text: String, type: String, eventId: String, strong: Bool = true) -> NotifEntry {
        let name = (who?.name).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Someone")
        let line = type == NotifType.mention ? String(localized: "\(name) mentioned you: \(text)") : "\(name): \(text)"
        return NotifEntry(issueId: issue.id, subject: issue.subject, project: issue.project.name, lines: [line],
                          at: Int64(at.timeIntervalSince1970 * 1000), avatarUserId: who?.id, type: type, eventId: eventId,
                          projectId: issue.project.id, strong: strong, author: name)
    }

    /// Чужая задача, созданная после since: «назначена мне» либо «новая задача».
    private func createdEntry(_ issue: Issue, since: Date) -> NotifEntry? {
        guard let at = parseRedmineDate(issue.createdOn), at > since, issue.author.id != s.userId else { return nil }
        return entry(issue, at: at, who: issue.author, text: String(localized: "new issue (\(issue.tracker.name))"),
                     type: issue.assignedTo?.id == s.userId ? NotifType.assigned : NotifType.newIssue, eventId: "created")
    }

    /// Чужие новые задачи в моих проектах. Ключ тот же («created») — задача из обоих списков не уведомит дважды.
    func newIssues(since: Date) async throws -> [NotifEntry] {
        var out: [NotifEntry] = []
        var offset = 0
        for _ in 0..<Self.maxPages {
            let page = try await api.newIssuesInMyProjects(createdSince: redmineISO(since), offset: offset)
            out += page.issues.compactMap { createdEntry($0, since: since) }
            offset += page.issues.count
            if page.issues.isEmpty || offset >= page.totalCount { break }
        }
        return out
    }

    // ponytail: «решена» — не признак в API, а название статуса; угадываем по слову
    private static let resolvedRe = RE("решен|решён|выполнен|resolv|done|fixed", caseInsensitive: true)

    /// Значимость внутри типа — для подопций «только закрытие/решение» и «только повышение». Не знаем — значимо.
    private func strong(_ j: Journal, _ type: String) async -> Bool {
        func detail(_ name: String) -> JournalDetail? { j.details.first { $0.property == "attr" && $0.name == name } }
        switch type {
        case NotifType.status:
            guard let id = detail("status_id")?.newValue,
                  let st = await soft({ try await refs.statuses() })?.first(where: { String($0.id) == id }) else { return true }
            return st.isClosed || Self.resolvedRe.contains(st.name)
        case NotifType.priority:
            // справочник приоритетов — по возрастанию важности
            guard let order = await soft({ try await refs.priorities() })?.map({ String($0.id) }) else { return true }
            let old = detail("priority_id")?.oldValue.flatMap { order.firstIndex(of: $0) }
            let new = detail("priority_id")?.newValue.flatMap { order.firstIndex(of: $0) }
            guard let old, let new else { return true }
            return new > old
        default: return true
        }
    }

    private func journalText(_ issue: Issue, _ j: Journal) async -> String {
        var parts: [String] = []
        for d in j.details { parts.append(await detailText(issue, d)) }
        return [parts.joined(separator: ", "), notePreview(j.notes ?? "")].filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private func named(_ v: String?, _ names: [Int: String]?, _ current: Named?) -> String? {
        guard let v, let id = Int(v) else { return v }
        return names?[id] ?? (current?.id == id ? current?.name : nil) ?? "#\(id)"
    }

    private func userName(_ issue: Issue, _ v: String?) async -> String? {
        guard let v, let id = Int(v) else { return v }
        if let n = ([issue.assignedTo, issue.author].compactMap { $0 } + issue.journals.compactMap(\.user)).first(where: { $0.id == id && !$0.name.isEmpty }) { return n.name }
        return await soft { try await refs.person(id).shortName }.flatMap { $0.isEmpty ? nil : $0 } ?? "#\(id)"
    }

    private func dict<T>(_ list: [T]?, _ f: (T) -> (Int, String)) -> [Int: String]? {
        list.map { Dictionary($0.map(f), uniquingKeysWith: { a, _ in a }) }
    }

    /// Правка → текст по new_value самого журнала (за окно могло быть несколько смен).
    private func detailText(_ issue: Issue, _ d: JournalDetail) async -> String {
        let v = d.newValue.flatMap { $0.isEmpty ? nil : $0 }
        // подпись из словаря (spec 14) — без запросов; справочники и сырое значение — после
        var known: String?
        if let k = v.flatMap({ labelKey(d, $0) }) { known = await LabelStore.shared.label(s.accountKey, k) }
        func line(_ label: String, _ value: String?) -> String { "\(label.lowercased()) → \(value.map { String($0.prefix(80)) } ?? "—")" }
        switch d.property {
        case "attr":
            switch d.name {
            case "status_id":
                let names = dict(await soft { try await refs.statuses() }) { ($0.id, $0.name) }
                return line(String(localized: "Status"), named(v, names, Named(id: issue.status.id, name: issue.status.name)))
            case "priority_id":
                let names = dict(await soft { try await refs.priorities() }) { ($0.id, $0.name) }
                return line(String(localized: "Priority"), named(v, names, issue.priority))
            case "tracker_id":
                let names = dict(await soft { try await refs.trackers() }) { ($0.id, $0.name) }
                return line(String(localized: "Tracker"), named(v, names, issue.tracker))
            case "fixed_version_id":
                let names = dict(await soft { try await refs.versions(issue.project.id) }) { ($0.id, $0.name) }
                return line(String(localized: "Version"), known ?? named(v, names, issue.fixedVersion))
            case "assigned_to_id": return line(String(localized: "Assignee"), await userName(issue, v))
            case "category_id": return line(String(localized: "Category"), known ?? named(v, nil, issue.category))
            case "project_id": return line(String(localized: "Project"), known ?? named(v, nil, issue.project))
            case "parent_id": return line(String(localized: "Parent issue"), v.map { "#\($0)" })
            case "done_ratio": return line(String(localized: "Progress"), v.map { "\($0)%" })
            case "due_date": return line(String(localized: "Due date"), v)
            case "start_date": return line(String(localized: "Start date"), v)
            case "estimated_hours": return line(String(localized: "Estimate"), v)
            case "subject": return line(String(localized: "Subject"), v)
            case "description": return String(localized: "description changed")
            case "is_private": return v == "1" || v == "true" ? String(localized: "the issue became private") : String(localized: "the issue became public")
            default: return line(d.name, known ?? v)
            }
        case "cf":
            let name = issue.customFields.first { String($0.id) == d.name }?.name
            return line(name.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "field"), known ?? v)
        case "attachment":
            return v.map { String(localized: "file: \($0)") } ?? String(localized: "file deleted: \(d.oldValue ?? "")")
        case "relation":
            return v.map { String(localized: "relation with #\($0)") } ?? String(localized: "relation with #\(d.oldValue ?? "") removed")
        default:
            return line(d.name.isEmpty ? d.property : d.name, v)
        }
    }

    /// Все события окна и новое состояние опроса. Ничего не сохраняет и не показывает.
    func collect(since: Date, now: Date, saved: PollState?) async throws -> ([NotifEntry], PollState) {
        let prev = saved?.scope == s.scopeKey ? saved : nil
        var out: [NotifEntry] = []
        let (changed, _) = try await myIssues(status: "*", updatedSince: redmineISO(since))
        let (open, complete) = try await myIssues(status: "open")
        // выпавшие из «моих»: переназначенные найдутся по журналу, удалённые/закрытые от меня ответят 404/403
        let left: Set<Int> = (prev != nil && complete) ? Set(prev!.mine.keys).subtracting(open.keys).subtracting(changed.keys) : []
        let mentionsOn = !s.notifMuted.contains(NotifType.mention)
        let mine = Set(changed.keys).union(left)
        for id in mine {
            if let e = try await issueEntries(id, since: since) { out += e }
            else if left.contains(id) {
                out.append(NotifEntry(issueId: id, subject: prev?.mine[id] ?? "", project: "",
                                      lines: [String(localized: "The issue was deleted or is no longer available")],
                                      at: Int64(now.timeIntervalSince1970 * 1000), type: NotifType.reassignedAway, eventId: "gone"))
            }
        }

        // упоминания вне «моих»; хвост, не влезший в потолок страниц, дочитывают следующие опросы
        var mentionSince: Date?
        var mentionOffset = 0
        if mentionsOn {
            let tail = saved?.mentionSince != nil ? saved : nil
            let (ids, more) = try await mentionIssueIds(since: since)
            var old = Set<Int>()
            var moreOld: Int?
            if let t = tail, let ms = t.mentionSince { (old, moreOld) = try await mentionIssueIds(since: ms, offset: t.mentionOffset) }
            let from = tail?.mentionSince ?? since
            for id in ids.union(old).subtracting(tail == nil ? mine : []) {
                if let e = try await issueEntries(id, since: from, mentionsOnly: true) { out += e }
            }
            if let m = more ?? moreOld { mentionSince = from; mentionOffset = m }
        }

        // новые задачи в моих проектах; категория выключена — запроса нет вовсе
        if !s.notifMuted.contains(NotifType.newIssue) {
            do { out += try await newIssues(since: since) }
            catch let e as RedmineError where e.code == 404 || e.code == 422 {}
        }

        // списания времени в моих задачах. ponytail: from — дата spent_on, задним числом раньше вчера не увидим
        var subjects = prev?.mine ?? [:]
        for (id, i) in open.merging(changed, uniquingKeysWith: { a, _ in a }) { subjects[id] = i.subject }
        let fromDay = Fmt.day(Calendar.current.date(byAdding: .day, value: -1, to: since) ?? since)
        var time: [TimeEntry] = []
        if !subjects.isEmpty {
            do { time = try await api.timeEntries(from: fromDay, createdAfter: since) }
            catch let e as RedmineError where e.code == 403 || e.code == 404 {}
        }
        for t in time {
            guard let id = t.issue?.id, let subject = subjects[id], let at = parseRedmineDate(t.createdOn), at > since, t.user?.id != s.userId else { continue }
            let who = (t.user?.name).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Someone")
            let text = String(localized: "time logged: \(Fmt.hours(t.hours)) h") + (t.comments.isEmpty ? "" : " — \(t.comments.prefix(140))")
            out.append(NotifEntry(issueId: id, subject: subject, project: t.project?.name ?? "", lines: ["\(who): \(text)"],
                                  at: Int64(at.timeIntervalSince1970 * 1000), avatarUserId: t.user?.id, type: NotifType.timeLogged,
                                  eventId: "t\(t.id)", projectId: t.project?.id, author: who))
        }

        // срок — локально: одно напоминание на задачу и дату (завтра / сегодня / просрочена)
        let today = Calendar.current.startOfDay(for: now)
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        var due = Set<String>()
        for i in open.values where i.assignedTo?.id == s.userId {
            guard let ds = i.dueDate, let d = Fmt.dayDate(ds), d <= tomorrow else { continue }
            let key = "\(i.id):\(ds)"
            due.insert(key)
            // первый опрос после входа: давно просроченное пачкой не вываливаем
            let known = prev == nil ? d < today : prev!.due.contains(key)
            if known { continue }
            let line = d < today ? String(localized: "Overdue since \(Fmt.date(ds))") : d == today ? String(localized: "Due today") : String(localized: "Due tomorrow")
            out.append(NotifEntry(issueId: i.id, subject: i.subject, project: i.project.name, lines: [line],
                                  at: Int64(now.timeIntervalSince1970 * 1000), type: NotifType.dueSoon, eventId: "due:\(ds)", projectId: i.project.id))
        }

        // неполный набор «моих» не запоминаем: по нему следующий опрос увидел бы ложные «выпавшие»
        let state = PollState(mine: complete ? open.mapValues(\.subject) : (prev?.mine ?? [:]),
                              due: complete ? due : (prev?.due ?? []).union(due), scope: s.scopeKey,
                              mentionSince: mentionSince, mentionOffset: mentionOffset)
        return (out, state)
    }
}

/**
 Фоновая проверка. iOS запускает BGAppRefreshTask по своему усмотрению (обычно не чаще раза в 15 минут
 и реже, если приложением мало пользуются) — поэтому ещё и проверка при каждом возврате в приложение.
 Окно (lastCheck) сдвигается, только если удались все запросы; повтор не дублирует уведомления.
 */
@MainActor
enum Poller {
    static let taskId = "ru.toxblh.RedTask.poll"
    static let muteAction = "mute-issue"
    static let category = "issue"
    private static var running = false
    private static var lastForeground = Date.distantPast

    /// Категория уведомлений с действием «Не уведомлять по задаче».
    static func register() {
        let mute = UNNotificationAction(identifier: muteAction, title: String(localized: "Mute this issue"),
                                        options: [], icon: UNNotificationActionIcon(systemImageName: "bell.slash"))
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category, actions: [mute], intentIdentifiers: [],
                                   hiddenPreviewsBodyPlaceholder: String(localized: "Issue update"), options: []),
        ])
    }

    static func schedule() {
        let app = AppModel.shared
        guard app.isLoggedIn, !app.isDemo, app.settings.notificationsEnabled else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskId)
            return
        }
        let r = BGAppRefreshTaskRequest(identifier: taskId)
        // spec 18: раз в 5 минут; iOS всё равно запускает по своему усмотрению
        r.earliestBeginDate = Date(timeIntervalSinceNow: 5 * 60)
        try? BGTaskScheduler.shared.submit(r)
    }

    /// Возврат в приложение: проверка не чаще раза в минуту.
    static func foreground() {
        guard Date().timeIntervalSince(lastForeground) > 60 else { return }
        lastForeground = Date()
        Task { await poll() }
    }

    /// Разрешение — тихое (provisional): без запроса, уведомления сразу в Центр уведомлений.
    static func requestProvisional() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge, .provisional])
    }

    @discardableResult
    static func poll() async -> Bool {
        let app = AppModel.shared
        guard !running, let api = app.api, let refs = app.refs, app.settings.isLoggedIn else { return false }
        running = true
        defer { running = false; schedule() }
        let s = app.settings
        let now = Date()
        // первый запуск: не заваливаем — только последний час; 90-сек запас на стык окон
        let since = (s.lastCheck ?? now.addingTimeInterval(-3600)).addingTimeInterval(-90)
        do {
            let saved = await NotifStore.shared.loadState()
            let (entries, state) = try await PollCollector(api: api, refs: refs, s: s).collect(since: since, now: now, saved: saved)
            // учётку сменили, пока шёл опрос — результат чужой
            guard app.settings.account == s.account else { return false }
            let fresh = try await NotifStore.shared.appendAll(entries)
            try await NotifStore.shared.saveState(state)
            app.settings.lastCheck = now
            app.settings.lastCheckError = nil
            if s.notificationsEnabled { await post(fresh.filter { app.settings.notifies($0) }) }
            await app.refreshUnread()
            Task { await app.refreshQueryBadges() }
            return true
        } catch {
            if app.settings.account == s.account { app.settings.lastCheckError = checkError(error) }
            return false
        }
    }

    /// Причина неудачной проверки для «Последняя проверка» (spec 18).
    private static func checkError(_ e: Error) -> String {
        if let r = e as? RedmineError { return (400...599).contains(r.code) ? String(localized: "Server responded \(r.code)") : r.message }
        return String(localized: "No connection")
    }

    /// Превью вложения (thumbnail 400) во временный JPEG.
    nonisolated private static func thumbnailFile(_ id: Int, api: RedmineAPI) async -> URL? {
        // перекодируем в JPEG: системе нужен узнаваемый тип файла
        guard let data = try? await api.thumbnail(id, size: 400), let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) else { return nil }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("notif-\(id)-\(UUID().uuidString).jpg")
        do { try jpeg.write(to: file) } catch { return nil }
        return file
    }

    /// Результат op, если он успел до deadline, иначе nil. Не дождавшийся op досчитается в фоне (кэш аватара пригодится).
    nonisolated static func before<T: Sendable>(_ deadline: ContinuousClock.Instant, _ op: @escaping @Sendable () async -> T?) async -> T? {
        let once = Once()
        return await withCheckedContinuation { (k: CheckedContinuation<T?, Never>) in
            Task { let v = await op(); if once.first() { k.resume(returning: v) } }
            Task { try? await Task.sleep(until: deadline); if once.first() { k.resume(returning: nil) } }
        }
    }

    /**
     Communication Notification (spec 4.2): автор события — отправитель INSendMessageIntent с аватаром,
     система рисует аватар слева и значок приложения в углу. Беседа — задача: имя группы = заголовок
     уведомления, иначе система заменила бы «#номер тема» именем автора.
     */
    nonisolated static func messageIntent(title: String, body: String, author: String, userId: Int, issueId: Int, avatar: Data?) -> INSendMessageIntent {
        let sender = INPerson(personHandle: INPersonHandle(value: "user-\(userId)", type: .unknown), nameComponents: nil,
                              displayName: author, image: avatar.map { INImage(imageData: $0) }, contactIdentifier: nil, customIdentifier: "user-\(userId)")
        // получателей двое (я и автор) — система показывает имя группы, а не только отправителя
        let me = INPerson(personHandle: INPersonHandle(value: "me", type: .unknown), nameComponents: nil, displayName: nil,
                          image: nil, contactIdentifier: nil, customIdentifier: nil, isMe: true)
        let intent = INSendMessageIntent(recipients: [me, sender], outgoingMessageType: .outgoingMessageText, content: body,
                                         speakableGroupName: INSpeakableString(spokenPhrase: title), conversationIdentifier: "issue-\(issueId)",
                                         serviceName: nil, sender: sender, attachments: nil)
        if let avatar { intent.setImage(INImage(imageData: avatar), forParameterNamed: \.sender) }
        return intent
    }

    /// Содержимое с аватаром автора; любой сбой (нет права Communication Notifications и т. п.) — прежнее содержимое.
    private static func withSender(_ c: UNMutableNotificationContent, author: String, userId: Int, issueId: Int, avatar: UIImage) async -> UNNotificationContent {
        guard let png = avatar.pngData() else { return c }
        let intent = messageIntent(title: c.title, body: c.body, author: author, userId: userId, issueId: issueId, avatar: png)
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        do {
            try await interaction.donate()
            return try c.updating(from: intent)
        } catch {
            return c
        }
    }

    private static var backfilling = false

    /**
     Однократный бэкфилл истории за 7 дней — при первом открытии колокольчика; непрочитанным не считается.
     Своя задача, а не задача экрана: закрыли колокольчик — бэкфилл не отменяется и всё равно допишет историю.
     Берёт только то, что не новее последнего опроса: более свежее — забота опроса (уведомление + «непрочитано»).
     */
    static func backfill() async {
        guard !backfilling else { return }
        backfilling = true
        await Task { @MainActor in
            defer { backfilling = false }
            let app = AppModel.shared
            guard await NotifStore.shared.needsBackfill(), let api = app.api, let refs = app.refs else { return }
            let now = Date()
            let until = Int64((app.settings.lastCheck ?? now).timeIntervalSince1970 * 1000)
            do {
                let (entries, _) = try await PollCollector(api: api, refs: refs, s: app.settings, pages: 1)
                    .collect(since: now.addingTimeInterval(-7 * 86400), now: now, saved: nil)
                _ = try await NotifStore.shared.appendAll(entries.filter { $0.at <= until })
                await NotifStore.shared.markBackfilled()
            } catch {}
        }.value
    }

    /**
     По уведомлению на задачу за опрос: строки событий (новые сверху), стопка по задаче (threadIdentifier).
     Тап ведёт к самому новому журналу. «Мне» и обсуждение — обычные, остальное — тихие (passive).
     */
    static func post(_ fresh: [NotifEntry], evenInDemo: Bool = false) async {
        // демо — только колокольчик, системных уведомлений о выдуманных задачах не шлём (кроме -RTNotify)
        guard !fresh.isEmpty, evenInDemo || !AppModel.shared.isDemo else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        let s = AppModel.shared.settings
        let byIssue = Dictionary(grouping: fresh.sorted { $0.at < $1.at }, by: \.issueId)
        for (issueId, list) in byIssue {
            let last = list.last!
            let group = list.flatMap { e in s.notifyTypes(e).map { NotifCategory.of($0).group } }.min() ?? .progress
            let c = UNMutableNotificationContent()
            c.title = "#\(issueId) \(last.subject)"
            if !last.project.isEmpty { c.subtitle = last.project }
            c.body = list.reversed().flatMap(\.lines).prefix(8).joined(separator: "\n")
            c.threadIdentifier = "issue-\(issueId)"
            c.categoryIdentifier = category
            c.sound = group <= .discussion ? .default : nil
            c.interruptionLevel = group <= .discussion ? .active : .passive
            var info: [String: Any] = ["issueId": issueId]
            if let note = list.compactMap(\.journalId).last { info["note"] = note }
            c.userInfo = info
            c.targetContentIdentifier = "issue-\(issueId)"
            // картинка — из самого свежего комментария, аватар — автора самого свежего события (spec 4, 4.2);
            // оба качаются параллельно в общий бюджет 10 с, не успели — уведомление без них
            let comment = list.last { $0.types.contains(NotifType.comment) || $0.types.contains(NotifType.privateNote) }
            let deadline = ContinuousClock.now + .seconds(10)
            let api = AppModel.shared.api, account = AppModel.shared.account
            async let file: URL? = { () async -> URL? in
                guard let id = comment?.imageId, let api else { return nil }
                return await before(deadline) { await thumbnailFile(id, api: api) }
            }()
            async let avatar: UIImage? = { () async -> UIImage? in
                guard let uid = last.avatarUserId, let api else { return nil }
                return await before(deadline) { await ImageStore.shared.avatar(uid, api: api, account: account) }
            }()
            if let file = await file, let a = try? UNNotificationAttachment(identifier: "image", url: file) {
                c.attachments = [a]
            }
            var content: UNNotificationContent = c
            if let img = await avatar, let uid = last.avatarUserId {
                content = await withSender(c, author: last.authorName, userId: uid, issueId: issueId, avatar: img)
            }
            try? await center.add(UNNotificationRequest(identifier: "issue-\(issueId)-\(last.key)", content: content, trigger: nil))
        }
    }

    #if DEBUG
    /// -RTNotify <id>: уведомление о задаче обычным путём post, и в демо — для UI-теста нажатия на уведомление.
    static func debugNotify(_ issueId: Int) async {
        guard let api = AppModel.shared.api, let issue = try? await api.issueJournals(issueId) else { return }
        await requestProvisional()
        let j = issue.journals.last { !($0.notes ?? "").isEmpty }
        let who = j?.user ?? issue.author
        let e = NotifEntry(issueId: issue.id, subject: issue.subject, project: issue.project.name,
                           lines: ["\(who.name): \(notePreview(j?.notes ?? ""))"], at: Int64(Date().timeIntervalSince1970 * 1000),
                           avatarUserId: who.id, type: NotifType.comment, eventId: j.map { "j\($0.id)" } ?? "debug",
                           projectId: issue.project.id, author: who.name)
        if AppModel.shared.isDemo {
            let img = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 120)).image { ctx in
                UIColor.systemTeal.setFill()
                ctx.fill(CGRect(x: 0, y: 0, width: 120, height: 120))
                (Avatar.initials(who.name) as NSString).draw(at: CGPoint(x: 24, y: 30), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 48, weight: .semibold), .foregroundColor: UIColor.white])
            }
            await ImageStore.shared.seedAvatar(who.id, img)
        }
        await post([e], evenInDemo: true)
    }
    #endif
}
