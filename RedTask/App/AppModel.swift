import Foundation
import SwiftUI
import WebKit
import UserNotifications

/// Куда перейти: задача и, если есть, журнал — фрагментом «note-N» или «change-ID» (уведомление, ссылка, колокольчик).
struct OpenRequest: Equatable {
    var issueId: Int
    var fragment: String?
    var token = UUID()
}

/**
 Состояние сессии: настройки, клиент API учётки, справочники, избранное, непрочитанное, переходы.
 Один на приложение.
 */
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    /// Демо-режим: в памяти, на диск настройки не пишутся, после перезапуска — снова экран входа.
    private(set) var isDemo = false
    var settings: AppSettings { didSet { if settings != oldValue && !isDemo { settings.save() } } }
    private(set) var api: RedmineAPI?
    private(set) var refs: RefData?
    /// Непрочитанные уведомления (spec 19.2) — бейдж колокольчика и иконки.
    var unreadCount = 0
    /// Прочитано и непрочитано (spec 19.1): файл в Application Support; в демо — только память.
    var readState = ReadState() {
        didSet { if readState != oldValue && !isDemo { try? Files.write(readState, Self.readFile) } }
    }
    /// Непрочитанные задачи избранных запросов (spec 19.3): id запроса → задача → updated_on.
    private(set) var queryUnread: [String: [Int: Int64]] = [:]
    private var queryCountedAt: [String: Date] = [:]
    var openRequest: OpenRequest?
    /// Растёт, когда списки могли устареть (сохранили задачу, создали новую): видимый список тихо перезапрашивается.
    var listEpoch = 0
    /// Растёт, когда избранное на сервере поменялось: список «Избранное» перезапрашивается.
    var favoritesEpoch = 0
    /// Растёт после скачивания вложения: строки вложений пробуют достать встроенную миниатюру.
    var downloadsEpoch = 0
    /// Ошибка звезды — общий алерт (RootView).
    var favoriteError: FavoriteError?
    /// Вход через сайт ради веб-сессии (звезда пишется только ею).
    var showWebLogin = false
    private var pendingFavorite: (id: Int, on: Bool)?
    /// Запросы, которые сейчас уходят на сервер (spec 17.3).
    private(set) var pushingQueries = Set<String>()
    /// Повтор «на сервер» без кнопки при открытии списка — не чаще раза в сессию на запрос.
    private var queriesRetried = Set<String>()
    private var favoriteWrites = 0
    private var migrating = false

    struct FavoriteError: Identifiable {
        let id = UUID()
        var message: String
        var needsWebLogin: Bool
    }

    private init() {
        settings = AppSettings.load()
        if settings.isLoggedIn {
            if let key = Keychain.load(account: settings.account), let url = URL(string: settings.serverURL) {
                connect(url: url, key: key)
            } else {
                settings.userId = 0 // ключа нет (переустановка без Keychain) — заново ко входу
            }
        }
        restoreBrowserPass()
        if isLoggedIn {
            // первый запуск версии со spec 19 — всё, что было до него, прочитано
            if let r = Files.read(ReadState.self, Self.readFile) { readState = r } else {
                readState.markAll(now: Self.nowMs)
                try? Files.write(readState, Self.readFile) // didSet в init не срабатывает
            }
            Task { await refreshFavorites() }
        }
        #if DEBUG
        debugLaunch()
        #endif
    }

    #if DEBUG
    /// Отладочный запуск из simctl: -RTKey <ключ> [-RTServer url] [-RTIssue id] [-RTNote id] [-RTNotify id].
    private func debugLaunch() {
        let d = UserDefaults.standard
        if d.bool(forKey: "RTDemo") { enterDemo() } // и поверх входа: снимки без настоящих данных
        if d.bool(forKey: "RTBoard") { settings.versionBoard = true }
        if let key = d.string(forKey: "RTKey"), !isLoggedIn {
            let server = d.string(forKey: "RTServer") ?? "https://my.basealt.space"
            Task { try? await login(server: server, key: key) }
        }
        if d.integer(forKey: "RTIssue") > 0 {
            let id = d.integer(forKey: "RTIssue"), note = d.integer(forKey: "RTNote")
            Task { try? await Task.sleep(for: .seconds(2)); open(id, fragment: note > 0 ? "change-\(note)" : nil) }
        }
        // -RTNotify <id>: через 3 с — системное уведомление о задаче (в демо тоже)
        if d.integer(forKey: "RTNotify") > 0 {
            let id = d.integer(forKey: "RTNotify")
            Task { try? await Task.sleep(for: .seconds(3)); await Poller.debugNotify(id) }
        }
    }
    #endif

    var account: String { settings.accountKey }
    var isLoggedIn: Bool { api != nil }

    private func connect(url: URL, key: String) {
        let api = RedmineAPI(baseURL: url, apiKey: key, protocolClasses: isDemo ? [DemoServer.self] : [])
        self.api = api
        refs = RefData(api: api, account: settings.accountKey)
    }

    /// «example.org/redmine/» → «https://example.org/redmine».
    static func normalize(_ server: String) -> URL? {
        var s = server.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.isEmpty { return nil }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") { s = "https://" + s }
        guard let u = URL(string: s), u.host != nil else { return nil }
        return u
    }

    /// Проверяет ключ (users/current) и только потом сохраняет: иначе в настройки попала бы личность с id = 0.
    func login(server: String, key rawKey: String) async throws {
        guard let url = Self.normalize(server) else { throw RedmineError(code: 0, message: String(localized: "Invalid server address")) }
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let user = try await RedmineAPI(baseURL: url, apiKey: key).currentUser()
        var s = settings
        s.serverURL = url.absoluteString
        s.userId = user.id
        s.userName = user.displayName
        s.userLogin = user.login
        s.lastCheck = Date()
        // другая учётка — отключённые задачи и проекты прежней к ней не относятся
        if await NotifStore.shared.claim(s.account) {
            s.mutedIssues = [:]
            s.mutedProjects = [:]
        }
        Keychain.save(key, account: s.account)
        settings = s
        connect(url: url, key: key)
        readState = ReadState(baseline: Self.nowMs)
        unreadCount = 0
        // тихое разрешение: без системного вопроса при входе (HIG — спрашивать по месту)
        await Poller.requestProvisional()
        Poller.schedule()
        Poller.foreground()
        await refreshFavorites()
    }

    /// Демо: выдуманный сервер в памяти (DemoServer), сеть не используется. Выход — «Выйти» в настройках.
    func enterDemo() {
        DemoServer.reset()
        isDemo = true
        var s = AppSettings(favoritesMigrated: true)
        s.serverURL = DemoServer.base.absoluteString
        s.userId = DemoServer.me.id
        s.userName = DemoServer.me.displayName
        s.userLogin = DemoServer.me.login
        s.favorites = DemoServer.favoriteIds
        settings = s
        try? FileManager.default.removeItem(at: Files.caches.appendingPathComponent(settings.accountKey))
        connect(url: DemoServer.base, key: "demo")
        // демо: события последних полутора часов — непрочитанные (точки и бейджи видны на снимках)
        readState = ReadState(baseline: Self.nowMs - 90 * 60 * 1000)
        unreadCount = 0
        // колокольчик — обычным опросом по демо-данным: свежие события станут непрочитанными
        Task {
            await NotifStore.shared.claim("demo")
            await NotifStore.shared.clear()
            await Poller.poll()
        }
    }

    /// Выход: ключ, кэши учётки, избранное. Настройки уведомлений остаются — тот же человек не настраивает их заново.
    func logout() {
        Keychain.delete(account: settings.account)
        try? FileManager.default.removeItem(at: Files.caches.appendingPathComponent(settings.accountKey))
        Task { await NotifStore.shared.clear() }
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
        UNUserNotificationCenter.current().setBadgeCount(0)
        api = nil
        refs = nil
        MentionStore.shared.clear()
        Task { await ImageStore.shared.clear(); await LabelStore.shared.clear() }
        unreadCount = 0
        pendingFavorite = nil
        queriesRetried = []
        queryUnread = [:]
        queryCountedAt = [:]
        readState = ReadState()
        if isDemo {
            // настройки демо на диск не попадали — возвращаем сохранённые (вышедшие) настройки
            isDemo = false
            settings = AppSettings.load()
            readState = Files.read(ReadState.self, Self.readFile) ?? ReadState()
            return
        }
        try? FileManager.default.removeItem(at: Self.readFile)
        var s = settings
        s.userId = 0
        s.userName = ""
        s.userLogin = ""
        s.favorites = []
        s.favoritesPending = []
        s.recentIssues = []
        s.localQueries = []
        s.recentFilters = []
        s.favoriteQueries = []
        s.lastCheck = nil
        s.lastCheckError = nil
        settings = s
    }

    // MARK: - Избранное (на сервере, плагин redmine_favourites_issues)

    func isFavorite(_ id: Int) -> Bool { settings.favorites.contains(id) }

    /// Звезда оптимистично: сразу на экране, запись на сервер фоном; сбой — откат и алерт.
    func toggleFavorite(_ id: Int) {
        let on = !isFavorite(id)
        setLocalFavorite(id, on)
        favoriteWrites += 1
        Task {
            defer { favoriteWrites -= 1 }
            do {
                try await writeFavorite(id, on)
                favoritesEpoch += 1
            } catch {
                setLocalFavorite(id, !on)
                let web = error is WebSessionRequired
                // после входа через сайт повторим — нажатие не теряется
                if web { pendingFavorite = (id, on) }
                favoriteError = FavoriteError(message: error.localizedDescription, needsWebLogin: web)
            }
        }
    }

    private func setLocalFavorite(_ id: Int, _ on: Bool) {
        settings.favorites.removeAll { $0 == id }
        if on { settings.favorites.insert(id, at: 0) }
    }

    private func writeFavorite(_ id: Int, _ on: Bool) async throws {
        if isDemo { return DemoServer.setFavorite(id, on) }
        try await webSession { api, cookie, agent in ((), try await api.setFavorite(id, on, cookie: cookie, userAgent: agent)) }
    }

    /// Действие веб-сессией сайта (куки WebView и его UA); в демо — выдуманная сессия, отвечает DemoServer.
    private func webSession<T>(_ op: (RedmineAPI, String, String) async throws -> (T, [HTTPCookie])) async throws -> T {
        guard let api, let host = api.baseURL.host else { throw WebSessionRequired() }
        let agent = UserDefaults.standard.string(forKey: "wafAgent") ?? RedmineAPI.userAgent
        if isDemo { return try await op(api, "_redmine_session=demo", agent).0 }
        guard let cookie = await Self.cookieHeader(host: host) else { throw WebSessionRequired() }
        let (value, fresh) = try await op(api, cookie, agent)
        // обновлённая сессия — обратно в WebView, иначе она истечёт по таймауту неактивности
        for c in fresh { await WKWebsiteDataStore.default().httpCookieStore.setCookie(c) }
        if !fresh.isEmpty { await loadBrowserCookies(agent: agent) }
        return value
    }

    /// Набор с сервера (вход, возврат в приложение, список «Избранное»); затем — перенос старого локального.
    func refreshFavorites() async {
        guard let api, favoriteWrites == 0 else { return }
        guard let ids = try? await api.favoriteIds(), favoriteWrites == 0, api === self.api else { return }
        if settings.favorites != ids { settings.favorites = ids }
        await migrateFavorites(server: ids)
    }

    /// Перенос избранного прежних версий: по одной задаче, пока есть веб-сессия; без неё ждём входа через сайт.
    private func migrateFavorites(server: [Int]) async {
        let todo = AppSettings.favoritesToMigrate(pending: settings.favoritesPending, server: Set(server))
        if todo.isEmpty {
            if !settings.favoritesPending.isEmpty { settings.favoritesPending = [] }
            return
        }
        guard !migrating else { return }
        migrating = true
        defer { migrating = false }
        var moved = false
        for id in todo {
            do {
                try await writeFavorite(id, true)
                setLocalFavorite(id, true)
                moved = true
            } catch let e as RedmineError where e.code == 403 || e.code == 404 {
                // задачи нет или нет доступа — переносить нечего
            } catch { break }
            settings.favoritesPending.removeAll { $0 == id }
        }
        if moved { favoritesEpoch += 1 }
    }

    /// Вход через сайт для звезды: ключ того же человека — повторяем отложенное нажатие и перенос.
    func webLoginDone(key: String, agent: String) async {
        showWebLogin = false
        await adoptBrowserPass(agent: agent)
        guard key == Keychain.load(account: settings.account) else {
            pendingFavorite = nil
            favoriteError = FavoriteError(message: String(localized: "You signed in on the website as a different user."), needsWebLogin: false)
            return
        }
        if let p = pendingFavorite {
            pendingFavorite = nil
            if isFavorite(p.id) != p.on { toggleFavorite(p.id) }
        }
        // запросы «Только на устройстве» — снова на сервер (spec 17.3)
        for q in settings.localQueries where !q.onServer && !q.detached { Task { await pushQuery(q.localId) } }
        await refreshFavorites()
    }

    func cancelPendingFavorite() { pendingFavorite = nil }

    // MARK: - Сохранённые запросы (spec 17)

    /// Шаг 1 — у себя, сразу; шаг 2 — на сервер фоном.
    func saveQuery(_ q: LocalQuery) {
        if let i = settings.localQueries.firstIndex(where: { $0.localId == q.localId }) { settings.localQueries[i] = q }
        else { settings.localQueries.insert(q, at: 0) }
        Task { await pushQuery(q.localId) }
    }

    /// Шаг 2 — веб-формой сайта. Не вышло — «Только на устройстве» с причиной.
    /// interactive — нажали «Сохранить на сервере»: нет веб-сессии — сразу вход через сайт (после него повтор сам).
    func pushQuery(_ localId: String, interactive: Bool = false) async {
        guard let q = settings.localQueries.first(where: { $0.localId == localId }), !pushingQueries.contains(localId) else { return }
        pushingQueries.insert(localId)
        defer { pushingQueries.remove(localId) }
        var serverId = q.serverId
        var reason: String?
        do {
            let id: Int = try await webSession { api, cookie, agent in try await api.saveQuery(q, cookie: cookie, userAgent: agent) }
            serverId = id
        }
        catch {
            reason = Self.queryError(error)
            if interactive && error is WebSessionRequired { showWebLogin = true }
        }
        guard let i = settings.localQueries.firstIndex(where: { $0.localId == localId }) else { return }
        settings.localQueries[i].serverId = serverId
        settings.localQueries[i].error = reason
        if reason == nil { settings.localQueries[i].detached = false }
    }

    private static func queryError(_ e: Error) -> String {
        if e is WebSessionRequired { return String(localized: "Sign in on the website") }
        if let r = e as? RedmineError, [403, 404, 422].contains(r.code) { return r.message }
        return String(localized: "No connection")
    }

    /// Удаление: есть server_id — сначала на сервере. false — сервер не удалил (спросить «Удалить только на устройстве?»).
    func deleteQuery(_ q: LocalQuery, localOnly: Bool = false) async -> Bool {
        if let sid = q.serverId, !localOnly {
            do { try await webSession { api, cookie, agent in ((), try await api.deleteQuery(sid, projectId: q.projectId, cookie: cookie, userAgent: agent)) } }
            catch { return false }
        }
        settings.localQueries.removeAll { $0.localId == q.localId }
        settings.favoriteQueries.removeAll { $0.id == q.run.id }
        return true
    }

    /// Сверка с queries.json (spec 17.4) и повтор «на сервер» без кнопки — раз в сессию на запрос.
    func syncQueries(_ server: [ServerQuery]) {
        let synced = syncLocalQueries(settings.localQueries, server: server, deletedReason: String(localized: "Deleted on the website"))
        if synced != settings.localQueries { settings.localQueries = synced }
        for q in synced where !q.onServer && !q.detached && queriesRetried.insert(q.localId).inserted {
            Task { await pushQuery(q.localId) }
        }
    }

    func addRecentFilter(_ f: IssueFilter) { settings.recentFilters = recentFilters(settings.recentFilters, f) }

    func isFavoriteQuery(_ id: String) -> Bool { settings.favoriteQueries.contains { $0.id == id } }
    func toggleFavoriteQuery(_ r: QueryRun) {
        if isFavoriteQuery(r.id) { settings.favoriteQueries.removeAll { $0.id == r.id } } else { settings.favoriteQueries.append(r) }
    }

    /// Избранный локальный запрос — с нынешними именем и условиями.
    func resolved(_ r: QueryRun) -> QueryRun {
        settings.localQueries.first { $0.run.id == r.id }?.run ?? r
    }

    // MARK: - Избранные проекты (локально, на учётку)

    var projectPins: [Int] { settings.projectPins[account] ?? [] }
    func isPinned(_ projectId: Int) -> Bool { projectPins.contains(projectId) }
    func togglePin(_ projectId: Int) {
        var pins = projectPins
        if let i = pins.firstIndex(of: projectId) { pins.remove(at: i) } else { pins.append(projectId) }
        settings.projectPins[account] = pins
    }

    func open(_ issueId: Int, fragment: String? = nil) { openRequest = OpenRequest(issueId: issueId, fragment: fragment) }

    // MARK: - Прочитано и непрочитано (spec 19)

    private static var readFile: URL { Files.support.appendingPathComponent("read-state.json") }
    static var nowMs: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    func isUnread(_ issue: Issue) -> Bool { redmineMillis(issue.updatedOn).map { readState.isUnread(issue.id, $0) } ?? false }
    func isUnread(_ e: NotifEntry) -> Bool { readState.isUnread(e.issueId, e.at) }

    /// Свежая версия задачи с сервера на экране — просмотр: точки, бейджи и колокольчик меняются сразу.
    func viewed(_ issue: Issue) {
        guard let u = redmineMillis(issue.updatedOn), readState.seen[issue.id] != u else { return }
        readState.view(issue.id, u)
        Task { await refreshUnread() }
    }

    func markAllRead() {
        readState.markAll(now: Self.nowMs)
        Task { await refreshUnread() }
    }

    func refreshUnread() async {
        let entries = await NotifStore.shared.load()
        unreadCount = entries.filter { isUnread($0) }.count
        try? await UNUserNotificationCenter.current().setBadgeCount(unreadCount)
    }

    /// Бейдж избранного запроса: сколько из его непрочитанных задач всё ещё непрочитаны.
    func queryBadge(_ id: String) -> Int { queryUnread[id]?.filter { readState.isUnread($0.key, $0.value) }.count ?? 0 }

    /// Пересчёт бейджей избранных запросов (опрос, показ вкладки) — не чаще раза в минуту на запрос.
    func refreshQueryBadges() async {
        guard let api else { return }
        for saved in settings.favoriteQueries {
            let run = resolved(saved)
            if let t = queryCountedAt[run.id], Date().timeIntervalSince(t) < 60 { continue }
            queryCountedAt[run.id] = Date()
            if let found = try? await unreadIssues(run.filter, api: api), api === self.api { queryUnread[run.id] = found }
        }
    }

    /// Тот же запрос свежими сверху, страницами по 100 — до задачи не новее рубежа или до 100 непрочитанных.
    private func unreadIssues(_ filter: IssueFilter, api: RedmineAPI) async throws -> [Int: Int64] {
        var f = filter
        f.sort = [SortCrit(field: "updated_on", dir: "desc")]
        var found: [Int: Int64] = [:]
        var offset = 0
        while true {
            let page = try await api.issues(f, offset: offset, limit: 100)
            for i in page.issues {
                guard let u = redmineMillis(i.updatedOn) else { continue }
                if u <= readState.baseline { return found }
                if readState.isUnread(i.id, u) { found[i.id] = u }
                if found.count >= 100 { return found }
            }
            offset += page.issues.count
            if page.issues.isEmpty || offset >= page.totalCount { return found }
        }
    }

    /// Universal link https://сервер/issues/123[#note-5 | #change-ID] → задача; журнал найдёт journalForFragment.
    func handle(url: URL) {
        guard let base = api?.baseURL, url.host == base.host else { return }
        let parts = url.path.split(separator: "/")
        guard let i = parts.firstIndex(of: "issues"), i + 1 < parts.count, let id = Int(parts[i + 1]) else { return }
        open(id, fragment: url.fragment)
    }

    // MARK: - Пропуск WAF

    /**
     После решения капчи (или входа через сайт) запросы идут с куками WKWebView и его UA:
     WAF привязывает пропуск к браузеру. UA помним между запусками, куки живут в WKWebsiteDataStore.
     */
    func adoptBrowserPass(agent: String) async {
        UserDefaults.standard.set(agent, forKey: "wafAgent")
        await loadBrowserCookies(agent: agent)
    }

    private func restoreBrowserPass() {
        guard let agent = UserDefaults.standard.string(forKey: "wafAgent") else { return }
        Task { await loadBrowserCookies(agent: agent) }
    }

    private func loadBrowserCookies(agent: String) async {
        guard let host = api?.baseURL.host ?? URL(string: settings.serverURL)?.host else { return }
        let header = await Self.cookieHeader(host: host)
        WafGate.shared.setBrowser(cookie: header, agent: agent)
    }

    /// Куки WKWebView для хоста одной строкой заголовка Cookie.
    static func cookieHeader(host: String) async -> String? {
        let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        let mine = cookies.filter { c in
            let d = c.domain.hasPrefix(".") ? String(c.domain.dropFirst()) : c.domain
            return host == d || host.hasSuffix("." + d)
        }
        guard !mine.isEmpty else { return nil }
        return mine.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}
