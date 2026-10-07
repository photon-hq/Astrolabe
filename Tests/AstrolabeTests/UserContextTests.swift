import Foundation
import Testing
@testable import Astrolabe

// MARK: - Group cap (ENG-3374)

/// gids are system-admin's on system410, a provisioned host (`id -G`); names are illustrative.
private let names: [gid_t: String] = [
    20: "staff", 12: "everyone", 61: "localaccounts", 79: "_appserverusr", 80: "admin",
    81: "_appserveradm", 33: "_appstore", 98: "_lpadmin", 100: "_lpoperator", 204: "_developer",
    250: "_analyticsusers", 395: "com.apple.access_ssh", 398: "com.apple.access_screensharing",
    399: "com.apple.access_remote_ae", 400: "com.apple.access_ftp",
    701: "com.apple.sharepoint.group.1", 702: "com.apple.sharepoint.group.2",
    703: "com.apple.sharepoint.group.3", 704: "com.apple.sharepoint.group.4",
    705: "com.apple.sharepoint.group.5", 706: "com.apple.sharepoint.group.6",
]
private let provisioned: [gid_t] = [20, 12, 61, 79, 80, 81, 706, 702, 33, 98, 100, 204, 250, 395, 398, 399, 400, 703, 704, 705, 701]

@Test func prioritizedKeepsEveryGroupOfAShortList() {
    let groups: [gid_t] = [20, 12, 61, 79, 80, 81]
    #expect(UserContext.prioritized(groups, primary: 20, name: { names[$0] }) == [20, 80, 12, 61, 79, 81])
    #expect(UserContext.prioritized([20, 12], primary: 20, name: { names[$0] }) == [20, 12])
}

@Test func prioritizedCapsAProvisionedHostAt16() {
    let kept = UserContext.prioritized(provisioned, primary: 20, name: { names[$0] })
    #expect(kept.count == Int(NGROUPS_MAX))
    #expect(kept == [20, 80, 12, 61, 79, 81, 33, 98, 100, 204, 250, 706, 702, 395, 398, 399])
}

/// system412: 17 groups, the 17th a reseller's leftover share group.
@Test func prioritizedDropsSystem412sLeftoverShareGroup() {
    let groups: [gid_t] = [20, 12, 61, 79, 80, 81, 702, 33, 98, 100, 204, 250, 395, 398, 399, 400, 701]
    let kept = UserContext.prioritized(groups, primary: 20, name: { names[$0] })
    #expect(kept.count == 16)
    #expect(!kept.contains(701))
}

@Test func prioritizedAlwaysKeepsPrimaryAdminAndStaff() {
    let shares = (701...706).map { gid_t($0) }
    let others: [gid_t] = [12, 61, 79, 81, 33, 98, 100, 204, 250, 395, 398, 399, 400]
    // Primary, admin and staff arrive last, after more than 16 other groups.
    let kept = UserContext.prioritized(shares + others + [80, 20, 501], primary: 501, limit: 4, name: { names[$0] })
    #expect(kept == [501, 80, 20, 12])
}

@Test func prioritizedDropsShareAndAccessGroupsFirst() {
    let kept = UserContext.prioritized([701, 395, 12, 61, 79], primary: 20, limit: 4, name: { names[$0] })
    #expect(kept == [20, 12, 61, 79])
}

@Test func prioritizedRemovesDuplicatesIncludingThePrimary() {
    let kept = UserContext.prioritized([20, 12, 12, 80, 20, 61, 80], primary: 20, name: { names[$0] })
    #expect(kept == [20, 80, 12, 61])
}

@Test func prioritizedKeepsUnnamedGroupsWithTheOthers() {
    let kept = UserContext.prioritized([701, 9999, 12], primary: 20, limit: 3, name: { names[$0] })
    #expect(kept == [20, 9999, 12])
}

// MARK: - Spawn errors

/// A non-root caller can't `setgroups()`, so spawning as itself fails in the forked child
/// without running anything; the error must name the user and group count.
@Test func spawnFailureAsAUserNamesTheUserAndGroupCount() async throws {
    guard geteuid() != 0, let user = UserContext(username: NSUserName()) else { return }
    do {
        _ = try await ProcessRunner.capture("/bin/echo", arguments: ["unreachable"], as: user)
        Issue.record("expected the spawn to fail for a non-root caller")
    } catch let error as ReconcileError {
        guard case .processFailed(let path, _, let output) = error else { return }
        #expect(path == "/bin/echo")
        #expect(output.contains("spawn as \(user.name)"))
        #expect(output.contains("\(user.supplementaryGroups.count) supplementary groups"))
    }
}
