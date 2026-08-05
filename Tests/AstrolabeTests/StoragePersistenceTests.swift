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

    // The child runs concurrently with the parent's writes — that overlap is the point of
    // the test. `async let` starts it and lets the parent race it to the same file.
    let writerPath = try storageClientWriterURL().path
    async let child = ProcessRunner.capture(
        writerPath,
        arguments: [fileURL.path, "child", "200"],
        timeout: .seconds(120)
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<200 {
            group.addTask {
                try StorageClient(fileURL: fileURL).write("gitgate/parent-\(index)", value: "checksum-parent-\(index)")
            }
        }
        try await group.waitForAll()
    }

    let result = try await child
    #expect(result.isSuccess, "StorageClientWriter failed: \(result.combined)")

    let client = StorageClient(fileURL: fileURL)
    #expect(Set(client.keys()).count == 400)
    for prefix in ["parent", "child"] {
        for index in 0..<200 {
            let value: String? = client.read("gitgate/\(prefix)-\(index)")
            #expect(value == "checksum-\(prefix)-\(index)")
        }
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

private func storageClientWriterURL() throws -> URL {
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<6 {
        let candidate = directory.appendingPathComponent("StorageClientWriter")
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        directory.deleteLastPathComponent()
    }
    throw StoragePersistenceTestError.helperNotFound
}

private enum StoragePersistenceTestError: Error {
    case helperNotFound
}
