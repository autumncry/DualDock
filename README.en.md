<div align="center">

<img src="Resources/AppIcon.iconset/icon_128x128@2x.png" width="112" alt="DualDock icon">

# DualDock

### One workspace, across your screens.

A native macOS Dock for multiple displays. Organize related apps into horizontal groups,
preview their windows, and keep the same layout on your MacBook and external monitors.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](#requirements)
[![Apple Silicon](https://img.shields.io/badge/Apple_Silicon-arm64-orange)](https://github.com/autumncry/DualDock/releases/latest)
[![Release](https://img.shields.io/github/v/release/autumncry/DualDock)](https://github.com/autumncry/DualDock/releases/latest)

[简体中文](README.md) &nbsp;·&nbsp; **English**

[**Download**](https://github.com/autumncry/DualDock/releases/latest) &nbsp;·&nbsp; [**Build from source**](#building-from-source) &nbsp;·&nbsp; [**Report an issue**](https://github.com/autumncry/DualDock/issues)

</div>

<div align="center">
  <img src="docs/images/dualdock-overview.png" width="1000" alt="DualDock example layout with grouped apps, a window preview, and the main Dock">
  <p><sub>Example layout rendered with actual AppKit components and sample content.</sub></p>
</div>

## Why DualDock

When your workspace extends beyond a laptop, your everyday apps should stay within reach. DualDock focuses on multiple displays and app groups, keeping a familiar starting point on each screen.

- **A shared layout.** Every extended display gets a Dock, with the same apps, groups, order, and display mode.
- **Apps organized around your work.** Group related apps, open them in a horizontal strip, and rearrange members whenever you need.
- **Source you can change.** Built with Swift, AppKit, and SwiftUI, and released under the MIT license.

## Features

### A Dock on each display

Use DualDock on your MacBook display and external monitors at the same time. It responds to display changes; mirrored displays follow the image duplicated by macOS. When an app enters full screen, DualDock hides only on that display.

### App groups and drag-and-drop

Drag apps in from Finder or add them through Settings. Drop near an icon's edge to reorder; hold over its center for about 0.6 seconds before dropping to create an app group.

Click a folder icon to expand its members horizontally. Reorder apps within a group, move them back to the main Dock, or use the context menu to rename or dissolve a group. The first launch imports pinned apps from the system Dock. DualDock then maintains its own layout; re-importing adds missing apps while preserving existing groups.

### Preview, switch, and close windows

Hover over a running app to see window thumbnails. Click a thumbnail to switch to that window, or use the **×** in its upper-right corner to request closing it. The original app handles any unsaved-changes confirmation. Closing dismisses the current preview; the next hover reads the window list again.

Windows without a usable screenshot are omitted. Screenshots are processed in local memory, without being saved to disk or uploaded.

### Two display modes

- **Pinned apps and groups + running apps:** keep your usual shortcuts alongside running apps that are not pinned.
- **Running apps only:** show regular running apps in a flat row, including hidden or minimized apps and apps on other Spaces. Switching back restores the saved groups and order.

Change the mode in Settings; every display updates together.

### Independent dimensions and smooth magnification

Adjust Dock height and width with separate continuous sliders. Icon spacing changes the density inside the bar. Nearby icons magnify gradually around the pointer, with an adjustable strength and an on/off switch, while the backdrop stays fixed. Overflow can be scrolled horizontally without a visible scrollbar.

The optional automatic-width mode adjusts the bar as pinned apps, collapsed groups, and running apps are added or removed. It disables the manual width slider while leaving height adjustable. Turning it off restores the last manual width. Icon spacing still affects only the contents, and automatic width respects the shared display limit. It is off by default, so upgrading preserves your existing fixed-width choice.

All displays share size limits: the maximum width is the narrowest display's effective width, and the maximum backdrop height is **12%** of the shortest display's effective height. Dimensions use macOS logical points after display scaling. Connecting a smaller display constrains the rendered size without overwriting your preference, so it can be restored after disconnection.

### More details

- **Notification badges:** individual apps show the labels supplied by the system; a group shows a red **!** when a member has an unread indicator. A global switch disables badges. Only badge state is read, not notification text. Some apps may not provide a usable label.
- **System Dock management:** optionally hide the system Dock. The preferences changed by DualDock are restored on normal exit, or recovered at the next launch after an interruption; later manual changes are preserved. A manual restore command is also available in the menu bar.
- **Quick access to Settings:** right-click a blank area of the Dock, or use the overlapping-rectangles icon in the menu bar.
- **Local configuration:** groups, order, and preferences live in `~/Library/Application Support/DualDock/`, with migration backups created when needed.

## Download and install

Download the latest `DualDock-<version>-arm64.dmg` and optional SHA-256 checksum from [Releases](https://github.com/autumncry/DualDock/releases/latest).

1. Open the DMG and drag `DualDock.app` into `Applications`.
2. Launch DualDock and grant **Screen Recording** and **Accessibility** access in its Permissions settings.
3. Choose the display mode and dimensions in Settings, then organize app groups with drag-and-drop. Hiding the system Dock is off by default and can be enabled when desired.

Screen Recording provides window thumbnails; Accessibility identifies, activates, and closes windows. If a permission change does not take effect, quit and reopen DualDock. To update, download the new DMG and replace the app; your local configuration is retained.

> [!NOTE]
> The current release targets Apple Silicon and uses an ad-hoc signature for personal use. It is not notarized by Apple. If macOS blocks the first launch, consult the [installation notes](docs/installation.txt) (Chinese).

## Building from source

```sh
git clone https://github.com/autumncry/DualDock.git
cd DualDock
./script/build_and_run.sh
```

This is a Swift Package Manager project; no Xcode project needs to be created. The script first asks an existing DualDock process to quit normally, then builds, bundles, locally signs, and launches `dist/DualDock.app`.

### Requirements

- Runtime: macOS 14 or later. The distributed DMG is built for Apple Silicon (arm64).
- The current app interface is in Simplified Chinese.
- Build tools: Xcode or command-line tools supporting Swift tools version 5.9 and the corresponding macOS SDK.

### Build and validation commands

```sh
./script/build_and_run.sh --build-only # Build the .app without launching it
./script/build_and_run.sh --verify     # Build, launch, and check the process
./script/package_dmg.sh               # Release build, DMG, and SHA-256
swift test -c release                 # Model, layout, and window-policy tests
./script/check_dock_views.sh          # Hidden AppKit component checks
./script/check_badges.sh              # Badge reads and asynchronous state checks
./script/check_system_dock.sh         # Isolated system Dock recovery checks
```

The build-and-run script also supports `--logs`, `--telemetry`, and `--debug`. Test instances can use the `.app` launch arguments `--config-dir <directory>` for isolated configuration and `--diagnostics <JSON path>` for layout diagnostics.

## Documentation

- [Installation notes](docs/installation.txt) (Chinese)
- [Validation records and known limitations](docs/validation.md) (Chinese)
- [Implementation research and initial design](docs/superpowers/specs/2026-11-09-dualdock-design.md) (Chinese)

Window identity matching and full-screen detection use optional macOS private interfaces with fallbacks. macOS updates may require adjustments. Preview and window-control behavior for minimized windows, other Spaces, and protected content depends on the target app and macOS.

## Feedback and contributions

Use [Issues](https://github.com/autumncry/DualDock/issues) for bug reports and suggestions. Please include the DualDock and macOS versions, display setup, and reproduction steps; redact private content before sharing screenshots. Pull requests are welcome.

The README presentation takes inspiration from [Docky](https://github.com/josejuanqm/docky). The text, branding, and demo content here are specific to DualDock.

## Dependencies

No third-party Swift Package dependencies. DualDock primarily uses system frameworks including AppKit, SwiftUI, ScreenCaptureKit, Accessibility, and CoreGraphics.

## License

[MIT License](LICENSE). Copyright © 2026 Ronny Cao.
