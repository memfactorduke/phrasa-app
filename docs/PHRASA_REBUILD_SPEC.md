# Phrasa rebuild specification

Status: source of truth for the native-first rebuild.

## Product promise

Phrasa is a calm, local-first teleprompter for iPhone, iPad, and Mac. A speaker can write or import a script, open a distraction-free stage, and either read at a dependable speed or let the text follow their voice. The core product must remain useful with no account, payment, or network connection.

The old repository is evidence, not a compatibility contract. Preserve valuable concepts and tested algorithms; replace its product structure and visual language.

## Hard boundaries

- Ship native Swift and SwiftUI only on Apple platforms.
- Support iOS 17+, iPadOS 17+, and macOS 14+ from shared domain and reader packages.
- Retire Expo and React Native as shipping surfaces. Keep only a bounded one-time migration reader until legacy users have moved.
- Keep a public website for marketing/legal plus a bounded web companion (`/app`) for library, editor, and speed prompting. Native apps remain the full product (Voice Follow is native-only).
- Do not add payments, pricing gates, AI writing, Google Drive, advertising, or third-party analytics.
- Offline library, editing, speed prompting, import, export, and backup must not depend on cloud availability.
- Prefer Apple frameworks and existing pure Swift code. Every new dependency requires a stability or maintenance justification.

## Canonical journeys

1. First open: Write, Present, Private onboarding; create or open the seeded sample; arrive in the library.
2. Write: create a script, edit title and body, organize it with folder and tags, and trust autosave.
3. Import: open TXT, Markdown, or PDF from Files; review the imported script; present it.
4. Speed prompt: choose speed, start after a quiet countdown, pause, scrub, adjust pace, blackout, finish, and see a rehearsal recap.
5. Voice prompt: grant microphone and speech permission, read naturally, see a restrained tracking state, recover to speed mode if speech is unavailable, and finish with a recap.
6. Resume: leave mid-read and continue later only when the script content signature still matches.
7. Outline: create ordered talking points and present them manually with touch, keyboard, clicker, or foot pedal controls.
8. Backup: export a complete versioned library backup; restore by merge or replace with explicit confirmation and atomic failure behavior.
9. Continuity: optionally sign in and explicitly sync; local content remains usable and ownership-safe when the service is unavailable.

## Product surfaces

### iPhone

- Full-screen searchable library.
- Push editor with Script and Outline sections.
- Full-screen reader with touch-first controls and no accidental edge dismissal.
- Sheets for reader settings, account/sync, import, export, and backup.

### iPad

- Navigation split view with folders and scripts beside the editor.
- Landscape-first reader and outline presenter.
- Full hardware-keyboard and remote command support.

### macOS

- Native SwiftUI/AppKit application, not Catalyst.
- Three-pane library, script list, and editor where window size permits.
- Dedicated full-screen reader window with keyboard, clicker, and menu commands.
- Native file import/export, security-scoped URL handling, and display-sleep prevention while presenting.
- Speed prompting is required. Voice ships only when the macOS audio and speech adapter passes the same reliability gates as iOS.

### Website

Public marketing routes:

- `/`: product story, native + web availability, App Store or honest coming-soon actions, link to the web companion.
- `/privacy`: plain-language policy for device-local storage, browser guest storage, optional account sync, microphone/Apple
  Speech (on-device when supported; otherwise Apple services), and what this
  release does not collect; contact routes to `/support` (no invented email or
  undeployed domain on the page).
- `/terms`: app license, content ownership, and service limits.
- `/support`: self-service help for documents, web companion, speed mode, voice permissions,
  backup, and offline use; TestFlight feedback only when the reader is a beta
  tester.

Web companion routes (product surface, not a second native app):

- `/app`: guest-capable script library, editor, and speed teleprompter.
- `/app/scripts/[id]`, `/app/scripts/[id]/read`: editor and speed reader.
- `/auth/callback`: Supabase OAuth / email confirmation (publishable key only).

Web companion rules:

