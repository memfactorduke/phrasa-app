#!/usr/bin/env bash
# Phrasa native iOS release automation — fail-closed lane for build 14.
#
# Safety:
#   - Never globs Xcode projects; only ios-native/PhrasaNative.xcodeproj
#   - Hard-fails on PhrasaNative 2/3/… .xcodeproj Finder duplicates
#   - Requires exact commit, version, build, bundle ID, team
#   - Requires human physical-device voice-acceptance evidence before archive
#   - --preflight never archives/exports/validates/uploads; only writes an
#     isolated gitignored proof directory under ios-native/build/release-runs/
#     (does not alter tracked files or App Store state)
#   - --release always runs package tests + full iOS XCTest (no skip hatch)
#   - --upload requires a second exact confirmation phrase
#   - Never accepts private key contents as arguments; never prints secrets
#   - Archive/export cleanup is confined to the unique run directory
#   - --release/--validate/--upload require PHRASA_SUPABASE_PUBLISHABLE_KEY
#     (publishable or legacy anon client key only; fail closed on missing,
#     privileged sb_secret_/service_role, or non-client forms). The key is
#     passed only as an xcodebuild build-setting override for shipping
#     Release build/archive; never written to preflight/showBuildSettings/proof
#     logs (redacted if it appears).
#
# Usage:
#   scripts/ios-release/release-ios.sh --preflight
#   scripts/ios-release/release-ios.sh --release
#   scripts/ios-release/release-ios.sh --release --validate
#   scripts/ios-release/release-ios.sh --release --validate --upload \
#       --confirm-upload 'UPLOAD BUILD 14 TO APP STORE CONNECT'
#
# Env:
#   PHRASA_VOICE_EVIDENCE_PATH   path to filled evidence file
#   PHRASA_ALLOW_KNOWN_FINDER_DUPES=1  tolerate four source duplicates only;
#                                      numbered PhrasaNative N.xcodeproj always blocks
#   PHRASA_SUPABASE_PUBLISHABLE_KEY  required for --release/--validate/--upload:
#                                      production publishable (sb_publishable_*)
#                                      or legacy JWT anon client key; never a
#                                      service-role/secret key; value never printed
#   ASC_KEY_ID / ASC_ISSUER_ID   for validate/upload (AuthKey_<id>.p8 by convention)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/constants.sh
source "${SCRIPT_DIR}/lib/constants.sh"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/supabase_key.sh
source "${SCRIPT_DIR}/lib/supabase_key.sh"
# shellcheck source=lib/evidence.sh
source "${SCRIPT_DIR}/lib/evidence.sh"
# shellcheck source=lib/preflight.sh
source "${SCRIPT_DIR}/lib/preflight.sh"
# shellcheck source=lib/inspect.sh
source "${SCRIPT_DIR}/lib/inspect.sh"
# shellcheck source=lib/build.sh
source "${SCRIPT_DIR}/lib/build.sh"

usage() {
  cat <<'EOF'
Phrasa iOS release automation (build 14, fail-closed)

  --preflight              Checks + isolated proof log only; no archive/export/upload
  --release                Gated path: preflight + tests + Release build + archive + export
  --validate               After export, run altool --validate-app (requires ASC_KEY_ID/ISSUER)
  --upload                 After successful validation, upload (requires --confirm-upload)
  --confirm-upload PHRASE  Exact phrase: UPLOAD BUILD 14 TO APP STORE CONNECT
  --help                   Show this help

There is no --skip-tests. Package tests and iOS XCTest always run on --release.

Default with no flags is --preflight.

Env (shipping cloud injection):
  PHRASA_SUPABASE_PUBLISHABLE_KEY  Required for --release/--validate/--upload.
                                   Must be a publishable (sb_publishable_*) or
                                   legacy JWT anon client key. Privileged forms
                                   (sb_secret_, service_role JWT) fail closed.
                                   Injected only as an xcodebuild build-setting
                                   override on shipping Release build/archive.
                                   Never printed or written to preflight/
                                   showBuildSettings/proof logs.

Artifacts land under ios-native/build/release-runs/<UTC>-<pid>-<random>/
(gitignored; collision-safe unique run dir per invocation).
--preflight only creates that proof directory (preflight.log, showBuildSettings
dump, run-meta). It does not create DerivedData, .xcarchive, or .ipa files, and
does not modify tracked source or App Store state. Archive/IPA inspection asserts
expanded PhrasaSupabaseURL is the production project URL and
PhrasaSupabasePublishableKey is non-empty and a safe client key.
EOF
}

