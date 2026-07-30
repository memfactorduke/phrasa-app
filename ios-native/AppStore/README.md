# App Store package — operator checklist

Release package for the native iPhone and iPad app. These documents and local
assets do not prove that anything has been uploaded, saved, or deployed.

| File | Contents |
| --- | --- |
| [Submission/](./Submission/) | **Machine-ready en-US submission packet** + live Connect audit + `validate.sh` (packet / release-ready / submission-ready) |
| [METADATA.md](./METADATA.md) | Verified release state, proposed store copy, App Privacy guidance, and owner decisions |
| [SCREENSHOT_PLAN.md](./SCREENSHOT_PLAN.md) | Device sizes, shot list, visual rules, and local asset inventory |
| [Screenshots/](./Screenshots/) | Local copies of the 10 JPEG assets uploaded to App Store Connect |
| [evidence/](./evidence/) | Physical-device voice acceptance template + workflow (hard gate for archive) |

**Fail-closed automation (build 14):**
[`scripts/ios-release/release-ios.sh`](../../scripts/ios-release/release-ios.sh)

---

## Verified release state (2026-07-29)

| Item | State |
| --- | --- |
| Apple ID / bundle ID | **6780259086** / **com.phrasa.app** |
| Team ID | **Q42MT7JA7Q** |
| Connect version | **1.0** |
| Local binary marketing version | **1.0** — aligned with Connect (verified in `project.yml` / `project.pbxproj`) |
| Exact release source commit | **`7fac6ea406341313a3f169fe2ae42b1e565d1da0`** |
| Final integrated iOS candidate | **14** — not builds 12–13 |
| App status | **Waiting for Review** |
| Saved name | **Phrasa Free Teleprompter** — owner-selected replacement, live-verified 2026-07-28 |
| Native Swift build 14 | Exported, uploaded, processed, selected, and submitted on 2026-07-29; build ID `9570010d-0625-403c-9955-c9d0d51e2306` |
| Review submission | **Waiting for Review** — submission ID `1ef88310-ff57-49d8-a02e-5a5c71ad07c5` |
| Native Swift build 13 | Prior local lineage; do not reuse as the shipping candidate |
| Native Swift build 12 | Prior local lineage; do not reuse as the shipping candidate |
| Native Swift build 11 | Prior local lineage; do not reuse as the shipping candidate |
| Legacy Expo builds 9 and 10 | Present, but not the shipping candidate |
| Screenshots | 10 COMPLETE assets uploaded: 5 iPhone 6.9-inch + 5 iPad 13-inch |
| Free Apps Agreement | **Active** |
| Paid Apps Agreement | Not needed while the app is free with no paid content or purchases |
| `phrasa.app`, `/privacy`, `/support` | **Live** — current production deployment reverified 2026-07-28 |
| Web companion `/app` | **Live**, including mirrored focus guide, Off / 5s / 15s countdown, and production Supabase/Apple OAuth redirect smoke proof |
| Latest support/source copy | Deployed to Vercel production and aliased to `phrasa.app` |
| Public support contact | **support@phrasa.app** is activated and monitored; verified at **2026-07-18T22:25:00Z**. Keep it monitored through review and release |
| Real-device voice acceptance | **Passed on iPad Air 5 / iPadOS 26.5 on 2026-07-29** — physical microphone, on-device recognition, alignment/progress, permission handling, relaunch/interruption, repeated starts/stops, and recovery accepted |
| Real Mac↔iPad Supabase sync | **Passed on physical Mac and iPad on 2026-07-29** |
| Signing / upload readiness | Apple Distribution identity and dedicated App Manager API key are live-verified |
| App Privacy | **Published live 2026-07-28** — Email Address, User ID, and Other User Content configured as linked/App Functionality/not tracking |
| Tax / extra platforms | `App Store software`; Apple Silicon Mac and Vision Pro availability disabled |

In-app Privacy Policy and Support links, plus the bundled Atkinson Hyperlegible
OFL notice, are in the submitted candidate. Preserve their verification as a
regression gate for any future build.

---

## Order of operations (three-phase packet + automation)

