import AppKit
import AuthenticationServices
import CaliBarCore
import SwiftUI

/// The optional Google connection used for Meet links and invitations. CaliBar works fully without it.
@MainActor
final class GoogleAccount: NSObject, ObservableObject {
    @Published private(set) var email: String?
    @Published private(set) var isSigningIn = false
    @Published var error: String?
    /// The signed-in account’s writable Google calendars, used to offer invitees only where they can be sent.
    @Published private(set) var calendars: [GoogleCalendarListEntry]?
    let client: GoogleClient?
    private let isDemo: Bool
    private var authSession: ASWebAuthenticationSession?
    private var anchorWindow: NSWindow?

    init(demo: Bool, bundle: Bundle = .main) {
        isDemo = demo
        if !demo, let configuration = GoogleOAuthConfiguration(clientID: bundle.object(forInfoDictionaryKey: "CaliBarGoogleClientID") as? String) {
            let storage = KeychainCredentialStorage(service: (bundle.bundleIdentifier ?? "com.robswift.Daybar") + ".google")
            client = GoogleClient(configuration: configuration, storage: storage)
            email = storage.load()?.email
        } else {
            client = nil
            email = demo ? "you@example.com" : nil
        }
        super.init()
    }

    /// Demo mode shows the feature without contacting Google.
    var isAvailable: Bool { client != nil || isDemo }
    var isSignedIn: Bool { email != nil }

    /// Re-reads the client’s state, e.g. after Google rejected an expired grant.
    func syncState() async {
        guard let client else { return }
        email = await client.account?.email
        if email == nil { calendars = nil }
    }

    /// Fetches the calendar list once per session; failures leave the name-based guess in place.
    func loadCalendarsIfNeeded() async {
        guard let client, email != nil, calendars == nil, await client.account?.canCreateCalendarEvents == true else { return }
        if let entries = try? await client.calendars() { calendars = entries } else { await syncState() }
    }

    func update(calendars entries: [GoogleCalendarListEntry]) { calendars = entries }

    @discardableResult
    func signIn() async -> Bool {
        guard !isDemo else { return true }
        guard let client, !isSigningIn else { return false }
        isSigningIn = true
        error = nil
        defer { isSigningIn = false; authSession = nil }
        let pkce = PKCE()
        let state = PKCE.randomString(bytes: 16)
        let configuration = client.configuration
        do {
            let callback = try await authenticate(url: configuration.authorizationURL(challenge: pkce.challenge, state: state, loginHint: email),
                                                  scheme: configuration.callbackScheme)
            let code = try configuration.authorizationCode(from: callback, expectedState: state)
            let credentials = try await client.completeSignIn(code: code, verifier: pkce.verifier)
            email = credentials.email
            calendars = nil
            Task { await loadCalendarsIfNeeded() }
            return true
        } catch GoogleError.signInCancelled {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func signOut() {
        guard !isDemo else { return }
        email = nil
        error = nil
        calendars = nil
        Task { await client?.signOut() }
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        let window = makeAnchorWindow()
        anchorWindow = window
        defer { window.orderOut(nil); anchorWindow = nil }
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callback, error in
                if let callback { continuation.resume(returning: callback); return }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: GoogleError.signInCancelled)
                } else {
                    continuation.resume(throwing: GoogleError.signInFailed(error?.localizedDescription ?? "no response"))
                }
            }
            session.presentationContextProvider = self
            authSession = session
            if !session.start() {
                authSession = nil
                continuation.resume(throwing: GoogleError.signInFailed("the sign-in window couldn’t open"))
            }
        }
    }

    /// The menu-bar panel is a borderless pop-up that hides on outside clicks, so sign-in gets its own window.
    private func makeAnchorWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 160),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Connect Google Account"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: VStack(spacing: 8) {
            Text("Sign in to Google").font(.headline)
            Text("CaliBar only creates the events, invitations and Meet links you save. You can disconnect in Settings.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(24).frame(width: 420, height: 160))
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }
}

extension GoogleAccount: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            anchorWindow ?? NSApp.keyWindow ?? NSWindow()
        }
    }
}
