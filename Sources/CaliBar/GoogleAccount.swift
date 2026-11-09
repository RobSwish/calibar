import AppKit
import AuthenticationServices
import CaliBarCore
import SwiftUI

/// The optional Google connections used for Meet links and invitations, one per Google account.
/// CaliBar works fully without any.
@MainActor
final class GoogleAccount: NSObject, ObservableObject {
    /// Connected accounts’ emails, sorted.
    @Published private(set) var emails: [String]
    @Published private(set) var isSigningIn = false
    @Published private(set) var isCreatingMeet = false
    @Published var error: String?
    /// Each account’s writable Google calendars, used to offer invitees only where they can be sent.
    @Published private(set) var calendars: [String: [GoogleCalendarListEntry]] = [:]
    let configuration: GoogleOAuthConfiguration?
    private let service: String
    private var clients: [String: GoogleClient] = [:]
    private let isDemo: Bool
    private var authSession: ASWebAuthenticationSession?
    private var anchorWindow: NSWindow?
    private var connectState: ConnectWindowState?

    init(demo: Bool, bundle: Bundle = .main) {
        isDemo = demo
        service = (bundle.bundleIdentifier ?? "com.robswift.Daybar") + ".google"
        configuration = demo ? nil : GoogleOAuthConfiguration(clientID: bundle.object(forInfoDictionaryKey: "CaliBarGoogleClientID") as? String)
        if let configuration {
            let connected = KeychainCredentialStorage.connectedEmails(service: service)
            emails = connected
            for email in connected {
                clients[email] = GoogleClient(configuration: configuration, storage: KeychainCredentialStorage(service: service, email: email))
            }
        } else {
            emails = demo ? ["you@example.com"] : []
        }
        super.init()
    }

    /// Demo mode shows the feature without contacting Google.
    var isAvailable: Bool { configuration != nil || isDemo }
    var isSignedIn: Bool { !emails.isEmpty }
    /// Whether every account’s calendar list has loaded, so calendar matching is exact rather than a guess.
    var hasAllCalendars: Bool { emails.allSatisfy { calendars[$0] != nil } }

    func client(for email: String) -> GoogleClient? { clients[email.lowercased()] }

    /// The connected account whose loaded calendar list contains this Apple Calendar calendar.
    func account(for calendar: CalendarInfo, among all: [CalendarInfo]) -> String? {
        emails.first { email in
            calendars[email].map { GoogleCalendarMatch.calendarID(for: calendar, among: all, google: $0, accountEmail: email) != nil } ?? false
        }
    }

    /// Drops accounts whose grant Google rejected, e.g. after access was revoked.
    func syncState() async {
        for email in emails where await clients[email]?.account == nil { forget(email) }
    }

    /// Fetches each account’s calendar list once per session; failures leave the name-based guess in place.
    func loadCalendarsIfNeeded() async {
        for email in emails where calendars[email] == nil {
            guard let client = clients[email], await client.account?.canCreateCalendarEvents == true else { continue }
            if let entries = try? await client.calendars() { calendars[email] = entries } else { await syncState() }
        }
    }

    func update(calendars entries: [GoogleCalendarListEntry], for email: String) { calendars[email.lowercased()] = entries }

    /// Connects a Google account. Choosing one that’s already connected refreshes its sign-in.
    @discardableResult
    func signIn() async -> Bool {
        guard !isDemo else { return true }
        guard let configuration, !isSigningIn else { return false }
        isSigningIn = true
        error = nil
        let connect = ConnectWindowState()
        let window = makeAnchorWindow(state: connect)
        anchorWindow = window
        defer {
            isSigningIn = false
            authSession = nil
            window.orderOut(nil)
            anchorWindow = nil
            connectState = nil
        }
        // Nothing reaches Google until the person chooses to continue.
        guard await withCheckedContinuation({ connect.choice = $0 }) else { return false }
        connect.isWaitingForGoogle = true
        let pkce = PKCE()
        let state = PKCE.randomString(bytes: 16)
        do {
            let url = configuration.authorizationURL(challenge: pkce.challenge, state: state, prompt: "select_account")
            let callback = try await authenticate(url: url, scheme: configuration.callbackScheme)
            let code = try configuration.authorizationCode(from: callback, expectedState: state)
            let signIn = try await GoogleClient.exchange(code: code, verifier: pkce.verifier, configuration: configuration)
            let email = signIn.credentials.email.lowercased()
            let client = clients[email] ?? GoogleClient(configuration: configuration, storage: KeychainCredentialStorage(service: service, email: email))
            try await client.adopt(signIn)
            clients[email] = client
            if !emails.contains(email) { emails = (emails + [email]).sorted() }
            calendars[email] = nil
            Task { await loadCalendarsIfNeeded() }
            return true
        } catch GoogleError.signInCancelled {
            return false
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    /// Creates a Meet room straight away, connecting Google first if needed, so the link shows in the editor.
    /// The room belongs to `preferredEmail` when that account is connected, otherwise to the first account.
    func createMeetLink(preferring preferredEmail: String? = nil) async -> URL? {
        if isDemo { return URL(string: "https://meet.google.com/abc-defg-hij") }
        guard isAvailable, !isCreatingMeet else { return nil }
        if !isSignedIn { guard await signIn() else { return nil } }
        guard let email = preferredEmail.flatMap({ emails.contains($0) ? $0 : nil }) ?? emails.first,
              let client = clients[email] else { return nil }
        guard await client.account?.canCreateMeetSpaces == true else {
            error = GoogleError.missingPermission.localizedDescription
            return nil
        }
        isCreatingMeet = true
        error = nil
        defer { isCreatingMeet = false }
        do {
            return try await client.createMeetSpace()
        } catch {
            self.error = error.localizedDescription
            await syncState()
            return nil
        }
    }

    /// Disconnects one account and asks Google to revoke its access.
    func signOut(_ email: String) {
        guard !isDemo, let client = clients[email] else { return }
        forget(email)
        error = nil
        Task { await client.signOut() }
    }

    private func forget(_ email: String) {
        emails.removeAll { $0 == email }
        clients[email] = nil
        calendars[email] = nil
    }

    private func authenticate(url: URL, scheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            // AuthenticationServices calls back on its XPC queue. @Sendable keeps this closure off the
            // main actor; an isolated closure would trap the executor check there.
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { @Sendable callback, error in
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
    private func makeAnchorWindow(state: ConnectWindowState) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Connect Google"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.contentView = NSHostingView(rootView: GoogleConnectView(state: state,
            proceed: { state.resolve(true) },
            cancel: { [weak self] in self?.cancelConnect(state) }))
        connectState = state
        window.delegate = self
        window.center()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        return window
    }

    /// Before Google opens, cancelling just declines; afterwards it ends Google’s session.
    private func cancelConnect(_ state: ConnectWindowState) {
        if state.choice != nil { state.resolve(false) } else { authSession?.cancel() }
    }
}

/// Whether the person chose to continue to Google, and whether Google’s sign-in is open.
@MainActor
final class ConnectWindowState: ObservableObject {
    @Published var isWaitingForGoogle = false
    var choice: CheckedContinuation<Bool, Never>?

