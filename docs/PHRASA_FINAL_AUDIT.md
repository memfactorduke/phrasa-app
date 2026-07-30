# Phrasa final rebuild audit

> **Historical snapshot — 2026-07-17.** This document records the tree named
> below and is not current release status or evidence for later source changes.
> Use `ios-native/AppStore/README.md`, `docs/FRESH_MAC_RELEASE.md`, and
> `docs/RELEASE_BLOCKERS.md` for the current build-14 boundary.

**Audited commit:** `bdebe6f09d3a71190bf894bbe6e32f60e95f00d4`  
(`bdebe6f` — *Mark macOS rebuild target done in TODOS.md*)  
**Product tree lineage:** source and tests last changed at `02b40c5680caa177040793f5599c9d6cb5e713b7` (iOS find-line select/scroll); `bdebe6f` is doc-only (`TODOS.md`).  
**Audit date:** 2026-07-17  
**Auditor:** independent repository read/verify against the pinned final tree. Older final-audit documents were not treated as authority.

---

## Evidence boundary

| In scope | Out of scope (not claimed) |
| --- | --- |
| Source at `bdebe6f` / product code through `02b40c5`; packages; iPhone/iPad/Mac apps; website; CI; migration path; `TODOS.md` / release docs | Physical-device voice, clicker, airplane-mode, or long-session proof |
| Coordinating integrated automated matrix (counts attributed below) | Production domain/deploy, App Store signing/submission |
| Local package performance re-runs and Mac chrome unit re-run by this auditor | Live Supabase/auth/sync end-to-end validation |
| Proven Computer Use UI evidence from the coordinating final QA (cited only as supplied) | Any Computer Use not listed by the coordinator |
| Safe local inspection only | External services, deploy, sign, publish |

**Payments:** no payment setup was requested for this rebuild bar, and **no payment product ships** in app source (no StoreKit / IAP / payment Swift). Historical Supabase billing migrations are optional-backend archaeology, not a shipping IAP surface.

---

## Executive verdict

The tree at `bdebe6f` is a **source-complete candidate** and is fit for **local/internal beta** packaging on the strength of packages, native iPhone/iPad/Mac apps, marketing website, Expo retirement with bounded legacy migration, truthful CI, integrated automated matrix, and direct simulator/Mac Computer Use evidence. **Public production release remains external work**, not a source failure.

| Bar | Status |
| --- | --- |
| **Source-complete candidate** | **PASS** |
| **Local / internal beta** | **PASS** |
| **Public production release** | **EXTERNAL / NO-GO** until the external checklist is complete |

---

## Requirement matrix

Legend: **PASS** = met in source/tests/QA evidence · **PARTIAL** = residual non-blocking risk · **EXTERNAL** = correctly outside source completeness.

| Area | Verdict | Notes |
| --- | --- | --- |
| **iPhone** | PASS | Full-screen library, editor (Script/Outline), reader, sheets; iPhone Debug build PASS; Computer Use on simulator (onboarding, library, editor, live reader). |
| **iPad** | PASS | Same `Phrasa` target (`TARGETED_DEVICE_FAMILY` 1,2); iPad Debug build PASS; final Computer Use: split library/editor, live reader, and find-line select/scroll (below). |
| **Mac** | PASS | Native `PhrasaMac` (not Catalyst); library/editor/reader/outline presenter; 35 tests; Mac build PASS; Section label squeeze fixed at `cc62b70` with tests + post-fix 1180×740 binary recheck PASS. |
| **Architecture / data** | PASS | `PhrasaCore` / `PhrasaDomain` / `PhrasaPersistence`; apps depend inward. Spec allows incremental folder migration — absence of a top-level `PhrasaShared/` folder is not a failure. Separate platform-native UI is valid; duplicated session/import code is maintenance risk only. SQLite is the shipping store. |
| **Website** | PASS | Only `/`, `/privacy`, `/terms`, `/support`; no browser product or product secrets required to render; 28 Vitest + 6 Playwright. Computer Use: desktop + phone widths, black/white, no horizontal overflow. |
| **Expo retirement / legacy migration** | PASS | No `mobile/`; CI/root guard PASS; Expo/RN/EAS shipping retired. `LegacyExpoMigrator` remains the one-time on-device upgrade path (failure does not replace the library; recovery moves with rollback). |
| **CI / testing / performance** | PASS | Real package `swift test`, real iOS/Mac `xcodebuild test`, `set -euo pipefail` on native pipelines, correct schemes/destinations. 2k-word pathological stall gates present with measured package re-runs (below). Process risk only: `project.yml` and checked-in `PhrasaNative.xcodeproj` can drift if XcodeGen is used without committing both; xcodegen left the product tree clean on the final closure pass. |
| **Payments** | PASS (absent by design) | Not requested; do not ship. Spec forbids pricing gates for the core local experience. |
| **TODOS.md currency** | PASS | Current at `bdebe6f`: **macOS target is Done**; open items correctly remain real-device voice/sync QA, optional Mac voice, and external owner/store/deploy/legal items. Do not treat TODOS as listing macOS as missing. |