The submission packet under [Submission/](./Submission/) defines a **non-circular**
three-phase workflow. Release automation maps **one-way** onto those phases:
preflight requires `--mode packet` only; packet tools never require a release run.
Do not invent a fourth phase. Product pin for this lane:
`7fac6ea406341313a3f169fe2ae42b1e565d1da0`.

| Step | Validator / tool | Meaning |
| --- | --- | --- |
| Before Connect work | `./Submission/validate.sh --mode packet` | Local packet complete (also required inside release `--preflight`) |
| Before archive/export/upload | `./Submission/validate.sh --mode release-ready` | Voice + owner external + signing ready |
| Archive / export (preferred) | `scripts/ios-release/release-ios.sh --preflight` then `--release` | Fail-closed pin/packet/evidence/signing + tests + archive + export |
| After Connect saves / build selection | `./Submission/validate.sh --mode submission-ready` | Exact Connect evidence OK to submit |

1. **Versions are aligned for the candidate**
   Connect and the binary both use marketing version **1.0**. Build **14** is
   the next final integrated candidate (not builds 12–13). Confirm the project
   build number is **14**. Run **packet** mode
   (`./Submission/validate.sh --mode packet`).

2. **Complete — physical Voice Follow acceptance**
   On real hardware, first ensure a valid physical session (no active call/VoIP,
   device unlocked, display on/awake, Phrasa visibly foregrounded — process
   residency alone is not proof), then accept the full microphone → recognition
   → alignment path: permission grant and denial, on-device recognition where
   supported, Apple-service fallback where available, progress through a real
   script, interruptions, background/foreground transitions, and repeated
   starts and stops. Simulator success and unit tests are not enough. Record
   evidence in [evidence/](./evidence/) (exact precondition tokens) for
   automation and in `Submission/voice-gate.yaml` for release-ready.
   This passed on the pinned candidate on 2026-07-29. Preserve the detailed
   ignored evidence securely; the tracked `voice-gate.yaml` is the public
   high-level record, not a substitute for preflight evidence.

3. **Complete — owner external readiness**
   Fill `Submission/operator-placeholders.yaml` (review contact, copyright, DSA
   decision, support channel activated/monitored, website redeploy + URL
   re-verify). Confirm signing and upload-path readiness in
   `Submission/release-prerequisites.yaml`. Run **release-ready** mode — must
   PASS before step 5.

4. **Verify in-app legal links and bundled OFL in the archive**
   Source includes the intended Privacy Policy and Support destinations and the
   bundled OFL notice. Confirm them in the archived binary (only after step 3).

5. **Complete — archive, export, and upload build 14**

   **Preferred — fail-closed automation** (repo root):

   ```bash
   scripts/ios-release/release-ios.sh --preflight
   scripts/ios-release/release-ios.sh --release
   # Optional: --validate --upload with typed confirmation (see automation section)
   ```

   Manual path (debugging only) still requires the authoritative project
   `ios-native/PhrasaNative.xcodeproj` (never Finder duplicates such as
   `PhrasaNative 2.xcodeproj`):

   ```bash
   # From ios-native/
   # Apple Distribution signing is required. -allowProvisioningUpdates may
   # self-heal signing/provisioning; that is not guaranteed.
   xcodebuild -allowProvisioningUpdates \
     -project PhrasaNative.xcodeproj \
     -scheme Phrasa \
     -configuration Release \
     -destination 'generic/platform=iOS' \
     -archivePath ./build/Phrasa.xcarchive \
     archive

   xcodebuild -exportArchive \
     -archivePath ./build/Phrasa.xcarchive \
     -exportPath ./build/export \
     -exportOptionsPlist ExportOptions.plist \
     -allowProvisioningUpdates
   ```

   The API-key upload path is configured. Example API-key form for a future
   candidate:

   ```bash
   xcrun altool --upload-app --type ios --file <path-to.ipa> \
     --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
   ```

   Build 14 was processed and selected in Connect on 2026-07-29 (build ID
   `9570010d-0625-403c-9955-c9d0d51e2306`). Do not select Expo build 9 or 10
   or reuse a stale build-11, build-12, or build-13 IPA.

