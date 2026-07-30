# TODOs — deferred follow-ups

Last refreshed for the native-first rebuild (Expo retired). Contributor-actionable
items that still need credentials or product decisions stay here.

## Owner actions and external release gates

- [x] **Submit native iOS 1.0 (14) for App Review.** The shipping SwiftUI app
      (`com.phrasa.app`, Apple ID `6780259086`) passed release readiness,
      physical Voice Follow, production Mac↔iPad sync, archive, export, upload,
      processing, build selection, and submission on 2026-07-29. Build ID:
      `9570010d-0625-403c-9955-c9d0d51e2306`; review submission ID:
      `1ef88310-ff57-49d8-a02e-5a5c71ad07c5`; current state:
      **Waiting for Review**.
- [ ] **Manually release iOS 1.0 after Apple approval.** Manual release is the
      saved Connect setting; do not publish before approval.
- [ ] **Finish production account-deletion integrations.** Live-test
      `delete_own_account` (email/password path) on the dedicated project. Deploy
      and secret-configure Edge Function `delete-apple-linked-account` (scaffold
      in `supabase/functions/`): set `APPLE_CLIENT_IDS=com.phrasa.app,com.phrasa.mac`
      (plus Team ID / Key ID / `.p8` / service role). Live-test SIWA reauth →
      allowlisted client_id exchange → Apple-returned id_token identity check →
      revoke → Supabase delete on **both** iOS and Mac. Do not assume one
      client_id works for both platforms. Client apps cannot carry Apple private
      secrets or be trusted for identity_token subject matching.
- [ ] **Formal legal review of `/privacy` and `/terms` before charging.**
      Production privacy/support pages and the monitored support contact are
      live and the App Store privacy questionnaire is published. Re-review
      whenever data flows change and before adding payments.
- [ ] **Paid tiers (optional later).** Not in the active sync schema. Redesign
      server-owned billing if needed; do not reapply archived Lemon Squeezy SQL.

## Native product

- [x] **Complete physical iPad Voice Follow acceptance.** Debug and shipping
      Release paths passed microphone permission, on-device recognition,
      alignment/progress, pause/resume, and lifecycle recovery on 2026-07-29.
      Preserve the detailed ignored device evidence securely; see
      `docs/RELEASE_BLOCKERS.md` and `AppStore/Submission/voice-gate.yaml`.
- [x] **Complete real Mac-to-iPad Supabase sync QA** on hardware. The timestamp
      defect was fixed and the full create/edit/conflict/delete matrix plus
      Apple SSO passed on 2026-07-29. See `docs/SYNC_QA_LOG.md`.
- [x] **Ship Sign in with Apple as the primary account path** on iOS/iPadOS and
      macOS, with email/password as a secondary fallback. Native Apple SSO and
      shared-account sync passed. Apple-linked deletion/revocation remains the
      separate external gate above and must not be overclaimed.
- [ ] **Optional macOS voice following** when the Mac speech adapter meets the
      same reliability gates as iOS (speed prompting already ships).
- [ ] **Optional:** design refresh of app icon after first store submission.

## Growth / strategy (still open)

- [ ] **On-stage ambient tint (evidence-gated).** Defer until real-mic accuracy
      data shows users misdiagnose tracking mid-read.
- [ ] Product decisions around outline-only scripts and pacing feedback remain
      open; see the rebuild spec for the feature contract.

## Web companion

- [x] **Configure the production Supabase web environment and Apple OAuth
      redirect.** Production `/app` points at the dedicated project with public
      browser-safe configuration; Apple remains the primary sign-in path.
- [ ] **Complete the extended web account matrix.** The production Apple OAuth
      redirect was smoke-tested. Still record guest → sign-in → guest import →
      sign-out isolation as a separate web acceptance run.

## Done (recent)

- [x] **Web companion at `/app`** — guest library/editor/speed reader, Apple
      primary + email secondary auth UI, namespaced local persistence, remote
      map to native sync schema, auth callback, Vitest + Playwright coverage.
- [x] **Dedicated production Supabase project and active native sync schema** —
      project `uqkjidvqyngrnyftdazp` has baseline migration
      `20260719000000` plus ACL remediation `20260719000001`; live role grants,
      RLS contract, password login, Apple SSO, and physical cross-device
      behavior were verified.
- [x] **Public website live verification** — `/`, `/privacy`, `/terms`, and
      `/support` returned HTTPS 200 with valid TLS and expected titles on
      2026-07-19 (America/Chicago).
- [x] **Fail-closed iOS cloud configuration** — the project URL is tracked and
      the production publishable key is injected only at build time. A build
      without the key stays offline; no secret or service-role credential is
      committed.
- [x] **macOS target** — native `PhrasaMac` (not Catalyst): three-pane library/
      editor, full-screen speed reader, outline presenter, offline SQLite,
      import/export/backup, recovery, keyboard/clicker commands, package-linked
      domain/persistence, Mac tests and build. Voice remains intentionally
      iOS/iPadOS-only.
- [x] **Public website marketing-only** — four routes, no browser product SaaS.
- [x] **Expo / React Native retirement** — `mobile/` removed; Atkinson font
      owned by `ios-native/`; `LegacyExpoMigrator` and tests retained; CI guard
      blocks reintroduction.
