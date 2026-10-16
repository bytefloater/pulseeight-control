# M0 spike findings: SwiftCrossUI 0.10.0

Throwaway app in `Sources/Spike/SpikeApp.swift`. Exercises the riskiest pieces from the plan on the
**AppKit backend (macOS 27, Swift 6.4, driven with real mouse events)** and, as a smoke test, the
**GTK 4 backend (built and run on macOS via Homebrew GTK 4.22)**. **Windows (WinUI) and real Linux were not
tested**; neither toolchain is available here.

## Verdict: GO for the routing grid and the native-app approach

The grid design survives, with three changes: number column headers (no rotation), `onTapGesture`
placed outermost, and `Rectangle`-style cells rather than `Button` cells.

## What was verified

| Area | Result | Backend |
|---|---|---|
| `NavigationSplitView` + `List(selection:)` sidebar | Works. Native vibrancy sidebar and selection style. | AppKit, GTK |
| 16×16 grid (256 cells), hover row/column highlight via `onHover` | Works. All 23 cell transitions on a diagonal sweep were processed; final highlight correct. Release build. | AppKit, GTK |
| Click a cell (`onTapGesture`) | Works **only if `onTapGesture` is the outermost modifier** (see gotchas). | AppKit |
| Native tooltips (`.help`) | Works. | AppKit, GTK |
| `Table` with view-based columns (status dot + text, buttons) | Renders as a native `NSTableView` with banded rows. | AppKit |
| Segmented `Picker`, `Toggle` with `.toggleStyle(.switch)`, `TextField`, `SecureField` | Work. Segmented renders as a dropdown on GTK. | AppKit, GTK |
| `.sheet(isPresented:)` with TextField + menu `Picker` | Works. A real macOS sheet, text field focused. | AppKit |
| `.commands { CommandMenu }` | Appears in the real macOS menu bar. | AppKit |
| `.preferredColorScheme(.light/.dark/nil)` | Flips the whole window, including sidebar vibrancy. | AppKit |
| `Color.system(.blue/.green/…)` | Platform-tailored palette. Active-cell blue and status dots use it. | AppKit |
| `@Observable` model with `@State` / `@Bindable` | Works. **Needs macOS 14+** (see gotchas). | AppKit |

## Gotchas (these cost time; do not rediscover them)

1. **`@Observable` crashes on a macOS 13 deployment target** at launch:
   `Could not cast Observation.ObservationRegistrar to ObservationPolyfillCore._ObservationPolyfillRegistrar`.
   Set `platforms: [.macOS(.v14)]`. (Alternatively use the `ObservationPolyfill` spellings at 13.)
2. **Modifier order matters for taps.** `onTapGesture` inside `onHover`/`.help` never fired; as the
   outermost modifier it works. Plain `Text("Tap me").background(...).onTapGesture` works in isolation.
3. **`Rectangle` + `onTapGesture` did not fire** in my first attempt. This was probably the same ordering
   problem, not the shape; I switched to `Text("").frame().background()`, and have not re-tested a bare `Rectangle` outermost.
4. **A `Button` inside a `Table` cell did not respond to a synthetic click** (the row/table took it). Standalone
   buttons and sheet buttons did. **Unverified with a real mouse. Needs a human click before committing to
   "Edit…" buttons in table rows.** Fallback: open the port sheet from row selection or from the routing grid headers.
5. **No `Color.primary` / semantic label colors.** Only override colour when needed; otherwise inherit the default
   text colour (done via a `@ViewBuilder` helper). Grid cell greys use `Color.gray.opacity(...)`, which reads fine in
   both light and dark.
6. **Native `Button` as a grid cell clips its label** at ~28pt (a "●" showed as a half-moon). Use drawn cells.
7. `ScrollView` centres content when it is smaller than the viewport; the grid floats mid-window.
   Needs an alignment pass (the grid should sit top-leading).
8. `.frame(width: Int)` and `Double` overloads both exist; `cornerRadius` takes `Int`.
9. `swift run` is not recommended by the project for real apps. The raw binary ran fine for the spike, but app
   bundles/icons/resources need Swift Bundler (not yet installed here).

## Not available in 0.10.0 (confirmed against the source)

- **No view rotation** (only `Path` transforms), so rotated column headers are impossible. Use number
  headers with `.help` tooltips (names listed in a legend), or horizontal abbreviated names.
- **No public keyboard-shortcut API.** The AppKit backend uses key equivalents internally; the app cannot declare
  ⌘R etc. for menu items. Plan accordingly.
- **No `TabView`, `Form`/`Section`, `LazyVGrid`, `Canvas`, `toolbar`, `navigationTitle`, or Settings scene.**
  The window title comes from `WindowGroup("Title")`. Settings is a sidebar page (as planned).
- No `Color.primary` / semantic backgrounds (see above).

## Performance (release build, M-series Mac)

| Grid | Time to rebuild on size change | Memory |
|---|---|---|
| 16×16 (256 cells) | ~1.9 s switching 32→16 | ~190 MB |
| 32×32 (1,024 cells) | ~2.7 s (5.8 s in a **debug** build) | ~690 MB (850 MB debug) |

The matrix this app controls is 8×8 or 16×16 at most (NeoMatrix), so 16×16 is the real ceiling and
interaction stayed responsive there. The rebuild cost matters for **polling**: the store publishes a new state every few
seconds, so the grid must update cells in place (stable identity, no full rebuild per poll). **Needs a dedicated
check in M3 with a live-updating model**, because the spike only measured a one-off size change, not a steady refresh.

## GTK 4 backend (smoke test only)

The same source built unchanged and ran. Layout matches; hover highlight and tooltips work. Visual differences
are the expected "at home" behaviour: the segmented `Picker` is a dropdown, toggles are GTK toggle buttons, the sidebar
is a GTK list, and the window follows the GTK theme. Not tested: clicks, `Table`, sheets, menu bar on GTK.

## Decisions this forces

1. Minimum macOS becomes **14** (also set in `swift/Package.swift`).
2. Routing grid: drawn cells, number headers + tooltips, `onTapGesture` outermost, in-place updates.
3. No keyboard shortcuts for commands in v1.
4. Verify buttons-in-table-cells with a real mouse before relying on them.
5. Windows and Linux remain unverified; schedule real-hardware passes in M5 and avoid claiming parity until then.