---

## Automated test and build evidence

### Coordinating integrated run (authoritative full matrix)

Provenance: **coordinating integrated automated matrix** for the final product tree (iOS suite closed at **201/201** after find-line tests; packages/website/Mac unchanged after earlier green runs). This auditor did not re-execute full app suites or multi-destination builds for this finalize pass.

| Surface | Result | Count / outcome |
| --- | --- | --- |
| Website Vitest | PASS | **28** tests |
| Website Playwright | PASS | **6** tests |
| PhrasaCore | PASS | **32** tests |
| PhrasaDomain | PASS | **15** tests |
| PhrasaPersistence | PASS | **12** tests |
| iOS app suite (`PhrasaTests`) | PASS | **201** tests |
| Mac app suite (`PhrasaMacTests`) | PASS | **35** tests |
| iPhone Debug build | PASS | Final integrated |
| iPad Debug build | PASS | Final integrated |
| macOS build | PASS | Final integrated |
| Expo guard | PASS | Final integrated |
| xcodegen product tree | clean | Final integrated (no dirty product files) |

### Definition-count cross-check (tree at `bdebe6f` / product through `02b40c5`)

| Suite | Defined tests (source scan) |
| --- | --- |
| PhrasaCore | 32 |
| PhrasaDomain | 15 |
| PhrasaPersistence | 12 |
| PhrasaTests | **201** (includes 4 `FindLineJumpTests`) |
| PhrasaMacTests | 35 |
| Vitest (`lib/` + `tests/unit/`) | 28 |
| Playwright | 6 |

### Commands this auditor actually ran

| Command | Outcome |
| --- | --- |
| `swift test --package-path ios-native/Packages/PhrasaCore --filter LargeScriptPerformanceTests` | PASS (3); PERF lines recorded |
| `swift test --package-path ios-native/Packages/PhrasaDomain --filter LargeScriptPerformanceTests` | PASS (3); PERF lines recorded |
| `swift test --package-path ios-native/Packages/PhrasaPersistence --filter testTwoThousandWordUpsertLoadAndRelaunchStayDurableAndBounded` | PASS; PERF lines recorded |
| `swift test --package-path ios-native/Packages/PhrasaPersistence --filter testEditAutosaveRelaunchRecoveryForLargeScript` | PASS; PERF lines recorded |
| Full package suites Core / Domain / Persistence (`--parallel`) | 32 / 15 / 12 XCTest cases scheduled and passed |
| `xcodebuild … PhrasaMac -only-testing:PhrasaMacTests/MacEditorChromePresentationTests test` | **TEST SUCCEEDED** (2 tests) |
| `node scripts/guard-no-expo.mjs` | Expo retirement guard passed |
| Website `npm test` | Not run (`node_modules` absent in this worktree) |
| Full iOS/Mac app suites and multi-destination builds | Not re-run by this auditor; attributed to coordinating integrated run |

---

## Performance (2,000-word gates)

Gates assert **pathological multi-second stalls only** and print `PERF …=…ms` for reporting. They are not tight wall-clock SLAs.

### Thresholds (source)

| Gate | Location | Threshold |
| --- | --- | --- |
| Tokenize ~2k words | `PhrasaCore/…/LargeScriptPerformanceTests.swift` | `< 2.0 s` |
| Alignment 200 steps on ~2k tokens | same | `< 3.0 s` |
| Normalize 5k words | same | `< 1.0 s` |
| Content signature / resume validate / find-line ~2k | `PhrasaDomain/…/LargeScriptPerformanceTests.swift` | each `< 1.0 s` |
| SQLite upsert / load / edit-relaunch ~2k | `PhrasaPersistence/…/SQLiteDurabilityTests.swift` | each `< 2.0 s` |
| Bulk 40×2k upserts | same | `< 15.0 s` (not re-timed by auditor) |
| App-layer 2k metrics / session / import-export / SQLite | `PhrasaTests/LargeScriptPerformanceTests.swift` | 0.5–2.0 s class bounds in source; not re-run by auditor |

### Observed measurements (auditor package re-runs)

