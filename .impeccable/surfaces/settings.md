# DualDock settings surface

Mode: Operate. Platform: native macOS. Target: Sources/DualDock/SettingsView.swift.

Direction: a quiet native inspector for a multi-display Dock. Use the existing blue brand and system materials, semantic text colors, precise alignment and ample grouping space. Keep the seven-category sidebar recognizable, but remove oversized selection blocks and repeated instructional paragraphs. Detail navigation returns to the top when the category changes.

First viewport: compact page title and one-sentence purpose; on sizing and positioning pages, a useful live Dock/display preview leads immediately into controls. The user-provided HTML is the layout/interaction reference. Defaults and advanced overrides must be visually distinct. Values remain readable, editable where appropriate, and reset actions name their scope.

Native controls, SF symbols, fixed type sizes, support both Light/Dark appearances and the implemented compact-to-large desktop layout. Default content size is 1080×740pt; minimum AppKit window size is 820×580pt (root view minimum content size 820×540pt). Custom sizing keeps a fluid preview column beside a 280pt control column at the compact width. No decorative gradients, fake dashboard metrics, extra brand badges or giant headers. Preserve the existing app icon and slogan.

Implementation is code-led for native settings. Real app icons may appear in a clearly identified preview; preview geometry is explanatory, and settings apply to the real Dock. No HTML webview inside the shipped settings.

Verify all seven categories, no-display and native-adaptive states, independent/synchronized displays, expanded advanced controls, and small/large settings windows. Use hidden NSHostingView rendering while desktop automation is unavailable; do not call that live UI acceptance.


## Direction contract

THESIS: Three primary choices explain Dock sizing through immediate visual feedback; precision is available on demand.
OWN-WORLD: Native macOS utility settings, existing blue multi-display identity, system typography/materials and actual app icons.
STORY: Select scope and system/custom mode, adjust size/density/length beside the preview, expand individual overrides only when needed.
FIRST VIEWPORT: Size, density and length remain directly operable with a visible preview at the supported compact width; reset and cross-display actions name their scope.
FORM: Seven-category sidebar plus a fluid preview/control split. The supplied prototype pins the content hierarchy; this code-led native adaptation does not replace the product identity or require an invented marketing-style concept tournament.