MODE=""
DO_VALIDATE=0
DO_UPLOAD=0
CONFIRM_UPLOAD=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preflight) MODE="preflight"; shift ;;
    --release) MODE="release"; shift ;;
    --validate) DO_VALIDATE=1; shift ;;
    --upload) DO_UPLOAD=1; shift ;;
    --confirm-upload)
      CONFIRM_UPLOAD="${2:-}"
      shift 2
      ;;
    --skip-tests)
      phrasa_die "--skip-tests is not supported; release always runs package tests and iOS XCTest"
      ;;
    --help|-h) usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  MODE="preflight"
fi

if (( DO_UPLOAD )) && [[ "$MODE" != "release" ]]; then
  phrasa_die "--upload requires --release"
fi
if (( DO_VALIDATE )) && [[ "$MODE" != "release" ]]; then
  phrasa_die "--validate requires --release"
fi
if (( DO_UPLOAD )) && (( ! DO_VALIDATE )); then
  phrasa_die "--upload requires --validate (validation must precede upload)"
fi
if (( DO_UPLOAD )); then
  if [[ "$CONFIRM_UPLOAD" != "$PHRASA_UPLOAD_CONFIRM_PHRASE" ]]; then
    phrasa_die "refusing upload: --confirm-upload must be exactly '${PHRASA_UPLOAD_CONFIRM_PHRASE}'"
  fi
fi

ROOT="$(phrasa_repo_root)"
cd "$ROOT"

# Refuse to operate if a second project path was somehow selected via env
if [[ -n "${PROJECT_FILE_PATH:-}" ]]; then
  phrasa_warn "ignoring PROJECT_FILE_PATH env; authoritative path is fixed"
fi

RUNS_PARENT="${ROOT}/ios-native/build/release-runs"
# Unique per invocation: never reuses/overwrites an existing run directory.
RUN_DIR="$(phrasa_create_run_dir "$RUNS_PARENT")"
PREFLIGHT_LOG="${RUN_DIR}/preflight.log"
export PHRASA_RUN_DIR="$RUN_DIR"

phrasa_info "run_dir=$RUN_DIR"
phrasa_info "mode=$MODE"

# Run preflight in this shell (not a pipe subshell) so BLOCKERS arrays survive.
set +e
phrasa_run_preflight >"$PREFLIGHT_LOG" 2>&1
PREFLIGHT_RC=$?
set -e
# Never persist a publishable key value in the preflight proof log.
phrasa_redact_supabase_key_in_file "$PREFLIGHT_LOG"
cat "$PREFLIGHT_LOG"

# Write fingerprint note
{
  echo "source_commit=${PHRASA_EXPECTED_COMMIT}"
  echo "candidate_fingerprint=${PHRASA_COMPUTED_FINGERPRINT:-}"
  echo "pbxproj_sha256=${PHRASA_PBXPROJ_SHA256:-}"
  echo "preflight_rc=$PREFLIGHT_RC"
  echo "hard_blockers=${#BLOCKERS[@]}"
  echo "upload_blockers=${#UPLOAD_BLOCKERS[@]}"
  echo "mode=$MODE"
} >"${RUN_DIR}/run-meta.txt"

