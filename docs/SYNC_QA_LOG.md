# Phrasa production sync QA log

Last updated: 2026-07-29 (America/New_York)

This log records redacted acceptance evidence for the dedicated production
Phrasa Supabase project. It intentionally contains no password, access token,
publishable key, or service-role credential.

## 2026-07-29 — conflict, both delete directions, and idempotence passed

- Intentional divergent-edit acceptance preserved the exact original body
  marker `REMOTE_VERSION` and created exactly one deterministic
  `— Local conflict` copy containing `IPAD_LOCAL_VERSION`.
- iPad-origin deletion used the exact disposable
  `SYNC QA DELETE IPAD 20260729T040142Z` fixture. The physical Release test
  passed in
  `/private/tmp/phrasa-voice-uiqa-logs/voice-uiqa-sync-delete-device-20260729T041452Z.log`;
  the same `cf2e…` script id was absent from production cloud, Mac, and iPad
  afterward.
- Mac-origin deletion removed the exact `52c68…` script id through the real
  signed Mac UI. A production remote filter returned no matching row.
- The final physical iPad sync passed in
  `/private/tmp/phrasa-voice-uiqa-logs/voice-uiqa-sync-device-20260729T041945Z.log`
  at
  `Synced · 0 up, 0 down`. A final production query reported
  `DELETE_ROWS=0`.
- These results close the intentional-conflict, delete-in-both-directions, and
  post-mutation idempotence gates. The abbreviated id prefixes above identify
  the disposable QA rows without publishing unrelated account data.

### Final physical Voice evidence

- Exact-candidate Debug Voice Follow passed in
  `/private/tmp/phrasa-voice-uiqa-logs/voice-uiqa-device-20260729T035244Z.log`.
- Exact-candidate Release Voice Follow passed in both
  `/private/tmp/phrasa-voice-uiqa-logs/voice-uiqa-release-device-20260729T042454Z.log`
  and its matching result bundle. The healthy startup status was `Listening`,
  and progress advanced from `0.0` to `0.489`.
- The Release reader chrome then auto-hid after the progress query. The harness
  recorded `chrome-auto-hidden-after-progress` as the expected final UI state;
  it did not misclassify chrome auto-hide as microphone failure.

## 2026-07-28 — signed Apple SSO and both origin directions passed

- Production project: Phrasa, project ref `uqkjidvqyngrnyftdazp`.
- QA used a private test account; its identifier is intentionally omitted.
- Both clients were signed Release builds with the production project URL and
  a build-injected public publishable key. Neither client contained or used a
  database/service-role credential.
- The signed Mac app completed Sign in with Apple and showed the private test
  account as signed in.
- The signed iPad app completed Sign in with Apple and an explicit **Sync now**.
  A second already-signed-in explicit sync also passed.
- Mac created `SYNC QA LIVE 2026-07-28 20:38 ET` with the body ending
  `Status: MAC_ORIGIN`.
- iPad downloaded the script, changed exactly `MAC_ORIGIN` to
  `IPAD_VERIFIED`, and saved it.
- Mac then reported `Synced · 0 up, 1 down`. Its library contained exactly one
  matching title whose body ended `Status: IPAD_VERIFIED`; there was no
  duplicate and no `Local conflict` copy.
- The iPad UI harness later failed only while navigating the split-view
  overflow menu after the edit had saved. The app's automatic durable push
  delivered the edit, so that navigation failure does not invalidate the
  verified Mac-origin round trip.

### Reverse-origin acceptance

- iPad created and saved `SYNC QA IPAD 2026-07-28 20:41 ET` with UUID
  `ca4be851-da50-4183-9aac-7ce16fa56140` and a body ending
  `Status: IPAD_ORIGIN`.
- The production `scripts` table later contained that exact UUID, title, QA
  account, and body marker.
- The normal Mac library later contained the same UUID and body marker. A
  fresh keyed Release Mac build restored the Apple session, displayed the
  iPad-origin script exactly once, and completed **Sync now** at
  `Synced · 0 up, 0 down`.
