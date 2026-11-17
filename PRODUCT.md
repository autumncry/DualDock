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
- User confirmed the HTML reference's simplified size model: size, density and length are primary controls; precise overrides live under advanced settings, with existing configuration preserved.

## Brand Commitments

Name: DualDock. Slogan: 应用有序收纳，Dock 多屏同在。 Keep the existing colored overlapping-display app icon and matching monochrome menu-bar icon. Public MIT project at https://github.com/autumncry/DualDock.

- User approved the November 17 redesign: compact left-aligned navigation, one fixed-zoom preview above aligned rows, full About content retained.
- First-launch Apple verification guidance must remain in both READMEs and every DMG until Developer ID distribution signing and notarization are established; see CONTRIBUTING.md.

## Evidence on Hand

Current SwiftUI/AppKit source; user-provided sizing prototype in Downloads; existing 2.2.2 critique at .impeccable/critique/2026-11-16T09-25-07Z__sources-dualdock-settingsview-swift.md. Tests distinguish injected/hidden component evidence from actual desktop interaction.

## Product Principles

- Settings show the result of a choice rather than requiring long explanatory paragraphs.
- Frequent controls stay visible; precision settings expand on demand.
- Preserve user choices and provide understandable recovery.
- Keep effects proportional, subdued and responsive; accessibility preferences take priority.
