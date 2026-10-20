# Releasing and updating

How a version of PulseEight Control gets from this repository to people's machines, and how the installed
apps find out about the next one. The macOS update path is built and tested end to end here. The Windows
installer, updater and the release workflow are written but have only been exercised in pieces on a Mac
(see "Windows" and "What is not verified yet" at the end).

## The moving parts

| Piece | What it does | Where |
|---|---|---|
| The release tag | The **only** place a version is defined: `v0.2.0`, `v0.2.0.rc-01`, `v0.2.0.beta-01` (next section). There is no `VERSION` file and no version number in any source file. | git |
| `version.py` | Turns a tag into every field a build needs, checks a tag is allowed before anything is built, and picks where its release notes start. | `scripts/release/` |
| `package.sh` | Builds the `.app`: embeds Sparkle, stamps the version fields, optionally stamps the update feed and key, signs ad-hoc. | `PulseEightControl-macos/` |
| `make-dmg.sh` | Wraps the `.app` in a disk image. The same file is the first download and every update. | `scripts/release/` |
| `ed25519.swift` | Signs a file with the update key (and verifies, and generates keys). | `scripts/release/` |
| `appcast.py` | Adds, removes and validates releases in a feed, with a channel for pre-releases. | `scripts/release/` |
| Feed | A small XML file the app downloads to learn what the newest version is and where to get it. | the public releases repo |

## Versions, releases and channels

A release is named by its tag, and by nothing else. Only this spelling is accepted (anything else fails in the first job):

| Tag | Release title | Channel |
|---|---|---|
| `v0.2.0` | `PulseEight Control 0.2.0: Release` | none: offered to everyone |
| `v0.2.0.rc-01` | `PulseEight Control 0.2.0: Release Candidate 1` | `rc` |
| `v0.2.0.beta-01` | `PulseEight Control 0.2.0: Beta 1` | `beta` |

The number after `rc-` or `beta-` is two digits, 01 to 99, so one release can't be named two ways. GitHub marks `rc` and `beta`
releases as pre-releases.

`python3 scripts/release/version.py fields <tag>` derives everything from the tag, and every script and job is handed those
fields rather than working them out again:

