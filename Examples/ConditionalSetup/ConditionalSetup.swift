import Astrolabe

/// Demonstrates conditional declarations driven by environment values.
///
/// Packages are only declared when their conditions are met.
/// The framework re-evaluates on each poll cycle, so if enrollment
/// status changes at runtime, the tree updates automatically.
@main
struct ConditionalSetup: Astrolabe {
    var body: some Setup {
        Pkg(.catalog(.homebrew))

        Brew("git")
        Brew("curl")

        if EnvironmentValues.current.isEnrolled {
            Brew("git-lfs")
            Pkg(.gitHub("AgileBits/1password-cli"))
        }
    }
}
