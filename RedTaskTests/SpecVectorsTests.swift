import Foundation
import Testing
#if canImport(RedTaskCore)
@testable import RedTaskCore
#else
@testable import RedTask
#endif

/// Общие наборы трёх клиентов (spec/vectors.json, ресурс тестов — ссылка RedTaskTests/vectors.json).
@Suite("Спецификация: spec/vectors.json")
struct SpecVectorsTests {
    private final class Token {}
    let v: [String: Any] = {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: Token.self)
        #endif
        let url = bundle.url(forResource: "vectors", withExtension: "json")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    private func section(_ name: String) -> [String: Any] { v[name] as! [String: Any] }
    private func cases(_ name: String) -> [[String: Any]] { (v[name] as? [[String: Any]]) ?? section(name)["cases"] as! [[String: Any]] }
    private func json(_ o: Any) -> String { String(data: try! JSONSerialization.data(withJSONObject: o, options: .fragmentsAllowed), encoding: .utf8)! }

    private func issue(_ id: Int, status: Int = 1, assignee: Any? = nil) -> RMIssue {
        let a = assignee.flatMap { $0 is NSNull ? nil : $0 }.map { #","assigned_to":\#(json($0))"# } ?? ""
        return decode(#"{"id":\#(id),"project":{"id":1},"tracker":{"id":1},"status":{"id":\#(status)},"priority":{"id":1},"author":{"id":1}\#(a)}"#)
    }

    @Test func statusKind() {
        for c in cases("status_kind") {
            let s: IssueStatus = decode(#"{"id":1,"name":\#(json(c["name"]!)),"is_closed":\#(c["closed"] as! Bool)}"#)
            #expect(s.kind.rawValue == c["kind"] as! String, "\(s.name)")
        }
    }

    @Test func noteLink() {
        let s = section("note_link")
        let server = URL(string: s["server"] as! String)!, issue = s["issue"] as! Int, journals = s["journals"] as! [Int]
        for l in s["links"] as! [[String: Any]] {
            #expect(noteUrl(server: server, issue: issue, journals: journals, journalId: l["journal"] as! Int)?.absoluteString == l["url"] as? String)
        }
        for f in s["fragments"] as! [[String: Any]] {
            #expect(journalForFragment(journals, f["fragment"] as! String) == f["journal"] as? Int, "\(f["fragment"]!)")
        }
    }

    @Test func quoteReplyCases() {
        for c in cases("quote_reply") {
            let out = quoteReply(author: c["author"] as! String, note: c["note"] as? Int, text: c["text"] as! String, lang: c["lang"] as! String)
            #expect(out == c["out"] as? String)
        }
    }

    @Test func projectPins() {
        let s = section("project_pins")
        let projects = (s["projects"] as! [[String: Any]]).map { Project(id: $0["id"] as! Int, name: $0["name"] as! String) }
        #expect(pinnedProjects(projects, pins: s["pins"] as! [Int]).map(\.id) == s["pinned"] as! [Int])
    }

    @Test func versionProgress() {
        for c in cases("version_progress") {
            let p = VersionProgress(closed: c["closed"] as! [Bool])
            #expect(p.done == c["done"] as! Int && p.total == c["total"] as! Int && p.percent == c["percent"] as! Int)
        }
    }

    @Test func assigneeFilter() {
        let s = section("assignee_filter")
        let me = s["me"] as! Int
        let issues = (s["issues"] as! [[String: Any]]).map { issue($0["id"] as! Int, assignee: $0["assignee"]) }
        let options = assigneeOptions(issues, me: me)
        let want = s["options"] as! [[String: Any]]
        #expect(options.map(\.key) == want.map { $0["key"] as! String })
        #expect(options.map(\.count) == want.map { $0["count"] as! Int })
        #expect(options.map(\.name) == want.map { $0["name"] as? String })
        for sel in s["select"] as! [[String: Any]] {
            #expect(filterByAssignee(issues, key: sel["key"] as! String, me: me).map(\.id) == sel["ids"] as! [Int])
        }
    }

    @Test func boardColumnsOrder() {
        let s = section("board_columns")
        let issues = (s["issues"] as! [[String: Any]]).map { issue($0["id"] as! Int, status: $0["status"] as! Int) }
        let cols = boardColumns(issues, statusOrder: s["status_order"] as! [Int])
        let want = s["columns"] as! [[String: Any]]
        #expect(cols.map(\.status.id) == want.map { $0["status"] as! Int })
        #expect(cols.map { $0.issues.map(\.id) } == want.map { $0["ids"] as! [Int] })
    }

    @Test func notifImage() {
        let s = section("notif_image")
        let attachments: [RMAttachment] = decode(json(s["attachments"]!))
        for c in s["cases"] as! [[String: Any]] {
            let details: [JournalDetail] = decode(json(c["details"]!))
            #expect(notificationImage(notes: c["notes"] as? String, details: details, attachments: attachments) == c["image"] as? Int, "\(c["notes"]!)")
        }
    }

    @Test func wikiLink() {
        for c in cases("wiki_link") {
            let want = Inline.wiki(project: c["project"] as? String, title: c["title"] as! String, label: c["label"] as! String)
            #expect(parseInline(c["src"] as! String) == [want])
        }
    }
}
