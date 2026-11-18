# Product

<!-- impeccable:product-schema 1 -->

## Platform

Native macOS 14+ desktop application. This is a SwiftUI/AppKit application, not a web wrapper or an iOS app.

## Users

Personal MacBook user with external displays, many running apps and task-based application groups. Chinese is the primary UI language.

## Product Purpose

Keep apps organized in expandable groups and make the same Dock available on every display. The product must remain quick to navigate and predictable while resizing, switching windows and using fullscreen applications.

## Capabilities and Constraints

- Shared apps/groups/order; per-display edge position (bottom, top, left, right).
- Manual/native-adaptive sizing and optional cross-display size synchronization. Preserve existing configuration when upgrading.
- Window previews and close controls; selected-window menus and repeatable minimize/restore, excluding fullscreen/maximized targets.
- Fullscreen Dock starts hidden and should reveal at its configured edge. Native system Dock behavior requires separate real-world verification.
- Settings remain native, support keyboard navigation and Light/Dark appearance, and keep permission and recovery actions discoverable.
- The current primary sizing controls are size, unified 0–100 icon spacing, length and position. Spacing replaces density and the duplicate advanced gap control; precise padding, height and length values remain under advanced settings.
- Visual spacing uses artwork bounds without cropping, enlarging or stretching icon bitmaps. Zero joins neighboring content bounds; 100 separates them by the mean visible size of the pair along the layout axis. Existing layouts stay on their legacy path until an explicit new-spacing/preset/reset choice.
- Settings use five fixed system-app examples that respond to controls, independent of the user's running applications and pins. Horizontal and vertical example scales are fixed at 75% and 45%; the example makes no actual-Dock-size claim.
- Advanced settings expand from the complete 44 pt header button, including its chevron, title and whitespace.
- General offers opt-in startup after macOS login through SMAppService.mainApp. System registration/approval state is authoritative; merely viewing settings must not enable it.

## Brand Commitments

Name: DualDock. Slogan: 应用有序收纳，Dock 多屏同在。 Keep the existing colored overlapping-display app icon and matching monochrome menu-bar icon. Public MIT project at https://github.com/autumncry/DualDock.

- User approved compact left-aligned navigation and aligned settings rows, then selected a responsive fixed-app layout example and unified spacing. Keep the full About content and the existing visual identity.
- First-launch Apple verification guidance must remain in both READMEs and every DMG until Developer ID distribution signing and notarization are established; see CONTRIBUTING.md.

## Evidence on Hand

Current SwiftUI/AppKit source; user-provided sizing prototype in Downloads; existing 2.2.2 critique at .impeccable/critique/2026-11-16T09-25-07Z__sources-dualdock-settingsview-swift.md. Tests distinguish injected/hidden component evidence from actual desktop interaction, VoiceOver and a real logout/login cycle. The product requirements here do not imply those acceptance runs have occurred.

## Product Principles

- Settings show the result of a choice rather than requiring long explanatory paragraphs.
- Frequent controls stay visible; precision settings expand on demand.
- Preserve user choices and provide understandable recovery.
- Keep effects proportional, subdued and responsive; accessibility preferences take priority.
