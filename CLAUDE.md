@AGENTS.md

# Phrasa — project guide

Native-first teleprompter. The **root Next.js app** hosts the public marketing
site (`/`, `/privacy`, `/terms`, `/support`) and the **web companion** (`/app`,
`/auth/callback`). See `docs/PHRASA_REBUILD_SPEC.md`.

## Commands

- `npm run dev` — marketing site + web companion (Turbopack)
- `npm test` / `npm run test:e2e` — Vitest / Playwright
- `npm run guard:no-expo` — fail if Expo/RN/EAS or `mobile/` reappears
- `npm run typecheck` / `npm run lint` / `npm run build`

## Versioning & releases

- **Scheme:** [Semantic Versioning](https://semver.org) in `package.json`.
- **Changelog:** `CHANGELOG.md` ([Keep a Changelog](https://keepachangelog.com)).
- Website versions live in `package.json`; native app versions live in
  `ios-native/project.yml`.

## Architecture

- **Website:** public marketing pages + web companion, black/white editorial
  design. Site URL via `lib/site.ts` (`NEXT_PUBLIC_SITE_URL` optional). Guest
  mode needs no secrets. Optional cloud:
  `NEXT_PUBLIC_PHRASA_SUPABASE_URL` +
  `NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY` (never service-role).
- **Native:** `ios-native/` — full shipping product (Swift/SwiftUI for
  iPhone, iPad, and Mac), including Voice Follow.
- **Supabase:** `supabase/migrations/` holds one active native-sync baseline
  (folders, scripts, user_settings, `delete_own_account`). Historical
  billing/analytics/profile/storage SQL lives under `supabase/archive/` and must
  never be applied to a new project. Clients use project URL + publishable key
  only (never service-role).
- **Retired:** Expo/React Native `mobile/` tree, pricing/billing/AI web APIs,
  PWA/service worker. Keep only `LegacyExpoMigrator` for on-device Expo SQLite
  upgrades. Do not reintroduce Expo, EAS, Metro, or React Native.

## Conventions

- Next 16: read `node_modules/next/dist/docs/` before changing Next APIs.
- Design tokens in `app/globals.css` (strict black/white per rebuild spec).
- Web companion: no Voice Follow / fake mic UI; honest sync status.
- Website lane does not edit `ios-native/**`.

## gstack

Use gstack skills for browse/QA/ship when needed. `/browse` for web automation.
