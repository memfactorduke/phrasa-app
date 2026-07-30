# Phrasa Native

The shipping Phrasa product is fully native: **iPhone/iPad** (`Phrasa` scheme)
and **macOS 14+** (`PhrasaMac` scheme), built with SwiftUI and AppKit on shared
domain and persistence packages. Expo and React Native are retired; this tree is
the only app surface.

## Open and run

```bash
cd ios-native
open PhrasaNative.xcodeproj
```

The canonical project and SwiftPM resolution are tracked. Run
`xcodegen generate` only when intentionally changing project structure, using
XcodeGen 2.45.4. A new release Mac should first follow
[`../docs/FRESH_MAC_RELEASE.md`](../docs/FRESH_MAC_RELEASE.md).

- **iOS:** choose an iPhone or iPad simulator and run the `Phrasa` scheme (iOS 17+).
- **macOS:** run the `PhrasaMac` scheme (macOS 14+). Native AppKit/SwiftUI only —
  not Catalyst. Speed prompting is shipping; voice following is deferred until the
  Mac speech adapter meets the same reliability gates as iOS.

The shipping iOS app uses SwiftUI, Speech, AVFoundation, PDFKit, TextKit, and
SQLite. The Mac app uses SQLite via `PhrasaPersistence`, AppKit TextKit for the
reader surface, PDFKit import, and ProcessInfo display-sleep prevention while
presenting.

Compiled Supabase Auth sources require both native deep links:
`phrasa://auth/callback` for
ordinary PKCE sign-in/confirmation and `phrasa://auth/recovery` for password
recovery. The distinct recovery route is required because the installed Swift
SDK reports a PKCE exchange as a generic sign-in event; the route tells Phrasa
to show its in-app new-password form.

Account deletion requires the active sync baseline
(`supabase/migrations/20260719000000_native_sync_baseline.sql`), which defines
`delete_own_account`, to be applied and verified on the dedicated Phrasa
Supabase project.

## What is included

- Offline-first script library with search, tags, folders, sorting, duplication,
  safe autosave, and a one-time importer for libraries from the retired Expo app
  (`LegacyExpoMigrator`).
- Native editor with outlines, find and replace, document statistics, TXT/Markdown/PDF
  import, text/JSON export, and complete-library backup restore.
- High-performance speed reader using one TextKit surface and `CADisplayLink`,
  continuous or line-step motion, scrubbing, mirror modes, themes, pacing, blackout,
  resume bookmarks, and completion recaps.
- Voice-follow reader using Apple's speech recognition and the tested Phrasa
  fuzzy-alignment engine. Adaptive scroll chase keeps the spoken line near the
  focus band without abrupt jumps. Spoken paragraph navigation (prefix-gated):
  **phrasa previous paragraph**, **phrasa next paragraph**, **phrasa current
  paragraph** (aliases: last/prior/go back/back; following/forward; this/
  restart/repeat). Bare script phrases without **phrasa** never jump.
- Offline-first by design. Optional production accounts and Supabase sync are
  enabled only when the Release build receives
  `PHRASA_SUPABASE_PUBLISHABLE_KEY` from the operator environment. Physical
  Mac-to-iPad sync acceptance passed on 2026-07-29; the key remains outside Git.
- Account ownership is never guessed: libraries saved before provenance existed
  and bulk-restored backups stay device-only instead of being silently uploaded
  to the next account. Newly created or duplicated items can be claimed by the
  signed-in account on its next explicit sync.
- First-run onboarding, iPhone/iPad/landscape support, accessibility labels,
  privacy manifest, app icon, and build number **14** (marketing version **1.0**).
- Reader typeface **Atkinson Hyperlegible** bundled under
  `Phrasa/Resources/Fonts/`.

## Legacy Expo library upgrade

Keeping bundle ID `com.phrasa.app` lets a store upgrade preserve scripts already
on the device. On first native launch, `LegacyExpoMigrator` looks for
`Documents/SQLite/ExpoSQLiteStorage` and imports `autoprompt.*.v1` keys into the
native SQLite library. Corrupt or unreadable legacy files are never overwritten
silently; the user can retry after fixing the file, or confirm **Start fresh**,
which moves the unreadable database (and `-wal`/`-shm` sidecars) into a recovery
folder under `Documents/SQLite/Recovery/`.

## Cloud release configuration

The iOS and Mac targets compile the Cloud sources, link Supabase, register the
`phrasa://` auth routes, and expose Account & sync. Both targets pin the
production project URL in `project.yml`; release automation injects the
production publishable key from `PHRASA_SUPABASE_PUBLISHABLE_KEY`. The key is
never tracked, while builds without it fail closed and remain usable offline.

For a release candidate:

1. Verify the active migrations, RLS, Auth providers, and redirect allow-list
   on the pinned production project.
2. Export the current publishable key as
   `PHRASA_SUPABASE_PUBLISHABLE_KEY` (publishable key only—never a
   service-role/secret key).
3. Keep Sign in with Apple primary and email/password secondary.
4. Preserve the 2026-07-29 real Mac↔iPad sync acceptance evidence. Re-test if
   the backend, auth, or sync implementation changes.
5. Treat Apple-linked deletion as a separate live gate; do not claim its
   end-to-end completion without platform-specific evidence.

Store listing draft copy lives in [`AppStore/`](./AppStore/). Do not claim
`phrasa.app` is live until deploy is verified; do not invent a support email.

