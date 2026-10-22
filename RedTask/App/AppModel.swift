import Foundation
import SwiftUI
import WebKit
import UserNotifications

/// Куда перейти: задача и, если есть, комментарий (из уведомления, ссылки, колокольчика).
struct OpenRequest: Equatable {
    var issueId: Int
    var note: Int?
    var token = UUID()
}

/**
 Состояние сессии: настройки, клиент API учётки, справочники, избранное, непрочитанное, переходы.
 Один на приложение.
 */
@MainActor @Observable
final class AppModel {
    static let shared = AppModel()

    var settings: AppSettings { didSet { if settings != oldValue { settings.save() } } }
    private(set) var api: RedmineAPI?
    private(set) var refs: RefData?
    var unreadCount = 0
    var openRequest: OpenRequest?
    /// Растёт, когда списки могли устареть (сохранили задачу, создали новую): видимый список тихо перезапрашивается.
    var listEpoch = 0

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
        #if DEBUG
        debugLaunch()
        #endif
    }

    #if DEBUG
    /// Отладочный запуск из simctl: -RTKey <ключ> [-RTServer url] [-RTIssue id] [-RTNote id].
    private func debugLaunch() {
        let d = UserDefaults.standard
        if let key = d.string(forKey: "RTKey"), !isLoggedIn {
            let server = d.string(forKey: "RTServer") ?? "https://my.basealt.space"
            Task { try? await login(server: server, key: key) }
        }
        if d.integer(forKey: "RTIssue") > 0 {
            let id = d.integer(forKey: "RTIssue"), note = d.integer(forKey: "RTNote")
            Task { try? await Task.sleep(for: .seconds(2)); open(id, note: note > 0 ? note : nil) }
        }
    }
    #endif

    var account: String { settings.accountKey }
    var isLoggedIn: Bool { api != nil }

    private func connect(url: URL, key: String) {
        let api = RedmineAPI(baseURL: url, apiKey: key)
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
        Poller.schedule()
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
        var s = settings
        s.userId = 0
        s.userName = ""
        s.userLogin = ""
        s.favorites = []
        s.lastCheck = nil
        settings = s
        unreadCount = 0
    }

    func isFavorite(_ id: Int) -> Bool { settings.favorites.contains(id) }

    func toggleFavorite(_ id: Int) {
        if let i = settings.favorites.firstIndex(of: id) { settings.favorites.remove(at: i) } else { settings.favorites.append(id) }
    }

    func open(_ issueId: Int, note: Int? = nil) { openRequest = OpenRequest(issueId: issueId, note: note) }

    func refreshUnread() async {
        unreadCount = await NotifStore.shared.unread().count
        try? await UNUserNotificationCenter.current().setBadgeCount(unreadCount)
    }

    /// Universal link https://сервер/issues/123[#note-5] → задача.
    func handle(url: URL) {
        guard let base = api?.baseURL, url.host == base.host else { return }
        let parts = url.path.split(separator: "/")
        guard let i = parts.firstIndex(of: "issues"), i + 1 < parts.count, let id = Int(parts[i + 1]) else { return }
        let note = url.fragment.flatMap { $0.hasPrefix("note-") ? Int($0.dropFirst(5)) : nil }
        open(id, note: note)
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
