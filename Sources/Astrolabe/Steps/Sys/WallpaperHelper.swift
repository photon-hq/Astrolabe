import AppKit
import Foundation

/// User-context helper for reading/writing the desktop wallpaper.
///
/// `NSWorkspace`'s desktop-image APIs require a WindowServer/Aqua session, which a root
/// `LaunchDaemon` does not have. So the daemon never calls these directly — it re-execs its
/// own binary as the logged-in user via `launchctl asuser` (see `LaunchctlHelper.runAsUser`),
/// passing a hidden `__wallpaper` subcommand that `Astrolabe.main()` dispatches here *before*
/// the root guard. This is the same approach `desktoppr` uses, and needs no SIP change and no
/// TCC grant.
///
/// Invoked as:
/// - `<binary> __wallpaper set <path> <scaling>` — set every screen's wallpaper.
/// - `<binary> __wallpaper get` — print the main screen's current wallpaper path.
///
/// `args` excludes the program name and the `__wallpaper` token.
enum WallpaperHelper {
    static func main(_ args: [String]) {
        guard let verb = args.first else { fail("usage: __wallpaper <set <path> [scaling]|get>") }
        switch verb {
        case "get":
            guard let screen = NSScreen.main else { print(""); return }
            print(NSWorkspace.shared.desktopImageURL(for: screen)?.path ?? "")
        case "set":
            guard args.count >= 2 else { fail("usage: __wallpaper set <path> [scaling]") }
            set(path: args[1], scaling: args.count >= 3 ? args[2] : "fill")
        default:
            fail("unknown verb '\(verb)'")
        }
    }

    private static func set(path: String, scaling: String) {
        guard FileManager.default.fileExists(atPath: path) else { fail("image not found at \(path)") }
        let url = URL(fileURLWithPath: path)
        let options = options(for: scaling)
        let screens = NSScreen.screens
        guard !screens.isEmpty else { fail("no screens available") }
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            } catch {
                fail("setDesktopImageURL failed: \(error)")
            }
        }
    }

    /// Maps a `WallpaperSetting.Scaling` raw value to NSWorkspace desktop-image options.
    private static func options(for scaling: String) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        switch scaling {
        case "fit":
            return [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: false]
        case "stretch":
            return [.imageScaling: NSImageScaling.scaleAxesIndependently.rawValue, .allowClipping: true]
        case "center":
            return [.imageScaling: NSImageScaling.scaleNone.rawValue, .allowClipping: false]
        case "fill":
            fallthrough
        default:
            return [.imageScaling: NSImageScaling.scaleProportionallyUpOrDown.rawValue, .allowClipping: true]
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("[wallpaper] \(message)\n".utf8))
        exit(1)
    }
}
