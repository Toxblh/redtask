import SwiftUI
import UserNotifications

/// Колокольчик: история уведомлений — лента или «по задачам» внутри дня, фильтр по группам, непрочитанное.
struct NotificationsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [NotifEntry] = []
    @State private var unread = Set<String>()
    @State private var group: NotifGroup?
    @State private var loading = true

    private var shown: [NotifEntry] {
        guard let group else { return entries }
        return entries.filter { e in e.types.contains { NotifCategory.of($0).group == group } }
    }

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            List {
                if app.settings.notifByIssue {
                    ForEach(groupByIssue(shown)) { day in
                        Section(dayTitle(day.date)) {
                            ForEach(day.groups) { g in
                                Button { open(g.issueId, g.journalId) } label: { IssueGroupRow(group: g, unread: g.unread(unread)) }
                                    .buttonStyle(.plain)
                                    .contextMenu { muteMenu(g.latest) }
                            }
                        }
                    }
                } else {
                    ForEach(days(shown), id: \.0) { day, list in
                        Section(dayTitle(day)) {
                            ForEach(list) { e in
                                Button { open(e.issueId, e.journalId) } label: { NotifRow(entry: e, unread: unread.contains(e.key)) }
                                    .buttonStyle(.plain)
                                    .contextMenu { muteMenu(e) }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if shown.isEmpty {
                    if loading { ProgressView() } else { ContentUnavailableView("No notifications yet", systemImage: "bell") }
                }
            }
            .refreshable {
                await Poller.poll()
                await reload(markRead: false)
            }
            .navigationTitle("Notifications")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { SheetConfirmButton("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("View", selection: $app.settings.notifByIssue) {
                            Label("Feed", systemImage: "list.bullet").tag(false)
                            Label("By issue", systemImage: "square.stack").tag(true)
                        }
                        Picker("Show", selection: $group) {
                            Text("All").tag(NotifGroup?.none)
                            ForEach(NotifGroup.allCases, id: \.self) { Text($0.title).tag(Optional($0)) }
                        }
                    } label: {
                        Label("View options", systemImage: group == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
        }
        .task {
            await reload(markRead: true)
            if await NotifStore.shared.needsBackfill() {
                await Poller.backfill()
                await reload(markRead: false)
            }
        }
    }

    /// Открытие колокольчика помечает всё прочитанным; подсветка «новое» остаётся до закрытия.
    private func reload(markRead: Bool) async {
        entries = await NotifStore.shared.load()
        if markRead { unread.formUnion(await NotifStore.shared.takeUnread()) }
        loading = false
        await app.refreshUnread()
    }

    private func open(_ issueId: Int, _ note: Int?) {
        dismiss()
        app.open(issueId, note: note)
    }

    @ViewBuilder
    private func muteMenu(_ e: NotifEntry) -> some View {
        let mutedIssue = app.settings.mutedIssues[e.issueId] != nil
        Button {
            if mutedIssue { app.settings.mutedIssues[e.issueId] = nil } else { app.settings.mutedIssues[e.issueId] = e.subject }
        } label: {
            Label(mutedIssue ? "Notify about this issue" : "Mute this issue", systemImage: mutedIssue ? "bell" : "bell.slash")
        }
        if let p = e.projectId {
            let mutedProject = app.settings.mutedProjects[p] != nil
            Button {
                if mutedProject { app.settings.mutedProjects[p] = nil } else { app.settings.mutedProjects[p] = e.project }
            } label: {
                Label(mutedProject ? "Notify about this project" : "Mute this project", systemImage: mutedProject ? "bell" : "bell.slash")
            }
        }
        if let api = app.api {
            Button { copyToPasteboard(api.issueWebURL(e.issueId).absoluteString) } label: { Label("Copy link", systemImage: "link") }
        }
    }

    private func days(_ list: [NotifEntry]) -> [(Date, [NotifEntry])] {
        var out: [(Date, [NotifEntry])] = []
        for e in list.sorted(by: { $0.at > $1.at }) {
            let d = Calendar.current.startOfDay(for: e.date)
            if out.last?.0 == d { out[out.count - 1].1.append(e) } else { out.append((d, [e])) }
        }
        return out
    }

    private func dayTitle(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return String(localized: "Today") }
        if Calendar.current.isDateInYesterday(d) { return String(localized: "Yesterday") }
        return d.formatted(date: .complete, time: .omitted)
    }
}

private struct NotifRow: View {
    @Environment(AppModel.self) private var app
    let entry: NotifEntry
    let unread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                if let id = entry.avatarUserId { Avatar(name: entry.authorName, userId: id, size: 36) }
                else { Image(systemName: NotifCategory.of(entry.type).symbol).font(.title3).frame(width: 36, height: 36).foregroundStyle(.secondary) }
                Image(systemName: NotifCategory.of(entry.type).symbol)
                    .font(.caption2)
                    .padding(3)
                    .background(.background, in: Circle())
                    .opacity(entry.avatarUserId == nil ? 0 : 1)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(verbatim: "#\(entry.issueId)").monospacedDigit()
                    Text(entry.project).lineLimit(1)
                    Spacer()
                    Text(entry.date, format: .dateTime.hour().minute())
                }
                .font(.caption).foregroundStyle(.secondary)
                Text(entry.subject).font(.subheadline.weight(unread ? .bold : .semibold)).lineLimit(2)
                ForEach(entry.lines, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary).lineLimit(4) }
                if !app.settings.notifies(entry) {
                    Label("Muted", systemImage: "bell.slash").font(.caption).foregroundStyle(.tertiary)
                }
            }
            if unread {
                Circle().fill(.tint).frame(width: 8, height: 8).padding(.top, 6)
                    .accessibilityLabel("New")
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension NotifEntry {
    var authorName: String { author.isEmpty ? (lines.first?.components(separatedBy: ":").first ?? "?") : author }
}

private struct IssueGroupRow: View {
    let group: NotifIssueGroup
    let unread: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(verbatim: "#\(group.issueId)").monospacedDigit()
                Text(group.latest.project).lineLimit(1)
                Spacer()
                Text(group.latest.date, format: .dateTime.hour().minute())
            }
            .font(.caption).foregroundStyle(.secondary)
            Text(group.latest.subject).font(.subheadline.weight(unread ? .bold : .semibold)).lineLimit(2)
            HStack(spacing: 6) {
                ForEach(group.types.prefix(6), id: \.self) { t in
                    Image(systemName: NotifCategory.of(t).symbol).accessibilityLabel(NotifCategory.of(t).title)
                }
                Text("\(group.entries.count) events").font(.caption)
                Spacer()
                HStack(spacing: -8) {
                    ForEach(group.people.prefix(4)) { p in Avatar(name: p.authorName, userId: p.avatarUserId, size: 24) }
                }
            }
            .foregroundStyle(.secondary)
            Text(group.latest.lines.first ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Настройки

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var confirmSignOut = false

    var body: some View {
        @Bindable var app = app
        NavigationStack {
            Form {
                if app.isDemo {
                    Section {
                        Label("Demo mode: made-up data on this device only, nothing is sent anywhere. Changes are lost when the app restarts. Sign out to return to the sign-in screen.", systemImage: "theatermasks")
                            .font(.footnote)
                    } header: { Text("Demo") }
                }
                Section("Account") {
                    HStack(spacing: 12) {
                        Avatar(name: app.settings.userName, userId: app.settings.userId, size: 44)
                        VStack(alignment: .leading) {
                            Text(app.settings.userName).font(.headline)
                            Text(verbatim: "@\(app.settings.userLogin)").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Server", value: URL(string: app.settings.serverURL)?.host ?? app.settings.serverURL)
                }
                Section {
                    Toggle("Notifications", isOn: $app.settings.notificationsEnabled)
                        .onChange(of: app.settings.notificationsEnabled) { Poller.schedule() }
                    NavigationLink("Categories and filters") { NotifSettingsView() }
                    LabeledContent("Last check", value: app.settings.lastCheck.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? String(localized: "never"))
                    Button("Check now") { Task { await Poller.poll() } }
                    SystemPermissionRow()
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("iOS decides when to run background checks — usually not more often than every 15 minutes, and less often if you rarely open the app. RedTask also checks every time you return to it.")
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                    if !app.isDemo { Button("Open Redmine in Safari") { if let u = app.api?.baseURL { openURL(u) } } }
                }
                Section {
                    Button("Sign Out", role: .destructive) { confirmSignOut = true }
                } footer: {
                    if !app.isDemo { Text("Signing out removes the API key from the Keychain and clears cached issues on this device.") }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { SheetConfirmButton("Done") { dismiss() } } }
            .confirmationDialog("Sign out?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { dismiss(); app.logout() }
            }
        }
    }
}

/// Состояние системного разрешения: тихие уведомления можно сделать обычными; отказ — ссылка в Настройки.
private struct SystemPermissionRow: View {
    @Environment(\.openURL) private var openURL
    @State private var status: UNAuthorizationStatus?

    var body: some View {
        Group {
            switch status {
            case .provisional, .notDetermined:
                Button("Show notifications as banners") {
                    Task {
                        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                        await refresh()
                    }
                }
            case .denied:
                Button("Notifications are off — open Settings") {
                    if let u = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(u) }
                }
            default:
                Button("Sound and alerts in Settings") {
                    if let u = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(u) }
                }
            }
        }
        .task { await refresh() }
    }

    private func refresh() async { status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus }
}

/// Категории (по группам), источники, подопции, отключённые задачи и проекты.
struct NotifSettingsView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        Form {
            Section {
                flag("Assigned to me", .scopeAssigned)
                flag("Created by me", .scopeAuthored)
                flag("Watched", .scopeWatched)
                flag("Favorites only", .favoritesOnly, hint: "Of the sources above, only issues marked with a star")
            } header: {
                Text("Which issues")
            } footer: {
                Text("A disabled source isn’t checked at all — its events won’t appear in the history either.")
            }
            ForEach(NotifGroup.allCases, id: \.self) { g in
                Section(g.title) {
                    ForEach(NotifCategory.allCases.filter { $0.group == g }, id: \.self) { c in
                        Toggle(isOn: Binding(get: { !app.settings.notifMuted.contains(c.rawValue) },
                                             set: { on in if on { app.settings.notifMuted.remove(c.rawValue) } else { app.settings.notifMuted.insert(c.rawValue) } })) {
                            Label {
                                VStack(alignment: .leading) {
                                    Text(c.title)
                                    if let h = hint(c) { Text(h).font(.caption).foregroundStyle(.secondary) }
                                }
                            } icon: { Image(systemName: c.symbol) }
                        }
                        if c == .status && !app.settings.notifMuted.contains(c.rawValue) { flag("Only closing or resolving", .statusClosedOnly) }
                        if c == .priority && !app.settings.notifMuted.contains(c.rawValue) { flag("Only raising", .priorityRaisedOnly) }
                    }
                }
            }
            Section {
                if app.settings.mutedIssues.isEmpty && app.settings.mutedProjects.isEmpty {
                    Text("Empty. Mute an issue from its notification or menu, or an issue or project with a long press in the notification history.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(app.settings.mutedIssues.sorted(by: { $0.key > $1.key }), id: \.key) { id, subject in
                    LabeledContent { Button("Unmute") { app.settings.mutedIssues[id] = nil } } label: {
                        Label("#\(id) \(subject)", systemImage: "checklist")
                    }
                }
                ForEach(app.settings.mutedProjects.sorted(by: { $0.value < $1.value }), id: \.key) { id, name in
                    LabeledContent { Button("Unmute") { app.settings.mutedProjects[id] = nil } } label: {
                        Label(name, systemImage: "folder")
                    }
                }
            } header: {
                Text("Muted issues and projects")
            }
            Section {
                Text("A disabled category doesn’t notify but stays in the bell history. Not collected at all (and not in the history): “New issue in my projects” and “Mentions” outside my issues while those categories are off, and issues from sources disabled above. There are no quiet hours in the app — use Focus.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notification settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func hint(_ c: NotifCategory) -> String? {
        switch c {
        case .mention: String(localized: "Comments with my login in any issue I can see. Mentions in issue descriptions aren’t tracked.")
        case .dueSoon: String(localized: "For issues assigned to me; one reminder per due date")
        case .newIssue: String(localized: "Other people’s new issues in projects I’m a member of. While off, the server isn’t asked at all.")
        default: nil
        }
    }

    private func flag(_ title: LocalizedStringKey, _ f: NotifFlag, hint: LocalizedStringKey? = nil) -> some View {
        Toggle(isOn: Binding(get: { app.settings.notifFlags.contains(f) },
                             set: { on in if on { app.settings.notifFlags.insert(f) } else { app.settings.notifFlags.remove(f) } })) {
            VStack(alignment: .leading) {
                Text(title)
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}