| Field | `v0.2.0` | `v0.2.0.rc-01` | Used for |
|---|---|---|---|
| `semver` | `0.2.0` | `0.2.0-rc.1` | file names, what people see (`CFBundleShortVersionString`, the feed's `shortVersionString`) |
| `build` | `0.2.0.300` | `0.2.0.201` | what updaters compare (`CFBundleVersion`, `sparkle:version`, the Windows file version) |
| `channel` | `release` | `rc` | the feed's `<sparkle:channel>` (a release has none) |
| `label` | `Release` | `Release Candidate 1` | titles, and the apps' version line (`0.2.0: Release Candidate 1 (build 0.2.0.201)`) |

`build` is `M.m.p.R` with R = 100 + N for a beta, 200 + N for a release candidate and 300 for the release. So within a version a
beta is older than a release candidate, which is older than the release, and a newer `M.m.p` is newer than all of them. It is
always the same for the same tag (a re-run changes nothing) and no two releases can share one. A development build (no tag) is
`0.0.0-dev`, build `0.0.0.0`, "Development build".

**A version can only be released once.** The first job (`verify`, on the cheapest runner, before any macOS or Windows runner
starts) refuses a tag that is malformed, is already in an update feed, is a pre-release of a version that is already released
(there is no `rc-02` of `0.2.0` once `0.2.0` is out), is lower than the newest release already offered (override: the manual
run's `allow_older` input), or whose rc/beta number isn't higher than the one before. It reads the feeds from the releases
repository, so it checks what people are actually offered.

### Pre-releases

Release candidates and betas are added to the same feeds as releases, on the `rc` or `beta` channel. A release has no channel,
and both Sparkle (macOS) and NetSparkle (Windows) offer an item with no channel to everyone, and an item on a channel only to an
app that asked for it. **Settings > Updates > Include pre-releases** asks for both channels. Until the person chooses, the
setting follows the installed build: a release build only gets releases; a release candidate or beta build keeps getting
pre-releases until they say otherwise. The choice is one shared setting (`updatePrereleases`, `docs/core-interface.md`).

On the Windows side NetSparkle's channel filter isn't relied on: `PrereleaseChannelFilter` in `PulseEight.Updates` does exactly
that rule and is tested against a real signed feed (`UpdateChannelTests`).

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
* The **hardened runtime** (which notarization requires) is on only for builds signed with a Developer ID
  (`P8_SIGN_IDENTITY`, below). Ad-hoc releases (everything until there is a Developer ID) are signed without
  it: on macOS 27, a browser-downloaded, unnotarized app that has the runtime hangs at launch (the dock icon
  bounces, no window opens, and the Open Anyway button in Privacy & Security doesn't help); the same app
  without the runtime opens normally. (The Xcode project still has
  `ENABLE_HARDENED_RUNTIME` on, with `PulseEightControl-macos/PulseEightControl.entitlements` switching library
  validation off so Sparkle loads under an ad-hoc signature; that only affects builds from Xcode.)

### Notarizing the macOS app (optional, not set up)

CI does **not** notarize, and nothing in the workflows sets `P8_SIGN_IDENTITY`, so every release stays ad-hoc
signed. This section is only for if it is ever decided to notarize, which needs a paid Apple Developer account and a **Developer ID Application** certificate in the keychain.

```sh
P8_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" PulseEightControl-macos/package.sh release --universal
```

With `P8_SIGN_IDENTITY` set, `package.sh` signs Sparkle's helpers, the framework and the app with that one
identity (hardened runtime, secure timestamp), so library validation stays on and passes because everything
shares the team. Then notarize and staple:

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
tag=v0.2.0.rc-01                                              # or v0.2.0, v0.2.0.beta-01
python3 scripts/release/version.py check $tag --feed appcast-macos.xml     # may this be released?
f() { python3 scripts/release/version.py fields $tag | sed -n "s/^$1=//p"; }
export P8_VERSION="$(f semver)" P8_BUILD="$(f build)" P8_CHANNEL="$(f channel)" P8_LABEL="$(f label)"
export P8_UPDATE_FEED_URL=https://<where the feed lives>/appcast-macos.xml
export P8_SPARKLE_PUBLIC_KEY=<the public key>
PulseEightControl-macos/package.sh release --universal       # out/macos/PulseEightControl.app
scripts/release/make-dmg.sh out/macos/PulseEightControl.app out/PulseEightControl-$P8_VERSION.dmg

ED25519_PRIVATE_KEY=<private key> swift scripts/release/ed25519.swift sign out/PulseEightControl-$P8_VERSION.dmg
# -> signature=...  length=...
channel=""; [ "$P8_CHANNEL" = release ] || channel="--channel $P8_CHANNEL"
python3 scripts/release/appcast.py add appcast-macos.xml --version "$P8_BUILD" --short "$P8_VERSION" $channel \
    --url https://<host>/PulseEightControl-$P8_VERSION.dmg --length <length> --signature <signature> \
    --min-os 14.0 --notes-file notes.html
python3 scripts/release/appcast.py validate --strict appcast-macos.xml
```

Publish the `.dmg` first and the feed second, so no app is ever offered a file that isn't there yet.

To **withdraw** a bad release: `appcast.py remove appcast-macos.xml --version 0.2.0.300` and publish the feed (the version stays
used: it can't be released again, so fix it with the next version). Apps
that already installed it need a newer release to move on (there is no downgrade).

## Testing the update path

```sh
scripts/release/e2e-macos-update.sh
```

Builds v0.1.0 and v0.1.1 (their fields come from the tags, as in the workflow), signs the update with a throwaway key, serves a
feed from this machine, launches 0.1.0, and clicks through Sparkle's own windows until the installed app is 0.1.1 with a valid
signature. `P8_E2E_SCENARIO` tests the channels with the real Sparkle: `rc-on` (pre-releases turned on installs a release
candidate), `rc-unset` (a release build is **not** offered one by default) and `rc-follow-build` (a beta build is offered the next
pre-release). It needs
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
| `PulseEightControl-windows/build.ps1 -Configuration Release -Version <semver> -Build <build> -Channel <channel> -Label <label> -UpdateBaseUrl ... -UpdatePublicKey ...` | Builds the core and the app, compiling the version fields, feed base address and public key into the app. Without the last two the app never checks for updates. |
| `PulseEightControl-windows/installer/build-installer.ps1 -Version <semver> -Build <build>` | Wraps that build in `out\release\PulseEightControl-Setup-<semver>-<arch>.exe`. Needs Inno Setup 6. |
| `appcast-windows-x64.xml`, `appcast-windows-arm64.xml` | One feed per architecture, so each machine is only offered its own installer. Each has a `.signature` file beside it. |

* **Version** is the same four fields as macOS, from the tag: the assembly's version is the `build` (`0.2.0.201`), and the feed's
  `sparkle:version` is compared against it. The semver, channel and label are stamped into the assembly's metadata
  (`ReleaseInfo`) for the About page and Settings.
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

`.github/workflows/release.yml`, on a pushed tag (`v0.2.0`, `v0.2.0.rc-01`, `v0.2.0.beta-01`) or run by hand as a dry run.

1. `verify`: the first job, on the cheapest runner. It reads the version from the tag (`version.py fields`), checks it is allowed
   and unreleased against the feeds in the releases repository (`version.py check`), checks the repository variables, and works out
   where the release notes start. Every other job waits for it, so a bad or duplicate version costs no macOS or Windows time.
2. `checks`: the same jobs as every pull request.
3. `macos` and `windows` (x64 and ARM64) build in parallel with the verified fields, check the built app reports exactly them, and
   upload their files to the run.
4. `publish`: creates the GitHub release (titled as in the table above, a pre-release for `rc` and `beta`) in the **releases
   repository** and uploads the installers and `SHA256SUMS`.
5. `offer`: only after step 4: signs the Windows installers and the feeds and pushes all three feeds to the releases repository,
   with the item on its channel for a release candidate or beta. Between the feed and its `.signature` file landing on the web,
   a check may fail once; the next check works.

A **manual run** takes the version it should dry-run (`v0.2.0.beta-01`): it checks it as `verify` would, builds and signs
everything and publishes nothing. Only a pushed tag publishes, so every published version has a tag.

If a run stops half way (the release exists but the feeds weren't updated) the version isn't in a feed yet, so re-running the
run is allowed and finishes the job. Once a version is in a feed it can't be released again.

Repository variables: `RELEASES_REPO` (`owner/name`), `UPDATE_BASE_URL` (where the releases repository's feeds
are served, no trailing slash), `SPARKLE_PUBLIC_KEY`. Secrets: `SPARKLE_ED_PRIVATE_KEY`, `RELEASE_REPO_TOKEN` (a
fine-grained token that can write to the releases repository and nothing else; `verify` also uses it to read the feeds).

Releases made before this scheme (`v0.1.0-rc.1`, `v0.1.0-rc.2` in the releases repository) are in no feed and are ignored.

## What is not verified yet

* Everything in `.github/workflows` has only been linted (`actionlint`) and its pieces run by hand; no workflow
  has run on GitHub yet.
* The Windows side was written on a Mac: the Swift core, the WinUI app, `build.ps1`, the Inno Setup script,
  `smoke.ps1` and NetSparkle inside a WinUI 3 app have not been run. The updater library itself
  (`PulseEight.Updates`) has 60 tests that do run on any OS (`DOTNET_ROLL_FORWARD=Major dotnet test PulseEightControl-windows/Updates.Tests`
on a machine with a newer .NET).
* The `verify` job's reading of the feeds through `gh api` (and its 404-versus-error handling) only exists in the workflow; the
  checks it runs (`version.py`) have their own tests.
* A checklist to do on a Windows machine once the first CI build exists: install a release candidate from the installer, publish
  a newer one to a local or test feed, check that the dialog appears, downloads, and that the app comes back as the new version;
  turn "Include pre-releases" off and on; repeat on ARM64; uninstall from Settings > Apps.