if [[ "$MODE" == "preflight" ]]; then
  phrasa_info "preflight log: $PREFLIGHT_LOG"
  # Sanity: preflight must not have produced archive/ipa/DerivedData product trees
  if find "$RUN_DIR" \( -name '*.xcarchive' -o -name '*.ipa' \) 2>/dev/null | grep -q .; then
    phrasa_die "preflight unexpectedly created archive/ipa under $RUN_DIR"
  fi
  if [[ -d "${RUN_DIR}/DerivedData" || -d "${RUN_DIR}/artifacts" ]]; then
    phrasa_die "preflight unexpectedly created DerivedData/artifacts under $RUN_DIR"
  fi
  exit "$PREFLIGHT_RC"
fi

# --- Gated release path ---
# Hard blockers always refuse archive. Upload blockers refuse only --validate/--upload.
if ! phrasa_hard_gates_clear; then
  phrasa_die "hard preflight blockers remain (${#BLOCKERS[@]}); refusing tests/build/archive/export (see $PREFLIGHT_LOG)"
fi
if (( DO_VALIDATE || DO_UPLOAD )) && ! phrasa_upload_gates_clear; then
  phrasa_die "upload/validate blockers remain (${#UPLOAD_BLOCKERS[@]}); refusing validate/upload (see $PREFLIGHT_LOG)"
fi

# Double-check evidence still present (preflight already validated)
EVIDENCE_PATH="${PHRASA_VOICE_EVIDENCE_PATH:-${ROOT}/${PHRASA_DEFAULT_EVIDENCE_REL}}"
if [[ ! -f "$EVIDENCE_PATH" ]]; then
  phrasa_die "evidence disappeared after preflight: $EVIDENCE_PATH"
fi

# Fail closed: shipping build requires a safe publishable/legacy-anon client key.
# Value is never printed; injected only as xcodebuild override on build/archive.
phrasa_require_shipping_supabase_publishable_key

DERIVED="${RUN_DIR}/DerivedData"
RESULTS="${RUN_DIR}/results"
ARTIFACTS="${RUN_DIR}/artifacts"
phrasa_ensure_dir "$DERIVED" "$RESULTS" "$ARTIFACTS"

# Always run tests — no SKIP_TESTS / --skip-tests production escape hatch.
phrasa_run_package_tests "$ROOT" "${RUN_DIR}/package-tests.log"
phrasa_run_ios_xctest "$ROOT" "$DERIVED" "${RESULTS}/Phrasa.xcresult" "${RUN_DIR}/xctest.log"

phrasa_run_release_build "$ROOT" "$DERIVED" "${RUN_DIR}/release-build.log"

ARCHIVE_PATH="${ARTIFACTS}/Phrasa.xcarchive"
phrasa_run_archive "$ROOT" "$ARCHIVE_PATH" "$DERIVED" "${RUN_DIR}/archive.log"

if ! phrasa_inspect_archive "$ARCHIVE_PATH" "${RUN_DIR}/archive-inspect.log"; then
  phrasa_die "archive inspection failed"
fi

EXPORT_OPTIONS="${RUN_DIR}/ExportOptions.generated.plist"
phrasa_write_temp_export_options "$EXPORT_OPTIONS"
EXPORT_PATH="${ARTIFACTS}/export"
# Do not capture stdout: export logs (phrasa_info + xcodebuild|tee) must stay visible.
# IPA path is returned only via PHRASA_EXPORTED_IPA_PATH (filesystem discovery, not log parse).
phrasa_run_export "$ARCHIVE_PATH" "$EXPORT_PATH" "$EXPORT_OPTIONS" "${RUN_DIR}/export.log"
if [[ -z "${PHRASA_EXPORTED_IPA_PATH:-}" || ! -f "${PHRASA_EXPORTED_IPA_PATH}" ]]; then
  phrasa_die "export did not set a valid PHRASA_EXPORTED_IPA_PATH"
