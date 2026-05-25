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

    let child = Process()
    child.executableURL = try storageClientWriterURL()
    child.arguments = [fileURL.path, "child", "200"]
    let output = Pipe()
    child.standardOutput = output
    child.standardError = output
    try child.run()

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<200 {
            group.addTask {
                try StorageClient(fileURL: fileURL).write("gitgate/parent-\(index)", value: "checksum-parent-\(index)")
            }
        }
        try await group.waitForAll()
    }

    child.waitUntilExit()
    let childOutput = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    #expect(child.terminationStatus == 0, "StorageClientWriter failed: \(childOutput)")

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
