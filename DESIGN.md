---
name: DualDock
description: Quiet native macOS settings for a multi-display Dock.
typography:
  page-title:
    fontFamily: "system-ui"
    fontSize: "24pt"
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
  group: "12pt"
  display-diagram: "9pt"
  message: "10pt"
spacing:
  label-control: "8pt"
  inline: "16pt"
  group-padding: "18pt"
  columns: "20pt"
  detail-sections: "22pt"
  page-inset: "26pt"
components:
  page-heading:
    typography: "{typography.page-title}"
  settings-group:
    rounded: "{rounded.group}"
    padding: "{spacing.group-padding}"
  sidebar:
    width: "182pt"
    typography: "{typography.body}"
  numeric-field:
    width: "60pt"
  primary-controls:
    width: "280pt"
    rounded: "{rounded.group}"
    padding: "{spacing.group-padding}"
  dock-preview:
    height: "260pt"
    rounded: "{rounded.group}"
  dock-preview-compact:
    height: "158pt"
    rounded: "{rounded.group}"
---

# Design System: DualDock

## Overview

**Creative North Star: "Quiet Native Inspector"**

DualDock uses a restrained native macOS settings language: clear groups, compact headings, familiar controls and visual feedback next to the setting being changed. Elegance comes from alignment and a readable hierarchy rather than decorative surfaces. Chinese is the primary interface language.

This document records the implemented SwiftUI/AppKit settings system. The phrase above names the direction already present in the surface brief; it is not a claim that the user selected a new brand concept. The existing application icon, monochrome menu-bar icon and slogan “应用有序收纳，Dock 多屏同在。” remain the identity. There are no newly generated raster assets or embedded HTML settings.

**Key Characteristics:**

- Native macOS controls, system typography and semantic colors.
- Stable navigation with a scrollable, clearly grouped detail area.
- A proportional Dock preview beside the three common sizing controls.
- Progressive disclosure for precision, with explicit scope and recovery actions.

The frontmatter contains only portable token classes supported by the document format. Its `pt` measurements are macOS logical points; `system-ui` records the native `Font.system` family choice, not a web implementation. AppKit semantic color selectors cannot be faithfully serialized as CSS colors, so their normative mapping is recorded below and in the sidecar's native extension. No sampled screenshot hex values or synthetic tonal ramps are substituted for these dynamic colors.

## Colors

The interface uses the macOS accent and adaptive neutrals; Light and Dark appearances share semantic roles rather than fixed RGB pairs.

### Primary

- **System accent — `Color.accentColor`:** active geometry, focused preview metrics, selected display edges and applicable preset emphasis. Standard sidebar and segmented-control selection remain platform-owned. The existing blue identity does not justify hardcoding blue over the user's system accent.

### Neutral

- **Primary text — `.primary`:** titles, control labels and current values.
- **Supporting text — `.secondary`:** descriptions, units, scope, mode notes and recovery explanations.
- **Quiet symbols — `.tertiary`:** the decorative display symbol within the position diagram.
- **Control surface — `NSColor.controlBackgroundColor`:** settings groups and the Dock preview's bar; the preview bar applies opacity `0.92`.
- **Recessed preview — `NSColor.underPageBackgroundColor`:** Dock canvas and display-position diagram.
- **Separator — `NSColor.separatorColor`:** group strokes use opacity `0.35`; preview canvas strokes use `0.45`, each at a `0.5pt` stroke width.
- **Message surface — `.quaternary`:** the dismissible inline information surface.

Permission confirmation additionally uses `Color.green` with a checkmark and the label “已授权”. It is a status signal, not a second brand accent. The ungranted state uses a lock symbol and supporting text color.

**The Semantic Color Rule.** Keep the native semantic selector as the source of truth; do not freeze Light or Dark screenshot samples into an application palette.

## Typography

**Display and body font:** SwiftUI `Font.system`, resolved by macOS. SF Symbols supply interface symbols. There is no custom font dependency, invented display face or text-glyph icon system.

Use the frontmatter hierarchy for page titles, section titles, control labels, body copy, supporting copy, captions and preview metrics. The sidebar brand uses a restrained `15pt` semibold label; the About page's product name uses `26pt` semibold. These are existing identity placements, not a general hero-heading pattern. Native controls inherit system control behavior and the root regular control size; the compact sizing group and recovery buttons use the small control size.

Numbers use `.monospacedDigit()` where values change or need comparison. Numeric text fields are right-aligned; their unit remains adjacent and visually secondary. The implementation does not define custom line heights or letter spacing. Long instructional copy wraps vertically rather than being compressed into a one-line truncation.

**The Numeric Clarity Rule.** Keep value, unit and control label together; use monospaced digits without replacing the surrounding system text face.

## Layout

The settings shell has a fixed sidebar, a native divider and a fluid detail column. The page heading sits outside the scrolling content. The detail area uses the frontmatter page inset; its heading has `24pt` top and `20pt` bottom padding. Changing category resets the detail scroll position through the category's view identity. Seven categories remain: 通用、外观与尺寸、屏幕与位置、交互、权限、使用方法、关于.

The window opens with a content size of `1080 × 740pt`. AppKit sets the minimum window size to `820 × 580pt`; the root view separately has a minimum content size of `820 × 540pt`. These are different measurements and must not be treated as the same frame. There is no mobile breakpoint or alternate stacked sizing layout in this native implementation.

