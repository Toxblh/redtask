// Poller — только в приложении (не в пакете RedTaskCore): тесты идут в tools/build.sh test.
#if !canImport(RedTaskCore)
import Foundation
import Intents
import Testing
@testable import RedTask

@Suite("Аватар автора в уведомлении (spec 4.2)")
@MainActor
struct NotifAvatarTests {
    @Test func intentCarriesSenderAvatarAndIssueAsGroup() {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let i = Poller.messageIntent(title: "#1240 Crash", body: "Anna: fixed", author: "Anna", userId: 5, issueId: 1240, avatar: png)
        #expect(i.sender?.displayName == "Anna")
        #expect(i.sender?.customIdentifier == "user-5")
        #expect(i.sender?.image != nil)
        // заголовок уведомления остаётся «#номер тема» — это имя группы
        #expect(i.speakableGroupName?.spokenPhrase == "#1240 Crash")
        #expect(i.recipients?.count == 2)
        #expect(i.conversationIdentifier == "issue-1240")
        #expect(i.content == "Anna: fixed")
    }

    @Test func budgetCutsSlowWork() async {
        let soon = ContinuousClock.now + .milliseconds(200)
        let slow: Int? = await Poller.before(soon) { try? await Task.sleep(for: .seconds(5)); return 1 }
        #expect(slow == nil)
        let fast: Int? = await Poller.before(ContinuousClock.now + .seconds(5)) { 2 }
        #expect(fast == 2)
        // бюджет общий: истёкший срок — сразу nil
        let late: Int? = await Poller.before(ContinuousClock.now - .seconds(1)) { try? await Task.sleep(for: .seconds(1)); return 3 }
        #expect(late == nil)
    }
}
#endif
