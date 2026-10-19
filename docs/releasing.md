# Releasing and updating

How a version of PulseEight Control gets from this repository to people's machines, and how the installed
apps find out about the next one. The macOS update path is built and tested end to end here. The Windows
installer, updater and the release workflow are written but have only been exercised in pieces on a Mac
(see "Windows" and "What is not verified yet" at the end).

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
* Until there is an Apple Developer ID the apps are **ad-hoc code signed, not notarized**. Consequences:
  * the first install, from a browser-downloaded `.dmg`, shows macOS's "unidentified developer" warning:
    right-click the app, choose Open (or allow it in System Settings > Privacy & Security);
  * updates installed by the app itself are not quarantined, so they don't show that warning again.
* The macOS app is built with the **hardened runtime on** (`ENABLE_HARDENED_RUNTIME` in the Xcode project,
  `--options runtime` in `package.sh`), as notarization requires. The runtime's library validation only
  loads frameworks signed by the same team, and an ad-hoc signature has no team, so ad-hoc builds (every
  development build, and releases until there is a Developer ID) carry `PulseEightControl-macos/PulseEightControl.entitlements`,
  which switches that check off. Without it the app aborts at launch with "Library not loaded: Sparkle".

### Notarizing the macOS app (optional, not set up)

CI does **not** notarize, and nothing in the workflows sets `P8_SIGN_IDENTITY`, so every release stays ad-hoc
signed. This section is only for if it is ever decided to notarize, which needs a paid Apple Developer account and a **Developer ID Application** certificate in the keychain.

```sh
P8_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" PulseEightControl-macos/package.sh release --universal
```

With `P8_SIGN_IDENTITY` set, `package.sh` signs Sparkle's helpers, the framework and the app with that one
identity (hardened runtime, secure timestamp) and leaves the entitlement out, so library validation stays on
and passes because everything shares the team. Then notarize and staple:

```sh
ditto -c -k --keepParent out/macos/PulseEightControl.app out/macos/PulseEightControl.zip
xcrun notarytool submit out/macos/PulseEightControl.zip --keychain-profile "<profile>" --wait   # store the profile once with `xcrun notarytool store-credentials`
xcrun stapler staple out/macos/PulseEightControl.app
```

Staple before the app goes into the disk image, and notarize the `.dmg` too if you ship one. The Developer ID
path of `package.sh` and these commands have not been run yet (no certificate), so expect to fix details on the
first attempt. If it is ever moved into CI it needs the certificate (as a base64 `.p12` secret) and the notarytool
credentials as secrets, imported into a temporary keychain in `release.yml`. When the app is signed with a Developer
ID, Sparkle's key rotation can rely on that signature (see Keys below).

## Keys

```sh
swift scripts/release/ed25519.swift generate
# private=<base64 of 64 bytes>   -> a secret (SPARKLE_ED_PRIVATE_KEY), nowhere else
# public=<base64 of 32 bytes>    -> P8_SPARKLE_PUBLIC_KEY, baked into every build
```

The private key's format is the one Sparkle's own `generate_keys -x` exports, so you can switch to Sparkle's
tools later without changing anything. **One key signs everything** (the macOS disk image, the Windows
installers and the Windows feeds): the secret is `SPARKLE_ED_PRIVATE_KEY`, the public half is the repository
variable `SPARKLE_PUBLIC_KEY` and is baked into both apps. One key is one thing to guard and back up; the
cost is that losing it affects both platforms.

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

## Windows

The app is a per-user installer (Inno Setup 6; no administrator prompt) built for each of x64 and ARM64, and it
updates itself with NetSparkle's core library under our own WinUI 3 windows (`App/Updates/`).

| Piece | What it does |
|---|---|
| `PulseEightControl-windows/build.ps1 -Configuration Release -Version <VERSION>.<build> -UpdateBaseUrl ... -UpdatePublicKey ...` | Builds the core and the app, compiling the version, feed base address and public key into the app. Without the last two the app never checks for updates. |
| `PulseEightControl-windows/installer/build-installer.ps1 -Version <same>` | Wraps that build in `out\release\PulseEightControl-Setup-<version>-<arch>.exe`. Needs Inno Setup 6. |
| `appcast-windows-x64.xml`, `appcast-windows-arm64.xml` | One feed per architecture, so each machine is only offered its own installer. Each has a `.signature` file beside it. |

* **Version** is `<VERSION>.<run number>` (for example `0.2.0.12`). The feed's `sparkle:version` is compared
  against the version compiled into the app, so it must rise with every release; the workflow's run number does.
* **Signing**: NetSparkle runs in strict mode. The installer's signature is in the feed, and the feed must be
  signed too (`appcast-windows-x64.xml.signature`, the base64 signature of the feed's exact bytes). The release
  workflow does both, with the same key and script as macOS, in the `offer` job.
* **What an update does**: the dialog downloads the installer, the library checks its signature, then runs it
  with `/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS`; the app exits, the installer replaces the files
  and its `[Run]` entry starts the app again.
* **The installer's identity** is the `AppId` GUID in `installer/PulseEightControl.iss`. Never change it, or the next
  version installs beside the old one instead of replacing it.
* **Not signed (Authenticode)**: Windows SmartScreen will warn on the first manual install ("Windows protected
  your PC" > More info > Run anyway). Updates run by the app are not affected by that prompt. Buying a code
  signing certificate (or Azure Trusted Signing) is the later fix; the installer script has no signing step yet.

## The release workflow

`.github/workflows/release.yml`, on a tag `vX.Y.Z` (the tag must match `VERSION`) or run by hand.

1. `verify`: the tag, `VERSION` and the repository variables agree.
2. `checks`: the same jobs as every pull request.
3. `macos` and `windows` (x64 and ARM64) build in parallel and upload their files to the run.
4. `publish`: creates the GitHub release in the **releases repository** and uploads the installers and
   `SHA256SUMS`.
5. `offer`: only after step 4, and not for pre-release tags (`v0.2.0-rc.1`): signs the Windows installers and the
   feeds and pushes all three feeds to the releases repository. Between the feed and its `.signature` file
   landing on the web, a check may fail once; the next check works.

A **manual run** with "publish" off builds and signs everything and uploads it to the run only: a dry run.

Repository variables: `RELEASES_REPO` (`owner/name`), `UPDATE_BASE_URL` (where the releases repository's feeds
are served, no trailing slash), `SPARKLE_PUBLIC_KEY`. Secrets: `SPARKLE_ED_PRIVATE_KEY`, `RELEASE_REPO_TOKEN` (a
fine-grained token that can write to the releases repository and nothing else).

## What is not verified yet

* Everything in `.github/workflows` has only been linted (`actionlint`) and its pieces run by hand; no workflow
  has run on GitHub yet.
* The Windows side was written on a Mac: the Swift core, the WinUI app, `build.ps1`, the Inno Setup script,
  `smoke.ps1` and NetSparkle inside a WinUI 3 app have not been run. The updater library itself
  (`PulseEight.Updates`) has 37 tests that do run on any OS.
* A checklist to do on a Windows machine once the first CI build exists: install 0.1.0 from the installer, publish
  a 0.1.1 to a local or test feed, check that the dialog appears, downloads, and that the app comes back as 0.1.1;
  repeat on ARM64; uninstall from Settings > Apps.
