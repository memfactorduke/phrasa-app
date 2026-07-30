# Phrasa iOS release automation (build 14)

Fail-closed lane for archiving and uploading the shipping iOS app. Uses only
`ios-native/PhrasaNative.xcodeproj` (hard-fails on numbered Finder duplicates).

## Entry point

```bash
scripts/ios-release/release-ios.sh --preflight
scripts/ios-release/release-ios.sh --release
scripts/ios-release/release-ios.sh --release --validate --upload \
  --confirm-upload 'UPLOAD BUILD 14 TO APP STORE CONNECT'
```

See `release-ios.sh --help` for flags. There is no `--skip-tests`.

## Production Supabase publishable-key injection

Shipping Release builds must inject the current **publishable** (or legacy JWT
**anon**) client key. The key is intentionally blank in `project.yml` /
`pbxproj` so source stays offline-safe.

| Concern | Behavior |
| --- | --- |
| Env var | `PHRASA_SUPABASE_PUBLISHABLE_KEY` |
| Required for | `--release`, `--validate`, `--upload` (fail closed if missing/empty) |
| Allowed forms | `sb_publishable_*`, or JWT with `"role":"anon"` |
| Rejected forms | empty; `sb_secret_*`; any `service_role` marker; JWT `service_role`; other non-client strings |
| Injection | `xcodebuild` build-setting override on **shipping** Release `build` and `archive` only (not XCTest, not package tests, not `showBuildSettings`) |
| Logging | Value is **never** printed intentionally; scrubbed from preflight / showBuildSettings / build / archive proof logs if it appears |
| Archive + IPA inspect | Expanded `PhrasaSupabaseURL` must equal the production URL; expanded `PhrasaSupabasePublishableKey` must be non-empty and a safe client key (value not printed) |

Production URL/host pins (must match product `CloudConfiguration`):

- `https://uqkjidvqyngrnyftdazp.supabase.co`
- `uqkjidvqyngrnyftdazp.supabase.co`

```bash
export PHRASA_SUPABASE_PUBLISHABLE_KEY='…'   # publishable or legacy anon only
scripts/ios-release/release-ios.sh --release
```

`--preflight` may run without the env var (reports a note). A **privileged** or
**invalid** value set during preflight is still a hard blocker.

## Tests

```bash
bash scripts/ios-release/tests/test_evidence_parser.sh
bash scripts/ios-release/tests/test_helpers_and_gates.sh
bash scripts/ios-release/tests/test_provisioning_profiles.sh
bash scripts/ios-release/tests/test_preflight_no_archive.sh
bash scripts/ios-release/tests/test_supabase_publishable_key.sh
bash -n scripts/ios-release/release-ios.sh
for f in scripts/ios-release/lib/*.sh; do bash -n "$f"; done
```

## Layout

| Path | Role |
| --- | --- |
| `release-ios.sh` | CLI entry |
| `lib/constants.sh` | Pin + production Supabase URL constants |
| `lib/supabase_key.sh` | Key validation, redaction, Info.plist cloud assertions |
| `lib/preflight.sh` | Readiness (no key injection into settings dump) |
| `lib/build.sh` | Tests + Release build/archive (key override on build/archive) |
| `lib/inspect.sh` | Archive/IPA inspection including cloud Info.plist |
| `tests/` | Shell regression suite |
