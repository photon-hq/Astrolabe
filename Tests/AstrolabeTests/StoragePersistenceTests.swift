import AstrolabeUtils
import Foundation
import Testing
@testable import Astrolabe

// MARK: - Storage Persistence

@Test func storageClientConcurrentWritesPreserveAllKeys() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("astrolabe-storage-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("storage.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<200 {
            group.addTask {
                try StorageClient(fileURL: fileURL).write("gitgate/repo-\(index)", value: "checksum-\(index)")
            }
        }
        try await group.waitForAll()
    }

    let client = StorageClient(fileURL: fileURL)
    #expect(Set(client.keys()).count == 200)
    for index in 0..<200 {
        let value: String? = client.read("gitgate/repo-\(index)")
        #expect(value == "checksum-\(index)")
    }
}

@Test func storageStoreSetPreservesExternalStorageClientWrites() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("astrolabe-storage-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("storage.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = StorageStore(fileURL: fileURL)
    let client = StorageClient(fileURL: fileURL)

    #expect(store.set("astrolabe.update.lastError", value: "old error"))
    try client.write("gitgate/photon-hq/macrocosm-route", value: "route-checksum")

    #expect(store.set("astrolabe.update.lastSeenVersion", value: "1.2.3"))

    let checksum: String? = client.read("gitgate/photon-hq/macrocosm-route")
    let version: String? = client.read("astrolabe.update.lastSeenVersion")
    #expect(checksum == "route-checksum")
    #expect(version == "1.2.3")
}