| Metric | Observed | Threshold |
| --- | --- | --- |
| `PERF tokenize_2000_words` | **56.569 ms** (2000 tokens) | `< 2000 ms` |
| `PERF alignment_200_steps_on_2000_tokens` | **790.549 ms** (cursor 793) | `< 3000 ms` |
| `PERF normalize_5000_words` | **137.093 ms** | `< 1000 ms` |
| `PERF content_signature_2000_words` | **0.214 ms** | `< 1000 ms` |
| `PERF resume_validate_2000_words` | **0.072 ms** | `< 1000 ms` |
| `PERF find_line_2000_words` | **0.324 ms** (line 26) | `< 1000 ms` |
| `PERF sqlite_upsert_2000_words` | **13.466 ms** | `< 2000 ms` |
| `PERF sqlite_load_2000_words` | **0.473 ms** | `< 2000 ms` |
| `PERF sqlite_edit_relaunch_2000_words` | **0.261 ms** | `< 2000 ms` |

No multi-second stalls on re-run package gates. Unchanged package sources after those re-runs.

---

## iOS / iPad find-line select and scroll (PASS)

Product delta from `cc62b70` through `02b40c5` (four files only; cherry-picked from Grok `be6281f`):

| File | Role |
| --- | --- |
| `ios-native/Phrasa/Editor/ScriptBodyTextEditor.swift` | TextKit `UITextView` editor; `applyJumpIfNeeded` sets `selectedRange` and `scrollRangeToVisible` |
| `ios-native/Phrasa/Editor/EditorView.swift` | `performFindLine` → `FindLineJumpPresentation.perform` → `findLineJump`; body uses `ScriptBodyTextEditor` |
| `ios-native/PhrasaTests/FindLineJumpTests.swift` | 4 unit tests: jump range/offset/announce, wrap/no-match, selection clamp/restore, jump identity |
| `ios-native/PhrasaNative.xcodeproj/project.pbxproj` | Includes editor source and tests in target membership |

Material lines:

- Jump applies selection + scroll: `ScriptBodyTextEditor.swift` ~119–134  
- Presentation produces jump range: `ScriptBodyTextEditor.swift` ~45–68  
- Editor wiring: `EditorView.swift` ~451–460, ~637  
- Tests: `FindLineJumpTests.swift` (4 cases; contributes to integrated **201**)

**Direct Computer Use (coordinator, final rebuilt iPad binary):** selected sample → More → Find a line → query `stumble` → Find; UI reported **Line 3**; TextKit visibly selected/highlighted the exact match and scrolled it into view. Split library/editor and live reader also visually passed.

Mac find already selected/scrolled via AppKit (`MacScriptBodyEditor.swift`). Find-line is **not** an open residual risk.

---

## Mac Section Picker squeeze (PASS at `cc62b70`, still current)

**Prior defect:** at ~1180×740, visible Picker title `"Section"` stacked between Folder and Script/Outline.

**Source fix:** `MacEditorChromePresentation.sectionPickerHidesVisibleLabel = true`, title/accessibility `"Editor section"`, `.labelsHidden()` — `MacEditorView.swift` ~205–230, ~365–377. Regression tests: `MacEditorChromePresentationTests.swift`.

**Auditor:** re-ran chrome presentation tests → PASS (2).  
**Computer Use (coordinator):** post-fix binary `/tmp/phrasa-integrated-qa-dd/Build/Products/Debug/PhrasaMac.app` rechecked at **1180×740** — clean chrome; accessibility **Editor section** with Script/Outline children. **PASS.**

---

## Direct UI evidence (coordinator Computer Use only)

| Surface | Evidence | Result |
| --- | --- | --- |
| Website (desktop + phone) | Four-route black/white; no horizontal overflow; accessible nav/support | OK |
| iPhone Simulator | Onboarding, library, editor, live reader operated | OK |
| Mac | Library, editor, reader, dedicated outline presenter operated | OK |
| Mac Section squeeze | Found, fixed at `cc62b70`, fixed-binary recheck 1180×740 | **PASS** |
| Final iPad find-line | Query `stumble` → Line 3; selection + scroll into view; split + reader | **PASS** |

This auditor did **not** perform Computer Use or physical-device work.

---

## Remaining source risks (non-blocking)

1. **Duplicated platform session/import code** — intentional separate Mac/iOS UI; maintenance risk only.  
2. **No top-level `PhrasaShared/` folder** — allowed incremental migration; shared packages already carry domain/persistence/core.  
3. **`project.yml` vs checked-in `PhrasaNative.xcodeproj`** — both present; CI builds the checked-in project; keep them aligned when regenerating.  
4. **Optional cloud** — client wiring and migrations exist; live backend verification is **EXTERNAL**. Offline local library remains usable.

**No P0 source safety blockers** in destructive backup restore, SQLite transaction/rollback, legacy migration, resume signatures, or library/session recovery:

