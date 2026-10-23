import SwiftUI
import WebKit

/// Вход: основной путь — «Войти через сайт», ручной ключ — запасная дверь.
struct LoginView: View {
    @Environment(AppModel.self) private var app
    @AppStorage("lastServer") private var server = "https://my.basealt.space"
    @State private var key = ""
    @State private var manual = false
    @State private var busy = false
    @State private var error: String?
    @State private var webLogin: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "checklist")
                            .font(.system(size: 56, weight: .semibold))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("RedTask").font(.largeTitle.bold())
                        Text("A client for your Redmine server").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 8)
                }
                Section {
                    TextField("Server address", text: $server)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server")
                }
                Section {
                    Button {
                        if let u = AppModel.normalize(server) { webLogin = u } else { error = String(localized: "Invalid server address") }
                    } label: {
                        Label("Sign in via website", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                } footer: {
                    Text("Sign in to your Redmine account — the app picks up the API key automatically.")
                }
                Section {
                    DisclosureGroup("Enter API key manually", isExpanded: $manual) {
                        SecureField("API key", text: $key)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                        Button {
                            Task { await signIn(key: key) }
                        } label: {
                            if busy { ProgressView() } else { Text("Sign In") }
                        }
                        .disabled(busy || key.isEmpty || server.isEmpty)
                    }
                } footer: {
                    if manual { Text("My account → API access key → Show") }
                }
                // вторичное действие (HIG): без сервера — посмотреть приложение на выдуманных данных
                Section {
                    Button("Try Demo") { app.enterDemo() }
                        .frame(maxWidth: .infinity)
                } footer: {
                    Text("No Redmine server at hand? Explore the app with sample data. Nothing is sent anywhere.")
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
            .background(Color(.systemGroupedBackground))
            .alert("Sign-in failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(error ?? "")
            }
            .fullScreenCover(item: $webLogin) { url in
                WebLoginView(server: url) { key, agent in
                    webLogin = nil
                    Task {
                        await signIn(key: key)
                        await app.adoptBrowserPass(agent: agent)
                    }
                } onCancel: { webLogin = nil }
            }
        }
    }

    private func signIn(key: String) async {
        busy = true
        defer { busy = false }
        do { try await app.login(server: server, key: key) } catch { self.error = error.localizedDescription }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

// MARK: - Веб-вход

/**
 Вход через сайт: WKWebView с формой логина. Сервер за WAF: веб-запросы от не-браузера он встречает
 капчей, поэтому ключ забираем fetch'ем ИЗ контекста страницы, где уже есть сессия и браузерная репутация:
 сначала users/current.json (api_key), иначе /my/api_key (ключ открытым текстом).
 callAsyncJavaScript дожидается Promise — опрос window.__key, нужный на Android, здесь не нужен.
 */
struct WebLoginView: View {
    let server: URL
    let onKey: (String, String) -> Void
    let onCancel: () -> Void
    @State private var page = BrowserPage()

    var body: some View {
        NavigationStack {
            WebContainer(page: page)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Sign in")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onCancel) }
                    ToolbarItem(placement: .principal) {
                        if page.loading { ProgressView() }
                    }
                }
                .safeAreaInset(edge: .top) {
                    Text("Sign in to your Redmine account — the app picks up the API key automatically.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal).padding(.vertical, 8)
                        .background(.bar)
                }
        }
        .task {
            page.load(server.appendingPathComponent("login"))
            // опрос: каждые 1.5 с, как только появилась сессия Redmine — fetch ключа из контекста страницы
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard await page.hasCookie("_redmine_session", host: server.host ?? "") else { continue }
                if let key = await page.fetchKey(), key.count >= 40, key.count <= 64, key.allSatisfy({ $0.isLetter || $0.isNumber }) {
                    onKey(key, await page.userAgent())
                    return
                }
            }
        }
    }
}

/// Капча WAF: сайт во весь экран, после «Готово» запросы идут с куками и UA этого WebView.
struct CaptchaView: View {
    let server: URL
    let onDone: () -> Void
    @Environment(AppModel.self) private var app
    @State private var page = BrowserPage()

    var body: some View {
        NavigationStack {
            WebContainer(page: page)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle("Pass the check and tap Done")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            Task {
                                await app.adoptBrowserPass(agent: await page.userAgent())
                                onDone()
                            }
                        }
                    }
                }
        }
        .task { page.load(server) }
    }
}

/// Кнопка «Решить капчу» — видна, только пока сервер отвечает капчей, а автоповтор её не прошёл.
struct CaptchaButton: View {
    @Environment(AppModel.self) private var app
    @State private var waf = WafState.shared
    @State private var open = false
    var onSolved: () -> Void = {}

    var body: some View {
        if waf.blocked, let url = app.api?.baseURL {
            Button("Solve captcha", systemImage: "checkmark.shield") { open = true }
                .buttonStyle(.bordered)
                .fullScreenCover(isPresented: $open) {
                    CaptchaView(server: url) {
                        open = false
                        waf.blocked = false
                        onSolved()
                    }
                }
        }
    }
}

// MARK: - WKWebView

@MainActor @Observable
final class BrowserPage: NSObject, WKNavigationDelegate {
    let view: WKWebView
    var loading = false

    override init() {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        view = WKWebView(frame: .zero, configuration: cfg)
        super.init()
        view.navigationDelegate = self
        view.allowsBackForwardNavigationGestures = true
    }

    func load(_ url: URL) { view.load(URLRequest(url: url)) }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { loading = false }

    func hasCookie(_ name: String, host: String) async -> Bool {
        await view.configuration.websiteDataStore.httpCookieStore.allCookies().contains { c in
            c.name == name && (host == c.domain || host.hasSuffix(c.domain.hasPrefix(".") ? c.domain : "." + c.domain))
        }
    }

    func userAgent() async -> String {
        (try? await view.evaluateJavaScript("navigator.userAgent") as? String) ?? RedmineAPI.userAgent
    }

    func fetchKey() async -> String? {
        let js = """
        const r = await fetch('/users/current.json', {credentials: 'same-origin'});
        try { const j = JSON.parse(await r.text()); if (j.user && j.user.api_key) return j.user.api_key; } catch (e) {}
        const t = await (await fetch('/my/api_key', {credentials: 'same-origin'})).text();
        const m = String(t).match(/[a-f0-9]{40}/i);
        return m ? m[0] : '';
        """
        let r = try? await view.callAsyncJavaScript(js, contentWorld: .page)
        return (r as? String).flatMap { $0.isEmpty ? nil : $0 }
    }
}

struct WebContainer: UIViewRepresentable {
    let page: BrowserPage
    func makeUIView(context: Context) -> WKWebView { page.view }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
