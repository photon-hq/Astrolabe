import Astrolabe

/// Demonstrates applying modifiers to groups of declarations.
///
/// `Group` lets you attach retry policies, environment overrides,
/// and failure handlers to multiple declarations at once.
@main
struct GroupModifiers: Astrolabe {
    var body: some Setup {
        Pkg(.catalog(.homebrew))

        Brew("wget")

        Group {
            Pkg(.gitHub("macadmins/nudge"))
            Pkg(.gitHub("ProfileCreator/ProfileCreator"))
        }
        .retry(3, delay: .seconds(10))
        .allowUntrusted()

        Brew("firefox", type: .cask)
            .onFail { error in
                print("Failed to install Firefox: \(error)")
            }
    }
}