| Topic | Evidence |
| --- | --- |
| Backup restore | Explicit merge/replace confirmation (`LibraryView.swift` ~201–214); `LibraryStore.restore` (~426–468) persists then publishes; failure does not claim success |
| SQLite rollback | Injected abort leaves prior settings (`SQLitePersistenceClientTests` ~490–511); durability/tombstone/quarantine/corrupt-preserve coverage in suites |
| Legacy Expo | Open/read failures do not replace library; recovery moves WAL/SHM with rollback (`LegacyExpoMigrator.swift`) |
| Resume | `ResumeBookmark.validated(against:)` requires matching `ScriptContentSignature` (`ResumeProgress.swift` ~48–53) |

---

## CI truthfulness

File: `.github/workflows/ci.yml`

| Job | Real work |
| --- | --- |
| `web` | `npm ci`, typecheck, lint, `npm test`, build |
| `e2e` | Playwright Chromium |
| `shipping-guard` | `node scripts/guard-no-expo.mjs` |
| `native-packages` | `swift test` for Core, Domain, Persistence |
| `native-ios` | `set -euo pipefail`; resolve iPhone Simulator; `xcodebuild -scheme Phrasa -only-testing:PhrasaTests test` |
| `native-mac` | `set -euo pipefail`; `xcodebuild -scheme PhrasaMac -destination 'platform=macOS,arch=arm64' test` |

Schemes `Phrasa` and `PhrasaMac` are checked in. CI does not regenerate from `project.yml` before test.

---

## External release checklist (not source failures)

| Item | Classification |
| --- | --- |
| Code signing, App Store Connect, archive/submit | EXTERNAL |
| Physical-device voice, clicker/foot pedal, airplane-mode full journey, long voice session | EXTERNAL |
| Production domain (`phrasa.app`), Netlify deploy, production smoke | EXTERNAL |
| Reachable support contact for store listing | EXTERNAL |
| Legal review of privacy/terms; store screenshots/metadata | EXTERNAL |
| Optional live sync: Supabase migrations through `0011_…`, Sign in with Apple/email recovery, account deletion | EXTERNAL |
| Paid tiers (later; not requested) | EXTERNAL / out of scope |

Aligned with current `TODOS.md` and `GO_LIVE.md`: owner/external items open; **macOS target completed** in TODOS Done section.

---

## Go / no-go conclusion

| Decision | Call |
| --- | --- |
| Source-complete candidate | **GO / PASS** |
| Local / internal beta | **GO / PASS** (automated matrix + simulator/Mac Computer Use) |
| Public production | **NO-GO / EXTERNAL** until external checklist is complete |

**Payments:** not requested; do not ship.  
**Expo:** shipping Expo/React Native/EAS retired; `LegacyExpoMigrator` retained by design.

---

## Material file-and-line evidence

| Claim | Location |
| --- | --- |
| Spec hard boundaries, architecture, verification | `docs/PHRASA_REBUILD_SPEC.md` |
| TODOS: macOS Done; real-device / Mac voice / external open | `TODOS.md` (Done + Native product + Owner actions) |
| iOS find-line jump + TextKit select/scroll | `ScriptBodyTextEditor.swift` ~45–68, ~119–134; `EditorView.swift` ~451–460, ~637 |
| Find-line unit tests | `PhrasaTests/FindLineJumpTests.swift` |
| Mac Section hide policy | `PhrasaMac/Editor/MacEditorView.swift` ~205–230, ~365–377 |
| Mac Section tests | `PhrasaMacTests/MacEditorChromePresentationTests.swift` |
| Mac find select/scroll | `PhrasaMac/Editor/MacScriptBodyEditor.swift` ~4–50 |
| Resume signature | `PhrasaDomain/…/ResumeProgress.swift` ~48–84 |
| Backup restore confirmation | `Phrasa/Library/LibraryView.swift` ~201–214 |
| Restore merge/replace | `Phrasa/Data/LibraryStore.swift` ~426–468 |
| Legacy Expo migrator | `Phrasa/Data/LegacyExpoMigrator.swift` |
| 2k-word PERF gates | package and `PhrasaTests` `LargeScriptPerformanceTests` / Persistence durability extension |
| CI | `.github/workflows/ci.yml` |
| Expo guard | `scripts/guard-no-expo.mjs` |
| Website four routes | `lib/site.ts`; `app/{page,privacy,terms,support}/page.tsx` |
| iOS+iPad family | `project.yml` `TARGETED_DEVICE_FAMILY: "1,2"` |
| Mac target | `ios-native/PhrasaMac/`, `PhrasaMac.xcscheme` |

---

*End of final audit.*
