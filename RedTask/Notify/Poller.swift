import Foundation

/// Фоновая проверка — дописывается на этапе уведомлений.
enum Poller {
    static let muteAction = "mute-issue"
    @MainActor static func schedule() {}
    @MainActor static func register() {}
    @MainActor static func foreground() {}
}
