import XCTest

/**
 Снимки экранов для сверки с HIG (не проверки): проходит экраны проекта, вехи, вики, файлов, меню комментария,
 «Выделить текст», смену статуса, поиск и колокольчик на английском и русском. Снимки — вложения xcresult.
 tools/build.sh uitest "<назначение>" HIGShots/testRussian
 */
@MainActor
final class HIGShots: XCTestCase {
    private var ru = false
    private func t(_ en: String, _ r: String) -> String { ru ? r : en }

    private func launch(_ args: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-RTDemo", "YES", "-AppleLanguages", ru ? "(ru)" : "(en)", "-AppleLocale", ru ? "ru_RU" : "en_US"] + args
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        sleep(1)
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = (ru ? "ru-" : "en-") + name
        a.lifetime = .keepAlways
        add(a)
    }

    private func tapIfExists(_ e: XCUIElement, timeout: TimeInterval = 5) {
        if e.waitForExistence(timeout: timeout) && e.isHittable { e.tap() }
    }

    func testEnglish() { walk() }
    func testRussian() { ru = true; walk() }

    private func walk() {
        var app = launch("-RTTab", "projects")
        let site = app.staticTexts[t("Website", "Сайт")]
        // iPad в портрете прячет колонку проектов, пока проект не выбран
        if site.waitForExistence(timeout: 10) {
            site.press(forDuration: 1.2)
            shot(app, "01-project-context-menu")
            tapIfExists(app.buttons[t("Add to Pinned", "Добавить в избранные")])
            shot(app, "02-projects-pinned")
        }

        app = launch("-RTTab", "projects", "-RTProject", "1")
        let title = app.navigationBars.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", t("Mobile App", "Мобильное приложение"))).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        sleep(2)
        shot(app, "03-project-issues")
        for (i, s) in [t("Overview", "Обзор"), t("Versions", "Вехи"), t("Wiki", "Вики"), t("Files", "Файлы")].enumerated() {
            title.tap()
            if i == 0 { shot(app, "04-project-title-menu") }
            tapIfExists(app.buttons[s].firstMatch)
            shot(app, "05-project-\(i)-\(s)")
        }
        // вики: страница
        title.tap(); tapIfExists(app.buttons[t("Wiki", "Вики")].firstMatch)
        tapIfExists(app.cells.staticTexts["Wiki"].firstMatch)
        _ = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", t("version 3", "версия 3"))).firstMatch.waitForExistence(timeout: 5)
        shot(app, "06-wiki-page")

        app = launch("-RTTab", "projects", "-RTProject", "1", "-RTVersion", "32")
        XCTAssertTrue(app.navigationBars["1.5"].waitForExistence(timeout: 10))
        shot(app, "07-version")
        let board = app.buttons[t("Board", "Доска")], list = app.buttons[t("List", "Список")]
        tapIfExists(board, timeout: 2)
        shot(app, "08-version-toggled")
        tapIfExists(list, timeout: 2)

        app = launch("-RTIssue", "1240")
        XCTAssertTrue(app.navigationBars["#1240"].waitForExistence(timeout: 10))
        shot(app, "09-issue")
        let status = app.buttons[t("Change status", "Сменить статус")]
        tapIfExists(status)
        shot(app, "10-status-menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)).tap()
        let mine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", t("Looks like the deep link", "Похоже, обработчик"))).firstMatch
        for _ in 0..<10 where !mine.exists { app.swipeUp() }
        shot(app, "11-comments")
        mine.press(forDuration: 1.2)
        shot(app, "12-comment-menu")
        tapIfExists(app.buttons[t("Select text", "Выделить текст")])
        shot(app, "13-select-text")
        tapIfExists(app.buttons.matching(NSPredicate(format: "label IN {'Close', 'Закрыть', 'Done', 'Готово'}")).firstMatch, timeout: 2)
        let changes = app.buttons[t("Changes", "Действия")].firstMatch
        for _ in 0..<10 where !changes.isHittable { app.swipeDown() }
        tapIfExists(changes)
        for _ in 0..<2 { app.swipeUp() }
        shot(app, "14-changes")

        app = launch("-RTTab", "search")
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(t("crash", "падение"))
        sleep(2)
        shot(app, "15-search")

        app = launch("-RTSheet", "bell")
        sleep(3)
        shot(app, "16-bell")
    }
}
