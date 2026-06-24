# Desktop wallpaper

Set the desktop background to a static image for the logged-in GUI user(s):

```swift
Sys(.wallpaper("/Users/Shared/standard.png"))
Sys(.wallpaper("/Users/Shared/standard.png", scaling: .fit))  // .fill (default) | .fit | .stretch | .center
```

It is a `Sys` setting like `.hostname`/`.pmset`: mount-only (declaring it sets the wallpaper;
removing the declaration does **not** revert it), checked and re-applied on the drift loop.

## How it works

- **Runs as the user, not the daemon.** The wallpaper is a per-GUI-user setting, and
  `NSWorkspace` needs a WindowServer session that a root `LaunchDaemon` lacks. So Astrolabe
  re-execs its own binary as each logged-in user via `launchctl asuser` (a hidden `__wallpaper`
  subcommand handled by `WallpaperHelper`), which calls `NSWorkspace.setDesktopImageURL` over
  every `NSScreen`. No SIP change and no TCC permission are required.
- **Content-addressed.** The declared image is copied to
  `/Library/Application Support/Astrolabe/Wallpapers/<sha256>.<ext>` (world-readable) and set
  from there. Because the staged filename *is* the content hash, the drift check is an exact
  content comparison, and macOS always refreshes when the image bytes change (re-versioning the
  same source path produces a new staged file → a new URL).
- **Drift.** Every loop, `check()` reads the current wallpaper back via `NSWorkspace` and
  re-applies if it differs from the staged path. If no user is logged in, it's a no-op.

## Requirements & notes

- The source image must exist at an absolute path. Deploy it separately (e.g. via a `.pkg` or
  Prism); use `.priority()` if it's placed by another node that must run first. A missing image
  surfaces a clear error and the loop retries once it appears.
- A wallpaper changed by a *user* in **System Settings** may not be detected (the `NSWorkspace`
  read can be stale on Sonoma/Sequoia) — not a concern for headless farm machines.