- The Mac library also retained the Mac-origin UUID
  `4b7f7a05-c43c-48f1-a0bc-4624ae5e6c5f` with the expected
  `Status: IPAD_VERIFIED` edit. Its sync state had five rows and zero script or
  folder deletion tombstones.
- This closes the reverse-origin create path. It does not claim the still
  untested destructive or intentional-conflict paths.

### Preserved local evidence

- iPad Apple SSO and first explicit sync:
  `/private/tmp/phrasa-ipad-apple-sso-uiqa-4.log`
- iPad edit of the Mac-origin handoff:
  `/private/tmp/phrasa-ipad-live-sync-edit-uiqa.log`
- iPad-origin creation:
  `/private/tmp/phrasa-ipad-origin-create-uiqa.log`
- Later already-signed-in explicit iPad sync:
  `/private/tmp/phrasa-ipad-explicit-sync-after-create.log`

## Physical sync matrix status

No physical sync scenario remains open in this matrix. Signed Apple SSO,
Mac-origin create/edit, iPad-origin create/edit, intentional conflict, delete
propagation in both directions, and final idempotence are accepted.

## 2026-07-20 — Mac half passed; iPad return trip pending

- Client: unsigned Release `PhrasaMac.app`, bundle id `com.phrasa.mac`, built
  from the current `codex/phrasa-rebuild` working tree with the production
  project URL and a build-injected publishable key.
- Local safety: the run used isolated home
  `/private/tmp/phrasa-mac-syncfixed-home.ZwCwy2`. The normal Mac library was
  not used. A pre-test backup remains at
  a private local backup created before the live-sync fix.
- QA user id: `0fcc3f12-9d53-4e76-ba63-2611761a0fc5`.
- Handoff script id: `63e110d1-314e-49fa-b549-36dcc3b5f557`.
- Handoff title: `SYNC QA HANDOFF 2026-07-19 23:12 CT`.
- Content integrity: body still ends `Status: PENDING`; tags remain
  `sync-qa, handoff`; `created_at` remains
  `2026-07-20T04:12:12.733+00:00`; content `updated_at` remains
  `2026-07-20T04:21:43.075535+00:00`.
- Timestamp repair acceptance: opening the handoff again on Mac and using the
  app's **Sync now** advanced remote `last_opened_at` to
  `2026-07-20T05:36:01.413+00:00` without changing content timestamps.
- First app-only recurrence pass: UI reported `Synced · 1 up, 0 down`.
- Immediate idempotence pass: UI reported exactly `Synced · 0 up, 0 down`.
- Local baseline: the handoff row now has a current 64-character v2 sync
  fingerprint. No `Local conflict` copy exists. The offline welcome script is
  correctly retained as unverified/device-only instead of being claimed by the
  QA account.
- Credential boundary: the app was built with only the public publishable key.
  The database/service-role credential was not placed in the binary or used by
  the client sync path.

During diagnosis, an authenticated direct PostgREST PATCH was used once to
prove that the exact `updated_at` OCC predicate plus monotonic
`last_opened_at` filter accepted a one-millisecond advance. The decisive
acceptance above was then repeated from a later timestamp using the rebuilt
Mac app alone; that app-only recurrence is the pass evidence.

## Historical checklist from the 2026-07-20 run

1. Install the signed candidate after the microphone blocker is understood.
2. Sign into the same QA account.
3. Confirm the handoff script downloads with the exact id/title/tags/body above.
4. Change only the final word from `PENDING` to `VERIFIED`, save, and sync.
5. Return to Mac, sync, and confirm the same row changes without a duplicate or
   `Local conflict` copy.
6. Exercise create, edit, delete, and intentional same-script conflict behavior
   in both directions, recording object ids and UTC timestamps here.

Steps 1–5 were superseded by the signed 2026-07-28 run above. The remaining
reverse-origin, delete, conflict, and final-idempotence checks were completed
on 2026-07-29.