The Xcode project is configured for Apple team `Q42MT7JA7Q`, but a given Mac's
Xcode installation may not have that developer account signed in. Add the
account in Xcode Settings → Accounts before producing a signed archive.

Native SIWA is primary with email/password secondary. Apple-linked deletion
requires fresh SIWA
reauthorization (authorization code + platform client id
`com.phrasa.app` / `com.phrasa.mac`) and the server scaffold
`supabase/functions/delete-apple-linked-account` (allowlist client id, exchange
code, validate Apple-returned id_token, revoke, then Supabase delete; secrets
server-only; client identity_token is not used). The server function and its
secrets remain external deployment state. Do not claim token revocation or
Apple-linked deletion complete without live evidence.

The active Supabase schema is **sync-only** (no subscriptions, Lemon Squeezy,
or analytics tables). Production Mac↔iPad sync passed on 2026-07-29. The
publishable key and server credentials remain external; Apple-linked deletion
still requires its own live evidence.

## App Store archive

Marketing version is **1.0** (matches App Store Connect). Build **14** is the
final integrated iOS candidate (not builds 12–13). Physical Voice Follow and
real Mac↔iPad sync passed, and the signed Release archive succeeded on
2026-07-29. It was exported, uploaded, processed, selected, and submitted for
review the same day. App Store Connect is **Waiting for Review** (build ID
`9570010d-0625-403c-9955-c9d0d51e2306`, submission ID
`1ef88310-ff57-49d8-a02e-5a5c71ad07c5`). Manual release remains after Apple
approval. Product pin:
`7fac6ea406341313a3f169fe2ae42b1e565d1da0`.

**Hard gate:** do not archive, export, or upload until
`AppStore/Submission/validate.sh --mode release-ready` passes. That phase
includes real-device voice acceptance (also recorded under
[`AppStore/evidence/`](./AppStore/evidence/)) plus owner/signing prerequisites.
Simulator success is not enough. See [`AppStore/README.md`](./AppStore/README.md)
and [`AppStore/Submission/README.md`](./AppStore/Submission/README.md).

**Preferred path — fail-closed automation** (repo root):

```bash
# Local store packet completeness (also required inside --preflight)
ios-native/AppStore/Submission/validate.sh --mode packet

# Preflight: pin + packet + evidence + signing; isolated proof log only
# (no archive/export/Connect upload)
scripts/ios-release/release-ios.sh --preflight

# After evidence + signing hard gates pass (always runs package + XCTest; no skip)
scripts/ios-release/release-ios.sh --release
```

Uses **only** `ios-native/PhrasaNative.xcodeproj` (hard-fails if
`PhrasaNative 2.xcodeproj` exists), scheme/target `Phrasa`, Release,
`generic/platform=iOS`, team `Q42MT7JA7Q`, bundle `com.phrasa.app`, product pin
`7fac6ea406341313a3f169fe2ae42b1e565d1da0`. Preflight resolves settings via
`xcodebuild -showBuildSettings`, re-runs `AppStore/Submission/validate.sh
--mode packet`, and writes only under
`ios-native/build/release-runs/<UTC>-<pid>-<random>/` (gitignored; unique per
invocation). Generates a temporary ExportOptions plist on `--release`. Upload
requires `--validate --upload` plus the exact confirmation phrase and ASC API
key env vars (never pass `.p8` contents). Store listing packet:
[`AppStore/Submission/`](./AppStore/Submission/).

Manual Xcode/`xcodebuild` remains possible for debugging but must still honor
release-ready and the authoritative project path. Do not run archive/export as
part of ordinary development or before release-ready passes. Build 14 has
already completed submission-ready checks and is Waiting for Review; do not
upload another build unless intentionally starting a new candidate.

## Voice-follow spoken commands (iOS)

While voice following is playing, say the full phrase including the wake word:

| Say | Effect |
|-----|--------|
| `phrasa previous paragraph` | First token of the previous paragraph (or start of the first) |
| `phrasa next paragraph` | First token of the next paragraph (no-op at end) |
| `phrasa current paragraph` | Restart the paragraph you are in |

Also accepted after normalize: `last` / `prior` / `go back` / `back` (previous);
`following` / `forward` (next); `this` / `restart` / `repeat` (current). ASR
wake-word variants `frasa` / `frase` are accepted. Matching is exact on
normalized tokens (suffix of the recognition tail), with a ~1.25s cooldown so
a single utterance cannot multi-fire. Ordinary words in the script without the
prefix never trigger navigation.

## Command-line verification

```bash
# iOS
xcodebuild -project PhrasaNative.xcodeproj \
  -scheme Phrasa \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  test

# macOS build through Xcode; for unsigned unit tests, build once and run the
# produced hosted test bundle with its app dylib on DYLD_LIBRARY_PATH.
xcodebuild -project PhrasaNative.xcodeproj \
  -scheme PhrasaMac \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO build-for-testing
```

Shared packages can also be tested independently:

```bash
swift test --package-path Packages/PhrasaCore --parallel
swift test --package-path Packages/PhrasaDomain --parallel
swift test --package-path Packages/PhrasaPersistence --parallel
swift test --package-path Packages/PhrasaSync --parallel
```

`PhrasaDomain` holds platform-neutral models, ownership/sync records, resume
progress invariants, and the `LibraryPersistence` protocol. `PhrasaPersistence`
holds the shipping SQLite store and the JSON test double. The iOS app still
compiles those package sources into its target for type resolution without
import churn. The Mac app links the package products directly (`import PhrasaDomain`,
`import PhrasaPersistence`).
