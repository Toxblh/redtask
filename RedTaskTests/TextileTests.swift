import Foundation
import Testing
#if canImport(RedTaskCore)
@testable import RedTaskCore
#else
@testable import RedTask
#endif

@Suite("Textile: блоки")
struct TextileBlockTests {
    @Test func headingsNeedDot() {
        #expect(parseTextile("h3. Заголовок") == [.heading(3, "Заголовок")])
        #expect(parseTextile("h264 codec") == [.plain("h264 codec")])
    }

    @Test func numberedListCountsPerLevelAndRestartsAfterBlank() {
        let lines = parseTextile("# один\n# два\n## вложенный\n# три\n\n# снова")
        #expect(lines == [
            .item(depth: 0, number: 1, text: "один"), .item(depth: 0, number: 2, text: "два"),
            .item(depth: 1, number: 1, text: "вложенный"), .item(depth: 0, number: 3, text: "три"),
            .plain(""), .item(depth: 0, number: 1, text: "снова"),
        ])
    }

    @Test func dashAndOneDotAreNotLists() {
        #expect(parseTextile("- пункт") == [.plain("- пункт")])
        #expect(parseTextile("1. пункт") == [.plain("1. пункт")])
    }

    @Test func nestedQuotes() {
        let lines = parseTextile("> Иван писал:\n> > исходник\n> ответ")
        #expect(lines == [.quote([.plain("Иван писал:"), .quote([.plain("исходник")]), .plain("ответ")])])
    }

    @Test func bqParagraphEndsAtBlankLine() {
        #expect(parseTextile("bq. цитата\nпродолжение\n\nтекст") == [.quote([.plain("цитата"), .plain("продолжение")]), .plain(""), .plain("текст")])
    }

    @Test func quoteDepthIsCapped() {
        let deep = String(repeating: ">", count: 50) + " x"
        var lines = parseTextile(deep)
        var depth = 0
        while case .quote(let inner)? = lines.first { depth += 1; lines = inner }
        #expect(depth <= Textile.maxQuoteDepth + 1)
    }

    @Test func preAndFenceAreCode() {
        #expect(parseTextile("<pre><code class=\"ruby\">a = 1\n*b*</code></pre>") == [.code("a = 1"), .code("*b*")])
        #expect(parseTextile("```\nx\n```") == [.code("x")])
    }

    @Test func tableCellsWithHeaderAndSpan() {
        #expect(parseTextile("|_. Имя |\\2. Широкая |") == [.row([TCell(text: "Имя", header: true), TCell(text: "Широкая", span: 2)])])
    }

    @Test func imageMacroSplitsParagraph() {
        #expect(parseTextile("до !screen.png! после") == [.plain("до"), .image("screen.png"), .plain("после")])
        #expect(parseTextile("Wow! Really!") == [.plain("Wow! Really!")])
    }

    @Test func collapseNeedsClosing() {
        #expect(parseTextile("{{collapse(Подробно)\nтекст\n}}") == [.collapse("Подробно", [.plain("текст")])])
        #expect(parseTextile("{{collapse\nбез конца") == [.plain("{{collapse"), .plain("без конца")])
    }

    @Test func entitiesAndNotextileAreInert() {
        #expect(parseTextile("&gt; не цитата").map { if case .plain(let s) = $0 { unraw(s) } else { "" } } == ["> не цитата"])
        let inline = parseInline(parseTextile("<notextile>*не жирный*</notextile>").first.map { if case .plain(let s) = $0 { s } else { "" } } ?? "")
        #expect(inline == [.text("*не жирный*")])
    }

    @Test func groupBlocksMarksParagraphGaps() {
        let b = groupBlocks(parseTextile("раз\nдва\n\nтри"))
        #expect(b.count == 2)
        #expect(b[0].lines.count == 2 && !b[0].gap)
        #expect(b[1].gap)
    }
}

@Suite("Textile: инлайн")
struct TextileInlineTests {
    @Test func boldItalicOnlyAtWordBoundaries() {
        #expect(parseInline("*жирный* и _курсив_") == [.styled(.bold, [.text("жирный")]), .text(" и "), .styled(.italic, [.text("курсив")])])
        #expect(parseInline("my_var_name и 2 * 3 * 4") == [.text("my_var_name и 2 * 3 * 4")])
    }

