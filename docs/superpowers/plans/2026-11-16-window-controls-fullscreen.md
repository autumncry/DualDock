# Window Controls and Fullscreen Reveal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Add exact-window menu selection, repeatable minimize/restore, and fullscreen edge reveal.
**Architecture:** A window interaction service discovers and validates live identities away from the main actor. The coordinator owns selection UI and dispatch; the visibility reducer/controller produces per-screen hidden/fullscreen snapshots consumed by AppKit panel membership.
**Tech Stack:** Swift 5.9, AppKit/SwiftUI, Accessibility, existing optional native window-ID bridge.
**Spec:** ../specs/2026-11-16-window-controls-fullscreen.md

## Global Constraints

- macOS14+, preserve2.2.2 resize/geometry behavior and existing configuration.
- Do not touch user windows/documents for tests; use hidden fixtures or own temporary blank windows.
- Keep .impeccable/ untracked user content untouched.
- Native animation request is not a guarantee of a particular Genie trajectory.

## Review Focus

- Stale/recycled window or process identity must never minimize a replacement window.
- Rapid repeated clicks must remain responsive and not leave a one-shot/stuck transition flag.
- Menus must contain minimized windows without requiring a screenshot.
- Fullscreen transitions must not flash a dock on entry; grouped interactions must remain usable after edge reveal.
- Native Dock competition and multi-display placement need real desktop validation in addition to reducer tests.

### Task 1: Window interactions

Files: new Sources/DualDock/WindowInteractionService.swift and backend/policy helpers; tests and focused script.
Interface: async list(for:)->DockWindowListSnapshot, select(_:for:), toggle(for:)->WindowInteractionResult; remember(_:for:), cancel().
- [x] Add injected tests for exact selection, repeated cycles, foreground/background distinction, stale identity, unsupported minimize and max/fullscreen exemptions.
- [x] Implement bounded background inventory and native minimize/restore with identity revalidation.
- [x] Verify focused tests and independent review.

### Task 2: Menu and click integration

Files: DisplayCoordinator.swift, DockTile.swift if asynchronous preparation needed; new focused menu helper if warranted.
- [x] Prepare window items asynchronously, render current selection/checkmark, cancel stale menu requests.
- [x] Route ordinary icon clicks to toggle; keep explicit Open/group-open commands activation-only.
- [x] Remember preview selection and preserve unsupported/permission fallback.
- [x] Verify menu construction and repeated activation with an own blank-window fixture.

### Task 3: Fullscreen reveal

Files: DockVisibilityPolicy.swift, DockVisibilityController.swift, DockUI.swift, DisplayCoordinator.swift, focused tests.
Interface: DockVisibilityController.Snapshot(hidden, fullscreen), fullscreenBounds(for:).
- [x] Reproduce old unconditional-fullscreen-hide failure.
- [x] Implement entry reset, edge dwell, engagement retention, exit delay and screen independence.
- [x] Apply dynamic fullscreen overlay membership and per-screen placement, including popups.
- [x] Investigate system Dock competition under existing hide switch; retain safe restoration semantics.
- [x] Verify reducer/controller tests and real fullscreen entry/reveal/exit with a test app.

### Task 4: Delivery

- [x] Review integrated diff, run targeted and affected regression checks.
- [x] Update bilingual docs and release notes, build/sign DMG, preserve current configuration during install.
- [x] Commit/push and publish validated DMG/SHA assets; state any live acceptance limits.

Acceptance evidence is recorded in docs/validation.md; publication verification is performed by the final release delivery step.