fi
IPA_PATH="${PHRASA_EXPORTED_IPA_PATH}"
phrasa_info "IPA=$IPA_PATH"

if ! phrasa_inspect_ipa "$IPA_PATH" "$RUN_DIR" "${RUN_DIR}/ipa-inspect.log"; then
  phrasa_die "IPA inspection failed"
fi

MANIFEST="${RUN_DIR}/proof-manifest.txt"
phrasa_write_proof_manifest "$MANIFEST" \
  "source_commit=${PHRASA_EXPECTED_COMMIT}" \
  "marketing_version=${PHRASA_MARKETING_VERSION}" \
  "build_number=${PHRASA_BUILD_NUMBER}" \
  "bundle_id=${PHRASA_BUNDLE_ID}" \
  "team_id=${PHRASA_TEAM_ID}" \
  "candidate_fingerprint=${PHRASA_COMPUTED_FINGERPRINT:-}" \
  "scheme=${PHRASA_SCHEME}" \
  "target=${PHRASA_TARGET}" \
  "configuration=${PHRASA_CONFIGURATION}" \
  "project=${PHRASA_PROJECT_REL}" \
  "run_dir=${RUN_DIR}"

phrasa_append_hash_line "$MANIFEST" "evidence" "$EVIDENCE_PATH"
phrasa_append_hash_line "$MANIFEST" "archive_info_plist" "${ARCHIVE_PATH}/Info.plist"
phrasa_write_dir_file_hashes "${RUN_DIR}/archive-file-hashes.txt" "$ARCHIVE_PATH" "archive_path"
phrasa_append_hash_line "$MANIFEST" "archive_file_hashes" "${RUN_DIR}/archive-file-hashes.txt"
phrasa_append_hash_line "$MANIFEST" "ipa" "$IPA_PATH"

# Test / build / inspection logs (no secrets).
phrasa_append_hash_line "$MANIFEST" "preflight_log" "$PREFLIGHT_LOG"
phrasa_append_hash_line "$MANIFEST" "package_tests_log" "${RUN_DIR}/package-tests.log"
phrasa_append_hash_line "$MANIFEST" "xctest_log" "${RUN_DIR}/xctest.log"
phrasa_append_hash_line "$MANIFEST" "release_build_log" "${RUN_DIR}/release-build.log"
phrasa_append_hash_line "$MANIFEST" "archive_log" "${RUN_DIR}/archive.log"
phrasa_append_hash_line "$MANIFEST" "archive_inspect_log" "${RUN_DIR}/archive-inspect.log"
phrasa_append_hash_line "$MANIFEST" "export_log" "${RUN_DIR}/export.log"
phrasa_append_hash_line "$MANIFEST" "ipa_inspect_log" "${RUN_DIR}/ipa-inspect.log"
phrasa_append_hash_line "$MANIFEST" "export_options" "$EXPORT_OPTIONS"

# Deterministic file-hash listing for the .xcresult bundle.
XCRESULT="${RESULTS}/Phrasa.xcresult"
phrasa_write_dir_file_hashes "${RUN_DIR}/xcresult-file-hashes.txt" "$XCRESULT" "xcresult_path"
phrasa_append_hash_line "$MANIFEST" "xcresult_file_hashes" "${RUN_DIR}/xcresult-file-hashes.txt"

if (( DO_VALIDATE )); then
  phrasa_run_validate "$IPA_PATH" "${RUN_DIR}/validate.log"
  phrasa_append_hash_line "$MANIFEST" "validate_log" "${RUN_DIR}/validate.log"
fi

if (( DO_UPLOAD )); then
  phrasa_run_upload "$IPA_PATH" "${RUN_DIR}/upload.log"
  phrasa_append_hash_line "$MANIFEST" "upload_log" "${RUN_DIR}/upload.log"
fi

phrasa_info "proof manifest: $MANIFEST"
phrasa_info "release path completed for build ${PHRASA_BUILD_NUMBER}"
exit 0
