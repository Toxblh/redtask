import SwiftUI
import UIKit
import SafariServices
import QuickLook

// MARK: - Форматирование

enum Fmt {
    static func date(_ iso: String?) -> String {
        guard let d = parseRedmineDate(iso) else { return iso ?? "" }
        // дата без времени — день по UTC, иначе на западе часового пояса уехала бы на вчера
        if (iso?.count ?? 0) <= 10 { return d.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: .gmt)) }
        return d.formatted(date: .abbreviated, time: .omitted)
    }

    /// «22 окт» — без года в текущем году и без точки сокращения: для тесных строк списка.
    static func shortDate(_ iso: String?) -> String {
        guard let d = dayDate(iso), Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year) else { return date(iso) }
        let s = d.formatted(.dateTime.day().month(.abbreviated))
        return s.hasSuffix(".") ? String(s.dropLast()) : s
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
    private var inFlight: [String: Task<(UIImage?, final: Bool), Never>] = [:]

    private func remember(_ key: String, _ img: UIImage) {
        if mem[key] == nil { order.append(key) }
        mem[key] = img
        // ponytail: простое окно последних 200 картинок, без учёта байт
        if order.count > 200 { mem[order.removeFirst()] = nil }
    }

    func clear() { mem = [:]; order = []; misses = [:] }

    func cached(_ key: String) -> UIImage? { mem[key] }
    #if DEBUG
    /// Подложить аватар (в демо их нет): -RTNotify показывает Communication Notification с картинкой.
    func seedAvatar(_ userId: Int, _ img: UIImage) { remember("avatar-\(userId)", img) }
    #endif

    /// sticky: определённое «нет» (404, нет миниатюры) не переспрашиваем до перезапуска; сбой — через 10 минут.
    private func load(_ key: String, account: String, disk: Bool, sticky: Bool = false, _ fetch: @escaping @Sendable () async throws -> Data?) async -> UIImage? {
        if let m = mem[key] { return m }
        if let miss = misses[key], Date().timeIntervalSince(miss) < 600 { return nil }
        if let t = inFlight[key] { return await t.value.0 }
        let file = Files.dir(Files.caches, account, "images").appendingPathComponent(key.replacingOccurrences(of: "/", with: "_"))
        let t = Task<(UIImage?, final: Bool), Never> {
            if disk, let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
               let mod = attrs[.modificationDate] as? Date, Date().timeIntervalSince(mod) < 86400,
               let d = try? Data(contentsOf: file), let img = UIImage(data: d) {
                return (img, true)
            }
            do {
                guard let d = try await fetch() else { return (nil, true) }
                if disk { try? d.write(to: file, options: .atomic) }
                return (Self.decode(d), true)
            } catch { return (nil, false) }
        }
        inFlight[key] = t
        let (img, final) = await t.value
        inFlight[key] = nil
        if let img { remember(key, img) } else { misses[key] = sticky && final ? .distantFuture : Date() }
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
        await load("thumb-\(attachmentId)", account: account, disk: true, sticky: true) { try await api.thumbnail(attachmentId, size: 200) }
    }

    /// Миниатюра, встроенная в скачанный ODF/OOXML; извлечённая лежит рядом с файлом (.thumbnail).
    func embedded(_ file: URL, id: Int, account: String) async -> UIImage? {
        await load("embedded-\(id)", account: account, disk: false, sticky: true) {
            let side = file.deletingLastPathComponent().appending(path: ".thumbnail")
            if let d = try? Data(contentsOf: side) { return d }
            guard let d = try embeddedThumbnail(Data(contentsOf: file, options: .mappedIfSafe)) else { return nil }
            try? d.write(to: side, options: .atomic)
            return d
        }
    }

    /// Встроенная миниатюра ещё не скачанного документа (spec 4.1). Итог — миниатюра или отметка «нет» — навсегда
    /// рядом с местом файла (каталог вложения, чистится при выходе). Не больше двух запросов сразу; вызывается из
    /// .task строки — ушла с экрана, запрос отменяется.
    func remoteEmbedded(_ a: Attachment, api: RedmineAPI, account: String) async -> UIImage? {
        let key = "embedded-\(a.id)"
        if let m = mem[key] { return m }
        let file = Files.attachment(a, account: account), dir = file.deletingLastPathComponent()
        let thumb = dir.appending(path: ".thumbnail"), none = dir.appending(path: ".nothumb")
        if FileManager.default.fileExists(atPath: none.path) { return nil }
        if let d = try? Data(contentsOf: thumb), let img = UIImage(data: d) { remember(key, img); return img }
        await Self.gate.wait()
        defer { Task { await Self.gate.signal() } }
        // сбой или отмена — без отметки, спросим при следующем показе; честное «нет» — отметкой
        let d: Data?
        do { d = try await api.remoteEmbeddedThumbnail(a, saveTo: file) } catch { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let d, let img = UIImage(data: d) else { try? Data().write(to: none); return nil }
        try? d.write(to: thumb, options: .atomic)
        remember(key, img)
        return img
    }

    private static let gate = Gate(2)

    func image(_ url: String, api: RedmineAPI, account: String) async -> UIImage? {
        await load("img-\(url.hashValue)", account: account, disk: false) { try await api.download(url) }
    }
}

