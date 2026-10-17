# Releasing and updating

How a version of PulseEight Control gets from this repository to people's machines, and how the installed
apps find out about the next one. The macOS side is built and tested; the Windows installer and updater and
the automated release workflow are described in the plan and are not built yet (see the end).

## The moving parts

| Piece | What it does | Where |
|---|---|---|
| `VERSION` | The marketing version, e.g. `0.1.0`. The one place to change it. | repository root |
| Build number | A whole number that **must rise with every release**: Sparkle decides "is this newer?" from it, not from the version text. CI uses the run number. | `P8_BUILD` |
| `package.sh` | Builds the `.app`: embeds Sparkle, stamps version and build, optionally stamps the update feed and key, signs ad-hoc. | `PulseEightControl-macos/` |
| `make-dmg.sh` | Wraps the `.app` in a disk image. The same file is the first download and every update. | `scripts/release/` |
| `ed25519.swift` | Signs a file with the update key (and verifies, and generates keys). | `scripts/release/` |
| `appcast.py` | Adds, replaces, removes and validates releases in a feed. | `scripts/release/` |
| Feed | A small XML file the app downloads to learn what the newest version is and where to get it. | the public releases repo |

## Why the feed address is not in the source

`SUFeedURL` (where to look) and `SUPublicEDKey` (the key updates must be signed with) are written into the
**built** app's `Info.plist` by `package.sh` from `P8_UPDATE_FEED_URL` and `P8_SPARKLE_PUBLIC_KEY`. They are not
in the checked-in `Info.plist`. So:

* a development build (`swift run`, Xcode, the tests) has neither and never checks for updates;
* where releases live is decided when releasing, and the address inside shipped apps is permanent, so
  **pick it carefully**: an app can only follow a feed that hasn't moved.

An app with only one of the two refuses to start the updater, and `package.sh` refuses to build one.

**Every release must carry the same feed address and key as the one before it.** Sparkle refuses ("The update is
improperly signed") an update whose app has no public key, because that app could not verify the *next*
update and its users would be stranded. So build every release with the same `P8_UPDATE_FEED_URL` and
`P8_SPARKLE_PUBLIC_KEY`; the release workflow takes both from repository variables for exactly this reason.
Treat the key as permanent: with only an ad-hoc signature, Sparkle has no other identity to trust across a
key change (its documented key rotation relies on the app's Developer ID signature, which this app doesn't have
yet), so a lost or replaced key would mean everyone installing the app again by hand. Back it up.

## Signing, and what it does and doesn't give you

* Updates are signed with an **Ed25519 key**. The app carries the public half and rejects anything not
  signed by the private half. This is what protects people from a tampered update, so **guard the private
  key** (a GitHub secret, never a file in the repository) and keep a backup: losing it means shipping a
  new build with a new key to everyone by hand.
* The apps are **ad-hoc code signed, not notarized** (no Apple Developer ID yet). Consequences:
  * the first install, from a browser-downloaded `.dmg`, shows macOS's "unidentified developer" warning:
    right-click the app, choose Open (or allow it in System Settings > Privacy & Security);
  * updates installed by the app itself are not quarantined, so they don't show that warning again;
  * hardened runtime is off, because with an ad-hoc signature its library validation refuses to load
    Sparkle. When a Developer ID is available: turn `ENABLE_HARDENED_RUNTIME` on in the Xcode project,
    sign with `--options runtime` in `package.sh`, and notarize.

## Keys

```sh
swift scripts/release/ed25519.swift generate
# private=<base64 of 64 bytes>   -> a secret (SPARKLE_ED_PRIVATE_KEY), nowhere else
# public=<base64 of 32 bytes>    -> P8_SPARKLE_PUBLIC_KEY, baked into every build
```

The private key's format is the one Sparkle's own `generate_keys -x` exports, so you can switch to Sparkle's
tools later without changing anything. Use a **separate key** for the Windows feeds.

## Making a macOS release by hand

```sh
export P8_VERSION=0.2.0 P8_BUILD=12                          # build number: higher than the last release
export P8_UPDATE_FEED_URL=https://<where the feed lives>/appcast-macos.xml
export P8_SPARKLE_PUBLIC_KEY=<the public key>
PulseEightControl-macos/package.sh release --universal       # out/macos/PulseEightControl.app
scripts/release/make-dmg.sh out/macos/PulseEightControl.app out/PulseEightControl-0.2.0.dmg

ED25519_PRIVATE_KEY=<private key> swift scripts/release/ed25519.swift sign out/PulseEightControl-0.2.0.dmg
# -> signature=...  length=...
python3 scripts/release/appcast.py add appcast-macos.xml --version 12 --short 0.2.0 \
    --url https://<host>/PulseEightControl-0.2.0.dmg --length <length> --signature <signature> \
    --min-os 14.0 --notes-file notes.html
python3 scripts/release/appcast.py validate appcast-macos.xml
```

Publish the `.dmg` first and the feed second, so no app is ever offered a file that isn't there yet.

To **withdraw** a bad release: `appcast.py remove appcast-macos.xml --version 12` and publish the feed. Apps
that already installed it need a newer release to move on (there is no downgrade).

## Testing the update path

```sh
scripts/release/e2e-macos-update.sh
```

Builds 0.1.0 and 0.1.1, signs the update with a throwaway key, serves a feed from this machine, launches 0.1.0,
and clicks through Sparkle's own windows until the installed app is 0.1.1 with a valid signature. It needs
Accessibility permission for the terminal, shows windows briefly, and touches nothing of yours
(`out/macos`, your settings and your Keychain are left alone). Run it after changing anything in the updater,
`package.sh`, or Sparkle's version.

The helper scripts have their own tests (`python3 scripts/run-tests.py`): the feed editor, the signer, the
release notes, the coverage summary and the check that every pinned action is the release it claims to be.
