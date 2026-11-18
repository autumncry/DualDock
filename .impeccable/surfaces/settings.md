# DualDock settings surface

Platform: native macOS 14+, SwiftUI/AppKit. Retain the approved quiet, aligned design: compact sidebar and one shallow layout example above full-width controls. The HTML draft is a layout reference, not an embedded web view.

Use system fonts and semantic colors; preserve the existing icon and slogan. Sidebar 176 pt, rows 34 pt, heading 21 pt, label 13 pt, support 12/11 pt, content inset 30 pt. Default content 1060×760 pt; minimum window frame 820×580 pt. Align labels, controls and values consistently.

The screen selector and synchronization appear only in appearance's header. Common choices: size, unified 0–100 icon spacing, length and position. Spacing replaces density and the advanced duplicate. Zero joins visible artwork bounding boxes; 100 is a gap equal to the mean adjacent visible dimension along the ordering axis. Keep original bitmap scale/aspect; cache artwork metrics and give overlapping transparent canvases independent hit ownership. A new visual-spacing setting must not be silently reduced by overflow or overridden by distribution. Legacy layouts remain intact until an explicit spacing/preset/reset choice.

One 190 pt “布局示例” card always uses five fixed system-app samples: Mail, Calendar, Notes, Safari and Music. It follows the selected controls, never the real application list or Dock presentation. Rendering stays at 75% for horizontal positions and 45% for vertical positions; no user zoom selector, auto-fit cancellation, actual-size readout or duplicate detail preview. Virtual reference lengths are 900/600 pt. Overflow pans without visible scrollbars; text identifies the illustrative nature.

Advanced settings use one native 44 pt header button: chevron, title, status and whitespace all toggle it. Precise padding, height and length values remain inspectable; reset actions name their scope.

General adds opt-in “登录时启动” using SMAppService.mainApp. Read system state; never register on appearance. Pending approval remains visibly pending with system-settings and cancel actions. Failed requests must not leave the toggle falsely on.

About retains full version, license, author, project/download/feedback/support information in the restrained layout. All seven sections remain. Verify Light/Dark, compact windows, no-display, advanced, native mode, independent/synchronized displays, four edges and stable sample identity. Distinguish owned fixture/event and injected service tests from fresh-desktop, VoiceOver and actual-login validation; do not claim the latter from the former.
