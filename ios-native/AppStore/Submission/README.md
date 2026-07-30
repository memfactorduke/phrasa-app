# App Store submission packet (en-US)

Machine-ready **local** packet for Phrasa iOS **1.0 (14)**. Operators can copy
fields into App Store Connect. This directory does **not** upload, save Connect
fields, or click Submit for Review by itself.

Validation is split into **three phases** so each command can be run at the
moment the docs say to run it — nothing requires proof that can only exist
*after* that step.

| Phase | When to run | What it proves |
| --- | --- | --- |
| **packet** | Anytime, before App Store work | Local metadata, screenshots, questionnaires, and project identity are complete and consistent. |
| **release-ready** | After voice + owner external gates + signing prep; **before** archive/export/upload | Safe to produce and upload the exact **1.0 (14)** candidate. Does **not** require Connect saves or a processed build. |
| **submission-ready** | After upload, processing, build selection, and all Connect saves; **immediately before Submit** | Machine-checked Connect evidence matches the required exact values for this release. |

**Current state (2026-07-29):** all three validation phases passed for build
**1.0 (14)**. Physical Voice Follow, production Mac↔iPad sync, signing/API
readiness, archive, export, upload, processing, build selection, and review
submission are complete. App Store Connect is **Waiting for Review**. Build ID:
`9570010d-0625-403c-9955-c9d0d51e2306`; submission ID:
`1ef88310-ff57-49d8-a02e-5a5c71ad07c5`. Manual release remains after approval.

Accessibility labels are **optional**. Do not claim or require them without proof.

---

## App Store Connect release-state audit (read-only, through 2026-07-29)

Current recorded *snapshot* of Connect after review submission:
[`connect-audit.yaml`](./connect-audit.yaml) (mirrored under `packet.json` →
`connect_audit`). The validator does **not** re-fetch Connect.

Progressive **save proof** belongs in
[`connect-evidence.yaml`](./connect-evidence.yaml) and is checked only in
**submission-ready**.

| Fact | Recorded Connect value | Operator action |
| --- | --- | --- |
| Apple ID | **6780259086** | Documented |
| iOS version | **1.0** — **Waiting for Review** | Preserve the submitted review state |
| Version store metadata | **Saved** | Later local copy edits require separate live verification |
| Screenshots in Connect | **10** | Complete: five iPhone 6.9-inch and five iPad 13-inch |
| Build selected | **1.0 (14)** | Submitted binary; do not attribute later source changes to it |
| Sign-in required | **OFF** | Saved target state |
| Release mode | **Manual** | Saved target state |
| App Review contact | **Saved** | Owner-supplied private values |
| DSA | **Saved**, U.S.-only decision | No remaining banner |
| Age rating Social Media answer | **No** | Saved; all Social/UGC **No/None** |

Field-level proof is in [`connect-evidence.yaml`](./connect-evidence.yaml).
The older July 18 empty-listing baseline remains documented in
[`../METADATA.md`](../METADATA.md), rather than being presented as current.
Build **1.0 (14)** was processed and selected, export compliance was saved, and
review submission completed on 2026-07-29.

---

## Validate

From this directory:

```bash
# Phase 1 — local packet (should PASS on the unfilled template)
./validate.sh
./validate.sh --mode packet

# Phase 2 — before archive/export/upload (currently passes)
./validate.sh --mode release-ready

# Phase 3 — after Connect work, before Submit (passes for submitted 1.0 (14))
./validate.sh --mode submission-ready

# Legacy alias (same as submission-ready)
./validate.sh --mode final
```

Or:

```bash
python3 validate_packet.py --mode packet
python3 validate_packet.py --mode release-ready
python3 validate_packet.py --mode submission-ready
```

Automated tests (from this directory):

```bash
python3 -m unittest test_validate_packet.py -v
```

Uses Python 3 stdlib plus macOS `sips` when available (optional Pillow). No network.

### Relation to release automation (one-way)

`scripts/ios-release/release-ios.sh --preflight` **requires** this packet
validator in `--mode packet` as a local source check. That is a one-way
dependency: release preflight → packet validate.

Do **not** invert the sequence (packet tools must not require a successful
release run). `--mode release-ready` and `--mode submission-ready` are
operator/owner gates and are **not** invoked by release automation. No mode
proves App Store Connect upload/save/processing; live Connect verification
stays a separate operator step after archive/export/upload.

---

