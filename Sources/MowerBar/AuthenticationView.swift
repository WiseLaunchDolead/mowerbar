import SwiftUI
import WebKit
import CryptoKit
import Security
import MowerBarCore

struct OAuthAttempt {
    let verifier: String, state: String, url: URL
    init() {
        func random() -> String {
            var bytes = [UInt8](repeating: 0, count: 32)
            precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess)
            return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        verifier = random(); state = random()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var c = URLComponents(string: "https://id.worx.com/oauth/authorize")!
        c.queryItems = [URLQueryItem(name: "response_type", value: "code"), .init(name: "client_id", value: CloudAPI.clientID),
            .init(name: "redirect_uri", value: CloudAPI.redirectURI), .init(name: "scope", value: CloudAPI.scope),
            .init(name: "state", value: state), .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256")]
        url = c.url!
    }
}

struct AuthenticationView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) var dismiss
    @State private var attempt = OAuthAttempt()
    @State private var error: String?
    @State private var exchanging = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Worx account sign-in", systemImage: "lock.shield")
                Spacer(); Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }.font(.headline).padding()
            Divider()
            if let error {
                ContentUnavailableView { Label("Sign-in interrupted", systemImage: "exclamationmark.triangle") }
                    description: { Text(error) } actions: { Button("Try again") { self.error = nil; attempt = OAuthAttempt() } }
            } else {
                AuthenticationBrowser(attempt: attempt) { result in
                    switch result {
                    case .failure: error = String(localized: "The Worx sign-in did not complete. Try again or close this window.")
                    case .success(let code):
                        guard !exchanging else { return }; exchanging = true
                        Task { @MainActor in
                            do {
                                try await store.api.exchange(code: code, verifier: attempt.verifier)
                                store.sessionAvailable = true; dismiss(); await store.refresh()
                            } catch { self.error = String(localized: "Worx did not accept the sign-in. Try again.") }
                            exchanging = false
                        }
                    }
                }.id(attempt.state).overlay { if exchanging { ProgressView("Signing in…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            }
        }.frame(width: 600, height: 720)
    }
}

struct AuthenticationBrowser: NSViewRepresentable {
    let attempt: OAuthAttempt
    var complete: (Result<String, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(attempt: attempt, complete: complete) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: attempt.url)); return view
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    final class Coordinator: NSObject, WKNavigationDelegate {
        let attempt: OAuthAttempt
        let complete: (Result<String, Error>) -> Void
        private var finished = false
        init(attempt: OAuthAttempt, complete: @escaping (Result<String, Error>) -> Void) { self.attempt = attempt; self.complete = complete }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if url.scheme == "https", url.host == "app.worxlandroid.com", url.path == "/login" {
                decisionHandler(.cancel)
                guard !finished else { return }; finished = true
                let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                guard q.first(where: { $0.name == "state" })?.value == attempt.state,
                      let code = q.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
                    complete(.failure(ProtocolError.invalid(String(localized: "Invalid sign-in response.")))); return
                }
                complete(.success(code)); return
            }
            // No TLS exceptions and no custom URL scheme execution from the login page.
            decisionHandler(url.scheme == "https" || url.absoluteString == "about:blank" ? .allow : .cancel)
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !finished, (error as NSError).code != NSURLErrorCancelled else { return }
            finished = true; complete(.failure(error))
        }
    }
}
