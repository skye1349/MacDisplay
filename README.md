# MacDisplay

MacDisplay is a native macOS display control app written from scratch in Swift/AppKit for local personal display management.

The project is currently an early personal-use build. It already provides practical display controls, and the long-term goal is to grow it into a more complete local display manager for external monitors, HiDPI workflows, presets, automation, and hardware controls.

## Features

Implemented now:

- Menu bar app plus a control panel window.
- Active display discovery.
- Per-display current resolution, refresh rate, HiDPI, physical pixel, vendor, model, and serial details.
- Resolution and refresh-rate switching through public CoreGraphics display modes.
- Per-display software dimming overlay.
- Menu bar dimming controls.
- Simple mirror, unmirror, and move-right-of-main actions when multiple displays are connected.
- Per-display presets that store the current display mode and dimming level.
- Experimental one-click HiDPI Display Override install, uninstall, and kit export.
- Experimental virtual HiDPI display creation and mirror-to-real-display workflow.
- Display diagnostics export for troubleshooting display identifiers, framebuffers, and mode lists.
- Automatic refresh when macOS display configuration changes.
- Local app bundle packaging with ad-hoc signing.
- Custom macOS app icon.

Planned next:

- DDC/CI hardware brightness, contrast, volume, and input source controls for supported external monitors.
- Keyboard shortcuts.
- CLI and URL scheme automation.
- Display layout snapshots.
- Safer rollback flow after risky display mode changes.
- Deeper EDID/config override support.
- Picture in Picture/streaming experiments.
- DDC capability detection and per-display hardware control profiles.

## Requirements

- macOS 13 Ventura or newer.
- Xcode Command Line Tools or Xcode.
- Swift toolchain available through `swift`.

Install Command Line Tools on a new Mac:

```sh
xcode-select --install
```

## Install On Another Mac

The most reliable install method is to build and sign the app locally on the target Mac:

```sh
git clone https://github.com/skye1349/MacDisplay.git
cd MacDisplay
Scripts/install.sh
open "$HOME/Applications/MacDisplay.app"
```

`Scripts/install.sh` quits any running MacDisplay process, builds the app, creates `MacDisplay.app`, ad-hoc signs it for local use, deletes the old installed copy, copies the new app to `~/Applications`, removes quarantine metadata if present, and re-registers the app with LaunchServices.

To install somewhere else:

```sh
MACDISPLAY_INSTALL_DIR="/Applications" Scripts/install.sh
```

If `/Applications` is not writable by your user account, use `~/Applications` or copy the app manually after building.

## Downloaded App Builds And Gatekeeper

Release zip files can be created with:

```sh
Scripts/make_release_zip.sh 0.3.1
```

The generated file is placed under `dist/`.

Important: this project does not currently use an Apple Developer ID certificate or Apple notarization. A downloaded `.app` from GitHub may be blocked by Gatekeeper on another computer because public downloads get quarantine metadata. Building with `Scripts/install.sh` on the target Mac is the recommended path until Developer ID signing and notarization are added.

If you choose to use a downloaded release zip, you may need to remove quarantine locally:

```sh
xattr -dr com.apple.quarantine /path/to/MacDisplay.app
open /path/to/MacDisplay.app
```

## Run From Source

```sh
swift run MacDisplay
```

The app appears in the macOS menu bar and opens a control panel window.

## HiDPI Override Workflow

MacDisplay includes an experimental HiDPI Override section. It can directly install a macOS Display Override for the selected monitor, using an administrator prompt, so you do not need to manually copy plist files.

This is the part meant for the M1 Pro + Samsung 57-inch Neo G9 use case: it tries to make macOS expose extra HiDPI scale resolutions for the monitor.

On the target Mac:

1. Open MacDisplay.
2. Select the external monitor.
3. Check the current framebuffer shown in the Resolution details.
4. In `HiDPI Override`, enter the target framebuffer.
5. Click `Install HiDPI Override`.
6. Approve the administrator prompt.
7. Restart macOS and check System Settings > Displays.

MacDisplay writes the override to:

```text
/Library/Displays/Contents/Resources/Overrides/DisplayVendorID-*/DisplayProductID-*
```

It also enables macOS display resolution options with:

