import SwiftUI
import UIKit
import SafariServices

// MARK: - Форматирование

enum Fmt {
    static func date(_ iso: String?) -> String {
        guard let d = parseRedmineDate(iso) else { return iso ?? "" }
        // дата без времени — день по UTC, иначе на западе часового пояса уехала бы на вчера
        if (iso?.count ?? 0) <= 10 { return d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)) }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    static func dateTime(_ iso: String?) -> String {
        guard let d = parseRedmineDate(iso) else { return iso ?? "" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    /// «5 мин», «3 ч», «2 дн.», дальше двух недель — дата.
    static func relative(_ iso: String?) -> String {
        guard let d = parseRedmineDate(iso) else { return iso ?? "" }
        let s = Date().timeIntervalSince(d)
        if s < 60 { return String(localized: "now") }
        if s > 14 * 86400 { return d.formatted(date: .abbreviated, time: .omitted) }
        let f = DateComponentsFormatter()
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 1
        f.allowedUnits = s < 3600 ? [.minute] : s < 86400 ? [.hour] : [.day]
        return f.string(from: s) ?? ""
    }

    static func hours(_ h: Double?) -> String {
        guard let h else { return "" }
        return h.formatted(.number.precision(.fractionLength(0...2)))
    }

    /// «2026-10-22» в локальном дне.
    static func day(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    static func dayDate(_ s: String?) -> Date? {
        guard let s, s.count >= 10 else { return nil }
        let p = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard p.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: p[0], month: p[1], day: p[2]))
    }

    static func isOverdue(_ due: String?) -> Bool {
        guard let d = dayDate(due) else { return false }
        return d < Calendar.current.startOfDay(for: Date())
    }

    static func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

// MARK: - Картинки

/**
 Аватары и миниатюры: память → диск каталога учётки (24 ч; «нет фото» — 10 минут) → сеть.
 Полноразмерные картинки из текста — только память.
 */
actor ImageStore {
    static let shared = ImageStore()
    private var mem: [String: UIImage] = [:]
    private var order: [String] = []
    private var misses: [String: Date] = [:]
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    private func remember(_ key: String, _ img: UIImage) {
        if mem[key] == nil { order.append(key) }
        mem[key] = img
        // ponytail: простое окно последних 200 картинок, без учёта байт
        if order.count > 200 { mem[order.removeFirst()] = nil }
    }

    func clear() { mem = [:]; order = []; misses = [:] }

    func cached(_ key: String) -> UIImage? { mem[key] }

    private func load(_ key: String, account: String, disk: Bool, _ fetch: @escaping @Sendable () async throws -> Data?) async -> UIImage? {
        if let m = mem[key] { return m }
        if let miss = misses[key], Date().timeIntervalSince(miss) < 600 { return nil }
        if let t = inFlight[key] { return await t.value }
        let file = Files.dir(Files.caches, account, "images").appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"))
        let t = Task<UIImage?, Never> {
            if disk, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let mod = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mod) < 86400,
               let d = try? Data(contentsOf: file), let img = UIImage(data: d) {
                return img
            }
            do {
                guard let d = try await fetch() else { return nil }
                if disk { try? d.write(to: file, options: .atomic) }
                return Self.decode(d)
            } catch { return nil }
        }
        inFlight[key] = t
        let img = await t.value
        inFlight[key] = nil
        if let img { remember(key, img) } else { misses[key] = Date() }
        return img
    }

    /// Большие картинки уменьшаем до 1600 px — фото с телефона в комментарии весит десятки МБ в памяти.
    nonisolated static func decode(_ d: Data) -> UIImage? {
        guard let img = UIImage(data: d) else { return nil }
        let maxSide = max(img.size.width, img.size.height)
        guard maxSide > 1600 else { return img }
        return img.preparingThumbnail(of: CGSize(width: img.size.width * 1600 / maxSide, height: img.size.height * 1600 / maxSide)) ?? img
    }

    func avatar(_ userId: Int, api: RedmineAPI, account: String) async -> UIImage? {
        await load("avatar-\(userId)", account: account, disk: true) { try await api.avatar(userId) }
    }

    func thumbnail(_ attachmentId: Int, api: RedmineAPI, account: String) async -> UIImage? {
        await load("thumb-\(attachmentId)", account: account, disk: true) { try await api.thumbnail(attachmentId, size: 400) }
    }

    func image(_ url: String, api: RedmineAPI, account: String) async -> UIImage? {
        await load("img-\(url.hashValue)", account: account, disk: false) { try await api.download(url) }
    }
}

/// Аватар: фото из профиля People или инициалы на цветном круге.
struct Avatar: View {
    @Environment(AppModel.self) private var app
    let name: String
    let userId: Int?
    var size: CGFloat = 32
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(Self.color(for: userId ?? name.hashValue).gradient)
                Text(Self.initials(name))
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
        .task(id: userId) {
            guard let userId, let api = app.api else { return }
            image = await ImageStore.shared.avatar(userId, api: api, account: app.account)
        }
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(separator: " ").prefix(2)
        let s = parts.compactMap(\.first).map(String.init).joined()
        return s.isEmpty ? "?" : s.uppercased()
    }

    static func color(for seed: Int) -> Color {
        let palette: [Color] = [.red, .orange, .green, .teal, .blue, .indigo, .purple, .pink, .brown, .mint, .cyan]
        return palette[abs(seed) % palette.count]
    }
}

// MARK: - Мелочи

/// Нет данных и сбой — системными ContentUnavailableView.
struct LoadErrorView: View {
    let message: String
    var retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Couldn’t load", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        } actions: {
            Button("Retry", action: retry).buttonStyle(.borderedProminent)
            CaptchaButton(onSolved: retry)
        }
    }
}

extension View {
    /// Ошибка действия — системный alert (HIG: ошибка — не уведомление).
    func errorAlert(_ error: Binding<String?>) -> some View {
        alert("Something went wrong", isPresented: Binding(get: { error.wrappedValue != nil }, set: { if !$0 { error.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(error.wrappedValue ?? "")
        }
    }
}

/// Цвет статуса: закрытые приглушены, остальное — акцент.
func statusTint(_ s: IssueStatus) -> Color { s.isClosed ? .secondary : .accentColor }

/// Копирование в буфер с тактильным откликом.
@MainActor func copyToPasteboard(_ s: String) {
    UIPasteboard.general.string = s
    UINotificationFeedbackGenerator().notificationOccurred(.success)
}

/// Подпись типа связи глазами задачи.
func relationLabel(_ type: String) -> String {
    switch type {
    case "relates": String(localized: "Related to")
    case "duplicates": String(localized: "Duplicates")
    case "duplicated": String(localized: "Duplicated by")
    case "blocks": String(localized: "Blocks")
    case "blocked": String(localized: "Blocked by")
    case "precedes": String(localized: "Precedes")
    case "follows": String(localized: "Follows")
    case "copied_to": String(localized: "Copied to")
    case "copied_from": String(localized: "Copied from")
    default: type
    }
}

/// Веб-версия внутри приложения (запасной путь, когда REST не разрешает действие).
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
