# Phrasa — App Store & TestFlight metadata

Release documentation for the native iPhone and iPad app. This file separates
verified App Store Connect state from proposed copy. Do not invent contact,
legal, or business answers where the owner must decide.

**Release posture:** free, local-first shipping build with **optional** Supabase
accounts and Mac/iPad sync. Sign in with Apple is primary; email/password is
secondary. No account is required for local use. App Privacy must declare data
collection for optional sync (not “no data collected”).

---

## Verified current state (audit 2026-07-29)

### App record and binary

| Field | Verified value |
| --- | --- |
| Apple ID | **6780259086** |
| Bundle ID | **com.phrasa.app** |
| App Store Connect version | **1.0** |
| Local native marketing version | **1.0** (aligned with Connect) |
| Final integrated iOS candidate | **14** — not builds 12–13 |
| Status | **Waiting for Review** |
| Saved localized name | **Phrasa Free Teleprompter** |
| Public-name decision | Owner-selected replacement saved and live-verified 2026-07-28 |
| Native Swift build 14 | Exported, uploaded, processed, selected, and submitted 2026-07-29; build ID `9570010d-0625-403c-9955-c9d0d51e2306` |
| Review submission | **Waiting for Review** — submission ID `1ef88310-ff57-49d8-a02e-5a5c71ad07c5`; manual release after approval |
| Native Swift build 13 | Prior local lineage; **do not reuse** as the shipping candidate |
| Native Swift build 12 | Prior local lineage; **do not reuse** as the shipping candidate |
| Native Swift build 11 | Prior local IPA/archive lineage; **do not reuse** as the shipping candidate |
| Legacy Expo builds 9 and 10 | Ready to Submit; not the shipping candidate |

Connect version **1.0** and the native binary marketing version **1.0** match.
Build **14** is the final integrated candidate so it cannot be confused
with builds 12–13 or a stale pre-rebuild build-11 IPA.

### Completed physical Voice gate

Real-device Voice Follow acceptance passed on 2026-07-29 on physical hardware.
The accepted session had no active calls/VoIP, the device was unlocked with its
display awake, and Phrasa was visibly foregrounded; process residency alone was
not treated as proof. It covered the microphone →
recognition → alignment path, permission handling, on-device recognition,
progress through a real script, relaunch/interruption, and repeated starts and
stops. Simulator success, unit tests, and other non-device checks would not
have proved that path.

The detailed acceptance record is the ignored local
`evidence/VOICE_ACCEPTANCE_BUILD14.md`, created from
[evidence/VOICE_ACCEPTANCE_TEMPLATE.md](./evidence/VOICE_ACCEPTANCE_TEMPLATE.md),
including exact precondition tokens
(`DEVICE_PASSCODE_REQUIRED=false`, `DEVICE_DISPLAY_STATE=on`,
`ACTIVE_CALL_OR_VOIP=false`, `PHRASA_VISIBLY_FOREGROUNDED=true`). The
fail-closed parser rejects template, incomplete, non-`pass`, stale, mismatched,
or non-exact-precondition fields. Securely transfer the real file between
release Macs; never commit its device identifier. Precondition fields are
human-attested and automation never fabricates evidence.

### Fail-closed automation (preferred)

Exact lane constants: product source pin
`7fac6ea406341313a3f169fe2ae42b1e565d1da0`, marketing **1.0**, build **14**,
bundle **com.phrasa.app**, team **Q42MT7JA7Q**, project
`ios-native/PhrasaNative.xcodeproj` only (hard-fail on
`PhrasaNative 2.xcodeproj`). Expected candidate fingerprint
`344fd52de4a8dce9e53ac825e0a02746976019a994715e7ab34acb26cd229436`
(pbxproj SHA-256
`3f4d3d4a7186b49777f1374206f0102d0807501040156a02ecd032f33ee0a091`).

```bash
# Local packet completeness (also required inside --preflight)
ios-native/AppStore/Submission/validate.sh --mode packet

# Read-only readiness (reports all blockers; no archive/export/Connect upload)
scripts/ios-release/release-ios.sh --preflight

# After hard gates pass: tests + Release build + archive + export + inspect
scripts/ios-release/release-ios.sh --release

# App Store Connect validate then upload (typed confirmation; .p8 never as argv)
# export ASC_KEY_ID=… ASC_ISSUER_ID=…
# AuthKey_<id>.p8 in ~/.appstoreconnect/private_keys/ (filename presence only in audits)
scripts/ios-release/release-ios.sh --release --validate --upload \
  --confirm-upload 'UPLOAD BUILD 14 TO APP STORE CONNECT'
```

