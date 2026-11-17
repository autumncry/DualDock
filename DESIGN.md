---
name: DualDock
description: Quiet native macOS settings for a multi-display Dock.
typography:
  page-title:
    fontFamily: "system-ui"
    fontSize: "21pt"
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
    fontSize: "11pt"
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
  group-padding: "20pt"
  columns: "20pt"
  detail-sections: "18pt"
  page-inset: "30pt"
components:
  page-heading:
    typography: "{typography.page-title}"
  settings-group:
    rounded: "{rounded.group}"
    padding: "{spacing.group-padding}"
  sidebar:
    width: "176pt"
    typography: "{typography.body}"
  numeric-field:
    width: "56pt"
  primary-controls:
    labelColumn: "108pt"
    columnGap: "20pt"
    valueColumn: "81pt"
    minimumRowHeight: "54pt"
  dock-preview:
    height: "190pt"
    rounded: "{rounded.group}"
---

# Design System: DualDock

Approved direction: quiet native macOS settings, based on the 2026-11-17 HTML draft. The draft is a layout reference; the shipping app uses SwiftUI/AppKit, system fonts, native controls and semantic colors. Keep the colored overlapping-display app icon, matching menu-bar identity and slogan “应用有序收纳，Dock 多屏同在。”.

## Navigation and hierarchy

The window opens at 1060 × 760 pt of content. AppKit minimum frame is 820 × 580 pt; root content minimum is 820 × 540 pt. The sidebar is 176 pt, with 34 pt rows, consistently sized symbol slots and left-aligned 13 pt labels. Selection uses a subtle accent tint, not a large solid block. Native buttons retain focus and activation; up/down keys move between categories. Selected state is exposed to accessibility.

Use a 21 pt semibold page heading and 12 pt secondary purpose sentence. The title remains above the scrolling content. Seven categories stay intact: 通用、外观与尺寸、屏幕与位置、交互、权限、使用方法、关于. Switching categories returns to the top. Screen scope appears only on the appearance page; screen position has its own per-display controls.

## Surfaces and typography

`Font.system` and SF Symbols are authoritative. Do not substitute the Figma draft's Noto fallback in the native app. Primary/secondary semantic text adapts to Light/Dark. The main surface is `controlBackgroundColor`, sidebar `windowBackgroundColor`; groups use a subtle window-background tint, 10 pt corners and 0.5 pt separator outline. No sampled screenshot hex palette or decorative shadows.

Labels are 13 pt medium, body 13 pt regular, supporting text 12 pt and captions 11 pt. Changing values use monospaced digits and an adjacent unit. Native controls own their focus, hover, disabled and pressed states. Keep long explanatory text wrapping rather than truncating it.

## Appearance and sizing

Screen picker and synchronization share the upper-right header. The system/custom selector and small presets precede one shallow preview. Below it, rows align labels, flexible controls and right-side values. Frequent choices are 大小、疏密、长度、位置. Precise gap, padding, minimum height, fixed length and overflow choices remain in one expandable advanced group.

The preview card is 190 pt, including its own header, followed by one quiet metrics line. The 50/75/100% zoom is explicitly chosen and never recalculated when icon size changes. At fixed zoom, doubling an unconstrained real icon doubles its drawn preview size. Use production resolved geometry, all visible entries and actual app icons. Scroll content beyond the viewport; do not shrink it to fit. Screen constraints may still reduce the real Dock's effective icon size, which must be disclosed separately. There is no second local-detail preview.

The drawing surface supports all four edges and hidden-scrollbar panning. It represents base size without hover magnification. Preview scale is local presentation state and must not change saved Dock settings. The view updates in place during sizing changes.

System mode follows native metrics and preserves manual values. Synchronization uses the currently selected screen as source. Positions remain per-screen. Both manual gap and padding overrides disable the density slider until the user chooses “恢复联动”. Reset actions say “恢复所有屏幕尺寸” or “恢复此屏幕尺寸”; they never silently clear app groups or positions.

## About and supporting pages

About uses a 72 pt icon, 25 pt product name, the full slogan and native macOS descriptor. Preserve version/build, MIT, author/copyright, visible project URL, releases, feedback and Star support. These are aligned rows, not a marketing hero. Other pages retain actual production features and permission/recovery actions; prototype-only controls must not enter production.

## Verification

Capture the actual native views in isolated fixtures at default and compact widths, Light/Dark, all categories, native/manual sizing, old overrides, no-display and many-app states. Use WindowServer captures of owned nonactivating windows for materials; view-cache images alone are insufficient. Separate these controlled captures and pixel regressions from physical-mouse desktop acceptance. The preview geometry has pure Core tests plus a retained-view rendering check. Document the exact evidence for each release.
