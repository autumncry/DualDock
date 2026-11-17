<div align="center">

<img src="Resources/AppIcon.iconset/icon_128x128@2x.png" width="112" alt="DualDock icon">

# DualDock

### Apps neatly organized. A Dock on every display.

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

Use DualDock on your MacBook display and external monitors at the same time. It responds to display changes; mirrored displays follow the image duplicated by macOS. When an app enters full screen, DualDock hides on that display. Dwell at its edge to reveal it; moving away hides it again.

### App groups and drag-and-drop

Drag apps in from Finder or add them through Settings. Drop near an icon's edge to reorder; hold over its center for about 0.6 seconds before dropping to create an app group.

Click a folder icon to expand its members horizontally. Reorder apps within a group, move them back to the main Dock, or use the context menu to rename or dissolve a group. The first launch imports pinned apps from the system Dock. DualDock then maintains its own layout; re-importing adds missing apps while preserving existing groups.

### Preview, switch, and close windows

Hover over a running app to see window thumbnails. Click a thumbnail to switch to that window, or use the **×** in its upper-right corner to request closing it. The original app handles any unsaved-changes confirmation. Closing dismisses the current preview; the next hover reads the window list again.

Windows without a usable screenshot are omitted. Screenshots are processed in local memory, without being saved to disk or uploaded.

### Choose a window and toggle it repeatedly

Right-click an app icon to list its actionable windows, including minimized ones. A checkmark identifies the selected target. Selecting a window brings it forward and keeps it as the target for subsequent icon clicks during this session.

- Background window: bring it forward first.
- Ordinary foreground window: minimize; click again to restore.
- Fullscreen or maximized window: activate without minimizing.

Window actions use the original app's native controls. Animation follows macOS and the app. Failed reads do not silently select and minimize another window. Accessibility permission is required.

### Two display modes

- **Pinned apps and groups + running apps:** keep your usual shortcuts alongside running apps that are not pinned.
- **Running apps only:** show regular running apps in a flat row, including hidden or minimized apps and apps on other Spaces. Switching back restores the saved groups and order.

Change the mode in Settings; every display updates together.

### Fully adaptive system Dock sizing

Choose “跟随系统 Dock” in Appearance & Size to follow the system Dock's base icon size, bar height, icon spacing, end padding, and magnification. The bar grows or shrinks with the app count and stays centered on its display edge. Hovering changes the icons while keeping the backdrop fixed.

Adaptive mode hides manual size and magnification controls and disables edge resizing. Turning it off restores the previous manual configuration. Users who enabled automatic width in an earlier version are migrated to fully adaptive sizing.

Dimensions are read from system preferences and Accessibility geometry without changing them. Temporary read failures retain the latest valid measurement; compatible values are used when there is no prior measurement. Accessibility bounds can differ from actual system rendering, so pixel-identical results are not guaranteed.

### Simple sizing with a live preview

Three primary controls cover everyday changes:

- **Size:** set the icon size; the default bar height is calculated automatically.
- **Density:** continuously adjust automatic spacing and end padding.
- **Length:** fit the content, fill the available edge, or use a fixed screen percentage.

Advanced settings expose spacing, padding, minimum height, fixed length percentage, alignment, and optional icon shrinking before scrolling. Manual overrides take priority and can be reset individually. Overflow scrolls without a visible scrollbar. The preview uses production geometry at a fixed 50%, 75%, or 100% zoom, so resizing remains visible instead of being canceled by auto-fit. Scroll to see overflow; numeric fields support precise adjustments.

Upgrades preserve the existing layout as advanced overrides. Restore linked spacing/padding or reset recommended sizing for the current display scope whenever desired.

### Per-display position and edge resizing

Choose **bottom, top, left, or right** independently for each display using a clickable display diagram. Icons stay upright, groups expand horizontally, and popups open inward.

Drag the inward edge to change height and scale icons, either endpoint to change length, or an inward corner to scale both axes. In content-fit mode, endpoint dragging redefines end padding.

“同步各屏尺寸” applies shared sizing within the range available to every display; turn it off for independent sizing. Re-enabling adopts the currently selected display's settings. Height remains capped at **12%** of the applicable short edge, and length at the available edge. Values use macOS logical points.

### Shape the magnification curve

In manual mode, the Interaction page provides two continuous sliders:

- **Peak size (放大峰值):** the maximum size of the icon under the pointer.
- **Influence range (联动范围):** how many neighboring icons join the wave. Narrowing it reduces magnification around the focused icon.

A curve preview updates with the sliders while the Dock backdrop stays fixed. Both controls are disabled when magnification is off. Fully adaptive mode continues to follow the system Dock and hides the manual curve controls. Your previous manual peak is preserved, and the new range initially matches the earlier behavior.

### Hide for maximized windows

Enable “最大化窗口时隐藏 Dock” in Interaction to hide a display's Dock when a window fills its available workspace. Pause the pointer at that edge to reveal it. Moving an ordinary window down over the Dock does not trigger hiding. For a top Dock, the activation edge sits below the menu bar.

The Dock stays available while you use a group, preview, context menu, or drag operation, then hides after you leave. Fullscreen apps also support edge reveal; fullscreen auto-hiding is independent of this toggle. The maximized-window option is off by default and does not resize other apps' windows.

### Sidebar settings

Settings use a category sidebar with configuration on the right: **General, Appearance & Size, Displays & Position, Interaction, Permissions, Help, and About**. The window can be resized and minimized. About includes the version, MIT license, and project links. The app interface remains in Simplified Chinese.

<img src="docs/images/dualdock-settings.png" width="1000" alt="Native DualDock settings with a live preview and Size, Density, and Length controls">