Details: [README.md](./README.md), [Submission/](./Submission/), and
[evidence/](./evidence/).

Build 14 was archived, exported, uploaded, processed, selected, and submitted
successfully on 2026-07-29. App Store Connect is **Waiting for Review**.
Distribution signing and upload credentials were ready: the valid Apple
Distribution identity is
`Apple Distribution: Memorable Factor (Q42MT7JA7Q)`, and the dedicated
App Store Connect App Manager API key has been live-verified. Private-key
material remains outside the repository and must never be printed or committed.

### Agreements

| Agreement | State | Release meaning |
| --- | --- | --- |
| Free Apps Agreement | **Active** | Sufficient for a free app. |
| Paid Apps Agreement | **Not active / New** | Not required while Phrasa is free and has no paid content or in-app purchases. |

The Paid Apps Agreement is **not** an upload blocker for this release. Revisit
it before adding a paid app, in-app purchases, or subscriptions.

### Store fields and release setup

| Field / area | Verified state |
| --- | --- |
| Subtitle, promotional text, description, keywords | Saved |
| What’s New | Not applicable to a first version; do not add release notes |
| Support URL / Marketing URL | Saved |
| Screenshots in Connect | 10 COMPLETE assets: 5 iPhone 6.9-inch + 5 iPad 13-inch |
| Selected build | **1.0 (14)** — build ID `9570010d-0625-403c-9955-c9d0d51e2306` |
| Review contact | Owner-supplied values saved |
| Sign-in required | Saved off; local use requires no account |
| Release mode | Manual |
| App Privacy questionnaire | Published live 2026-07-28: three types linked, App Functionality, not tracking |
| Privacy Policy URL | Saved: `https://phrasa.app/privacy` |
| Category / content rights / age rating | Saved: Productivity / Utilities, rights confirmed, 4+ |
| Price / tax / extra platforms | Free, `App Store software`; Apple Silicon Mac and Vision Pro availability disabled |
| DSA trader status | Saved: not a trader / no planned EU distribution; U.S.-only release |

### Website and policy verification

| Destination | Current state |
| --- | --- |
| `https://phrasa.app` | **Live** — current source deployed and reverified 2026-07-28 |
| `https://phrasa.app/privacy` | **Live** — reverified 2026-07-28 |
| `https://phrasa.app/support` | **Live** — reverified 2026-07-28 |
| Latest support/source copy | Deployed to Vercel production and aliased to `phrasa.app` |
| `support@phrasa.app` | Activated and monitored; verified 2026-07-18 |

**Before entering URLs in App Store Connect:** re-verify the live pages in a
normal browser after any redeploy, confirm they match the intended product
behavior, and confirm the public support contact is owner-approved and actually
monitored. Do not save Connect fields from unverified assumptions.

In-app Privacy Policy and Support links, plus the bundled Atkinson Hyperlegible
OFL notice, have landed in source. Verify them in the final archive before
submission; do not assume source changes reached the binary.

### Release evidence and non-claims

- Physical iPad Voice Follow acceptance passed on 2026-07-29. The valid
  human-attested `VOICE_ACCEPTANCE_BUILD14.md` is intentionally ignored by Git
  because it contains a real device identifier; transfer it securely.
- Real production Mac↔iPad Supabase sync acceptance passed on 2026-07-29.
- Native build 14 was archived, exported, uploaded, processed, selected, and
  submitted on 2026-07-29. Build ID:
  `9570010d-0625-403c-9955-c9d0d51e2306`. Review submission ID:
  `1ef88310-ff57-49d8-a02e-5a5c71ad07c5`. Current state: Waiting for Review.
  Builds 12–13 are not the shipping candidate.
- Exact product source pin for this automation lane:
  `7fac6ea406341313a3f169fe2ae42b1e565d1da0`; expected candidate fingerprint
  `344fd52de4a8dce9e53ac825e0a02746976019a994715e7ab34acb26cd229436`.