## Safe operator order (non-circular)

Do **not** treat this list as authorization to upload or submit. Full binary
lane detail also lives in [../README.md](../README.md). Sequence maps to the
three phases only — no circular dependency on release automation.

### Phase 1 — Packet

1. Complete local copy, questionnaires, and screenshot assets in this packet.
2. Run `./validate.sh --mode packet` — fix any FAIL before continuing.
   (Release `--preflight` re-runs this one-way; packet tools never require release.)

### Phase 2 — Release-ready (before any archive)

3. Complete **physical voice acceptance** on real hardware:
   - Fail-closed evidence file under [`../evidence/`](../evidence/) for
     release automation (exact precondition tokens required).
   - Set `voice-gate.yaml` to `status: passed` and fill `evidence`
     (`device_model`, `ios_version`, `tested_on`, `notes`) for release-ready.
4. Activate and verify monitoring of `support@phrasa.app`; update
   `operator-placeholders.yaml`.
5. Redeploy website source if production must match the repo; browser-verify
   home, privacy, and support URLs; record dates in `operator-placeholders.yaml`.
6. Fill owner-only fields in `operator-placeholders.yaml`: App Review contact,
   copyright, DSA decision (`trader` | `non_trader` | `not_applicable_decision`).
7. Confirm signing and upload-path readiness in
   [`release-prerequisites.yaml`](./release-prerequisites.yaml)
   (Apple Distribution, provisioning, API key or Transporter credentials).
   Set `ready_to_archive: true` only when those are real.
8. Run `./validate.sh --mode release-ready` — must **PASS** before archive.
   Preferred readiness path also:
   `scripts/ios-release/release-ios.sh --preflight` (requires packet mode +
   evidence + signing; never archives).

### Archive / export / upload (only after release-ready PASS)

9. Preferred: `scripts/ios-release/release-ios.sh --release` (always runs tests).
   Manual: archive / export / upload native **1.0 (14)** using
   `ios-native/PhrasaNative.xcodeproj` only (never Finder duplicates whose
   names contain ` 2`). Commands live in [`../README.md`](../README.md).
10. Wait until the build is **processed** in App Store Connect.

### Phase 3 — Submission-ready (after Connect work)

11. In Connect (owner), save everything this release requires, then record
    **exact values** in [`connect-evidence.yaml`](./connect-evidence.yaml):

    | Gate | Evidence field (exact checks) |
    | --- | --- |
    | Public app name **Phrasa Free Teleprompter** | `public_app_name.saved_value: Phrasa Free Teleprompter` |
    | All version metadata saved | `version_metadata.*_saved: true` |
    | Privacy completed + published | `privacy.questionnaire_completed`, `privacy.published`, collects **true** (optional sync) / tracks **false**, Email Address + User ID + Other User Content, URL exact |
    | Age rating + Social/UGC all No | `age_rating.*` + `social_media_age_rating.answer: no` |
    | Categories Productivity / Utilities | `categories.primary_saved` / `secondary_saved` |
    | Content rights saved | `content_rights.*` |
    | Export compliance saved | `export_compliance.uses_non_exempt_encryption: false` |
    | Free price + tax **App Store software** + US | `pricing_availability.*` |
    | Screenshots in **iPhone 6.9-inch** and **iPad 13-inch** only | `screenshots.iphone_6_9` / `ipad_13` count + file order bound to manifest |
    | Exact **1.0 (14)** processed build selected | `build_selection.*` |
    | Sign-in required **OFF** | `sign_in_required.saved_value: false` |
    | Manual release | `release_mode.saved_value: manual` |
    | Apple Silicon Mac **disabled** | `apple_silicon_mac.availability: disabled` |
    | Vision Pro **disabled** | `vision_pro.compatibility: disabled` |
    | Review contact + notes saved | `app_review.*` |
    | DSA decision saved | `dsa.decision_saved` + `dsa.status` |
    | Social-media age-rating answer saved | `social_media_age_rating.*` |

12. Run `./validate.sh --mode submission-ready` — must **PASS** before Submit.
13. Owner submits for review when ready. After approval, **manually** release.

---

## What is complete (packet)