- Guest/local mode works with no cloud configuration.
- Apple SSO via Supabase is primary sign-in; email/password secondary.
- No browser Voice Follow; state that it is native-only; no fake mic controls.
- Namespace persisted data by guest vs authenticated user id; sign-out must not reveal prior account cache.
- Guest import only after successful login; clear guest data only after successful remote upsert.
- Prefer honest sync status over pretend conflict resolution.
- Env: `NEXT_PUBLIC_PHRASA_SUPABASE_URL` + `NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY` (never service-role).
- Do not reintroduce pricing, billing, AI APIs, webhooks, analytics API, PWA, or service worker.

## Feature contract

### Library and editor

- Create, rename, duplicate, move, delete, search, filter by `#tag`, sort, and organize with folders.
- Autosave through one serialized durable write lane; flush on background, navigation, and presentation.
- Find and replace, word count, estimated duration, tags, folder, and ordered outline points.
- Import TXT, Markdown, and bounded PDF files.
- Export a script as UTF-8 text and versioned Phrasa JSON.
- Export and restore the complete library with symmetric size limits and atomic merge/replace.
- Preserve corrupt database and import artifacts in a recovery location before offering a fresh start.

### Reader

- One rendered text surface driven by display refresh; never one SwiftUI view per word.
- Speed range: 40 to 400 WPM with continuous and line-step motion.
- User controls: typeface, size, leading, text width, focus position, horizontal mirror, vertical mirror, black/white inversion, countdown, and optional pacing target.
- Horizontal and vertical mirror are mutually exclusive unless a tested optical use case proves otherwise.
- Playing chrome hides after about 2.5 seconds. Tap reveals it. Blackout always has an obvious escape.
- Speed progress and voice token progress are separate domain values. Resume stores a canonical focus token or both values with a content signature; it never reuses an incompatible scalar.
- Completion records active time, average WPM, target difference when present, resume state, and run count. The UI shows the latest recap rather than an analytics dashboard.

### Voice following

- Use Apple Speech and AVFoundation behind platform adapters; prefer on-device recognition when supported.
- Use the pure alignment engine as the only authority for accepted progress.
- States: idle, requestingPermission, listening, tracking, searching, restarting, paused, denied, unavailable, failed, complete.
- Denied or unavailable states stop voice playback and offer Open Settings and Use Speed.
- A recognition generation token rejects stale callbacks. Restarts preserve alignment position without replaying already accepted words.
- Tracking confidence is communicated without a permanent meter: stable focus line while tracking, restrained pulse while searching, explicit copy only for actionable problems.
- Microphone audio is never sent to Phrasa servers.

### Inputs

- Space: play or pause.
- B: blackout.
- Up/Down: decrease/increase speed by 10 WPM.
- Left/Right: nudge one line or a small token step.
- Page Up/Page Down: previous/next outline point or remote step.
- Escape: close sheet or exit reader.
- `?`: shortcuts help.
- `/`: find a line on Mac and keyboard-equipped iPad.

## Architecture

```text
ios-native/
  Packages/
    PhrasaCore/          pure tokenization and alignment
    PhrasaDomain/        models, invariants, reader/session/sync plans
    PhrasaPersistence/   SQLite repository and migrations
  PhrasaShared/          cross-platform SwiftUI screens and app services
  PhrasaiOS/             iOS/iPadOS entry point and platform adapters
  PhrasaMac/             macOS entry point and platform adapters
  Tests/                 package, adapter, integration, and UI tests
```

The exact folder migration may be incremental, but dependencies must point inward: platform applications depend on shared UI and domain packages; domain code never imports UIKit, AppKit, Supabase, Speech, AVFoundation, or SwiftUI.

### Persistence

- SQLite is the only shipping library store.
- Use WAL mode, versioned migrations, transactions, foreign keys, and bounded query/result sizes.
- Store scripts, folders, settings, tombstones, ownership, bookmarks, and recaps in one schema or one coordinated database.
- Keep the JSON persistence implementation only as a test double until in-memory SQLite tests replace it.
- All visible mutations are commit-before-publish except explicitly staged editor drafts.

