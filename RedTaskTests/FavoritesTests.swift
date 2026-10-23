import Foundation
import Testing
#if canImport(RedTaskCore)
@testable import RedTaskCore
typealias RMAttachment = RedTaskCore.Attachment // Testing тоже объявляет Attachment
#else
@testable import RedTask
typealias RMAttachment = RedTask.Attachment
#endif

@Suite("Избранное на сервере")
struct FavoritesTests {
    let api = RedmineAPI(baseURL: URL(string: "https://example.org")!, apiKey: "k")

    @Test func queryUsesFullFilterForm() {
        var q = IssueQuery(statusFilter: "open", subject: "crash", favorites: true, limit: 50)
        q.offset = 50
        let p = api.favoritesQuery(q)
        func has(_ k: String, _ v: String) -> Bool { p.contains { $0.0 == k && $0.1 == v } }
        #expect(has("set_filter", "1"))
        #expect(has("f[]", "favourite_state") && has("op[favourite_state]", "="))
        // с f[] короткий status_id сервер не читает — статус фильтром
        #expect(has("f[]", "status_id") && has("op[status_id]", "o"))
        #expect(!p.contains { $0.0 == "status_id" })
        #expect(has("op[subject]", "~") && has("v[subject][]", "crash"))
        #expect(has("offset", "50") && has("limit", "50"))
        #expect(api.favoritesQuery(IssueQuery(statusFilter: "closed", favorites: true)).contains { $0.0 == "op[status_id]" && $0.1 == "c" })
        #expect(api.favoritesQuery(IssueQuery(statusFilter: "*", favorites: true)).contains { $0.0 == "op[status_id]" && $0.1 == "*" })
    }

    @Test func pageParsing() {
        let on = #"<meta name="csrf-token" content="ab+c/1==" /> $(link).before('<a class="issue-244551-favourite icon icon-favourites-on" data-method="delete" href="/favourites/fav?object_id=244551">')"#
        #expect(csrfToken(on) == "ab+c/1==")
        #expect(pageFavoriteState(on, issueId: 244551) == true)
        #expect(pageFavoriteState(on, issueId: 24455) == nil)
        let off = #"<a class="issue-244293-favourite icon icon-favourites-off" data-method="post">"#
        #expect(pageFavoriteState(off, issueId: 244293) == false)
        #expect(csrfToken("<html></html>") == nil)
    }

    @Test func cookieMerge() {
        let fresh = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "_redmine_session=NEW; path=/; HttpOnly"], for: URL(string: "https://example.org")!)
        #expect(mergeCookies("waf=1; _redmine_session=OLD", fresh) == "waf=1; _redmine_session=NEW")
        #expect(mergeCookies("waf=1", fresh) == "waf=1; _redmine_session=NEW")
    }

    @Test func migrationFromLocalFavorites() throws {
        // настройки прежней версии: избранное только локальное, флага нет
        let old = try JSONSerialization.data(withJSONObject: ["serverURL": "https://example.org", "userId": 5, "favorites": [3, 1, 2]])
        let s = AppSettings.decode(old)
        #expect(s.favoritesMigrated)
        #expect(s.favoritesPending == [3, 1, 2])
        #expect(s.favorites.isEmpty)
        // перенесённое однажды не возвращается в очередь: кэш сервера остаётся кэшем
        var later = s
        later.favorites = [7]
        later.favoritesPending = []
        let again = AppSettings.decode(try JSONEncoder().encode(later))
        #expect(again.favoritesPending.isEmpty && again.favorites == [7])
        #expect(AppSettings.favoritesToMigrate(pending: [3, 1, 2], server: [1, 9]) == [3, 2])
        #expect(AppSettings.favoritesToMigrate(pending: [1], server: [1]).isEmpty)
    }
}
