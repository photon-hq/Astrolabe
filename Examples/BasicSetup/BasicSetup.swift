import Astrolabe

/// A minimal Astrolabe configuration that installs a few Homebrew packages.
@main
struct BasicSetup: Astrolabe {
    var body: some Setup {
        Pkg(.catalog(.homebrew))

        Brew("wget")
        Brew("jq")
        Brew("firefox", type: .cask)
        Brew("htop")
    }
}
