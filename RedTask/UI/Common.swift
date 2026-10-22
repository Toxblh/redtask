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

/// Цвет статуса — системные цвета (сами подстраиваются под тёмную тему и повышенный контраст).
func statusTint(_ s: IssueStatus) -> Color {
    switch s.kind {
    case .todo: .gray
    case .inProgress: .blue
    case .done: .green
    case .rejected: .red
    }
}

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

/// Кнопки краёв листа. iOS 26+: круглые ✕ и ✓ (как в системных листах) — заголовок листа не теснят
/// длинные «Отменить»/«Сохранить»; раньше — привычный текст.
struct SheetCancelButton: View {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    var body: some View {
        if #available(iOS 26, *) { Button(role: .cancel, action: action) } else { Button("Cancel", action: action) }
    }
}

struct SheetConfirmButton: View {
    let title: LocalizedStringKey
    var systemImage = "checkmark"
    let action: () -> Void
    init(_ title: LocalizedStringKey, systemImage: String = "checkmark", _ action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.action = action
    }
    var body: some View {
        if #available(iOS 26, *) {
            Button(action: action) { Label(title, systemImage: systemImage) }
                .labelStyle(.iconOnly)
                .buttonStyle(.glassProminent)
        } else {
            Button(title, action: action).fontWeight(.semibold)
        }
    }
}

/// Действие свайпом от края строки.
struct EdgeAction {
    let title: LocalizedStringKey
    let systemImage: String
    let tint: Color
    let action: () -> Void
}

extension View {
    /// Свайп от края строки — действие (как «Ответить» в Telegram); свайп из середины — переключение фильтра.
    func edgeSwipe(leading: EdgeAction?, trailing: EdgeAction?) -> some View {
        modifier(EdgeSwipe(leading: leading, trailing: trailing))
    }

    /// Горизонтальный свайп, начатый не у края: шаг +1 (влево, к следующему) или −1.
    func middleSwipe(_ onSwipe: @escaping (Int) -> Void) -> some View {
        modifier(MiddleSwipe(onSwipe: onSwipe))
    }
}

private struct EdgeSwipe: ViewModifier {
    let leading: EdgeAction?
    let trailing: EdgeAction?
    @State private var offset: CGFloat = 0
    @State private var frame: CGRect = .zero
    private let threshold: CGFloat = 72

    private var current: EdgeAction? { offset > 0 ? leading : offset < 0 ? trailing : nil }

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(offset == 0 ? Color.clear : Color(.systemBackground))
            .offset(x: offset)
            .background {
                if let a = current {
                    let armed = abs(offset) >= threshold
                    Image(systemName: a.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .scaleEffect(armed ? 1.15 : 0.85)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: offset > 0 ? .leading : .trailing)
                        .padding(.horizontal, 20)
                        .background(armed ? a.tint : a.tint.opacity(0.5))
                        .padding(.horizontal, -20).padding(.vertical, -8) // во всю строку, за отступы списка
                        .animation(.snappy, value: armed)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .gesture(EdgePan(frame: frame, leading: leading != nil, trailing: trailing != nil) { dx in
                let was = abs(offset) >= threshold
                offset = dx > 0 ? (leading == nil ? 0 : rubber(dx)) : (trailing == nil ? 0 : -rubber(-dx))
                if was != (abs(offset) >= threshold) { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            } ended: { _ in
                if abs(offset) >= threshold { current?.action() }
                withAnimation(.snappy) { offset = 0 }
            })
            .accessibilityActions {
                if let leading { Button(leading.title, action: leading.action) }
                if let trailing { Button(trailing.title, action: trailing.action) }
            }
    }

    private func rubber(_ x: CGFloat) -> CGFloat { x < threshold ? x : threshold + (x - threshold) * 0.35 }
}

private struct MiddleSwipe: ViewModifier {
    let onSwipe: (Int) -> Void
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .gesture(EdgePan(frame: frame, leading: true, trailing: true, middle: true) { _ in } ended: { dx in
                if abs(dx) > 60 { onSwipe(dx < 0 ? 1 : -1) }
            })
    }
}

/// Горизонтальный пан, начатый у края строки (или, с `middle`, не у края): прокрутка ждёт его отказа, иначе жест её.
private struct EdgePan: UIGestureRecognizerRepresentable {
    let frame: CGRect
    let leading: Bool
    let trailing: Bool
    var middle = false
    let changed: (CGFloat) -> Void
    let ended: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func updateUIGestureRecognizer(_ g: UIPanGestureRecognizer, context: Context) {
        context.coordinator.frame = frame
        context.coordinator.leading = leading
        context.coordinator.trailing = trailing
        context.coordinator.middle = middle
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        switch g.state {
        case .changed: changed(g.translation(in: nil).x)
        case .ended: ended(g.translation(in: nil).x)
        case .cancelled, .failed: ended(0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var frame: CGRect = .zero
        var leading = false
        var trailing = false
        var middle = false
        /// Ширина зоны у края строки, откуда свайп — действие.
        let edge: CGFloat = 36

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return false }
            let v = p.velocity(in: nil), t = p.translation(in: nil)
            guard abs(v.x) > abs(v.y) else { return false }
            let x = p.location(in: nil).x - t.x
            if middle { return abs(v.x) > abs(v.y) * 1.5 && x > frame.minX + edge && x < frame.maxX - edge }
            return (leading && v.x > 0 && x < frame.minX + edge) || (trailing && v.x < 0 && x > frame.maxX - edge)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
    }
}
