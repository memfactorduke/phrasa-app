# Phrasa release blockers

Last updated: 2026-07-29 (America/New_York)

This is the short list of remaining release gates. Local tests, simulator
results, or metadata saves do not clear physical-device or owner/legal gates.

> Current release boundary: native iOS `1.0 (14)` was uploaded, selected, and
> submitted on 2026-07-29. App Store Connect is **Waiting for Review**. That
> submitted build is immutable. Post-submission source hardening belongs to a
> later candidate and must not be described as part of build 14.

## 1. Physical iPad Voice Follow acceptance

**Status:** passed on the exact pinned candidate on 2026-07-29.

The final signed candidate passed both physical harnesses on an iPad Air (5th
generation), iPadOS 26.5. Debug passed in log `20260729T035244Z`, including the
instrumented microphone, recognition, alignment, progress, pause/resume, and
background/foreground checks. Release passed in log and result
`20260729T042454Z`: visible progress advanced from `0.0` to `0.489` and the
healthy startup Voice status was `Listening`. Reader chrome then auto-hid
after the progress read, and the harness recorded
`chrome-auto-hidden-after-progress` rather than misclassifying that expected UI
state as microphone failure.

## 2. Real Mac to iPad Supabase sync acceptance

**Status:** complete physical matrix passed on 2026-07-29.

Production Supabase is configured, Sign in with Apple is primary, and the
`delete-apple-linked-account` Edge Function is deployed ACTIVE with JWT
verification. A signed Mac app uploaded a known script, the signed iPad app
downloaded and edited it, and the Mac downloaded that exact edit without a
duplicate or `Local conflict` copy. Apple SSO and explicit **Sync now** also
passed on both platforms.

The iPad-origin script later appeared in production Supabase and the signed
Mac library under the same UUID with the expected `IPAD_ORIGIN` body marker.
A fresh keyed Release Mac build restored the Apple session and completed
**Sync now** at `0 up, 0 down` without duplicates or tombstone drift. The
intentional divergent edit retained the exact `REMOTE_VERSION` original and
created exactly one `— Local conflict` copy containing `IPAD_LOCAL_VERSION`.
Delete propagation then passed in both directions through the real app UIs.
The final iPad sync (`20260729T041945Z`) was `0 up, 0 down`, and the production
database reported `DELETE_ROWS=0`. Redacted evidence is in
`docs/SYNC_QA_LOG.md`.

## 3. App Store review and manual release

**Status:** build `1.0 (14)` is **Waiting for Review**.

Completed live: dedicated App Manager API key, Apple Distribution certificate,
metadata, categories, 4+ age rating, content rights, free USA-only
availability, manual release, ten COMPLETE screenshots, public name `Phrasa
Free Teleprompter`, App Review contact and notes, copyright, Sign-in required
OFF, and U.S.-only/non-EU DSA status. App Privacy was published live with all
three correct data types as App Functionality, linked, and not tracking.

Archive, upload, processing, build selection, and App Review submission are
complete. Manual public release remains after Apple approval. If Apple rejects
the submitted build or the owner chooses to ship post-submission source
hardening, create a new version/build candidate and rerun the applicable
physical-device and release gates. Never mutate the build-14 packet to imply
that later source changes were included.

## Protected workspace data

Do not edit, delete, stage, or compile the protected untracked Finder
duplicates listed in `ios-native/AppStore/README.md`, including every numbered
`PhrasaNative` project copy. The authoritative project is
`ios-native/PhrasaNative.xcodeproj`.
