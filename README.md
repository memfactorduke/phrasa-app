# Phrasa

Calm, **local-first teleprompter** for **iPhone, iPad, and Mac**, with a
**browser companion** for scripts and speed prompting. This repository root hosts
the **public website** (marketing + legal) and the **web companion** at `/app`.
The full shipping product (including Voice Follow) is native Swift/SwiftUI
(`ios-native/`).

## Open source

Phrasa is open source under the
[Apache License 2.0](https://www.apache.org/licenses/LICENSE-2.0). You can read,
audit, modify, and contribute to the complete product source at
[github.com/memfactorduke/phrasa-app](https://github.com/memfactorduke/phrasa-app).
The license covers the code, not permission to impersonate Phrasa or use its
name and branding for a different product. See [`LICENSE`](./LICENSE),
[`NOTICE`](./NOTICE), [`CONTRIBUTING.md`](./CONTRIBUTING.md), and
[`SECURITY.md`](./SECURITY.md).

> Optional native and web accounts/sync (Sign in with Apple primary;
> email/password secondary) use a **single** strict migration under
> `supabase/migrations/` (folders, scripts, user_settings, owner-only RLS,
> `delete_own_account`) on a dedicated Supabase project. Clients use project URL
> + **publishable** key only (never service-role). Guest web mode works with no
> cloud configuration.

## Public routes

| Path | Purpose |
| --- | --- |
| `/` | Product story, platforms, App Store / coming-soon CTA, link to web companion |
| `/privacy` | Data and microphone policy (native + web) |
| `/terms` | App license and service limits |
| `/support` | Self-service help: web companion, mic recovery, optional sync, offline use |
| `/app` | Web companion: guest/local library, editor, speed teleprompter, optional auth |
| `/auth/callback` | Supabase OAuth / email confirmation callback |

## Quick start (website + web companion)

```bash
nvm use   # Node 22+
npm ci
npm run dev
```

Open <http://localhost:3000> (marketing) or <http://localhost:3000/app> (companion).

No Supabase secrets are required for marketing pages or **guest** web mode.

Optional cloud auth/sync for the web companion:

```bash
export NEXT_PUBLIC_PHRASA_SUPABASE_URL="https://YOUR_PROJECT.supabase.co"
export NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY="your-publishable-anon-key"
```

Also configure in the Supabase dashboard:

- Auth redirect URL: `https://your-domain/auth/callback` (and localhost for dev)
- Apple provider: Services ID, secret key, and return URLs (external Apple setup)
- Email provider if using email/password

**Never** put a service-role key in the website, app, or git.

Optional: set `NEXT_PUBLIC_SITE_URL` for canonical/OG/sitemap URLs in deploy
previews (production default is `https://phrasa.app`).

## Web companion behavior

- **Guest mode** — full library/editor/speed reader in `localStorage`, namespaced
  under a guest principal. Works offline with zero cloud config.
- **Account mode** — when env vars are set, Sign in with Apple is primary; email
  and password is secondary. Loads remote scripts/folders and upserts edits.
  Honest sync status (no pretend conflict UI).
- **Data safety** — each user id has its own storage namespace. Sign-out switches
  to guest and never shows the previous account’s cached library. Guest scripts
  import only after successful login, and guest data clears only after successful
  remote upsert.
- **No Voice Follow on web** — native-only; no fake microphone controls.

## Checks

```bash
npm test              # Vitest — models, persistence, sync map, auth copy, routes
npm run guard:no-expo # Standalone: fail if Expo/RN/EAS or mobile/ reappears
npm run test:e2e      # Playwright: marketing smoke + guest web app flows
npm run guard:public-env # Reject incomplete/privileged browser cloud config
npm run typecheck
npm run lint
npm run build
```

Native app verification (on a Mac with Xcode):

```bash
cd ios-native
swift test --package-path Packages/PhrasaCore --parallel
swift test --package-path Packages/PhrasaDomain --parallel
swift test --package-path Packages/PhrasaPersistence --parallel
xcodebuild -project PhrasaNative.xcodeproj -scheme Phrasa \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

The canonical Xcode project and SwiftPM resolution are tracked; XcodeGen is
needed only when intentionally regenerating the project from `project.yml`.
For a new release machine, follow
[`docs/FRESH_MAC_RELEASE.md`](./docs/FRESH_MAC_RELEASE.md) before building or
restoring signing credentials.

## Related trees

- `ios-native/` — shipping SwiftUI app and shared packages
- `docs/PHRASA_REBUILD_SPEC.md` — source of truth for the native-first rebuild
- `supabase/migrations/` — single active native-sync baseline for optional accounts/sync
- `supabase/archive/historical-migrations-pre-sync-baseline/` — retired billing/analytics SQL; **never apply to a new project**

### Optional: dedicated Phrasa Supabase project

1. Create a **new dedicated** Supabase project for Phrasa.
2. Apply only files in `supabase/migrations/` (baseline + ACL remediation).
3. Configure Auth redirect URLs:
   - Native: `phrasa://auth/callback`, `phrasa://auth/recovery`
   - Web: `https://your-site/auth/callback`
4. Enable Apple provider (Services ID + key) and email if needed.
5. Put **only** the project URL and **publishable** key in clients.

## Legacy upgrades

Users who still have an older Expo build of `com.phrasa.app` on device keep
their scripts: the native app’s `LegacyExpoMigrator` reads the on-device
`ExpoSQLiteStorage` key/value store once and imports folders, scripts, and
reader settings into SQLite. That migrator is not a shipping Expo surface.