| Area | Location |
| --- | --- |
| Live Connect audit snapshot | `connect-audit.yaml`, `packet.json` |
| Connect save evidence template | `connect-evidence.yaml` (null until proven) |
| Pre-archive prerequisites template | `release-prerequisites.yaml` |
| Public name, subtitle, promo, description, keywords | `en-US/*.txt`, `en-US/store-listing.yaml` |
| Support / marketing / privacy URLs | `packet.json`, `en-US/store-listing.yaml` |
| App Review notes (voice steps + Apple Speech disclosure) | `en-US/review-notes.txt` |
| Privacy questionnaire | `privacy-questionnaire.yaml` |
| Age rating + social media capability **No** + all Social/UGC No/None | `age-rating.yaml` |
| Categories (Productivity / Utilities) | `categories.yaml` |
| Content rights | `content-rights.yaml` |
| Export compliance (`ITSAppUsesNonExemptEncryption` false) | `export-compliance.yaml` |
| Pricing (free) + US-first + tax category App Store software | `pricing-availability.yaml` |
| Sign-in desired **OFF** | `sign-in.yaml` |
| Release desired **manual** | `release-mode.yaml` |
| Build identity **1.0 (14)** / Apple ID | `build-identity.yaml`, `packet.json` |
| Screenshots (6.9 iPhone + 13 iPad, voice-first) | `screenshots-manifest.yaml` → `../Screenshots/` |
| Voice gate status + acceptance criteria | `voice-gate.yaml` |
| Owner-only placeholders (null/TODO) | `operator-placeholders.yaml` |

### Screenshot size classes and Media Manager slots

Official accepted sizes used by this packet (1–10 images per device display slot):

| Local set | Pixels | **Upload to Connect slot** | **Do not use** |
| --- | --- | --- | --- |
| `Screenshots/iPhone-6.9/` | **1320×2868** | Media Manager **iPhone 6.9-inch** | **iPhone 6.5-inch** well (often shown on the default version page) |
| `Screenshots/iPad-13/` | **2064×2752** | Media Manager **iPad 13-inch** | Any non-13-inch iPad well |

**Operator warning:** the default version page may display a **6.5-inch**
screenshot well. The existing 1320×2868 images **belong only in the 6.9-inch
Media Manager slot**. Do not place them in the 6.5-inch well.

Upload order (both sets): Voice → Library → Editor → Speed → Onboarding.
Voice frames are **static** (e.g. Voice paused)—UI presence only, not live recognition.

Optional not captured: 6.5-inch dedicated assets, other iPhone sizes, reader
settings, outline presenter. Accessibility labels are optional.

---

## What each phase blocks on

### packet (should pass now)

Missing files, bad field limits, wrong project identity, missing local
screenshots, prohibited marketing claims, inconsistent packet answers.

### release-ready (passes for the pinned candidate)

1. `voice-gate.yaml` `status: passed` with non-null evidence fields
2. App Review contact, copyright, DSA decision in `operator-placeholders.yaml`
3. Support channel activated + monitored + `verified_at`
4. Website redeploy + live URL re-verify dates
5. `release-prerequisites.yaml`: exact **1.0 (14)** candidate, signing ready,
   upload path credentials verified, `ready_to_archive: true`
6. Must **not** claim archive/upload/selection completed inside
   `release-prerequisites.yaml` (those belong later in connect evidence)

### submission-ready (passed for 1.0 (14))

Everything in release-ready, **plus** all exact-value fields in
`connect-evidence.yaml` listed in the table above (wrong values fail closed).
For build 14 these values were filled and the app was submitted successfully.

---

## Field limits (en-US, stable)

| Field | Limit | How measured |
| --- | --- | --- |
| Name | 30 characters | Unicode length |
| Subtitle | 30 characters | Unicode length |
| Promotional text | 170 characters | Unicode length |
| Description | 4000 characters | Unicode length |
| Keywords | 100 **UTF-8 bytes** | Entire string **including commas**; no spaces after commas |

---

## Related docs

- [`connect-audit.yaml`](./connect-audit.yaml) — live Connect read-only snapshot
- [`connect-evidence.yaml`](./connect-evidence.yaml) — Connect save evidence (submission-ready)
- [`release-prerequisites.yaml`](./release-prerequisites.yaml) — pre-archive readiness
- `../METADATA.md` — prior audit notes + proposed copy history
- `../README.md` — operator checklist, three-phase flow, and release automation
- `../evidence/` — physical-device voice acceptance for release automation
- `../../../scripts/ios-release/release-ios.sh` — fail-closed preflight/release lane
- `../SCREENSHOT_PLAN.md` — capture rules and honesty boundary for voice frames