/// Не больше n одновременно. ponytail: отменённый в очереди всё равно дожидается места и сразу его отдаёт.
actor Gate {
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { free = n }
    func wait() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func signal() { if waiting.isEmpty { free += 1 } else { waiting.removeFirst().resume() } }
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

/// Цветная точка статуса для меню и пикеров (spec 0): в системное меню цвет SwiftUI не доходит — картинка alwaysOriginal.
func statusDot(_ s: IssueStatus) -> Image {
    Image(uiImage: UIImage(systemName: "circle.fill")!.withTintColor(UIColor(statusTint(s)), renderingMode: .alwaysOriginal))
}

/// Пункт меню или пикера статуса: точка цвета + название.
func statusLabel(_ s: IssueStatus) -> some View { Label { Text(s.name) } icon: { statusDot(s) } }

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

/// Лист только для просмотра (колокольчик, настройки, профиль, выделение текста): «Закрыть», а не одинокое «Готово» —
/// HIG Sheets (март 2026): Done всегда в паре с Cancel; Toolbars: стандартная кнопка Close у модального окна.
struct SheetCloseButton: View {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    var body: some View {
        if #available(iOS 26, *) { Button(role: .close, action: action) } else { Button("Done", action: action) }
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
    /// Свайп от края строки открывает кнопку действия (как в Telegram), длинный свайп — сразу выполняет.
    /// Одновременно открыта одна строка: `open` — её id. Отступы строки задаёт сам модификатор.
    func edgeSwipe(id: Int, open: Binding<Int?>, leading: EdgeAction?, trailing: EdgeAction?) -> some View {
        modifier(EdgeSwipe(id: id, open: open, leading: leading, trailing: trailing))
    }

    /// Горизонтальный пан не от края: сдвиг за пальцем и конец жеста (сдвиг, скорость).
    func middleSwipe(changed: @escaping (CGFloat) -> Void, ended: @escaping (CGFloat, CGFloat) -> Void) -> some View {
        modifier(MiddleSwipe(changed: changed, ended: ended))
    }
}

private struct EdgeSwipe: ViewModifier {
    let id: Int
    @Binding var open: Int?
    let leading: EdgeAction?
    let trailing: EdgeAction?
    @State private var offset: CGFloat = 0
    /// Сдвиг в начале жеста: открытая строка тянется от своей открытой позиции.
    @State private var base: CGFloat = 0
    @State private var frame: CGRect = .zero

    /// Ширина открытой кнопки — слот Telegram (60) с полями.
    private let slot: CGFloat = 76
    /// Дальше этого сдвига отпускание выполняет действие сразу.
    private var full: CGFloat { max(slot * 2.2, frame.width * 0.5) }
    private var current: EdgeAction? { offset > 0 ? leading : offset < 0 ? trailing : nil }

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if offset != 0 { Color(.secondarySystemBackground) }
            }
            .clipShape(RoundedRectangle(cornerRadius: offset == 0 ? 0 : 22, style: .continuous))
            .overlay {
                // открытая строка: тап по ней закрывает кнопки, а не открывает задачу
                if open == id && offset != 0 {
                    Color.clear.contentShape(Rectangle()).onTapGesture { close() }
                }
            }
            .offset(x: offset)
            .background { if let a = current { button(a) } }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .gesture(EdgePan(frame: frame, leading: leading != nil, trailing: trailing != nil, anywhere: offset != 0) { dx in
                if base == 0 && offset != 0 { base = offset }
                let was = abs(offset) >= full
                let x = base + dx
                offset = x > 0 ? (leading == nil ? 0 : x) : (trailing == nil ? 0 : x)
                if was != (abs(offset) >= full) { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            } ended: { _, vx in
                settle(vx)
            })
            .onChange(of: open) { if open != id && offset != 0 { withAnimation(.snappy) { offset = 0 } } }
            .accessibilityActions {
                if let leading { Button(leading.title, action: leading.action) }
                if let trailing { Button(trailing.title, action: trailing.action) }
            }
    }

    /// Кнопка-круг с подписью; при длинном свайпе едет за строкой.
    private func button(_ a: EdgeAction) -> some View {
        let progress = min(1, abs(offset) / slot)
        let armed = abs(offset) >= full
        return Button {
            a.action()
            close()
        } label: {
            VStack(spacing: 5) {
                Image(systemName: a.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
                    .background(a.tint, in: Circle())
                    .scaleEffect(armed ? 1.1 : 0.6 + 0.4 * progress)
                Text(a.title).font(.caption2.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
            }
            .opacity(progress)
            .frame(width: max(slot, abs(offset)), alignment: armed ? (offset > 0 ? .trailing : .leading) : .center)
            .animation(.snappy, value: armed)
        }
        .buttonStyle(.borderless)
        .accessibilityHidden(true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: offset > 0 ? .leading : .trailing)
    }

    private func settle(_ vx: CGFloat) {
        let x = offset
        base = 0
        if abs(x) >= full {
            current?.action()
            close()
        } else if (x > slot / 2 || (x > 0 && vx > 300)) && !(vx < -300) {
            withAnimation(.snappy) { offset = slot }
            open = id
        } else if (x < -slot / 2 || (x < 0 && vx < -300)) && !(vx > 300) {
            withAnimation(.snappy) { offset = -slot }
            open = id
        } else {
            close()
        }
    }

    private func close() {
        withAnimation(.snappy) { offset = 0 }
        base = 0
        if open == id { open = nil }
    }
}

private struct MiddleSwipe: ViewModifier {
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void
    @State private var frame: CGRect = .zero

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .gesture(EdgePan(frame: frame, leading: true, trailing: true, middle: true, changed: changed, ended: ended))
    }
}

/// Горизонтальный пан: у края строки (`middle` — наоборот, не у края; `anywhere` — где угодно).
/// Прокрутка ждёт его отказа: вертикальный жест он отдаёт сразу.
private struct EdgePan: UIGestureRecognizerRepresentable {
    let frame: CGRect
    let leading: Bool
    let trailing: Bool
    var middle = false
    var anywhere = false
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let g = UIPanGestureRecognizer()
        g.delegate = context.coordinator
        return g
    }

    func updateUIGestureRecognizer(_ g: UIPanGestureRecognizer, context: Context) {
        let c = context.coordinator
        c.frame = frame; c.leading = leading; c.trailing = trailing; c.middle = middle; c.anywhere = anywhere
    }

    func handleUIGestureRecognizerAction(_ g: UIPanGestureRecognizer, context: Context) {
        switch g.state {
        case .changed: changed(g.translation(in: nil).x)
        case .ended: ended(g.translation(in: nil).x, g.velocity(in: nil).x)
        case .cancelled, .failed: ended(0, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var frame: CGRect = .zero
        var leading = false
        var trailing = false
        var middle = false
        var anywhere = false
        /// Зона у края строки, откуда свайп — действие (у Telegram край для «назад» — 1/6 ширины, 22…80).
        let edge: CGFloat = 44

        func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
            guard let p = g as? UIPanGestureRecognizer else { return false }
            let v = p.velocity(in: nil), t = p.translation(in: nil)
            guard abs(v.x) > abs(v.y) * 1.2 else { return false }
            let x = p.location(in: nil).x - t.x
            if anywhere { return true }
            if middle { return x > frame.minX + edge && x < frame.maxX - edge }
            return (leading && v.x > 0 && x < frame.minX + edge) || (trailing && v.x < 0 && x > frame.maxX - edge)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view is UIScrollView
        }
    }
}

/// Предпросмотр файла системным QuickLook, показанным из UIKit: так он закрывается смахиванием вниз,
/// как в «Файлах» и «Почте» (SwiftUI-модификатор `.quickLookPreview` этого не умеет).
@MainActor func presentQuickLook(_ url: URL) {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    guard var top = scene?.keyWindow?.rootViewController else { return }
    while let p = top.presentedViewController { top = p }
    top.present(FilePreview(url: url), animated: true)
}

private final class FilePreview: QLPreviewController, QLPreviewControllerDataSource {
    let url: URL
    init(url: URL) {
        self.url = url
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }
    required init?(coder: NSCoder) { fatalError() }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
}

// MARK: - Приватные заметки (spec 13)

extension Color {
    /// Янтарный приватных заметок — один на все платформы: текст и полоса (#B26A00, в тёмной #FFCA28).
    static let privateInk = Color(UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(red: 1, green: 0xCA / 255, blue: 0x28 / 255, alpha: 1)
        : UIColor(red: 0xB2 / 255, green: 0x6A / 255, blue: 0, alpha: 1) })
    /// Фон — #FFB300 с прозрачностью.
    static let privateFill = Color(red: 1, green: 0xB3 / 255, blue: 0)
}

/// «🔒 Приватная» после номера комментария.
struct PrivatePill: View {
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "lock.fill")
            Text("Private")
        }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.privateInk)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Color.privateFill.opacity(0.22), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Private note"))
    }
}
