# Fable adversarial hardening pass

Date: 2026-07-29
Branch: `codex/fable-adversarial-hardening`
Base: `f3629e5` (`Record App Store review submission`)

## Safety boundary

This work was performed in a separate clean worktree. It did not edit the
original checkout, deploy the website or Edge Function, mutate production
Supabase, operate App Store Connect, or change the submitted iOS `1.0 (14)`
candidate. Build 14 remains **Waiting for Review** and cannot contain any source
change in this pass.

## Adversarial review design

Four Fable roles attacked the product from different directions:

1. **Web, data, auth, and security:** principal isolation, stale requests,
   offline/local persistence, pagination, optimistic concurrency, multi-tab
   behavior, auth recovery, deletion security, and hostile storage failures.
2. **iOS reader and Voice Follow:** editor-to-reader durability, lifecycle
   transitions, gestures, accessibility, pacing accuracy, performance, and
   immutable presentation state.
3. **Mac workspace and release surface:** editor save gates, window/session
   ownership, audience output, presentation snapshots, cloud scheduling,
   source-hygiene checks, and current public claims.
4. **Whole-system red team:** contradictions between platforms, production and
   repository boundaries, release evidence, failure recovery, and cross-surface
   user expectations.

## Findings and dispositions

| Severity | Adversarial finding | Resolution in this branch |
| --- | --- | --- |
| Critical | An account-A sync request could finish after switching to account B and apply A state to B’s visible library. | Added generation tokens, synchronous principal invalidation, separate account-cache writes, and current-principal guards around every visible update. |
| Critical | A completed stale upload could replace newer local keystrokes with the older acknowledged row. | Reconcile acknowledgements into the latest cache, preserve newer edits, and schedule a follow-up push. |
| High | Pulls, pushes, reconnects, and manual sync could overlap and race. | Added one serialized sync lane plus revision-aware follow-up scheduling. |
| High | Remote pagination could silently accept gaps, duplicate/order drift, or an unverified absence. | Added keyset pagination, exact page validation, stable ordering, and point checks before treating a row as deleted. |
| High | Local clock skew, timestamp collisions, or metadata-only changes could create false conflicts or be lost. | Track the exact remote wire timestamp plus an acknowledged full-content fingerprint covering title, body, source, folder, tags, and outline. |
| High | Cross-tab edits could overwrite one another; delete failure recovery was not propagated; a stale tab could resurrect a just-cleared library or duplicate the untouched Welcome sample. | Merge storage events, broadcast delete/restore/clear intent, install one shared post-clear replacement snapshot, collapse duplicate untouched samples, retain current-principal isolation, and requeue dirty merged work. |
| High | Malformed or inaccessible browser storage looked like an empty library and could be overwritten. | Added strict parsing, raw recovery preservation/download, quota/read failure reporting, overwrite blocking when preservation fails, and an explicit confirmed “Clear this browser” path. |
| High | The web editor could lose the final title/body keystroke on immediate navigation. | Local cache writes now happen on each edit; only cloud transport is debounced. Added an end-to-end regression test. |
| High | Email users had no complete password-recovery flow, while open sign-up copy implied unsupported account provisioning. | Added reset-link and new-password flows, removed the unsupported sign-up action, and sanitized callback failures. |
| High | The auth callback could reflect provider error text and was indexable. | Replaced external error details with bounded messages and added `noindex`, `nofollow`, and `noarchive` metadata. |
| High | Apple account deletion checked exchange-token claims but did not verify Apple’s signature. | Added fail-closed RS256 verification against Apple JWKS, a bounded cache, one forced refresh on key rotation, and source-order tests. It is not active until separately reviewed and deployed. |
| High | iOS could switch documents or open a presentation before a failed autosave completed. | Document switches and presentation requests now require a successful flush and reject stale async opens. |
| High | A live iOS or Mac presentation could read a mutable library row and change underneath the speaker. | Reader and outline launches now carry immutable request snapshots with unique presentation IDs. |
| High | Mac toolbar/menu/context presentation paths could bypass the editor save gate. | Added one app-level editor flush broker and routed all presentation commands through it. |
| High | Backup merge trusted `updatedAt`, allowing clock skew to choose the wrong content. | Matching content merges metadata; divergent same-ID content is preserved as a deterministic “Backup copy.” |
| High | Restore could run while an editor draft was staged. | Restore now fails closed until staged drafts are flushed or discarded by the user. |
| Medium | Reader settings changes triggered unnecessary cloud synchronization. | Settings remain device-local and no longer schedule script/folder sync. |
| Medium | Cloud-runtime retry could hot-spin on the main actor while the coordinator was busy. | Retry yields through one bounded delayed task rather than immediately rescheduling. |
| Medium | Backgrounding could leave Voice Follow listening or restart it without clear user intent. | Stop on background, remember only an active listening intent, and resume only that prior intent on foreground. |
| Medium | Permission recovery could restart listening implicitly. | Foreground refresh reveals recovery UI; microphone/speech retry remains an explicit user action. |
| Medium | Reader-stage tap gestures could be triggered by controls, and blackout was not a true accessible button. | Contained stage gestures, converted blackout to a button action/trait, and enlarged recovery targets. |
| Medium | iOS pacing status used stale elapsed time while the session ran. | Recompute elapsed time on the timeline clock and cover the calculation with tests. |
| Medium | Reader layout repeatedly tokenized and measured large scripts on high-frequency progress updates. | Cache word count, insets, geometry, style signature, and voice target inputs. |
| Medium | A filtered-out library selection could remain active. | Selection is retained only when its ID is still visible in the filtered result. |
| Medium | Web WPM duration used a rough body-length proxy and large frame gaps could jump the script. | Use exact word count for maximum duration and clamp frame deltas after tab suspension. |
| Medium | Global Space handling could hijack buttons, links, or editable controls. | Exclude interactive/editable targets and keep keyboard handling at the reader surface. |
| Medium | Public copy claimed broader Mac, web, voice, offline, import/export, and completion behavior than shipped. | Reconciled marketing, support, privacy, terms, not-found, account, and reader copy to platform reality. |
| Medium | Release blockers still instructed operators to submit a build that was already Waiting for Review. | Updated the current build-14 boundary and marked the older final audit as historical. |
| Medium | Mac source-reading tests hung or failed under the app test sandbox and emitted database cleanup warnings. | Moved source hygiene to a deterministic CI shell guard, kept runtime host tests, and made test teardown release stores before temporary directories. |
| Low | Notification observer storage relied on unsafe actor annotations. | Replaced it with small locked, sendable holders that clean up both explicitly and on deinit. |
| Low | Safe patched transitive packages were available. | Applied the non-breaking npm audit update. Remaining findings are in development-only ESLint dependencies and require a breaking ESLint-major move. |