### Optional sync

- Keep optional account-based sync and the current ownership/quarantine protections. After sign-in, durable library changes sync automatically on launch, foreground, and after saves; keep an explicit Sync now control as well. Reader settings and unsaved drafts remain local.
- Do not add CloudKit beside Supabase, background continuous sync, or bookmark sync in the first release.
- Foreign-owned and quarantined rows are never silently claimed or uploaded.
- Divergent edits create a durable conflict copy before either side is discarded.
- Stale sync generations cannot apply. A failed remote or local apply leaves the visible local library intact.
- If the existing cloud service cannot pass live verification, ship local-only with honest UI rather than weakening the offline core.

## Visual system

- Canvas: `#000000`; elevated canvas: `#0A0A0A`.
- Primary ink: `#FFFFFF`; secondary ink: `#A3A3A3`; divider: `#1F1F1F`.
- Use semantic system red only inside destructive warnings.
- Use SF system type for product chrome. Keep Atkinson Hyperlegible, SF, serif, and mono as reader choices.
- Corners are square to 8 points. No gradients, glow, glass, ornamental shadows, colored theme matrix, or oversized SaaS cards.
- Motion is functional, 120–200 ms ease-out, and removed or reduced when Reduce Motion is enabled.
- Controls have at least 44-point touch targets, full VoiceOver labels, keyboard focus, Dynamic Type for chrome, and WCAG AA contrast.

## Verification gates

- Package tests pass for alignment, tokenization, reader state, ownership, persistence, sync planning, imports, backups, and migrations.
- Alignment accuracy gates remain at least as strict as the current PhrasaCore suite.
- iPhone, iPad, and Mac schemes build from a clean checkout.
- Airplane-mode test proves create, edit, present, recap, export, backup, relaunch, and restore.
- A 2,000-word speed read completes without multi-second stalls on supported devices.
- A 10-minute real-device voice read survives normal pauses and recognition restarts without backward jumps.
- Killing or backgrounding during editing loses no text beyond the documented debounce window.
- Corrupt SQLite, session archive, import, and backup fixtures preserve recoverable artifacts and never silently replace the library.
- Keyboard, clicker, mirroring, blackout, orientation, display-sleep, permission denial, and accessibility journeys pass on relevant platforms.
- Website marketing routes plus `/app` companion: no service worker or service-role secrets; guest mode works without cloud env; keyboard accessible; marketing pages remain honest about native Voice Follow.
- No release is called complete until simulator and real-device behavior, website production rendering, and optional live sync are separately verified.

## Parallel work packages

1. **Native foundation** owns `ios-native/Packages/**`, persistence/domain extraction, progress invariants, and package tests. It does not edit SwiftUI feature screens.
2. **Native experience** owns `ios-native/Phrasa/**` SwiftUI design, library/editor/reader interaction, keyboard commands, and accessibility. It consumes current package APIs and does not move persistence types.
3. **Mac platform** owns the macOS target, AppKit adapters, Mac entry point, menus, window behavior, and Mac-specific tests. It coordinates project configuration with the integration lane.
4. **Website** owns the root Next.js app, public components/assets, metadata, legal/support copy, and web tests. It does not edit native code.
5. **Integration and adversarial QA** owns project generation, dependency cleanup, migrations between lane APIs, all builds/tests, simulator and browser QA, and final deletion of retired surfaces.

## Milestones

1. Lock this specification and baseline current tests.
2. Extract pure domain and persistence boundaries without behavior regressions.
3. Replace the native visual shell and reader interaction while keeping engines green.
4. Add the native macOS target and platform adapters.
5. Replace the website and delete retired web/Expo product code (Expo `mobile/`
   tree removed; keep only `LegacyExpoMigrator` for on-device upgrades).
6. Run integration, performance, recovery, accessibility, and real-surface QA.
7. Reconcile signing, App Store, domain, support contact, privacy, and any live sync gates before release.
