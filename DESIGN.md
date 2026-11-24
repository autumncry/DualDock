---
name: DualDock
description: Quiet native macOS settings for a multi-display Dock.
typography:
  page-title:
    fontFamily: "system-ui"
    fontSize: "18pt"
    fontWeight: 600
  section-title:
    fontFamily: "system-ui"
    fontSize: "13pt"
    fontWeight: 600
  control-label:
    fontFamily: "system-ui"
    fontSize: "13pt"
    fontWeight: 500
  body:
    fontFamily: "system-ui"
    fontSize: "13pt"
    fontWeight: 400
  supporting:
    fontFamily: "system-ui"
    fontSize: "12pt"
    fontWeight: 400
  caption:
    fontFamily: "system-ui"
    fontSize: "12pt"
    fontWeight: 400
  metric:
    fontFamily: "system-ui"
    fontSize: "12pt"
    fontWeight: 500
rounded:
  group: "10pt"
  display-diagram: "9pt"
  message: "10pt"
spacing:
  label-control: "8pt"
  inline: "16pt"
  group-padding: "7pt 9pt"
  columns: "20pt"
  detail-sections: "12pt"
  page-inset: "22pt"
components:
  page-heading:
    typography: "{typography.page-title}"
  settings-group:
    rounded: "{rounded.group}"
    padding: "{spacing.group-padding}"
  sidebar:
    width: "190pt"
    typography: "{typography.body}"
  numeric-field:
    width: "56pt"
  primary-controls:
    labelColumn: "112pt"
    columnGap: "14pt"
    valueColumn: "81pt"
    minimumRowHeight: "45pt"
  dock-preview:
    horizontalHeight: "108–180pt"
    verticalHeight: "174pt"
    rounded: "{rounded.group}"
    horizontalScale: 0.75
    verticalScale: 0.45
  advanced-header:
    minimumHeight: "44pt"
---

# Design System: DualDock

Approved direction: quiet native macOS settings, based on the 2026-11-17 HTML draft. The draft is a layout reference; the shipping app uses SwiftUI/AppKit, system fonts, native controls and semantic colors. Keep the colored overlapping-display app icon, matching menu-bar identity and slogan “应用有序收纳，Dock 多屏同在。”.

## Navigation and hierarchy

Settings opens at 820 × 560 pt including its toolbar. The frame is independent of page selection, language, and disclosure states. Keep the user’s chosen frame across navigation. Related sections in Interaction, General, and the Dock display options flow down one scrollable form. Sidebar selections scroll to a section. Appearance, Group Appearance, Help, and About each have their own detail view. An AppKit preferences toolbar shows Dock, Interaction, General, and Support with native icons and labels. Each category remembers its last selected page during the session. A 190 pt sidebar uses a native source list and a search field. Return opens the first matching page, Escape clears the search, and Command-F focuses it. Search includes both interface languages. The detail pane uses an accent-colored symbol, an 18 pt semibold heading and grouped native controls. Display scope stays next to the sizing page heading.


## Surfaces and typography

`Font.system` and SF Symbols are authoritative. Do not substitute the Figma draft's Noto fallback in the native app. Primary/secondary semantic text adapts to Light/Dark. The main surface is `controlBackgroundColor`, sidebar uses a system material, and settings groups use native GroupBox styling. No sampled screenshot hex palette or decorative shadows.

Option labels are 13 pt medium, body text is 13 pt and supporting text is 12 pt. Changing values use monospaced digits and an adjacent unit. Native controls own their focus, hover, disabled and pressed states. Keep long explanatory text wrapping rather than truncating it.

## Appearance and sizing

Screen picker and synchronization share the upper-right header. The system/custom selector and small presets precede one shallow layout example. Below it, rows align labels, flexible controls and right-side values. Frequent choices are 大小、图标间距、长度、位置. The unified 0–100 spacing control replaces 疏密 and the duplicate advanced gap control. Padding, minimum height, fixed length, alignment and overflow choices remain in one advanced group.