    @Test func strikeIgnoresHyphenatedWordsAndDates() {
        #expect(parseInline("well-known 2020-01-01 --force") == [.text("well-known 2020-01-01 --force")])
        #expect(parseInline("-удалено-") == [.styled(.strike, [.text("удалено")])])
    }

    @Test func plusIsNotUnderlineInMath() {
        #expect(parseInline("C++ и 2 + 3 + 4") == [.text("C++ и 2 + 3 + 4")])
    }

    @Test func issueAndNoteRefs() {
        #expect(parseInline("см. #123") == [.text("см. "), .issue(text: "#123", id: 123, note: nil)])
        #expect(parseInline("#123#note-5") == [.issue(text: "#123#note-5", id: 123, note: 5)])
        #expect(parseInline("#note-2") == [.note(text: "#note-2", number: 2)])
        #expect(parseInline("a#1 #12abc") == [.text("a#1 #12abc")])
    }

    @Test func mentionsResolveOnlyWhenKnown() {
        let m = ["ivanov": (7, "Иван Иванов")]
        #expect(parseInline("привет @ivanov.", mentions: m) == [.text("привет "), .mention(id: 7, name: "Иван Иванов"), .text(".")])
        #expect(parseInline("почта a@ivanov.ru", mentions: m) == [.text("почта a@ivanov.ru")])
        #expect(mentionLogins("@a, @B и @code@") == ["a", "b"])
    }

    @Test func linksTrimTrailingPunctuation() {
        #expect(parseInline("см. https://example.org/a_(b)).") == [.text("см. "), .link(text: "https://example.org/a_(b)", url: "https://example.org/a_(b)"), .text(").")])
        #expect(parseInline("\"сайт\":https://x.org/") == [.link(text: "сайт", url: "https://x.org/")])
        #expect(parseInline("\"профиль\":/people/107") == [.link(text: "профиль", url: "/people/107")])
    }

    @Test func urlWithUnderscoresStaysWhole() {
        #expect(parseInline("_см https://x.org/a_b_") == [.text("_см "), .link(text: "https://x.org/a_b_", url: "https://x.org/a_b_")])
    }

    @Test func inlineCode() {
        #expect(parseInline("код @x = 1@ и `y`") == [.text("код "), .code("x = 1"), .text(" и "), .code("y")])
    }

    @Test func longLineSkipsMarkup() {
        let s = String(repeating: "*a* ", count: 6000)
        #expect(parseInline(s) == [.text(s)])
    }

    @Test func notePreviewStripsMarkup() {
        #expect(notePreview("bq. *Важно*: !shot.png! \"тут\":http://x") == "Важно: shot.png тут")
    }
}

@Suite("Редактор")
struct TextileEditTests {
    @Test func wrapSelection() {
        let (t, sel) = TextileEdit.wrap("abc", 1..<2, "*", "*")
        #expect(t == "a*b*c" && sel == 2..<3)
    }

    @Test func prefixEveryLine() {
        let (t, _) = TextileEdit.prefixLines("раз\nдва", 0..<7, "* ")
        #expect(t == "* раз\n* два")
    }

    @Test func listContinuesAndEnds() {
        let r = TextileEdit.continueList("* пункт\n", cursor: 8)
        #expect(r?.0 == "* пункт\n* " && r?.1 == 10)
        let end = TextileEdit.continueList("* пункт\n* \n", cursor: 11)
        #expect(end?.0 == "* пункт\n")
        #expect(TextileEdit.continueList("текст\n", cursor: 6) == nil)
    }
}

@Suite("Textile: таблицы")
struct TableCellTests {
    @Test func headerWithoutSpace() {
        // RedCloth не требует пробела после «.»: так пишут шаблоны полей на сервере
        let c = parseCells("|_.Статья |_.б/н | 7700.00 |")
        #expect(c.map(\.header) == [true, true, false])
        #expect(c.map(\.text) == ["Статья", "б/н", "7700.00"])
    }

    @Test func plainTextAsShown() {
        #expect(plainText("h2. Шаги\n\n# *раз* @код@\n# [[Вики|два]]\n\n> цитата\n!a.png!") == "Шаги\n\n1. раз код\n2. два\n\nцитата")
    }
}
