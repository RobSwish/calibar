import CryptoKit
import Foundation
import Security

/// Google OAuth for an installed app, using an iOS-type client ID and PKCE. No client secret exists or is needed.
public struct GoogleOAuthConfiguration: Equatable, Sendable {
    public static let clientIDSuffix = ".apps.googleusercontent.com"
    public static let calendarEventsScope = "https://www.googleapis.com/auth/calendar.events"
    public static let calendarListScope = "https://www.googleapis.com/auth/calendar.calendarlist.readonly"
    public static let meetScope = "https://www.googleapis.com/auth/meetings.space.created"
    public static let scopes = ["openid", "email", calendarEventsScope, calendarListScope, meetScope]

    public let clientID: String

    public init?(clientID: String?) {
        let value = (clientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasSuffix(Self.clientIDSuffix), value.count > Self.clientIDSuffix.count,
              !value.contains("$("), value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return nil }
        self.clientID = value
    }

    /// iOS-type Google clients redirect to the reversed client ID.
    public var callbackScheme: String {
        "com.googleusercontent.apps." + clientID.dropLast(Self.clientIDSuffix.count)
    }
    public var redirectURI: String { callbackScheme + ":/oauth2redirect" }

    public func authorizationURL(challenge: String, state: String, loginHint: String? = nil) -> URL {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        components.queryItems = items
        return components.url!
    }

    /// Reads the authorization code from Google's redirect, rejecting a mismatched state.
    public func authorizationCode(from callback: URL, expectedState: String) throws -> String {
        guard callback.scheme?.lowercased() == callbackScheme.lowercased(),
              let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw GoogleError.invalidResponse
        }
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { throw GoogleError.invalidResponse }
        if let error = value("error") { throw error == "access_denied" ? GoogleError.signInCancelled : GoogleError.signInFailed(error) }
        guard let code = value("code"), !code.isEmpty else { throw GoogleError.invalidResponse }
        return code
    }
}

public struct PKCE: Sendable {
    public let verifier: String
    public var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    public init(verifier: String? = nil) {
        self.verifier = verifier ?? Self.randomString()
    }

    public static func randomString(bytes count: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            bytes = (0..<count).map { _ in UInt8.random(in: .min ... .max) }
        }
        return base64URL(Data(bytes))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// What CaliBar keeps in the Keychain. Access tokens stay in memory only.
public struct GoogleCredentials: Codable, Equatable, Sendable {
    public var email: String
    public var refreshToken: String
    public var scopes: Set<String>

    public init(email: String, refreshToken: String, scopes: Set<String>) {
        self.email = email; self.refreshToken = refreshToken; self.scopes = scopes
    }

    public var canCreateCalendarEvents: Bool {
        scopes.contains(GoogleOAuthConfiguration.calendarEventsScope) && scopes.contains(GoogleOAuthConfiguration.calendarListScope)
    }
    public var canCreateMeetSpaces: Bool { scopes.contains(GoogleOAuthConfiguration.meetScope) }
}

struct GoogleTokenResponse: Decodable {
    let accessToken: String
    let expiresIn: Double?
    let refreshToken: String?
    let scope: String?
    let idToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token", expiresIn = "expires_in", refreshToken = "refresh_token", scope, idToken = "id_token"
    }

    var scopes: Set<String> { Set((scope ?? "").split(separator: " ").map(String.init)) }
}

public enum GoogleIDToken {
    /// The ID token arrives directly from Google's token endpoint over TLS; its email is used only for display and matching.
    public static func email(from token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["email"] as? String
    }
}

public enum GoogleError: LocalizedError, Equatable, Sendable {
    case notConfigured, notSignedIn, signInCancelled, signInFailed(String), reconnectRequired, missingPermission
    case invalidResponse, http(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Google sign-in isn’t set up in this build of CaliBar."
        case .notSignedIn: "Connect your Google account in Settings to add Google Meet."
        case .signInCancelled: "Google sign-in was cancelled."
        case .signInFailed(let reason): "Google sign-in didn’t finish (\(reason)). Try again."
        case .reconnectRequired: "Your Google connection has expired. Connect your Google account again in Settings."
        case .missingPermission: "CaliBar needs permission to create Google Meet links. Connect your Google account again and allow every requested permission."
        case .invalidResponse: "Google returned an unexpected response. Try again."
        case .http(let status, let message): message.isEmpty ? "Google returned an error (\(status)). Try again." : "Google: \(message)"
        }
    }

    /// A 4xx response means Google rejected the request without creating anything.
    public var isRejection: Bool {
        if case .http(let status, _) = self { return (400..<500).contains(status) }
        return self == .missingPermission
    }
}

public protocol GoogleCredentialStorage: Sendable {
    func load() -> GoogleCredentials?
    func save(_ credentials: GoogleCredentials) throws
    func clear()
}

public struct KeychainCredentialStorage: GoogleCredentialStorage {
    let service: String
    let account: String

    public init(service: String, account: String = "google") {
        self.service = service; self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func load() -> GoogleCredentials? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleCredentials.self, from: data)
    }

    public func save(_ credentials: GoogleCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw GoogleError.signInFailed("Keychain error \(added)") }
        } else if status != errSecSuccess {
            throw GoogleError.signInFailed("Keychain error \(status)")
        }
    }

    public func clear() { SecItemDelete(query as CFDictionary) }
}
