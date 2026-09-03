import Foundation
@testable import MetadataAPI
import Testing

@Suite("TMDBKeyStore")
struct TMDBKeyStoreTests {
    /// A unique service string per test run, so parallel test runs and a
    /// leftover item from a crashed previous run can never collide.
    private func makeStore() -> TMDBKeyStore {
        TMDBKeyStore(service: "omnitag.tmdb.test.\(UUID().uuidString)")
    }

    @Test("no key set reads back nil")
    func readsNilWhenUnset() {
        let store = makeStore()
        #expect(store.key() == nil)
    }

    @Test("a saved key round-trips")
    func savesAndReads() {
        let store = makeStore()
        store.save(key: "abc123")
        #expect(store.key() == "abc123")
        store.delete()
    }

    @Test("saving twice overwrites rather than duplicating")
    func overwritesExisting() {
        let store = makeStore()
        store.save(key: "first")
        store.save(key: "second")
        #expect(store.key() == "second")
        store.delete()
    }

    @Test("deleting removes the key")
    func deletes() {
        let store = makeStore()
        store.save(key: "abc123")
        store.delete()
        #expect(store.key() == nil)
    }
}
