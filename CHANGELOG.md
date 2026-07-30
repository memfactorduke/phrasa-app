# Changelog

All notable changes to Phrasa are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) (`MAJOR.MINOR.PATCH`),
with `package.json` `version` as the source of truth. See the "Versioning &
releases" section in `CLAUDE.md` for the bump rules.

## [Unreleased]

### Added

- **Open-source release.** Apache License 2.0, trademark notice, contribution
  and security guidance, public source links in iOS, Mac, and web surfaces, and
  App Store promotional/description copy that advertises the public source.
- **Adversarial regression coverage.** Account/principal isolation, serialized
  web sync, stale acknowledgement recovery, keyset pagination, corrupt browser
  storage preservation, multi-tab clearing, immutable native presentation
  requests, autosave failure gates, and clock-skew-safe backup conflicts.

### Changed

- **Native and web reliability hardening.** Editor switching, foreground voice
  lifecycle, reader pacing/performance, Mac presentation routing, password
  recovery, account deletion verification, and public product truth now fail
  safely across the reviewed edge cases.

## [1.1.0] — 2026-07-20

### Added
- **Web companion at `/app`.** Guest/local script library, editor, and speed
  teleprompter with countdown (Off/5/15, default 5), WPM, font size, focus line,
  margins, and horizontal/vertical mirrors. No browser Voice Follow (native-only
  copy; no fake mic controls). Optional Supabase auth/sync via
  `NEXT_PUBLIC_PHRASA_SUPABASE_URL` +
  `NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY` (publishable key only);
  Apple SSO primary, email/password secondary; `/auth/callback` exchange.
  Namespaced localStorage by guest vs user id; sign-out isolation; guest import
  only after successful remote upsert. `@supabase/supabase-js` dependency.
  Vitest coverage for models, persistence, remote map, auth copy; Playwright
  guest create/edit/reader/countdown/responsive flows.

### Changed
- **Marketing and legal copy** updated for the web companion and honest native
  Voice Follow claims. README, rebuild spec website section, TODOS, and site
  nav link to `/app`.

## [1.0.0] — prior

Website marketing-only release notes and native rebuild history remain in git
history; abbreviated below for continuity.

### Changed
- **Supabase sync-only baseline.** Active migrations are a single native-sync
  schema (`folders`, `scripts` with `outline`, `user_settings`, owner-only RLS,
  same-owner composite `scripts(folder_id, user_id)` → `folders(id, user_id)`
  FK with `ON DELETE SET NULL (folder_id)`, hardened `set_updated_at`, dedicated
  `scripts_preserve_updated_at_on_open` trigger that preserves `updated_at` on
  `last_opened_at`-only stamps while still bumping on real field changes,
  `delete_own_account`). Historical `0001`–`0011` billing/analytics/profile/
  storage SQL moved to `supabase/archive/` and must never be applied to a new
  project. No live Supabase project is linked or applied from this repo;
  clients use project URL + publishable key only.
- **Native marketing version aligned to App Store Connect 1.0**; build bumped
  to **12** (next fresh candidate only — not archived/exported/uploaded).
- **Terms, home, and README** truth pass for the local-only first release: no
  user accounts, cloud sync, cloud-backed deletion, or published support email.
- **Privacy and Support pages** rewritten as polished customer-facing copy:
  scripts/settings stay on device; no Phrasa account, cloud sync, ads,
  tracking, or payments in this release; accurate Apple Speech wording
  (on-device when supported; otherwise Apple services may process audio; never
  sent to Phrasa or developer servers); self-service Support topics; Privacy
  contact routes to Support without inventing email; TestFlight guidance is
  conditional for beta testers only. Public pages omit internal release-note
  language (candidate/local-only/domain claims). Route metadata and accessible
  legal section structure updated; unit tests guard these constraints.

### Fixed
- **Public site accessibility** — skip link now focuses `#main`, header/footer
  nav landmarks use distinct labels, and primary nav/logo/skip targets keep a
  44px minimum hit height on tablet and desktop (not only phone).

### Removed
- **Expo / React Native app** (`mobile/**`) and EAS/Metro/root Expo config —
  the shipping product is Swift/SwiftUI only (`ios-native/`).

### Changed
- **Atkinson Hyperlegible** is bundled under
  `ios-native/Phrasa/Resources/Fonts/` (no longer loaded from `mobile/assets`).
- **CI** runs a shipping-surface guard and Swift package tests instead of the
  Expo mobile job.
- **Docs** describe one native product plus a marketing website; dual-lane
  Expo vs native guidance is gone.

### Kept
- **`LegacyExpoMigrator`** and its tests — one-time on-device import of the
  retired Expo SQLite library for `com.phrasa.app` upgrades.

## [1.0.0] — 2026-07-17

### Added
- **Public Phrasa site** with four routes only: home, privacy, terms, and
  support — product story for iPhone, iPad, and Mac, with an honest App Store
  coming-soon call to action until a public store URL is published.
- **Strict black-and-white editorial design** aligned with the native rebuild
  visual system (no browser SaaS chrome).

### Removed
- **Browser teleprompter product** — library, editor, reader, auth, pricing,
  billing, AI APIs, analytics API, guest mode, PWA/service worker, and the web
  dashboard. The website no longer requires Supabase or product secrets to
  render.
- **Web-only dependencies** for the retired SaaS surface (Supabase clients,
  document parsers, speech helpers, Radix app chrome, etc.).

### Changed
- **Website is marketing-only.** Optional native sync schema remains under
  `supabase/migrations/` for the native apps; it is not imported by the site.

## [0.6.0] — prior

Prior browser SaaS releases (voice-following web prompter, cloud library,
billing, AI features) are superseded by the native-first rebuild. See git
history for detail.
