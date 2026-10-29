import Foundation
import Security
import CryptoKit

// MARK: - Keychain

/// API-ключ — только в Keychain. Доступен после первой разблокировки: он нужен фоновому опросу.
enum Keychain {
    private static let service = "ru.toxblh.RedTask.apikey"

    static func save(_ key: String, account: String) {
        delete(account: account)
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Настройки

enum NotifFlag: String, Codable, Sendable, CaseIterable {
    case scopeAssigned, scopeAuthored, scopeWatched, favoritesOnly, statusClosedOnly, priorityRaisedOnly
    var defaultOn: Bool { [.scopeAssigned, .scopeAuthored, .scopeWatched].contains(self) }
}

struct AppSettings: Codable, Sendable, Equatable {
    var serverURL = ""
    var userId = 0
    var userName = ""
    /// Логин — по нему ищутся @упоминания.
    var userLogin = ""
    var notificationsEnabled = true
    var lastCheck: Date?
    /// Избранное сервера (кэш набора, источник правды — сервер).
    var favorites: [Int] = []
    /// Избранное прежних версий (хранилось только здесь) — ждёт переноса на сервер.
    var favoritesPending: [Int] = []
    /// Локальное избранное уже переложено в очередь переноса.
    var favoritesMigrated = false
    /// Выключенные категории уведомлений — значения NotifType.
    var notifMuted: Set<String> = NotifCategory.defaultMuted
    var notifFlags: Set<NotifFlag> = Set(NotifFlag.allCases.filter(\.defaultOn))
    /// Задачи и проекты без уведомлений: id → название.
    var mutedIssues: [Int: String] = [:]
    var mutedProjects: [Int: String] = [:]
    /// Вид колокольчика: false — лента, true — по задачам внутри дня.
    var notifByIssue = false
    /// Комментарии: свежие сверху.
    var newestFirst = true
    /// Избранные проекты — локально, на учётку (accountKey → id проектов): на сервере такого нет.
    var projectPins: [String: [Int]] = [:]
    /// Экран вехи: доска вместо списка.
    var versionBoard = false

    var isLoggedIn: Bool { !serverURL.isEmpty && userId != 0 }
    var account: String { "\(serverURL)#\(userId)" }

    /// Каталог кэшей учётки: смена учётки — другой каталог, выход — удаление.
    var accountKey: String {
        SHA256.hash(data: Data(account.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /**
     Категории события, по которым оно уведомляет: включённые и не отсечённые подопцией «только…».
     Пусто — уведомления нет (в том числе по отключённой задаче или проекту).
     На историю колокольчика это не влияет.
     */
    func notifyTypes(_ e: NotifEntry) -> [String] {
        if mutedIssues[e.issueId] != nil { return [] }
        if let p = e.projectId, mutedProjects[p] != nil { return [] }
        func on(_ type: String, _ strong: Bool) -> Bool {
            let cat = NotifCategory.of(type)
            let weak = !strong && (cat == .status && notifFlags.contains(.statusClosedOnly) || cat == .priority && notifFlags.contains(.priorityRaisedOnly))
            return !notifMuted.contains(cat.rawValue) && !weak
        }
        return e.types.filter { on($0, $0 == e.type ? e.strong : (e.alsoTypes[$0] ?? true)) }
    }

    func notifies(_ e: NotifEntry) -> Bool { !notifyTypes(e).isEmpty }

    /// Отпечаток охвата: сменился — прошлый набор «моих» задач с новым сравнивать нельзя.
    var scopeKey: String {
        let flags: [NotifFlag] = [.scopeAssigned, .scopeAuthored, .scopeWatched, .favoritesOnly]
        var s = flags.map { notifFlags.contains($0) ? "1" : "0" }.joined()
        if notifFlags.contains(.favoritesOnly) { s += ":" + favorites.sorted().map(String.init).joined(separator: ",") }
        return s
    }

    static func load() -> AppSettings {
        guard let d = UserDefaults.standard.data(forKey: "settings") else { return AppSettings(favoritesMigrated: true) }
        return decode(d)
    }

    /// Что из очереди переноса ещё не на сервере.
    static func favoritesToMigrate(pending: [Int], server: Set<Int>) -> [Int] { pending.filter { !server.contains($0) } }

    /**
     Поля, появившиеся в новой версии, берутся по умолчанию — сохранённое старой версией читается.
     Избранное старой версии было локальным: однажды уходит в очередь переноса на сервер.
     */
    static func decode(_ d: Data) -> AppSettings {
        var s = merged(d)
        if !s.favoritesMigrated {
            s.favoritesPending = s.favorites
            s.favorites = []
            s.favoritesMigrated = true
        }
        return s
    }

    private static func merged(_ d: Data) -> AppSettings {
        guard let stored = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let defData = try? JSONEncoder().encode(AppSettings()),
              let def = (try? JSONSerialization.jsonObject(with: defData)) as? [String: Any],
              let merged = try? JSONSerialization.data(withJSONObject: def.merging(stored) { $1 }),
              let s = try? JSONDecoder().decode(AppSettings.self, from: merged) else { return AppSettings() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "settings") }
    }
}

// MARK: - Файлы

enum Files {
    static var caches: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }
    static var support: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func dir(_ base: URL, _ parts: String...) -> URL {
        var u = base
        for p in parts { u.appendPathComponent(p, isDirectory: true) }
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func read<T: Decodable>(_ type: T.Type, _ url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSON.decoder().decode(T.self, from: d)
    }

    /// Атомарная запись: оборванная не оставляет вместо прежнего файла обрубок.
    static func write<T: Encodable>(_ value: T, _ url: URL) throws {
        try JSON.encoder().encode(value).write(to: url, options: [.atomic])
    }
}

/// Значение с временем получения с сервера — TTL кэшей на диске.
struct Stamped<T: Codable & Sendable>: Codable, Sendable {
    var at: Date
    var value: T
}

// MARK: - Кэш списков и задач (stale-while-revalidate)

/// Последняя выдача списка и последний снимок задачи: экран показывает их мгновенно, сеть освежает фоном.
enum ListCache {
    @concurrent static func load(_ account: String, _ key: String) async -> [Issue]? {
        Files.read([Issue].self, Files.dir(Files.caches, account, "lists").appendingPathComponent(safe(key) + ".json"))
    }
    @concurrent static func save(_ account: String, _ key: String, _ issues: [Issue]) async {
        try? Files.write(issues, Files.dir(Files.caches, account, "lists").appendingPathComponent(safe(key) + ".json"))
    }
    static func safe(_ key: String) -> String { key.replacingOccurrences(of: "/", with: "_") }
}

struct IssueSnapshot: Codable, Sendable {
    var issue: Issue
    var timeEntries: [TimeEntry]
}

enum IssueCache {
    @concurrent static func load(_ account: String, _ id: Int) async -> IssueSnapshot? {
        Files.read(IssueSnapshot.self, Files.dir(Files.caches, account, "issues").appendingPathComponent("\(id).json"))
    }
    @concurrent static func save(_ account: String, _ snap: IssueSnapshot) async {
        try? Files.write(snap, Files.dir(Files.caches, account, "issues").appendingPathComponent("\(snap.issue.id).json"))
    }
}

// MARK: - Справочники

/**
 Справочники (статусы, приоритеты, трекеры, деятельности, проекты, участники, версии, люди, права):
 память → диск → сеть, TTL одинаковый на обоих слоях: справочники и люди — 24 ч, проекты — 7 д.
 Один запрос на ключ: спросивший во время загрузки ждёт тот же Task. Отказ 403/404 помним 10 минут.
 */
actor RefData {
    private let api: RedmineAPI
    private let dir: URL
    private var mem: [String: (at: Date, value: any Sendable)] = [:]
    private var inFlight: [String: Task<any Sendable, Error>] = [:]
    private var misses: [String: Date] = [:]

    static let ttl: TimeInterval = 24 * 3600
    static let projectsTTL: TimeInterval = 7 * 24 * 3600
    static let missTTL: TimeInterval = 600

    init(api: RedmineAPI, account: String) {
        self.api = api
        dir = Files.dir(Files.caches, account, "refdata")
    }

    private func cached<T: Codable & Sendable>(_ name: String, ttl: TimeInterval = RefData.ttl, force: Bool = false,
                                                 _ fetch: @escaping @Sendable (RedmineAPI) async throws -> T) async throws -> T {
        if !force, let e = mem[name], Date().timeIntervalSince(e.at) < ttl, let v = e.value as? T { return v }
        let key = force ? name + "!" : name
        if let t = inFlight[key], let s = try await t.value as? Stamped<T> { return s.value }
        let file = dir.appendingPathComponent(name + ".json")
        let api = self.api
        let task = Task<any Sendable, Error> {
            if !force, let s = Files.read(Stamped<T>.self, file), Date().timeIntervalSince(s.at) < ttl { return Stamped(at: s.at, value: s.value) }
            let v = try await fetch(api)
            let s = Stamped(at: Date(), value: v)
            try? Files.write(s, file)
            return s
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        guard let s = try await task.value as? Stamped<T> else { throw RedmineError(code: 0, message: "cache") }
        mem[name] = (s.at, s.value)
        return s.value
    }

    /// Как cached, но отказ сервера (403/404) — nil, и помним его 10 минут.
    private func cachedOrMiss<T: Codable & Sendable>(_ name: String, _ fetch: @escaping @Sendable (RedmineAPI) async throws -> T) async throws -> T? {
        if let m = misses[name], Date().timeIntervalSince(m) < Self.missTTL { return nil }
        do { return try await cached(name, fetch) }
        catch let e as RedmineError where e.code == 403 || e.code == 404 {
            misses[name] = Date()
            return nil
        }
    }

    func projects(force: Bool = false) async throws -> [Project] { try await cached("projects", ttl: Self.projectsTTL, force: force) { try await $0.projects() } }
    func statuses(force: Bool = false) async throws -> [IssueStatus] { try await cached("statuses", force: force) { try await $0.statuses() } }
    func priorities(force: Bool = false) async throws -> [Priority] { try await cached("priorities", force: force) { try await $0.priorities() } }
    func trackers(force: Bool = false) async throws -> [Tracker] { try await cached("trackers", force: force) { try await $0.trackers() } }
    func activities(force: Bool = false) async throws -> [TimeEntryActivity] { try await cached("activities", force: force) { try await $0.activities() } }
    func members(_ projectId: Int, force: Bool = false) async throws -> [Named] {
        try await cached("members-\(projectId)", force: force) { try await $0.members(projectId) }
    }
    func versions(_ projectId: Int, force: Bool = false) async throws -> [Version] {
        try await cached("versions-\(projectId)", force: force) { try await $0.versions(projectId) }
    }

    /// Профиль человека: память → диск (24 ч) → сеть; отказ сервера помним 10 минут.
    func person(_ userId: Int, force: Bool = false) async throws -> Person {
        let name = "person-\(userId)"
        if !force, let m = misses[name], Date().timeIntervalSince(m) < Self.missTTL { throw RedmineError(code: 404, message: String(localized: "Not found")) }
        do { return try await cached(name, force: force) { try await $0.person(userId) } }
        catch let e as RedmineError { misses[name] = Date(); throw e }
    }

    /**
     Мои права в проекте — объединение прав всех моих ролей в нём; у админа — {"*"}.
     nil — узнать не удалось (сбой, не участник, сервер не отдаёт роли): вызывающий остаётся оптимистом.
     */
    func permissions(_ projectId: Int) async -> Set<String>? {
        guard let my = try? await cachedOrMiss("my-roles", { try await $0.myRoles() }) else { return nil }
        if my.admin { return ["*"] }
        guard let ids = my.roles[projectId], !ids.isEmpty else { return nil }
        var all = Set<String>()
        for id in ids {
            // неизвестна хоть одна роль — неизвестно и объединение
            guard let p = try? await cachedOrMiss("role-\(id)", { try await $0.rolePermissions(id) }) else { return nil }
            all.formUnion(p)
        }
        return all
    }

    /// Человек по логину (упоминание): поиск People по началу — берём точное совпадение. Только память.
    func personByLogin(_ login: String) async -> Person? {
        let l = login.trimmingCharacters(in: .whitespaces).lowercased()
        guard !l.isEmpty else { return nil }
        let name = "login-\(l)"
        if let e = mem[name] {
            let fresh = Date().timeIntervalSince(e.at) < ((e.value is Person) ? Self.ttl : Self.missTTL)
            if fresh { return e.value as? Person }
        }
        do {
            // с запасом: по началу «iv» сервер вернёт и Ивановых
            let found = try await api.searchPeople(l, limit: 100).first { ($0.login ?? "").lowercased() == l }
            mem[name] = (Date(), found.map { $0 as any Sendable } ?? false)
            return found
        } catch let e as RedmineError where e.code == 403 || e.code == 404 {
            mem[name] = (Date(), false)
            return nil
        } catch { return nil }
    }
}
