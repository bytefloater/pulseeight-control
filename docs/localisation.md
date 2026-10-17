# Localisation

All user-visible text lives once, in the shared core (`PulseEightKit/Sources/PulseEightCore/Localization`).
Both apps look text up from it, so a language is added in one place. English is the only language so
far; the language option is there so that adding another doesn't need any interface work.

## How it fits together

| Piece | Role |
|---|---|
| `StringKey` | One case per piece of text. The raw value is the stable dotted name (`settings.title`) that non-Swift clients use. |
| `Catalog_en.swift` | The English table, the reference. Every key must be here. |
| `Strings` | Looks a key up in one language, fills `{0}`, `{1}`... placeholders, falls back to English per key. |
| `Language` / `Languages` | The available languages, and how the saved setting (`"system"` or a code such as `"en"`) turns into one. `"system"` follows the OS's preferred languages and falls back to English. |
| `AppCore.strings` | The `Strings` for the language in force. Text the core produces (hardware rows, validation errors, connection summaries, port status) is already in that language. |
| `{"cmd":"strings"}` | Returns the whole table as JSON, for the Windows app (`Loc.Load`). No new C function was needed. |
| `{"cmd":"setLanguage","value":"en"}` | Saves the choice and notifies observers; the snapshot's `language` then changes. |

On Windows, `Loc.T("key")` / `Loc.F("key", args...)` / `Loc.Count(n, "one.key", "other.key")` read the
table; `MainWindow.ApplyLanguage` reloads it and rebuilds the pages that hold text when the snapshot's
language changes. Text that is not translated (device names, port types, device error messages from
`PulseEightKit`) is shown as the matrix sent it.

## Adding a language

1. Copy `Catalog_en.swift` to `Catalog_xx.swift` (`xx` = the language code, e.g. `de`) and translate
   the values. Keep the keys, and keep every `{0}`, `{1}` placeholder (you may reorder them).
2. Register it: add `"xx": xx` to `Catalog.tables` in `Strings.swift`, and
   `Language(code: "xx", nativeName: "Deutsch")` to `Languages.all` in `Language.swift` (the native
   name is what the language picker shows).
3. Run `swift test --package-path PulseEightKit`. `CatalogTests` fails if the table is missing a
   key, has an extra one, or changes a placeholder.
4. Plurals: `Strings.count(_:one:other:)` only distinguishes 1 from everything else. A language with
   other plural rules needs that function extended first.

A key missing from a language falls back to English, so a half-finished translation never shows a
blank or a raw key, but the tests above insist on completeness anyway.

## Adding text

1. Add a case to `StringKey` and its English text to `Catalog_en.swift`. (Tests fail until every
   language has the key too.)
2. Swift: `strings.text(.yourKey, arguments)`. Windows: `Loc.T("your.key")`.
   `PulseEightControl-windows/Core.Tests/LocalisationTests.cs` fails if a key written in the app's
   source doesn't exist.

## Not translated yet

* The macOS app (`PulseEightControl-macos`) still has its English text inline. Moving it onto
  `AppCore.strings` also needs a language picker in its Settings; do it on a Mac so it can be compiled.
* Developer-facing text: the JSON command protocol's own errors (`Unknown command`, `Missing text field`),
  `p8ctl` output, and `PulseEightKit`'s diagnostic messages.
