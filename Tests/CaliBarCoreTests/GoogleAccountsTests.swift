import Foundation
import Testing
@testable import CaliBarCore

@Suite("Google accounts", .serialized)
struct GoogleAccountsTests {
    private let configuration = GoogleOAuthConfiguration(clientID: "123-abc.apps.googleusercontent.com")!

    @Test func addingAnAccountShowsGooglesChooser() throws {
        let url = configuration.authorizationURL(challenge: "c", state: "s", prompt: "select_account")
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items.first { $0.name == "prompt" }?.value == "select_account")
        #expect(items.contains { $0.name == "login_hint" } == false)
    }

    @Test func eachAccountHasItsOwnKeychainItemAndTheOldOneMoves() throws {
        let service = "com.robswift.Daybar.tests.\(UUID().uuidString)"
        let legacy = KeychainCredentialStorage(service: service, account: KeychainCredentialStorage.legacyAccount)
        let first = GoogleCredentials(email: "Me@Example.com", refreshToken: "r1", scopes: [])
        let second = GoogleCredentials(email: "work@example.org", refreshToken: "r2", scopes: [])
        try legacy.save(first)
        try KeychainCredentialStorage(service: service, email: second.email).save(second)
        defer {
            for email in KeychainCredentialStorage.connectedEmails(service: service) {
                KeychainCredentialStorage(service: service, email: email).clear()
            }
            legacy.clear()
        }

        #expect(KeychainCredentialStorage.connectedEmails(service: service) == ["me@example.com", "work@example.org"])
        #expect(legacy.load() == nil)
        #expect(KeychainCredentialStorage(service: service, email: "me@example.com").load() == first)
        #expect(KeychainCredentialStorage(service: service, email: "WORK@example.org").load() == second)
    }
}
