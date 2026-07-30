# Phrasa — go-live runbook

Status rechecked for the native-first rebuild. The public website includes the
browser companion at `/app`; Voice Follow remains exclusive to the native
Swift/SwiftUI product in `ios-native/`. Expo and React Native are retired.

There are two release tracks: **website deployment** and **native App Store
release**. Neither should be described as live until its external checks below
are complete. Paid tiers are a separate, later release decision.

---

## 0. What "done" means today

- **Website** includes marketing/legal/support plus `/app`, a guest/local
  library, editor, and speed teleprompter. Voice Follow is native-only.
- **`phrasa.app` is deployed and smoke-tested.** The `/app` companion supports
  guest use and production Supabase sign-in/sync; its Apple OAuth redirect was
  smoke-tested.
- **Native accounts and sync are release-tested.** Sign in with Apple is the
  primary path, email/password is secondary, and the production Mac↔iPad sync
  matrix passed on 2026-07-29. The release key is injected at build time and
  never committed. Apple-linked account deletion remains a separate live gate:
  do not claim Apple token revocation or deletion end-to-end until the Edge
  Function and both native clients have their own evidence.
- **One shipping app:** `ios-native/` (Swift/SwiftUI, bundle ID `com.phrasa.app`).
  The Expo `mobile/` tree is removed. Upgrades from the old Expo build keep
  on-device libraries via `LegacyExpoMigrator`.
- **Paid tiers / Lemon Squeezy / analytics** are not part of the active schema.
  Historical billing SQL is archived under
  `supabase/archive/historical-migrations-pre-sync-baseline/` and must never be
  applied to a new project.

---

## 1. Website — production maintenance

1. **Review, merge, and deploy** website changes through the configured
   production host; smoke marketing, legal, support, `/app`, and
   `/auth/callback` on preview and production.
2. **Maintain the pinned production Supabase project.** Verify and apply
   only active files in `supabase/migrations/`; never apply `supabase/archive/`.
   Supply the current **publishable** key to native Release and the two
   `NEXT_PUBLIC_PHRASA_*` variables in the web build. Never place a service-role
   or secret key in the app, browser environment, or git.
3. **Custom domain** — keep `phrasa.app` attached to the verified production
   deployment. `NEXT_PUBLIC_SITE_URL` defaults to `https://phrasa.app` for
   canonical/OG URLs.
4. **Supabase Auth → URL configuration** — allow both native URIs,
   `phrasa://auth/callback` and `phrasa://auth/recovery`, so email, recovery,
   and OAuth callbacks resolve. Enable Google/Apple providers only when those
   buttons should appear.

---

## 2. Legal and support

The `/privacy` and `/support` pages are **customer-facing**: they state that
local use requires no account; optional account data and saved library content
sync through Supabase; reader settings and unsaved drafts remain local; there
are no ads, tracking, or payments; Apple Speech is on-device when supported and
otherwise may use Apple services. Audio and transcripts do not go to Phrasa or
developer servers. They **are not legal advice**. Before charging customers or
after any material data-flow change:

- Re-read them against how the shipping binary actually handles data.
- Keep `https://phrasa.app/privacy` and `https://phrasa.app/support` reachable.
- Keep `support@phrasa.app` monitored; it was verified on 2026-07-18.
- Revisit legal review before adding payments or materially changing sync.

---

## 3. Native App Store launch (`ios-native/`)

Full notes live in `ios-native/README.md`. Critical path:

1. **Xcode project** — from a clean checkout:
   ```bash
   cd ios-native
   open PhrasaNative.xcodeproj
   ```
   The canonical project is tracked. Regenerate with XcodeGen only when
   intentionally changing project structure.
2. **Real-device QA** — physical iPad Voice Follow and production Mac↔iPad sync
   passed on 2026-07-29. Preserve the ignored detailed Voice evidence securely.
   Re-run affected scenarios after any voice, auth, backend, or sync change.
3. **Store setup** — metadata, screenshots, privacy, review information,
   pricing, U.S. availability, and manual release are saved in App Store
   Connect. Processed build **1.0 (14)** is selected.
4. **Submission complete** — build 14 (build ID
   `9570010d-0625-403c-9955-c9d0d51e2306`) was exported, uploaded, processed,
   selected, and submitted on 2026-07-29. App Store Connect is **Waiting for
   Review** under submission ID
   `1ef88310-ff57-49d8-a02e-5a5c71ad07c5`. After approval, release it manually.

Do not reintroduce Expo, EAS, or React Native for store builds. CI runs
`scripts/guard-no-expo.mjs` to block that regression.

---

## 4. Paid tiers (out of scope for the sync baseline)

The active Supabase baseline is **sync-only**. It does not install subscriptions,
Lemon Squeezy fields, webhooks, or analytics tables. Historical billing SQL under
`supabase/archive/` must not be reapplied to a new project. If paid tiers return
later, design a new server-owned billing surface deliberately; clients must never
hold Lemon Squeezy or Apple private secrets. Prefer keeping paid tiers off until
native product, account deletion, and legal review are complete.

---

## Quick status board

| Area | State |
|---|---|
| Website code | ✅ marketing + legal/support + guest web companion |
| Website production deploy / domain | ✅ live smoke passed at `phrasa.app` |
| Supabase accounts + sync | ✅ production Apple SSO and Mac↔iPad sync acceptance passed |
| Apple-linked account deletion | ⏳ separate server deployment and two-platform live evidence |
| Legal / support | ✅ privacy/support live and Connect privacy published; re-review before payments |
| Native Swift app | ✅ shipping surface; physical Voice + sync + archive passed |
| App Store metadata | ✅ saved with 10 screenshots, U.S.-only free pricing, manual release |
| Expo / React Native lane | ✅ retired (`mobile/` removed; migrator kept) |
| App Store binary / submission | ✅ build 1.0 (14) uploaded, processed, selected, and Waiting for Review |
| App Store release | ⏳ manual release after Apple approval |
| Paid tiers | ❌ not in active schema (archive only; redesign if needed) |
