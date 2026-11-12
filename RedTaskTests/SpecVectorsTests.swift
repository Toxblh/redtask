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

    @Test func thumbnailSourceCases() {
        for c in cases("thumbnail_source") {
            let f = c["filename"] as! String
            #expect(thumbnailSource(filename: f, contentType: c["content_type"] as? String).rawValue == c["source"] as! String, "\(f)")
        }
    }

    @Test func embeddedThumbnailCases() {
        for c in cases("embedded_thumbnail") {
            let out = embeddedThumbnail(Data(base64Encoded: c["zip"] as! String)!)
            #expect(out == (c["out"] as? String).flatMap { Data(base64Encoded: $0) }, "\(c["name"]!)")
        }
    }

    @Test func tableColumnsCases() {
        for c in cases("table_columns") {
            let f = { (k: String) in (c[k] as! [Double]).map { CGFloat($0) } }
            let out = tableColumns(min: f("min"), max: f("max"), avail: CGFloat(c["avail"] as! Double))
            let want = f("widths")
            #expect(out.scroll == c["scroll"] as! Bool && out.widths.count == want.count, "\(c)")
            #expect(zip(out.widths, want).allSatisfy { abs($0 - $1) < 0.01 }, "\(out.widths) != \(want)")
        }
    }

    @Test func textileTableCases() {
        for c in cases("textile_table") {
            let rows = textileTableRows(c["src"] as! String).map { $0.map { ["h": $0.header, "text": $0.text] as [String: AnyHashable] } }
            let want = (c["rows"] as! [[[String: Any]]]).map { $0.map { ["h": $0["h"] as! Bool, "text": $0["text"] as! String] as [String: AnyHashable] } }
            #expect(rows == want, "\(c["name"]!)")
        }
    }

    @Test func mentionQueryCases() {
        for c in cases("mention_query") {
            #expect(mentionQuery(c["text"] as! String, cursor: c["cursor"] as! Int) == c["query"] as? String, "\(c["text"]!)")
        }
    }

    @Test func mentionCandidatesCases() {
        let s = section("mention_candidates")
        func people(_ k: String) -> [MentionPerson] {
            (s[k] as! [[String: Any]]).map { MentionPerson(id: $0["id"] as! Int, name: $0["name"] as! String, login: $0["login"] as! String) }
        }
        for c in s["cases"] as! [[String: Any]] {
            let out = mentionCandidates(participants: people("participants"), people: people("people"), query: c["query"] as! String, limit: c["limit"] as! Int)
            #expect(out.map(\.id) == c["ids"] as! [Int], "\(c["query"]!)")
        }
    }

    @Test func recentOpenedCases() {
        for c in cases("recent_opened") {
            #expect(recentOpened(c["list"] as! [Int], c["open"] as! Int) == c["out"] as! [Int])
        }
    }

    @Test func boardFilterCases() {
        let s = section("board_filter")
        let me = s["me"] as! Int
        let issues: [RMIssue] = (s["issues"] as! [[String: Any]]).map {
            var i = issue($0["id"] as! Int, assignee: $0["assignee"])
            i.subject = $0["subject"] as! String
            return i
        }
        for c in s["cases"] as! [[String: Any]] {
            let out = boardFilter(issues, me: me, assignees: Set(c["assignees"] as! [String]), query: c["query"] as! String)
            #expect(out.map(\.id) == c["ids"] as! [Int], "\(c["assignees"]!) \(c["query"]!)")
        }
    }

    @Test func zipTailCases() {
        for c in cases("zip_tail") {
            let e = zipTailEntry(size: c["size"] as! Int, tail: Data(base64Encoded: c["tail"] as! String)!)
            let want = (c["entry"] as? [String: Any]).map {
                ZipEntry(name: $0["name"] as! String, localOffset: $0["local_offset"] as! Int,
                         compressedSize: $0["compressed_size"] as! Int, method: $0["method"] as! Int)
            }
            let got = e.map { ZipEntry(name: $0.name, localOffset: $0.localOffset, compressedSize: $0.compressedSize, method: $0.method) }
            #expect(got == want, "\(c["name"]!)")
        }
    }

    @Test func customTablesCases() {
        for c in cases("custom_tables") {
            let out = customTables(c["html"] as! String).map { t in
                "\(t.title) | \(t.columns) | " + t.rows.map { $0.map { "\($0.text)#\($0.userId ?? 0)" }.joined(separator: ",") }.joined(separator: " / ")
                    + " | \(t.tableId ?? 0) | \(t.rowIds.map { $0 ?? 0 })"
            }
            let want = (c["tables"] as! [[String: Any]]).map { t in
                "\(t["title"] as! String) | \(t["columns"] as! [String]) | " + (t["rows"] as! [[[String: Any]]])
                    .map { $0.map { "\($0["text"] as! String)#\($0["user_id"] as? Int ?? 0)" }.joined(separator: ",") }.joined(separator: " / ")
                    + " | \(t["table_id"] as? Int ?? 0) | \((t["row_ids"] as! [Any]).map { $0 as? Int ?? 0 })"
            }
            #expect(out == want, "\(c["name"]!)")
        }
    }

    @Test func assigneeAvatarsCases() {
        let s = section("assignee_avatars")
        let me = s["me"] as! Int
        let issues: [RMIssue] = (s["issues"] as! [[String: Any]]).map {
            issue($0["id"] as! Int, status: ($0["closed"] as! Bool) ? 5 : 1, assignee: $0["assignee"])
        }.map { var i = $0; i.status.isClosed = i.status.id == 5; return i }
        for c in s["cases"] as! [[String: Any]] {
            let out = assigneeAvatars(issues, me: me, status: c["status"] as! String)
            let want = c["options"] as! [[String: Any]]
            #expect(out.map(\.key) == want.map { $0["key"] as! String }, "\(c["status"]!)")
            #expect(out.map(\.count) == want.map { $0["count"] as! Int }, "\(c["status"]!)")
        }
    }

    @Test func peoplePhonesCases() {
        for c in cases("people_phones") {
            let out = peoplePhones(c["html"] as! String).map { "\($0.text)|\($0.tel)" }
            let want = (c["phones"] as! [[String: Any]]).map { "\($0["text"] as! String)|\($0["tel"] as! String)" }
            #expect(out == want, "\(c["name"]!)")
        }
    }

    @Test func journalLabelsCases() {
        for c in cases("journal_labels") {
            let journals: [Journal] = (c["journals"] as! [[String: Any]]).map { decode(json($0)) }
            let out = journalDetailLabels(c["html"] as! String, journals: journals, multiple: Set(c["multiple"] as? [Int] ?? []))
            for (id, want) in c["expected"] as! [String: [[String: Any]]] {
                let got = (out[Int(id)!] ?? []).map { "\($0.old ?? "nil")|\($0.new ?? "nil")" }
                #expect(got == want.map { "\($0["old"] as? String ?? "nil")|\($0["new"] as? String ?? "nil")" }, "\(c["name"]!) #\(id)")
            }
        }
    }

    private func conds(_ a: Any?) -> [FilterCond] {
        (a as! [[String: Any]]).map { FilterCond(field: $0["field"] as! String, op: $0["op"] as! String, values: $0["values"] as! [String]) }
    }
    private func sorts(_ a: Any?) -> [SortCrit] { (a as! [[String]]).map { SortCrit(field: $0[0], dir: $0[1]) } }
    private func pairs(_ p: [(String, String)]) -> [String] { p.map { "\($0.0)=\($0.1)" } }
    private func expected(_ a: Any?) -> [String] { (a as! [[String]]).map { "\($0[0])=\($0[1])" } }

    @Test func filterCatalogCase() {
        let s = section("filter_catalog")
        let out = filterCatalog(s["html"] as! String)
        let want = s["expected"] as! [[String: Any]]
        #expect(out.map(\.field) == want.map { $0["field"] as! String })
        for (o, w) in zip(out, want) {
            #expect(o.name == w["name"] as! String && o.type == w["type"] as! String && o.ops == w["ops"] as! [String], "\(o.field)")
            #expect(o.values == w["values"] as! [[String]] && o.remote == w["remote"] as! Bool, "\(o.field)")
        }
    }

    @Test func filterParamsCases() {
        for c in cases("filter_params") {
            #expect(pairs(filterParams(conds(c["filters"]), sort: sorts(c["sort"]))) == expected(c["expected"]))
        }
    }

    @Test func queryFormCases() {
        for c in cases("query_form") {
            let out = queryFormFields(name: c["name"] as! String, description: c["description"] as! String, visibility: c["visibility"] as! Int,
                                      roleIds: c["role_ids"] as! [Int], forAll: c["for_all"] as! Bool,
                                      filters: conds(c["filters"]), sort: sorts(c["sort"]))
            #expect(pairs(out) == expected(c["expected"]), "\(c["name"]!)")
        }
    }

    @Test func querySavedCases() {
        for c in section("query_saved")["cases"] as! [[Any]] {
            #expect(savedQueryId(c[0] as! String) == c[1] as? Int, "\(c[0])")
        }
    }
}