- Apple Distribution signing and the exact `com.phrasa.app` App Store profile
  completed the build-14 export and upload successfully.
- Upload/validate requires `ASC_KEY_ID`, `ASC_ISSUER_ID`, and a matching
  `AuthKey_*.p8` in a standard private_keys directory (filename checks only;
  private key body never accepted as a CLI argument and never printed). The
  dedicated API key has been live-verified.
- Ten screenshots are uploaded in the correct Connect slots.
- Latest source deployment, public-name change, metadata, screenshots, privacy
  details, binary upload, build selection, and review submission are saved and
  live-verified.
- Owner decisions for the public name, App Review contact, copyright, DSA
  status, and release mode were supplied and saved on 2026-07-28. The review
  submission was completed on 2026-07-29; manual release remains after approval.

---

## Machine-ready submission packet

Canonical en-US packet for copy/paste and local validation:

- Directory: [`Submission/`](./Submission/)
- Live Connect snapshot: [`Submission/connect-audit.yaml`](./Submission/connect-audit.yaml)
- Connect save evidence: [`Submission/connect-evidence.yaml`](./Submission/connect-evidence.yaml)
- Pre-archive prerequisites: [`Submission/release-prerequisites.yaml`](./Submission/release-prerequisites.yaml)
- Validate packet: `Submission/validate.sh --mode packet`
- Before archive/upload: `Submission/validate.sh --mode release-ready`
- Before Submit (after Connect saves): `Submission/validate.sh --mode submission-ready`
- Legacy alias: `--mode final` → submission-ready

Release preflight requires packet mode one-way (`release-ios.sh --preflight` →
`Submission/validate.sh --mode packet`). Packet success is local completeness
only — not Connect upload, field-save, or processing proof.

**Historical Connect audit (2026-07-18, read-only):** Apple ID 6780259086; iOS 1.0
Prepare for Submission; version metadata blank; screenshots 0; no build selected;
Sign-in required ON (must OFF); release Automatic (must Manual); App Review
contact blank; DSA banner present (status owner/legal); Social Media age-rating
banner present (Apple 2026-07-09: social media capability = redistribute/amplify/interact
with UGC via social feed or discovery; responses required Sep 2026; Phrasa **No**;
all related fields No/None). This is an immutable old baseline, not current
state. On 2026-07-29 build 14 was uploaded, processed, selected, and submitted;
Connect moved to Waiting for Review. Screenshot upload: 1320×2868 → Media Manager
**6.9-inch only** (not the default 6.5-inch well); 2064×2752 → **13-inch iPad**.

The sections below remain the human audit trail. Prefer `Submission/en-US/` text
files when pasting into App Store Connect so limits and plain-text formatting stay
aligned with the validator.

---

## Current App Store copy packet and verification status

The base 2026-07-29 listing was saved before review submission. The open-source
promotional text and description below were prepared afterward, so each must be
live-verified separately before this document represents it as saved.

### App name

**Phrasa Free Teleprompter**

### Subtitle

**Voice & speed teleprompter**

26 characters; 30-character limit.

### Promotional text

Current local open-source revision; not yet live-verified in Connect:

> A calm, open-source teleprompter for iPhone and iPad. Write or import
> scripts, use speed or Voice Follow, and work without an account or
> subscription.

150 characters; 170-character limit.

### Description

Prefer `Submission/en-US/description.txt` as the paste source. Summary:

Current local open-source revision; not yet live-verified in Connect. Phrasa is
a native teleprompter for speakers who need a dependable stage, not
another account dashboard. Local library features work offline without an
account. Optional Sign in with Apple (primary) or email opts the user into
cross-device sync of scripts, folders, tags, and outlines for App Functionality
only. After sign-in, that content synchronizes automatically on launch,
foreground, and shortly after saved library changes; Sync now is also
available. Unsaved drafts are not uploaded. Reader settings stay on each
device. No ads, tracking, or subscription. Microphone audio and speech
recognition text are never sent to Phrasa's developer-operated servers or
Supabase.

The final description also identifies Phrasa as open source under the Apache
License 2.0 and links the clean public repository at
`https://github.com/memfactorduke/phrasa-app`.

> **Historical operator gate — not part of the App Store description:** Voice
> Follow passed its physical-device gate before build 14 was submitted.