The horizontal layout example measures 108–180 pt according to the sample height. The vertical example sits beside the controls in a 120 pt wide, 174 pt tall column. Both include a compact header. It always contains the same five sample apps: Mail, Calendar, Notes, Safari and Music. It does not read the user's running-app list, pins, groups or live Dock presentation. The title “布局示例” identifies the sample. Size, spacing, length, position, padding and height update the example from the selected preferences. System-follow mode uses read-only native metrics.

The example uses fixed 75% scale horizontally and 45% vertically. These orientation-specific constants are never recalculated to fit a size-slider change, and there is no zoom menu or “actual size” readout. Virtual edge lengths are 900 pt horizontally and 600 pt vertically; a saved legacy absolute screen length is not copied into this illustrative layout. Overflow pans without a visible scrollbar. The surface depicts base size rather than hover magnification, supports all four edges and updates in place.

New spacing is measured between visible artwork bounds while the original square bitmap canvas, scale, aspect and pixels remain unchanged. At 0, adjacent artwork bounding boxes meet along the ordering axis. At 100, the gap equals the mean visible main-axis extent of the adjacent pair; intermediate values interpolate proportionally. This describes bounding boxes, not guaranteed contact between every irregular silhouette. Artwork metadata is cached rather than scanned during each animation frame. Transparent drawing canvases may overlap; hit ownership, indicators and badges use the corresponding content geometry.

Opening settings does not rewrite a legacy layout. Existing density/gap values remain effective until the user explicitly edits the new spacing control, chooses a new preset or resets sizing. The slider presents the legacy layout's approximate visual-equivalent percentage. In the new mode the requested ratio remains authoritative: overflow does not secretly compress the gaps, and uniform-distribution alignment cannot override the ratio. Optional shrinking scales the optical row proportionally and scrolling handles remaining overflow. Native-follow sizing retains native behavior.

The advanced header is one native button with a minimum height of 44 pt. Chevron, title, status text and the intervening whitespace toggle the same expanded state exactly once. It retains native keyboard activation and explicit expanded/collapsed accessibility text; this design contract does not assert a completed VoiceOver or physical-keyboard acceptance run.

Synchronization uses the currently selected screen as source. Positions remain per-screen. Reset actions say “恢复所有屏幕尺寸” or “恢复此屏幕尺寸”; they never silently clear app groups or positions. Existing manual padding and height remain visible and individually resettable.

## About and supporting pages

About uses a 56 pt icon, 22 pt product name, the full slogan and native macOS descriptor. Preserve version/build, MIT, author/copyright, visible project URL, releases, feedback and Star support. These are aligned rows, not a marketing hero. Other pages retain actual production features and permission/recovery actions; prototype-only controls must not enter production.

General includes an opt-in “登录时启动” control backed by `SMAppService.mainApp`. Reading or opening settings must not register the app. ServiceManagement status is the source of truth: only enabled is shown as on; pending system approval stays off with an explanation, an “打开系统登录项” action and cancellation. Registration errors must remain visible rather than being saved as a successful local preference. This starts the app after user login, not before the macOS session exists.

## Verification

Capture actual native views in isolated fixtures at default and compact widths, Light/Dark, all categories, native/manual sizing, old overrides, no-display and overflow states. Include fixed samples across different real-app counts, spacing endpoints on all four edges, and expanded/collapsed headers. Use WindowServer captures of owned nonactivating windows for materials; view-cache images alone are insufficient.

Separate controlled geometry tests, retained-view rendering, native event dispatch and injected login-service state checks from physical-mouse, VoiceOver and actual-login acceptance. The fixed-sample geometry has focused checks for 0/7/40 real fixture apps and responsive controls. Login tests must not register or unregister the real app unless that action is explicitly authorized. Record the exact evidence and remaining limits for each release; this document's source update itself is not fresh desktop or login validation.
