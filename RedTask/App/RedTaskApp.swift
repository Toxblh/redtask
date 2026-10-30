import SwiftUI
import UserNotifications

@main
struct RedTaskApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some Scene {
        WindowGroup {
            Group {
                if app.isLoggedIn { RootView() } else { LoginView() }
            }
            .environment(app)
            .tint(Color("AccentColor"))
            .onOpenURL { app.handle(url: $0) }
            .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { a in
                if let u = a.webpageURL { app.handle(url: u) }
            }
        }
        // фоновая проверка: когда её запустить, решает iOS (честно: не по расписанию)
        .backgroundTask(.appRefresh(Poller.taskId)) { await Poller.poll() }
        .onChange(of: phase) { _, p in
            // возврат в приложение — честная проверка вместо фоновой, которую iOS запускает когда захочет
            if p == .active {
                Poller.foreground()
                Task { await app.refreshFavorites() }
            }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Poller.register()
        return true
    }

    /// Приложение на экране: баннер не нужен — растёт бейдж колокольчика (HIG → Notifications).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.list]
    }

    /// Вариант с completionHandler, а не async: async-вариант система завершает не на главном потоке,
    /// а UIKit при нажатии на уведомление обновляет снимок сцены и падает на проверке главного потока (SIGABRT).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let info = response.notification.request.content.userInfo
        let issueId = info["issueId"] as? Int
        let note = info["note"] as? Int
        let subject = response.notification.request.content.title
        let action = response.actionIdentifier
        Task { @MainActor in
            if let issueId {
                if action == Poller.muteAction {
                    AppModel.shared.settings.mutedIssues[issueId] = subject
                } else {
                    AppModel.shared.open(issueId, fragment: note.map { "change-\($0)" })
                }
            }
            completionHandler()
        }
    }
}
