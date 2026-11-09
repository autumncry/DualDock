# DualDock Refinement Implementation Plan

> Execute the approved changes with independently owned modules and a final integration review.

**Goal:** Resolve per-display size clipping, add continuous size/density controls and magnification, show only valid centered previews, and distinguish folders and anchored menus.

**Architecture:** Shared Codable appearance settings; each DockStripView owns transient wave animation; AppKit panel geometry is updated without rebuilding tile views during animation. Preview capture validity and strip geometry are separately testable.

**Tech Stack:** Existing SwiftPM/AppKit/SwiftUI/ScreenCaptureKit stack, no new dependencies.

**Spec:** ../specs/2026-11-09-dock-refinement.md

## Tasks

- [x] Reproduce narrow-screen saturation using actual v1.0.1 DockStripView.
- [x] Reproduce transparent duplicate preview with unknown AX coverage, implement current valid-image output and window identity checks.
- [x] Reproduce single-preview centering failure, implement centered strip geometry and hide empty panes.
- [x] Add schema migration and continuous appearance controls; verify old user groups and values survive.
- [x] Implement per-strip wave geometry, hover state, drag/menu freezes, adaptive viewport and independent folder shape.
- [x] Integrate panel resize anchoring, reset/cleanup and fresh preview/menu coordinates.
- [x] Run complete tests and targeted actual API/layout probes; review fixes and package next Release.
- [x] Install update with configuration preservation and report completed versus pending GUI verification accurately.

2026-11-09: release tests 46/46 pass. Real DockStripView feedback loop passes across two viewport widths; actual Clash/CC screenshot probes pass, including AX-unavailable path. Native NSPanel rounding issue reproduced and fixed. Final install preserves all settings and three groups. Physical/interactive GUI checks still awaiting user availability; current display setup has one logical screen.