## Verification completed

- Web: lint, TypeScript, production build, three product guards, 178 Vitest
  tests, and 11 Chromium Playwright tests passed. The browser suite includes
  immediate-navigation durability and real two-tab clear-resurrection coverage.
- Swift packages: Core 72, Domain 21, Persistence 15, and Sync 45 tests passed.
- iOS: 397 simulator tests passed; static analysis also succeeded.
- Mac: 95 tests passed; five source-reading cases are intentionally skipped in
  the sandbox and their external source-hygiene guard passed.
- Release safeguards passed: evidence parser 40, helper/gates 39, provisioning
  60, key contract 75, voice/cloud key contract 141, packet unit 28, and the
  submission-ready validator. A deliberate dirty-branch preflight correctly
  blocked archive/release and produced no archive or IPA.
- The canonical Xcode project is `ios-native/PhrasaNative.xcodeproj`. Numbered
  Finder duplicates were not read, edited, compiled, staged, or deleted.

## Honest remaining gates

These require authority or real external state and were intentionally not
claimed as completed by source tests:

- Review and deploy the updated Apple-JWKS deletion function, then perform a
  disposable-account revoke/delete acceptance on both iOS and Mac.
- Exercise signed web account A → B switching, concurrent tabs, reconnect, and
  RLS behavior against the exact production project without synthetic data
  leaking into user libraries.
- If these changes are selected for release, make a new iOS build and repeat
  physical Voice Follow/lifecycle acceptance. Do not alter or relabel build 14.
- Review and deploy the corrected public web copy if desired.
- Durable web delete tombstones would require a deliberate schema/product
  migration; this branch prevents common live-tab resurrection but does not
  invent a production schema change.
- The remaining npm audit advisory is confined to development lint tooling.
  Eliminating it currently requires a breaking ESLint 10 upgrade and should be
  handled as a separate toolchain migration.