### Keywords

`teleprompter,prompter,script,speech,presenter,voice,rehearsal,speaker,offline,outline`

85 ASCII bytes; 100-byte limit.

### What’s New

Do **not** provide What’s New text for version 1.0. App Store Connect does not
require release notes for the first version.

### App Review notes

Prefer `Submission/en-US/review-notes.txt` as the paste source.

- Sign-in required: **No** (local use needs no account).
- Optional Sign in with Apple is **primary**; email/password is secondary.
- Demo account: none.
- App Privacy: **Yes**, data collected for optional sync — Email Address, User
  ID, Other User Content; linked to user; App Functionality; **not** tracking.
- In-app Supabase account deletion exists; **do not** claim Apple token
  revocation is complete (server-side release blocker).
- The Phrasa app uses recognized words only to follow the user's place.
  Microphone audio and speech recognition text are never sent to Phrasa's
  developer-operated servers or Supabase; keep the Apple Speech on-device /
  Apple-services disclosure.

Use the owner’s real App Review contact in Connect. Do not paste a fabricated
name, phone number, or email from this document.

### TestFlight beta notes

Thanks for trying Phrasa. This native build focuses on the local-first library,
editor, speed reader, voice following, outline presenter, import/export,
backup, and optional account sync.

Voice following passed physical-device acceptance. It works offline only when
Apple Speech supports on-device recognition; otherwise it may require internet
access. Please report tracking that jumps backward, stalls, or fails
after permission changes, along with lost edits, import/export failures, sync
issues, or reader controls that are difficult to reach.

Optional sync uses Sign in with Apple first. After sign-in, library content
syncs automatically on launch/foreground/saved changes, with Sync now
available. Local features still work without signing in. Reader settings and
unsaved drafts are not synced.

---

## App Privacy answers for this binary

For the top-level App Privacy question, the defensible answer for the intended
sync-enabled shipping build is:

> **Yes, we collect data from this app** (for optional sync only).

Also answer **No** to tracking.

Declare these types as **linked to the user**, purpose **App Functionality**,
**not used for tracking**:

| Type | Notes |
| --- | --- |
| **Email Address** | Email or Apple private relay when using Sign in with Apple |
| **User ID** | Supabase user UUID |
| **Other User Content** | Scripts, folders, tags, and outlines (reader settings stay local) |

Local library, editing, prompting, export, and backup work without an account.
No third-party analytics or advertising SDK is integrated. The Phrasa app uses
recognized words only to follow the user's place. Microphone audio and speech
recognition text are **never** sent to Phrasa's developer-operated servers or
Supabase.

Voice mode still requests optional Microphone and Speech Recognition access.
When on-device recognition is unavailable, Apple Speech may process audio
through Apple services. Disclose that accurately in the privacy policy and
review notes.

The privacy manifest declares no tracking, lists the three collected types
above for App Functionality, and keeps the UserDefaults required-reason API
(`CA92.1`).

---

## Recommended setup answers

These are technical recommendations based on this binary, not confirmations
that the fields are saved.

| Field | Recommendation |
| --- | --- |
| Primary category | **Productivity** |
| Secondary category | **Utilities** |
| Sign-in required | **No / off** |
| Demo account | None |
| Export compliance | Uses exempt system encryption only; `ITSAppUsesNonExemptEncryption` is false |
| Age rating | Expected **4+** under the current questionnaire, with all listed content/capabilities set to none/no if that remains accurate |
| Content rights | Confirm the app contains or has rights to all included content; bundled font license notice must be present |

### URLs

Use these only after live browser verification (and after any redeploy of
latest source):

| Field | Intended URL | Required proof before entry |
| --- | --- | --- |
| Privacy Policy URL | `https://phrasa.app/privacy` | Live policy, correct app behavior, and an in-app link |
| Support URL | `https://phrasa.app/support` | Live page with a real owner-approved **activated and monitored** contact (hard blocker if the channel is not working) |
| Marketing URL | `https://phrasa.app` | Live product page; optional field |

---

## Owner action still required

- After Apple approval, perform the configured **manual release**. Do not claim
  approval or public availability while the app remains Waiting for Review.

Primary localization is English (U.S.). No additional localizations are claimed
for the first release.
