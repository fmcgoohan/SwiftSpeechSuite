import Foundation
import Testing
@testable import ElevenLabsSwift

/// Exercises the real KeychainCredentialStore logic (add/update/delete
/// semantics), but against a disposable test-only service/account rather
/// than the app's real "com.speakflowlocal.elevenlabs" item — never
/// touches whatever key the user has actually configured.
@Test func keychainStoreRoundTrips() throws {
    let store = KeychainCredentialStore(service: "com.speakflowlocal.tests", account: "unit-test-\(UUID().uuidString)")
    defer { try? store.delete() }

    #expect(store.load() == nil)

    try store.save("first-value")
    #expect(store.load() == "first-value")

    try store.save("updated-value") // exercises the update path, not just add
    #expect(store.load() == "updated-value")

    try store.delete()
    #expect(store.load() == nil)
}

@Test func deletingAMissingItemDoesNotThrow() throws {
    let store = KeychainCredentialStore(service: "com.speakflowlocal.tests", account: "never-created-\(UUID().uuidString)")
    try store.delete() // errSecItemNotFound is treated as success
}