    func resolve(_ proceed: Bool) {
        choice?.resume(returning: proceed)
        choice = nil
    }
}

extension GoogleAccount: NSWindowDelegate {
    /// Closing the window abandons the sign-in.
    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { if let connectState { cancelConnect(connectState) } }
    }
}

/// Explains what connecting does, then hands over to Google’s sign-in sheet.
private struct GoogleConnectView: View {
    @ObservedObject var state: ConnectWindowState
    let proceed: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                CaliBarTile(glyphScale: 0.75)
                    .frame(width: 48, height: 48)
                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
                Image(systemName: "arrow.left.arrow.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.tertiary)
                GoogleMeetLogo().frame(width: 28)
                    .frame(width: 48, height: 48)
                    .background(.background, in: RoundedRectangle(cornerRadius: 48 * 0.225, style: .continuous))
                    .shadow(color: .black.opacity(0.14), radius: 1.5, y: 1)
            }
            .accessibilityHidden(true)
            .padding(.top, 40)

            Text("Connect Google").font(.system(size: 20, weight: .semibold)).padding(.top, 18)
            Text("Add Meet links and send invitations without leaving CaliBar.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.top, 6)

            VStack(spacing: 8) {
                row("video", "Meet links on any event you add")
                row("person.2", "Invitations from your Google calendars")
                row("lock", "Only what you save. Disconnect in Settings.")
            }
            .padding(.top, 20)

            Spacer(minLength: 16)
            HStack(spacing: 8) {
                if state.isWaitingForGoogle {
                    ProgressView().controlSize(.small)
                    Text("Continue in the Google window…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                if !state.isWaitingForGoogle {
                    Button("Continue with Google", action: proceed).keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 28).padding(.bottom, 20)
        .frame(width: 440, height: 340)
    }

    private func row(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(text)
        }
    }
}

extension GoogleAccount: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            anchorWindow ?? NSApp.keyWindow ?? NSWindow()
        }
    }
}

/// CaliBar’s app icon drawn as a tile, so the calendar glyph can sit with more margin than the icon artwork.
/// Proportions are measured from AppIcon.icns.
struct CaliBarTile: View {
    var glyphScale: CGFloat = 1

    private static let red = Color(red: 1, green: 0x69 / 255, blue: 0x55 / 255)
    private static let paper = Color(red: 1, green: 0xFD / 255, blue: 0xF7 / 255)

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let stroke = side * 0.086
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: side * 0.225, style: .continuous).fill(Self.red)
                ZStack(alignment: .topLeading) {
                    ForEach([0.348, 0.654], id: \.self) { x in
                        Capsule().fill(Self.paper)
                            .frame(width: stroke, height: side * 0.2)
                            .offset(x: side * x - stroke / 2, y: side * 0.164)
                    }
                    RoundedRectangle(cornerRadius: side * 0.097, style: .continuous).fill(Self.paper)
                        .frame(width: side * 0.622, height: side * 0.546)
                        .offset(x: side * 0.19, y: side * 0.283)
                    Path { path in
                        path.move(to: CGPoint(x: side * 0.359, y: side * 0.575))
                        path.addLine(to: CGPoint(x: side * 0.467, y: side * 0.687))
                        path.addLine(to: CGPoint(x: side * 0.665, y: side * 0.462))
                    }
                    .stroke(Self.red, style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round))
                }
                .frame(width: side, height: side, alignment: .topLeading)
                .scaleEffect(glyphScale)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
