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
    var unreadCount = 0
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
        if isLoggedIn { Task { await refreshFavorites() } }
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
        Task { await ImageStore.shared.clear() }
        unreadCount = 0
        pendingFavorite = nil
        if isDemo {
            // настройки демо на диск не попадали — возвращаем сохранённые (вышедшие) настройки
            isDemo = false
            settings = AppSettings.load()
            return
        }
        var s = settings
        s.userId = 0
        s.userName = ""
        s.userLogin = ""
        s.favorites = []
        s.favoritesPending = []
        s.lastCheck = nil
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
        guard let api, let host = api.baseURL.host else { return }
        guard let cookie = await Self.cookieHeader(host: host) else { throw WebSessionRequired() }
        let agent = UserDefaults.standard.string(forKey: "wafAgent") ?? RedmineAPI.userAgent
        let fresh = try await api.setFavorite(id, on, cookie: cookie, userAgent: agent)
        // обновлённая сессия — обратно в WebView, иначе она истечёт по таймауту неактивности
        for c in fresh { await WKWebsiteDataStore.default().httpCookieStore.setCookie(c) }
        if !fresh.isEmpty { await loadBrowserCookies(agent: agent) }
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
        await refreshFavorites()
    }

    func cancelPendingFavorite() { pendingFavorite = nil }

    // MARK: - Избранные проекты (локально, на учётку)

    var projectPins: [Int] { settings.projectPins[account] ?? [] }
    func isPinned(_ projectId: Int) -> Bool { projectPins.contains(projectId) }
    func togglePin(_ projectId: Int) {
        var pins = projectPins
        if let i = pins.firstIndex(of: projectId) { pins.remove(at: i) } else { pins.append(projectId) }
        settings.projectPins[account] = pins
    }

    func open(_ issueId: Int, fragment: String? = nil) { openRequest = OpenRequest(issueId: issueId, fragment: fragment) }

    func refreshUnread() async {
        unreadCount = await NotifStore.shared.unread().count
        try? await UNUserNotificationCenter.current().setBadgeCount(unreadCount)
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
