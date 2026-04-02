import Foundation
import SystemConfiguration

/// Enumerates macOS user accounts for per-user launchd operations.
enum UserHelper {

    struct User: Sendable {
        let username: String
        let uid: uid_t
    }

    /// Returns the currently active console user, or nil if no one is logged in.
    static func consoleUser() -> User? {
        var uid: uid_t = 0
        guard let username = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String,
              uid != 0,
              username != "loginwindow"
        else { return nil }
        return User(username: username, uid: uid)
    }

    /// Returns all non-system users (UID >= 500, excluding nobody).
    static func allUsers() -> [User] {
        var users: [User] = []
        setpwent()
        while let pw = getpwent() {
            let uid = pw.pointee.pw_uid
            guard uid >= 500, uid != 65534 else { continue }
            let home = String(cString: pw.pointee.pw_dir)
            guard home.hasPrefix("/Users/") else { continue }
            let name = String(cString: pw.pointee.pw_name)
            users.append(User(username: name, uid: uid))
        }
        endpwent()
        return users
    }
}