6. **Save the public name and store copy**
   **Complete:** `Phrasa Free Teleprompter` and the reviewed subtitle,
   promotional text, description, keywords, and review notes are saved. What’s
   New is correctly omitted for this first version. Exact live evidence is in
   `Submission/connect-evidence.yaml`.

7. **Upload screenshots**

   - iPhone 6.9-inch: **1320 × 2868**
   - iPad 13-inch: **2064 × 2752**

   Local capture does not equal Connect upload. See
   [SCREENSHOT_PLAN.md](./SCREENSHOT_PLAN.md). Bind counts and file order in
   `connect-evidence.yaml` to the packet manifest.

8. **Complete App Privacy, categories, age rating, rights, export, pricing**
   For the intended sync-enabled binary, the top-level privacy answer is **Yes,
   we collect data** for optional sync: Email Address, User ID, and Other User
   Content (linked to user, App Functionality, not tracking). Answer **No** to
   tracking. Free price; tax category exactly **App Store software**; US
   availability. Publish the verified privacy URL. Record exact values in
   `connect-evidence.yaml`.

9. **Complete — review, compliance, and build selection**
   Sign-in required is off, Manual release
   is set, Apple Silicon Mac and Vision Pro availability are disabled, the
   owner’s private review contact and notes are saved, and DSA/social-media
   answers are saved. Processed build **1.0 (14)** is selected.

10. **Complete — submission**
    Submission-ready passed and the owner submitted build **1.0 (14)** on
    2026-07-29. Current state is **Waiting for Review**, submission ID
    `1ef88310-ff57-49d8-a02e-5a5c71ad07c5`. After approval, **manually**
    release.

---

## Release automation (fail-closed)

Authoritative inputs only:

| Input | Value |
| --- | --- |
| Xcode project | **`ios-native/PhrasaNative.xcodeproj`** only (never glob; never `PhrasaNative 2.xcodeproj`) |
| Scheme / config / destination | `Phrasa` / `Release` / `generic/platform=iOS` |
| Marketing / build / bundle / team | `1.0` / `14` / `com.phrasa.app` / `Q42MT7JA7Q` |
| Product source pin | `7fac6ea406341313a3f169fe2ae42b1e565d1da0` (HEAD may be a descendant only if product paths match the pin) |
| Expected pbxproj SHA-256 | `3f4d3d4a7186b49777f1374206f0102d0807501040156a02ecd032f33ee0a091` |
| Expected candidate fingerprint | `344fd52de4a8dce9e53ac825e0a02746976019a994715e7ab34acb26cd229436` |

### Commands

```bash
# Optional fast local packet check (also required inside --preflight):
ios-native/AppStore/Submission/validate.sh --mode packet

# Preflight: source pin + packet + evidence + signing audits; reports every blocker;
# never archives/exports/App Store validates/uploads.
# Writes only an isolated gitignored proof dir (log + showBuildSettings dump).
# Does not alter tracked files or App Store Connect state.
scripts/ios-release/release-ios.sh --preflight

# Gated path after preflight hard gates pass (evidence + signing + clean tree, …):
# always runs package tests + full iOS XCTest (no --skip-tests), then
# Release generic build, archive, export, inspect
scripts/ios-release/release-ios.sh --release

# App Store Connect validate then upload (second explicit confirmation; never default)
export ASC_KEY_ID=…          # key id only — never the .p8 body
export ASC_ISSUER_ID=…       # issuer UUID
# Place AuthKey_<ASC_KEY_ID>.p8 in ~/.appstoreconnect/private_keys/ (or ~/private_keys/)
scripts/ios-release/release-ios.sh --release --validate --upload \
  --confirm-upload 'UPLOAD BUILD 14 TO APP STORE CONNECT'
```

There is **no** `--skip-tests`. Production release always runs package tests and
iOS XCTest.

Artifacts and tee logs: `ios-native/build/release-runs/<UTC>-<pid>-<random>/`
(gitignored; unique per invocation), including `preflight.log`,
`phrasa-release-showBuildSettings.txt`, and (on `--release`)
`proof-manifest.txt` (source commit + SHA-256 hashes of evidence, archive/IPA,
export/validation/upload proofs, test/build/inspection logs, and deterministic
`.xcresult` file-hash listings; no secrets). Preflight does **not** create
DerivedData, `.xcarchive`, or `.ipa`.

