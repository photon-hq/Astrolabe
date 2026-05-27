import Astrolabe

/// Demonstrates applying modifiers to groups of declarations.
///
/// `Group` lets you attach environment overrides, drift-loop cadence,
/// and other modifiers to multiple declarations at once.
@main
struct GroupModifiers: Astrolabe {
    static var version: String { "0.0.1" }

    var body: some Setup {
        Pkg(.catalog(.homebrew))

        Brew("wget")

        Group {
            Pkg(.gitHub("macadmins/nudge"))
            Pkg(.gitHub("ProfileCreator/ProfileCreator"))
        }
        .allowUntrusted()
        .loopInterval(.seconds(30))

        Brew("firefox", type: .cask)
    }
}