```sh
defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool true
```

For a Samsung 57-inch Neo G9, the most important target to try is:

```text
7680 x 2160
```

That creates a baseline mode that should look like:

```text
3840 x 1080 HiDPI
```

If your USB-C to HDMI cable or adapter only lets macOS see a lower framebuffer, the override may not be enough. In that case, click `Export Report` from the HiDPI section and check whether macOS sees `7680x2160` anywhere in the available mode list. If it does not, the cable, adapter, GPU link mode, DSC, HDMI, or DisplayPort bandwidth is probably the first bottleneck.

To undo an installed override:

1. Select the same display in MacDisplay.
2. Click `Remove Override`.
3. Approve the administrator prompt.
4. Restart macOS.

`Export Kit` is still available for a manual backup workflow. It creates a folder with `install.sh`, `uninstall.sh`, the generated plist, and a display report.

## Virtual HiDPI Mirror Workflow

MacDisplay also includes an experimental virtual-display path for displays where a direct Display Override is not enough.

On the target Mac:

1. Open MacDisplay.
2. Select the real external monitor.
3. In `HiDPI Override`, enter the target framebuffer.
4. For Samsung 57-inch Neo G9 testing, start with `7680 x 2160`.
5. Click `Create Virtual HiDPI Mirror`.

MacDisplay creates a virtual HiDPI screen with a logical desktop that is half of the target framebuffer, then mirrors the real monitor to that virtual screen. For `7680 x 2160`, the virtual screen should appear as `3840 x 1080 HiDPI`.

To undo this path, click `Remove Virtual Mirror` or quit MacDisplay. The virtual display exists only while MacDisplay keeps it alive.

This virtual-display implementation uses macOS `CGVirtualDisplay` runtime classes that Apple ships but does not document as stable public API. It is useful for a personal local app, but it can change across macOS releases.

## Build An App Bundle

```sh
Scripts/package_app.sh
open build/MacDisplay.app
```

The packaging script:

- Builds a release binary.
- Creates `build/MacDisplay.app`.
- Ad-hoc signs the app bundle for local use.
- Attempts a universal Apple Silicon + Intel build by building both architectures and combining them with `lipo`.
- Falls back to a native-architecture build when only Command Line Tools are installed.

## Publish A Public GitHub Repo

Create an empty public GitHub repository named `MacDisplay`, then run:

```sh
git remote add origin git@github.com:skye1349/MacDisplay.git
git push -u origin main
```

To publish an initial release after pushing:

```sh
git tag v0.3.1
git push origin v0.3.1
Scripts/make_release_zip.sh 0.3.1
```

Then upload `dist/MacDisplay-0.3.1-macOS.zip` to the GitHub release.

This repository also includes a GitHub Actions workflow that builds the project and uploads a zipped app artifact on pushes, pull requests, manual runs, and published releases.

## Project Layout

```text
.
├── Package.swift
├── Resources/MacDisplayIcon.png
├── Sources/MacDisplay/main.swift
├── Sources/VirtualDisplayBridge/
├── Scripts/install.sh
├── Scripts/package_app.sh
├── Scripts/make_release_zip.sh
├── .github/workflows/build.yml
└── README.md
```

## Current Limitations

- Hardware DDC/CI controls are not implemented yet.
- HiDPI support now includes Display Override install/uninstall and an experimental virtual HiDPI mirror.
- Display Override changes require a restart and may still be rejected by macOS on some Apple Silicon configurations.
- Virtual HiDPI mirror support depends on undocumented macOS runtime classes and may break on future macOS versions.
- Picture in Picture and local streaming are not implemented yet.
- App bundles are ad-hoc signed, not Developer ID signed or notarized.
- Some display mode changes can still be rejected by macOS, especially during fullscreen apps, mirroring, or unsupported monitor states.
- Display Override files cannot overcome physical cable, adapter, GPU, DSC, HDMI, or DisplayPort bandwidth limits.

## Safety Notes

Display management can affect your active screen configuration. Use caution when switching modes, mirroring displays, or experimenting with external monitors. A future version should add rollback timers before more aggressive display changes are enabled.

## License

MIT. See [LICENSE](LICENSE).