Preflight asserts **resolved Phrasa target Release** settings via
`xcodebuild -showBuildSettings` (`-project` / `-target Phrasa` /
`-configuration Release` / `-destination generic/platform=iOS`), not a loose
grep of `project.pbxproj`.

Export uses a **temporary** `ExportOptions.generated.plist` (App Store Connect
method, automatic signing, `manageAppVersionAndBuildNumber=false`, team
`Q42MT7JA7Q`, symbols on). Do not depend on a stale checked-in
`ios-native/ExportOptions.plist` for the automated path.

Archive inspection proves team identity via codesign and/or embedded profile
(rejects ad-hoc and missing/mismatched TeamIdentifier). IPA inspection requires
**Apple Distribution** signing, matching team, and embedded profile. Privacy
manifests are parsed as plists (`NSPrivacyTracking=false` + required reason API).

### Physical voice-acceptance evidence

1. Confirm local packet completeness (`Submission/validate.sh --mode packet`) and
   note the expected fingerprint from the table above (or from `--preflight`).
2. Copy [evidence/VOICE_ACCEPTANCE_TEMPLATE.md](./evidence/VOICE_ACCEPTANCE_TEMPLATE.md)
   to `evidence/VOICE_ACCEPTANCE_BUILD14.md` (or set `PHRASA_VOICE_EVIDENCE_PATH`).
3. On **physical** hardware, prepare a valid session, then prove the full mic →
   recognition → alignment path and fill every `KEY=VALUE` field
   (`OUTCOME_*=pass` only when truly proven).
   **Operator sequence:** end all calls/VoIP (reboot if call UI stuck) → unlock
   (`DEVICE_PASSCODE_REQUIRED=false`) → display on/awake
   (`DEVICE_DISPLAY_STATE=on`) → open Phrasa visibly foregrounded
   (`PHRASA_VISIBLY_FOREGROUNDED=true`) → confirm
   `ACTIVE_CALL_OR_VOIP=false` → run the full stimulus. Process residency alone
   is not proof; precondition fields are human-attested and must not be
   fabricated.
4. When physical proof is complete, also set
   [Submission/voice-gate.yaml](./Submission/voice-gate.yaml) `status: passed`
   with device notes (required for `--mode release-ready`; not a substitute
   for the evidence file).
5. Re-run `--preflight`. Template/missing/incomplete/false/stale/mismatched/
   non-exact-precondition evidence fails closed. Automation never fabricates
   or auto-approves.

### Worktree cleanliness

Tracked tree must be clean. Untracked files fail closed **except** when the
operator explicitly elects `PHRASA_ALLOW_KNOWN_FINDER_DUPES=1` for these four
pre-existing Finder duplicates only (main checkout):

- `ios-native/Phrasa/Design/VoiceTrustPresentation 2.swift`
- `ios-native/Phrasa/Reader/PrompterTextView 2.swift`
- `ios-native/Phrasa/Reader/ReaderView 2.swift`
- `ios-native/PhrasaMac/Reader/MacDisplaySleepGuard 2.swift`

**`ios-native/PhrasaNative 2.xcodeproj` is always a hard failure.** Prefer the
isolated clean release worktree (no untracked files).

### Current release state (2026-07-29; no secret material)

As of this documentation pass on the operator machine used to land automation:

| Area | Observed state |
| --- | --- |
| Physical voice evidence file | **Complete and intentionally ignored by Git** — securely transfer the real `VOICE_ACCEPTANCE_BUILD14.md` or set `PHRASA_VOICE_EVIDENCE_PATH`; never commit its device identifier |
| Apple Distribution identity | **Present and valid** — `Apple Distribution: Memorable Factor (Q42MT7JA7Q)`, expires 2027-07-28 |
| Provisioning profiles | **7 profile files** under modern Xcode root `~/Library/Developer/Xcode/UserData/Provisioning Profiles`; **none** under legacy `~/Library/MobileDevice/Provisioning Profiles`. One **exact valid App Store match**: Name `iOS Team Store Provisioning Profile: com.phrasa.app`, team `Q42MT7JA7Q`, application-identifier `Q42MT7JA7Q.com.phrasa.app`, expiration `2027-07-17` — **no longer a provisioning hard blocker** |
| ASC API key file (`AuthKey_*.p8`) | Dedicated App Manager key securely stored outside the repository and live-verified |
| `ASC_KEY_ID` / `ASC_ISSUER_ID` | Known to the release operator; never commit or print private-key material |
| Build 14 archive / IPA / Connect | **Complete through submission** — build ID `9570010d-0625-403c-9955-c9d0d51e2306`, selected for 1.0 |
| Review submission | **Waiting for Review** — submission ID `1ef88310-ff57-49d8-a02e-5a5c71ad07c5`; manual release remains after approval |