In custom sizing, the preview column is flexible with a minimum width of `220pt`, and the common controls retain their frontmatter width. The columns remain beside each other at the supported compact width. Scope and system/custom mode precede them; advanced controls and scope-specific reset follow below. The compact rendered review shows size, density and length together with the preview. Native-system mode uses a shorter preview and read-only system metrics.

Groups use a default internal rhythm of `15pt`; common sizing controls tighten that rhythm to `10pt`. General, interaction and permission sections use `24pt` spacing. Position settings use a diagram beside controls, with the display name and primary-display identity above them. Empty-display states replace unavailable editing content with a direct connection message.

**The Visible Choice Rule.** Keep the three common sizing choices beside a visible preview at the supported compact width; additional precision belongs in the expandable group below.

## Elevation & Depth

Depth is predominantly tonal. The sidebar uses SwiftUI `.regularMaterial`; groups use control-background surfaces with fine separator strokes, and previews use a recessed system background. Settings code introduces no custom shadow vocabulary or decorative gradients. Native buttons, fields, selection highlights and the window retain the depth and focus treatment supplied by macOS.

No custom settings animation duration or easing curve is defined. Preview geometry and focus emphasis update with the controls; platform controls own their interaction animation. Do not infer custom motion tokens from the screenshot captures or transfer production Dock animation rules into the settings shell.

## Shapes

Use the frontmatter group radius for settings groups, advanced settings and preview canvases. Message and display-diagram radii are distinct local roles. Native button, field, toggle and segmented-control shapes remain platform-owned rather than being rebuilt to match the group radius.

The proportional preview's Dock bar radius is `min(14, barThickness × previewScale × 0.28)` points. Selected length/height outlines use the system accent at `1.5pt`; the resting bar uses primary color at opacity `0.13` with a `0.5pt` stroke. Position diagrams use capsule-shaped edge targets. These are explanatory geometry, not a general card or button style.

## Components

### Navigation and page heading

A native sidebar `List` combines a one-line Chinese label with an SF Symbol. It owns selection and keyboard behavior. Brand identity appears once above the list; the short “改动即时生效” note is anchored below. Every detail page uses a concise title and a single purpose sentence.

### Settings groups

`SettingsGroup` places a semibold section label above related controls on a semantic control surface. Use grouping to expose relationships, not to give each individual row its own container. Advanced settings reuse that surface with a native `DisclosureGroup` and a count of manual overrides.

### Buttons, toggles and segmented choices

Use native controls and their default keyboard, focus, disabled and hover behavior. Small preset and recovery buttons sit within their associated group. Segmented controls represent short mutually exclusive choices, including custom/system mode, length and display edge. Toggles represent independent on/off decisions. Reset and navigation actions name “所有屏幕” or “此屏幕” according to synchronization state.

### Numeric sliders

`SettingsNumericSlider` combines a visible label, a rounded-border numeric field, a unit and a native slider. The text field accepts zero or one decimal place, rejects nonfinite values and clamps committed changes to the applicable range. Hover, slider editing and text-field focus highlight the corresponding preview measurement. A degenerate range disables the slider; the value remains inspectable. `DockSettingsSlider` is the lighter, read-only-value variant used for interaction tuning.

### Dock and display previews

`SettingsDockPreview` derives its shape from production `DockGeometry` and uses actual installed-app icons plus an SF Symbol for groups. It removes magnification when presenting the base size. The preview exposes icon size, height, length and spacing as labeled metrics. When the full Dock is too reduced to read, a labeled local detail preserves understandable icon scale; it is not an additional live Dock. An accessibility summary describes the configured edge, dimensions and entry count.

The position diagram presents all four edges as button targets and repeats the choice in a segmented picker. The selected edge uses accent color and an explicit accessibility value. Mirrored displays disable independent position changes and explain the relationship.

### Advanced values and status

Size, density and length form the primary model. Manual spacing, padding, minimum height and fixed-length details remain inspectable in advanced settings; each applicable override offers a return to automatic calculation. Existing manual values are retained. If both gap and padding are manual, density is visibly disabled with a scoped “恢复联动” action. Permission rows pair a symbol, title, explanation and explicit action; inline messages can be dismissed without changing settings.

## Do's and Don'ts

### Do:

- **Do** preserve native semantic colors, control states, focus treatment and keyboard behavior.
- **Do** retain the existing app icon, menu-bar identity and Chinese slogan.
- **Do** keep size, density and length beside the preview at the supported compact width.
- **Do** make synchronization scope visible in both explanatory text and recovery actions.
- **Do** preserve manual overrides until the user chooses a corresponding reset.
- **Do** verify Light and Dark appearances, compact windows, empty displays and expanded advanced states.

### Don't:

- **Don't** replace the native settings surface with an HTML webview or a web-style imitation of macOS controls.
- **Don't** invent brand colors, tonal ramps, shadow tokens or motion curves absent from the code.
- **Don't** treat preview geometry or hidden-hosting renders as proof of real desktop behavior.
- **Don't** infer a new brand identity or new assets from the settings redesign.

Source of truth: `Sources/DualDock/SettingsView.swift`, `SettingsSection.swift`, `SettingsDockPreview.swift`, `AppearanceSettingsView.swift`, `DisplayPositionSettingsView.swift`, `SettingsWindowController.swift` and the five remaining detail views. The reviewed native captures live under `.impeccable/review/settings/`; they are fixture-based hidden `NSHostingView` renders, not live desktop acceptance. The browser-oriented sidecar renderer cannot reproduce AppKit materials or native controls. Its native metadata records their implementation without claiming a web rendering or web detector result.
