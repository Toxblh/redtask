import XCTest

/// Дымовые UI-тесты в демо-режиме (-RTDemo YES, английский): основные экраны открываются и показывают своё.
@MainActor
final class SmokeUITests: XCTestCase {
    private func launch(_ args: String...) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-RTDemo", "YES", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + args
        app.launch()
        return app
    }

    private func tab(_ app: XCUIApplication, _ name: String) {
        let b = app.tabBars.buttons[name].firstMatch
        (b.exists ? b : app.buttons[name].firstMatch).tap()
    }

    /// Пункты открытого контекстного меню сверху вниз.
    private func menuItems(_ app: XCUIApplication, _ expected: [String]) -> [String] {
        XCTAssertTrue(app.buttons[expected[0]].waitForExistence(timeout: 5))
        return expected.filter { app.buttons[$0].exists }
            .sorted { app.buttons[$0].frame.minY < app.buttons[$1].frame.minY }
    }

    func testTabs() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Crash when opening a notification while the app is in the background"].waitForExistence(timeout: 10))
        tab(app, "Watching")
        XCTAssertTrue(app.navigationBars["Watching"].waitForExistence(timeout: 5))
        tab(app, "Favorites")
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 5))
        tab(app, "Projects")
        XCTAssertTrue(app.staticTexts["Mobile App"].waitForExistence(timeout: 5))
        tab(app, "My")
        XCTAssertTrue(app.navigationBars["My Issues"].waitForExistence(timeout: 5))
        // поиск последним: в iOS 26 вкладка поиска сворачивает таб-бар в кнопку
        tab(app, "Search")
        XCTAssertTrue(app.searchFields.firstMatch.waitForExistence(timeout: 5))
    }

    /// Шапка комментария «дата · #N» (spec 1.1) и порядок пунктов меню комментария (spec 1.2).
    func testIssueCommentsAndMenu() {
        let app = launch("-RTIssue", "1240")
        XCTAssertTrue(app.navigationBars["#1240"].waitForExistence(timeout: 10))
        // лента внизу экрана задачи: List ленивый, строки появляются только после прокрутки
        let mine = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Looks like the deep link handler'")).firstMatch
        for _ in 0..<10 where !mine.exists { app.swipeUp() }
        XCTAssertTrue(mine.waitForExistence(timeout: 5), "нет своего комментария")
        let number = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '· #'")).firstMatch
        XCTAssertTrue(number.exists, "нет «дата · #N» в шапке комментария")
        // свой комментарий (автор — демо-пользователь): все пять пунктов + «Выделить текст»
        mine.press(forDuration: 1.2)
        let order = ["Reply with quote", "Copy text", "Copy link to comment", "Edit comment", "Delete", "Select text"]
        XCTAssertEqual(menuItems(app, order), order)
        app.buttons["Select text"].tap()
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 5))
    }

    /// Закрепление проекта свайпом и контекстным меню (spec 2.1).
    func testProjectPins() {
        let app = launch("-RTTab", "projects")
        let row = app.staticTexts["Website"]
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeRight()
        app.buttons["Pin"].tap()
        XCTAssertTrue(app.staticTexts["Pinned"].waitForExistence(timeout: 5))
        app.staticTexts["Infrastructure"].press(forDuration: 1.2)
        app.buttons["Add to Pinned"].tap()
        XCTAssertTrue(app.images["Pinned"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.images.matching(identifier: "Pinned").count, 4) // по 2 строки: в «Закреплённых» и в общем списке
    }

    /// Разделы проекта (spec 2.2): каждый открывается и показывает своё.
    func testProjectSections() {
        let app = launch("-RTTab", "projects", "-RTProject", "1")
        XCTAssertTrue(app.staticTexts["Crash when opening a notification while the app is in the background"].waitForExistence(timeout: 10))
        section(app, "Overview")
        XCTAssertTrue(app.staticTexts["Identifier"].waitForExistence(timeout: 5))
        section(app, "Versions")
        XCTAssertTrue(app.staticTexts["1.5"].waitForExistence(timeout: 5))
        section(app, "Wiki")
        let page = app.cells.staticTexts["Wiki"].firstMatch
        XCTAssertTrue(page.waitForExistence(timeout: 5))
        section(app, "Files")
        XCTAssertTrue(app.cells.firstMatch.waitForExistence(timeout: 5))
    }

    /// Раздел проекта — меню заголовка навбара.
    private func section(_ app: XCUIApplication, _ name: String) {
        projectTitle(app).tap()
        let item = app.buttons[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        item.tap()
    }

    private func projectTitle(_ app: XCUIApplication) -> XCUIElement {
        app.navigationBars.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Mobile App'")).firstMatch
    }

    /// Экран вехи: переключение Список ↔ Доска.
    func testVersionBoardToggle() {
        let app = launch("-RTTab", "projects", "-RTProject", "1", "-RTVersion", "32")
        XCTAssertTrue(app.navigationBars["1.5"].waitForExistence(timeout: 10))
        let board = app.buttons["Board"], list = app.buttons["List"]
        XCTAssertTrue(board.waitForExistence(timeout: 5) || list.exists)
        let toBoard = board.exists
        (toBoard ? board : list).tap()
        XCTAssertTrue((toBoard ? list : board).waitForExistence(timeout: 5))
        (toBoard ? list : board).tap()
        XCTAssertTrue((toBoard ? board : list).waitForExistence(timeout: 5))
    }

    /// Вики: список страниц → страница с текстом.
    func testWikiPage() {
        let app = launch("-RTTab", "projects", "-RTProject", "1")
        XCTAssertTrue(projectTitle(app).waitForExistence(timeout: 10))
        section(app, "Wiki")
        let row = app.cells.staticTexts["Wiki"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "нет страницы в списке вики")
        row.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'version 3'")).firstMatch.waitForExistence(timeout: 5),
                      "страница вики не открылась")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testSettings() {
        let app = launch()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
    }

    func testBell() {
        let app = launch()
        let bell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Notifications'")).firstMatch
        XCTAssertTrue(bell.waitForExistence(timeout: 10))
        bell.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
    }

    /**
     Нажатие на системное уведомление открывает задачу (было падение SIGABRT в didReceive).
     -RTNotify шлёт уведомление о #1240 через 3 с; приложение уходит в фон, Центр уведомлений — свайпом сверху.
     */
    func testNotificationTapOpensIssue() {
        let app = launch("-RTTab", "favorites", "-RTNotify", "1240")
        XCTAssertTrue(app.navigationBars["Favorites"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        sleep(5)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let top = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.001))
        top.press(forDuration: 0.1, thenDragTo: springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.7)))
        // содержимое карточки, а не ячейка целиком: у тихого (provisional) уведомления в ячейке ещё «Продолжать/Выключить»
        let note = springboard.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH 'ShortLook.Platter.Content' AND label CONTAINS '#1240'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 10), "уведомления нет в Центре уведомлений")
        shot(springboard, "центр-уведомлений")
        note.tap()
        // на экране блокировки (Центр уведомлений iOS 26) нажатие лишь выдвигает кнопку «Открыть»
        let open = springboard.buttons.matching(NSPredicate(format: "label IN {'Open', 'Открыть'}")).firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() }
        sleep(2)
        shot(springboard, "после-нажатия")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "приложение не вернулось (упало?)")
        XCTAssertTrue(app.navigationBars["#1240"].waitForExistence(timeout: 10), "задача #1240 не открылась")
    }
}