Preflight still verifies the exact identity, profile, and credentials at release
time for any future candidate. Build 14 has completed Voice, owner, signing,
archive, export, upload, processing, build selection, and submission gates.

### Parser / smoke tests

```bash
bash scripts/ios-release/tests/test_evidence_parser.sh
bash scripts/ios-release/tests/test_helpers_and_gates.sh
bash scripts/ios-release/tests/test_provisioning_profiles.sh
bash scripts/ios-release/tests/test_preflight_no_archive.sh
bash -n scripts/ios-release/release-ios.sh
for f in scripts/ios-release/lib/*.sh; do bash -n "$f"; done
```

---

## Screenshot inventory

The same assets exist locally and are **uploaded** in App Store Connect. Each
set has **five** JPEG frames (no alpha), in Voice-first order. Filenames keep
their capture numbers; Connect order is independent of the `01`–`05` prefixes.

### iPhone 6.9-inch — 1320 × 2868

| Upload order | File | Shot |
| --- | --- | --- |
| 1 | `Screenshots/iPhone-6.9/05-voice-reader.jpg` | Voice reader (static UI; not live recognition) |
| 2 | `Screenshots/iPhone-6.9/01-library.jpg` | Library |
| 3 | `Screenshots/iPhone-6.9/02-editor.jpg` | Editor |
| 4 | `Screenshots/iPhone-6.9/03-speed-reader.jpg` | Speed reader |
| 5 | `Screenshots/iPhone-6.9/04-onboarding.jpg` | Onboarding |

### iPad 13-inch — 2064 × 2752

| Upload order | File | Shot |
| --- | --- | --- |
| 1 | `Screenshots/iPad-13/05-voice-reader.jpg` | Voice reader (static UI; not live recognition) |
| 2 | `Screenshots/iPad-13/01-library.jpg` | Library |
| 3 | `Screenshots/iPad-13/02-editor.jpg` | Editor |
| 4 | `Screenshots/iPad-13/03-speed-reader.jpg` | Speed reader |
| 5 | `Screenshots/iPad-13/04-onboarding.jpg` | Onboarding |

Optional and not yet captured: reader settings/appearance and outline presenter.
See [SCREENSHOT_PLAN.md](./SCREENSHOT_PLAN.md) for capture rules and size
constraints.

---

## Release warnings

- The Paid Apps Agreement is not required for this free release. Do not treat
  it as an upload blocker unless the business model changes.
- Build 14 was exported, uploaded, processed, selected, and submitted on
  2026-07-29. It is Waiting for Review; builds 12–13 and any prior build-11
  local IPA must not be treated as this candidate.
- The physical iPad microphone → recognition → alignment acceptance passed.
  Preserve its ignored human-attested evidence securely and never commit the
  device identifier.
- Archive/export must use `ios-native/PhrasaNative.xcodeproj`, not Finder
  duplicate projects.
- Apple Distribution signing and App Store Connect API-key credentials were
  sufficient for the completed build-14 upload. Keep them outside Git.
- Public routes are live from the current production deploy, and
  `support@phrasa.app` is activated and monitored.
- Do not publish or enter placeholder domains, contact details, legal answers,
  or copyright information.
- The name, build upload, selection, and review submission are verified live.
  Do not claim approval or public release until Apple provides it and the owner
  completes manual release.
- Production Supabase configuration is injected from the operator environment,
  never Git. Physical Mac↔iPad sync passed; Apple-linked deletion remains a
  separate evidence gate and is not claimed complete.
