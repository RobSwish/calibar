import Foundation

/// A completed Google sign-in, before it’s stored for its account.
public struct GoogleSignIn: Sendable {
    public let credentials: GoogleCredentials
    let accessToken: String
    let expiry: Date
}

/// Talks to Google’s OAuth, Calendar and Meet endpoints for one Google account. Only the refresh token is persisted.
public actor GoogleClient {
    public nonisolated let configuration: GoogleOAuthConfiguration
    private let storage: any GoogleCredentialStorage
    private let session: URLSession
    private var credentials: GoogleCredentials?
    private var accessToken: (value: String, expiry: Date)?

    public init(configuration: GoogleOAuthConfiguration, storage: any GoogleCredentialStorage, session: URLSession = .shared) {
        self.configuration = configuration
        self.storage = storage
        self.session = session
        credentials = storage.load()
    }

    public var account: GoogleCredentials? { credentials }

    /// Exchanges the sign-in code. The account isn’t known until Google answers, so the caller then
    /// hands the result to that account’s client with `adopt(_:)`.
    public static func exchange(code: String, verifier: String, configuration: GoogleOAuthConfiguration,
                                session: URLSession = .shared) async throws -> GoogleSignIn {
        let token = try await tokenRequest([
            "code": code, "client_id": configuration.clientID, "redirect_uri": configuration.redirectURI,
            "grant_type": "authorization_code", "code_verifier": verifier
        ], session: session)
        guard let refresh = token.refreshToken, let email = token.idToken.flatMap(GoogleIDToken.email(from:)) else {
            throw GoogleError.invalidResponse
        }
        let signedIn = GoogleCredentials(email: email, refreshToken: refresh, scopes: token.scopes)
        guard signedIn.canCreateMeetSpaces || signedIn.canCreateCalendarEvents else { throw GoogleError.missingPermission }
        return GoogleSignIn(credentials: signedIn, accessToken: token.accessToken,
                            expiry: Date().addingTimeInterval((token.expiresIn ?? 3600) - 60))
    }

    /// Stores a fresh sign-in for this client’s account.
    public func adopt(_ signIn: GoogleSignIn) throws {
        try storage.save(signIn.credentials)
        credentials = signIn.credentials
        accessToken = (signIn.accessToken, signIn.expiry)
    }

    /// Forgets the account locally, then asks Google to revoke the grant (best effort).
    public func signOut() async {
        let token = credentials?.refreshToken
        credentials = nil
        accessToken = nil
        storage.clear()
        guard let token else { return }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.form(["token": token])
        _ = try? await session.data(for: request)
    }

    public func calendars() async throws -> [GoogleCalendarListEntry] {
        struct Page: Decodable { let items: [GoogleCalendarListEntry]?; let nextPageToken: String? }
        var entries: [GoogleCalendarListEntry] = []
        var pageToken: String?
        repeat {
            var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/users/me/calendarList")!
            components.queryItems = [URLQueryItem(name: "minAccessRole", value: "writer"), URLQueryItem(name: "maxResults", value: "250")]
                + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
            let page: Page = try await send(URLRequest(url: components.url!))
            entries += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil && entries.count < 2000
        return entries
    }

    public func insertEvent(_ body: GoogleEventBody, calendarID: String) async throws -> GoogleCreatedEvent {
        let id = calendarID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/@"))) ?? calendarID
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3/calendars/\(id)/events")!
        // Google emails invitees only when the user added some; otherwise nobody is notified.
        components.queryItems = [URLQueryItem(name: "conferenceDataVersion", value: "1"),
                                 URLQueryItem(name: "sendUpdates", value: body.sendsInvitations ? "all" : "none")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        let created: GoogleCreatedEvent = try await send(request)
        if body.conferenceData == nil || created.meetURL != nil { return created }
        // Conference creation is usually immediate but may briefly be pending.
        for delay in [0.5, 1.0, 2.0] {
            try await Task.sleep(for: .seconds(delay))
            let eventID = created.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? created.id
            let fetched: GoogleCreatedEvent = try await send(URLRequest(url: URL(string: "https://www.googleapis.com/calendar/v3/calendars/\(id)/events/\(eventID)")!))
            if fetched.meetURL != nil { return fetched }
        }
        return created
    }

    /// A standalone Meet room, for events saved to calendars Google doesn’t manage.
    public func createMeetSpace() async throws -> URL {
        struct Space: Decodable { let meetingUri: String? }
        var request = URLRequest(url: URL(string: "https://meet.googleapis.com/v2/spaces")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)
        let space: Space = try await send(request)
        guard let text = space.meetingUri, let url = URL(string: text), MeetingLink.recognize(url) != nil else {
            throw GoogleError.invalidResponse
        }
        return url
    }

    // MARK: - Transport

    private func validAccessToken() async throws -> String {
        if let accessToken, accessToken.expiry > Date() { return accessToken.value }
        guard let credentials else { throw GoogleError.notSignedIn }
        do {
            let token: GoogleTokenResponse = try await tokenRequest([
                "client_id": configuration.clientID, "refresh_token": credentials.refreshToken, "grant_type": "refresh_token"
            ])
            accessToken = (token.accessToken, Date().addingTimeInterval((token.expiresIn ?? 3600) - 60))
            if !token.scopes.isEmpty, token.scopes != credentials.scopes {
                var updated = credentials
                updated.scopes = token.scopes
                try? storage.save(updated)
                self.credentials = updated
            }
            return token.accessToken
        } catch GoogleError.http(let status, _) where status == 400 || status == 401 {
            // invalid_grant: the user revoked access or the token expired. Forget it so the UI can reconnect.
            self.credentials = nil
            accessToken = nil
            storage.clear()
            throw GoogleError.reconnectRequired
        }
    }

    private func send<T: Decodable>(_ request: URLRequest, retrying: Bool = true) async throws -> T {
        var authorized = request
        authorized.setValue("Bearer \(try await validAccessToken())", forHTTPHeaderField: "Authorization")
        authorized.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: authorized)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw GoogleError.invalidResponse }
        if status == 401 && retrying {
            accessToken = nil
            return try await send(request, retrying: false)
        }
        try Self.check(status: status, data: data)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw GoogleError.invalidResponse }
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> GoogleTokenResponse {
        try await Self.tokenRequest(fields, session: session)
    }

    private static func tokenRequest(_ fields: [String: String], session: URLSession) async throws -> GoogleTokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(fields)
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw GoogleError.invalidResponse }
        try check(status: status, data: data)
        do { return try JSONDecoder().decode(GoogleTokenResponse.self, from: data) } catch { throw GoogleError.invalidResponse }
    }

    static func check(status: Int, data: Data) throws {
        guard !(200..<300).contains(status) else { return }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let nested = object?["error"] as? [String: Any]
        let reason = ((nested?["errors"] as? [[String: Any]])?.first?["reason"] as? String) ?? (nested?["status"] as? String)
        if status == 403, ["insufficientPermissions", "PERMISSION_DENIED", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"].contains(reason ?? "") {
            throw GoogleError.missingPermission
        }
        let message = (nested?["message"] as? String) ?? (object?["error_description"] as? String) ?? (object?["error"] as? String) ?? ""
        throw GoogleError.http(status: status, message: message)
    }

    static func form(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }.map {
            "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&").utf8)
    }
}