<sub>Native settings capture using an isolated example configuration.</sub>

### More details

- **Notification badges:** individual apps show the labels supplied by the system; a group shows a red **!** when a member has an unread indicator. A global switch disables badges. Only badge state is read, not notification text. Some apps may not provide a usable label.
- **System Dock management:** optionally hide the system Dock. The preferences changed by DualDock are restored on normal exit, or recovered at the next launch after an interruption; later manual changes are preserved. A manual restore command is also available in the menu bar.
- **Quick access to Settings:** right-click a blank area of the Dock, or use the overlapping-rectangles icon in the menu bar.
- **Local configuration:** groups, order, and preferences live in `~/Library/Application Support/DualDock/`, with migration backups created when needed.

## Download and install

Download the latest `DualDock-<version>-arm64.dmg` and optional SHA-256 checksum from [Releases](https://github.com/autumncry/DualDock/releases/latest).

1. Open the DMG and drag `DualDock.app` into `Applications`.
2. Launch DualDock and grant **Screen Recording** and **Accessibility** access in its Permissions settings.
3. Choose the display mode, adaptive or manual sizing, and each display’s position in Settings, then organize app groups with drag-and-drop. Hiding the system Dock is off by default and can be enabled when desired.

Screen Recording provides window thumbnails; Accessibility identifies, activates, and closes windows, and reads system Dock layout and badge information. If a permission change does not take effect, quit and reopen DualDock. To update, download the new DMG and replace the app; your local configuration is retained.

> [!NOTE]
> The current release targets Apple Silicon and uses an ad-hoc signature for personal use. It is not notarized by Apple. If macOS blocks the first launch, consult the [installation notes](docs/installation.txt) (Chinese).

<!-- first-launch-guidance:start -->
### First launch: Apple cannot verify the app or developer

The current release is not Apple Developer ID signed or notarized. macOS may say that Apple cannot verify DualDock or that the developer cannot be verified. **Proceed only if you obtained the app from this project's [official Releases](https://github.com/autumncry/DualDock/releases/latest), trust its source, have checked that it was not tampered with, and choose to open it.** This approval applies to this app:

1. After copying DualDock to Applications, try opening it once, then dismiss the verification alert.
2. Open **System Settings → Privacy & Security**, scroll to Security, and find the blocked DualDock entry. Click **Open Anyway**; some macOS versions first show an **Open** entry.
3. Authenticate with your login password or Touch ID when requested, then confirm **Open**. You can subsequently launch the app normally.
4. If the button is missing, try opening DualDock from Applications again, then return to this page. Apple says the option is available for about one hour after an attempted launch. On a managed Mac, contact your administrator if the option is restricted.

If the alert says the app **will damage your computer**, contains detected malware, or **is damaged**, stop opening it. Download it again from official Releases and compare the SHA-256 checksum; [report the issue](https://github.com/autumncry/DualDock/issues) if it persists. These alerts differ from an unverified developer and should not be approved using the steps above. Do not disable system-wide security protections.

Apple guidance: [Safely open apps on your Mac](https://support.apple.com/en-us/102445) and [the per-app approval and its time limit](https://support.apple.com/en-gb/guide/mac-help/mh40617/mac).
<!-- first-launch-guidance:end -->

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
./script/check_four_edge_views.sh     # Four-edge layout, scroll, and input routing
./script/check_display_sizing_store.sh # Per-display sizing, sync, and resize commits
./script/check_native_dock_metrics.sh # Native Dock measurement and fallback checks
./script/check_dock_animation.sh      # Hover redraw, layout, and badge regressions
./script/check_terminal_hover.sh      # Endpoint magnification, exit, and scroll stability
./script/check_dock_visibility.sh     # Visibility timing and lifecycle checks
./script/check_fullscreen_fallback.sh # Async fullscreen fallback and stale results
./script/check_window_obstruction.sh  # Obstruction reads, caching, and coalescing
./script/check_application_activation.sh # App and helper-process activation routing
./script/check_badges.sh              # Badge reads and asynchronous state checks
./script/check_system_dock.sh         # Isolated system Dock recovery checks
```

The build-and-run script also supports `--logs`, `--telemetry`, and `--debug`. Test instances can use the `.app` launch arguments `--config-dir <directory>` for isolated configuration and `--diagnostics <JSON path>` for layout diagnostics.

## Documentation

- [Installation notes](docs/installation.txt) (Chinese)
- [Validation records and known limitations](docs/validation.md) (Chinese)
- [Implementation research and initial design](docs/superpowers/specs/2026-11-09-dualdock-design.md) (Chinese)
- [2.0 adaptive sizing, per-display positions, and resizing](docs/superpowers/specs/2026-11-10-four-edge-adaptive.md) (Chinese)
- [2.1 visibility, activation, and animation changes](docs/superpowers/specs/2026-11-11-visibility-and-motion.md) (Chinese)

Window identity matching and full-screen detection use optional macOS private interfaces with fallbacks. macOS updates may require adjustments. Preview and window-control behavior for minimized windows, other Spaces, and protected content depends on the target app and macOS.

## Feedback and contributions

Use [Issues](https://github.com/autumncry/DualDock/issues) for bug reports and suggestions. Please include the DualDock and macOS versions, display setup, and reproduction steps; redact private content before sharing screenshots. Pull requests are welcome.

The README presentation takes inspiration from [Docky](https://github.com/josejuanqm/docky). The text, branding, and demo content here are specific to DualDock.

## Dependencies

No third-party Swift Package dependencies. DualDock primarily uses system frameworks including AppKit, SwiftUI, ScreenCaptureKit, Accessibility, and CoreGraphics.

## License

[MIT License](LICENSE). Copyright © 2026 Ronny Cao.
