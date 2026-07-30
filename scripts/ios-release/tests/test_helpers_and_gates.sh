#!/usr/bin/env bash
# Unit tests: ensure_dir multi-arg, safe_rm_rf, release gates, skip-tests removed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=../lib/constants.sh
source "${SCRIPT_DIR}/../lib/constants.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/evidence.sh
source "${SCRIPT_DIR}/../lib/evidence.sh"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"
# shellcheck source=../lib/build.sh
source "${SCRIPT_DIR}/../lib/build.sh"

PASS=0
FAIL=0

assert_ok() {
  local name="$1"
  shift
  if "$@"; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local name="$1"
  shift
  if "$@"; then
    echo "FAIL: $name (expected failure)" >&2
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $name"
    PASS=$((PASS + 1))
  fi
}

# --- expected fingerprint for product pin ---
PBX_HASH="$(phrasa_sha256_file "${ROOT}/ios-native/PhrasaNative.xcodeproj/project.pbxproj")"
assert_ok "pbxproj sha256 matches constant" \
  test "$PBX_HASH" = "$PHRASA_EXPECTED_PBXPROJ_SHA256"
FP_LIVE="$(phrasa_candidate_fingerprint \
  "$PHRASA_EXPECTED_COMMIT" \
  "$PHRASA_MARKETING_VERSION" \
  "$PHRASA_BUILD_NUMBER" \
  "$PHRASA_BUNDLE_ID" \
  "$PHRASA_TEAM_ID" \
  "$PBX_HASH")"
assert_ok "candidate fingerprint matches constant" \
  test "$FP_LIVE" = "$PHRASA_EXPECTED_FINGERPRINT"
assert_ok "product pin includes physical Voice Follow recovery" \
  test "$PHRASA_EXPECTED_COMMIT" = "7fac6ea406341313a3f169fe2ae42b1e565d1da0"

# --- simulator selection is name-agnostic and binds to a concrete UDID ---
SIM_DEST="$(
  xcodebuild() {
    printf '%s\n' \
      '{ platform:iOS Simulator, id:dvtdevice-DVTiOSDeviceSimulatorPlaceholder-iphonesimulator:placeholder, name:Any iOS Simulator Device }' \
      '{ platform:iOS Simulator, arch:arm64, id:258960B0-098F-4670-A17B-22A9049FA04E, OS:26.5, name:Phrasa App Store iPhone }'
  }
  phrasa_pick_ios_simulator_destination ignored-project
)"
assert_ok "simulator picker accepts custom iPhone name and returns UDID" \
  test "$SIM_DEST" = "platform=iOS Simulator,id=258960B0-098F-4670-A17B-22A9049FA04E"

# --- phrasa_ensure_dir ---
TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/phrasa-ensure-XXXXXX")"
# mktemp already creates; use subdirs with enough depth
A="${TMP_BASE}/run/a"
B="${TMP_BASE}/run/b"
C="${TMP_BASE}/run/c"

assert_ok "ensure_dir multi-arg creates all" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_ensure_dir '$A' '$B' '$C'
  [[ -d '$A' && -d '$B' && -d '$C' ]]
"

assert_fail "ensure_dir empty path refused" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_ensure_dir ''
"

assert_fail "ensure_dir no args refused" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_ensure_dir
"

assert_fail "ensure_dir relative path refused" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_ensure_dir 'relative/path/here'
"

assert_fail "ensure_dir root refused" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_ensure_dir /
"

assert_fail "ensure_dir too shallow refused" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_ensure_dir /tmp/x
"

# --- phrasa_safe_rm_rf ---
RUN="${TMP_BASE}/safe-run"
NEST="${RUN}/artifacts/Phrasa.xcarchive"
mkdir -p "$NEST"
echo junk >"${NEST}/x"
assert_ok "safe_rm_rf removes nested target" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_safe_rm_rf '$NEST' '$RUN'
  [[ ! -e '$NEST' ]]
"

mkdir -p "${RUN}/artifacts/export"
assert_fail "safe_rm_rf refuses outside run_dir" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_safe_rm_rf '${TMP_BASE}' '$RUN'
"

assert_fail "safe_rm_rf refuses entire run_dir" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_safe_rm_rf '$RUN' '$RUN'
"

assert_fail "safe_rm_rf refuses slash" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_safe_rm_rf / '$RUN'
"

# Path traversal: raw ".." must be refused even when string prefix looks nested.
OUTSIDE_VICTIM="${TMP_BASE}/outside-victim"
mkdir -p "${RUN}/subdir"
echo "must-survive" >"$OUTSIDE_VICTIM"
assert_fail "safe_rm_rf refuses run/subdir/../../outside traversal" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_safe_rm_rf '${RUN}/subdir/../../outside-victim' '$RUN'
"
if [[ -f "$OUTSIDE_VICTIM" ]] && grep -q 'must-survive' "$OUTSIDE_VICTIM"; then
  echo "PASS: traversal target outside run_dir was not deleted"
  PASS=$((PASS + 1))
else
  echo "FAIL: traversal deleted external target (or content lost)" >&2
  FAIL=$((FAIL + 1))
fi

# Symlink inside run pointing outside: must not delete external target.
SYMLINK_OUTSIDE="${RUN}/artifacts/link-to-outside"
ln -s "$OUTSIDE_VICTIM" "$SYMLINK_OUTSIDE"
assert_fail "safe_rm_rf refuses symlink whose resolution escapes run_dir" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  # Directory-style escape: replace with dir symlink for resolution via cd -P
  rm -f '$SYMLINK_OUTSIDE'
  OUT_DIR='${TMP_BASE}/outside-dir-victim'
  mkdir -p \"\$OUT_DIR\"
  echo survive >\"\$OUT_DIR/marker\"
  ln -s \"\$OUT_DIR\" '$SYMLINK_OUTSIDE'
  phrasa_safe_rm_rf '$SYMLINK_OUTSIDE' '$RUN'
"
# Re-create dir symlink scenario and verify external marker survives after refuse
OUT_DIR="${TMP_BASE}/outside-dir-victim"
mkdir -p "$OUT_DIR"
echo survive >"${OUT_DIR}/marker"
rm -f "$SYMLINK_OUTSIDE"
ln -s "$OUT_DIR" "$SYMLINK_OUTSIDE"
set +e
bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_safe_rm_rf '$SYMLINK_OUTSIDE' '$RUN'
" >/dev/null 2>&1
SYM_RC=$?
set -e
if [[ $SYM_RC -ne 0 && -f "${OUT_DIR}/marker" ]] && grep -q survive "${OUT_DIR}/marker"; then
  echo "PASS: symlink-escape refuse left external target intact"
  PASS=$((PASS + 1))
else
  echo "FAIL: symlink-escape mishandled (rc=$SYM_RC external=$(ls -la "$OUT_DIR" 2>&1))" >&2
  FAIL=$((FAIL + 1))
fi

# Explicit raw ".." component rejection helper
assert_ok "path_has_dotdot detects .." bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_path_has_dotdot_component '/a/b/../c'
"
assert_ok "path_has_dotdot clean path is false" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  ! phrasa_path_has_dotdot_component '/a/b/c'
"

# --- run directory uniqueness ---
RUNS_PARENT="${TMP_BASE}/release-runs-parent"
# Need depth >= 3 for ensure_dir
assert_ok "create_run_dir returns unique dirs" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  d1=\$(phrasa_create_run_dir '$RUNS_PARENT')
  d2=\$(phrasa_create_run_dir '$RUNS_PARENT')
  [[ -d \"\$d1\" && -d \"\$d2\" && \"\$d1\" != \"\$d2\" ]]
"
assert_ok "create_run_dir stamp is readable UTC+pid form" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  d=\$(phrasa_create_run_dir '$RUNS_PARENT')
  base=\$(basename \"\$d\")
  # YYYYMMDDTHHMMSSZ-<pid>-XXXXXX
  [[ \"\$base\" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+-[A-Za-z0-9]+$ ]]
"
assert_ok "run_stamp includes pid" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  s=\$(phrasa_run_stamp)
  [[ \"\$s\" == *-\$\$ ]]
  [[ \"\$s\" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9]+$ ]]
"

# --- hard gates ---
BLOCKERS=("evidence missing")
UPLOAD_BLOCKERS=()
assert_fail "hard gates clear fails with blockers" phrasa_hard_gates_clear
BLOCKERS=()
assert_ok "hard gates clear when empty" phrasa_hard_gates_clear

# The release preflight must enforce the explicit release-ready validator, not
# stop after packet-mode completeness. Mock bash so this stays deterministic
# after the real operator eventually flips ready_to_archive to true.
BLOCKERS=()
NOTES=()
bash() {
  if [[ "$*" == *"--mode packet"* ]]; then
    echo "RESULT: PASS [packet mode]"
    return 0
  fi
  if [[ "$*" == *"--mode release-ready"* ]]; then
    echo "ERR RELEASE-READY: ready_to_archive must be true"
    echo "RESULT: FAIL (1 error(s)) [release-ready mode]"
    return 1
  fi
  command bash "$@"
}
phrasa_check_submission_packet "$ROOT"
unset -f bash
if printf '%s\n' "${BLOCKERS[@]}" | grep -q "submission packet --mode release-ready failed"; then
  echo "PASS: preflight enforces release-ready validator"
  PASS=$((PASS + 1))
else
  echo "FAIL: preflight enforces release-ready validator" >&2
  FAIL=$((FAIL + 1))
fi

# --- forbidden project evaluation ---
BLOCKERS=()
NOTES=()
phrasa_evaluate_untracked "ios-native/PhrasaNative 2.xcodeproj"
if ((${#BLOCKERS[@]} > 0)); then
  echo "PASS: forbidden project is hard blocker"
  PASS=$((PASS + 1))
else
  echo "FAIL: forbidden project is hard blocker" >&2
  FAIL=$((FAIL + 1))
fi

BLOCKERS=()
NOTES=()
phrasa_evaluate_untracked "ios-native/mystery-file.swift"
if ((${#BLOCKERS[@]} > 0)); then
  echo "PASS: unknown untracked is hard blocker"
  PASS=$((PASS + 1))
else
  echo "FAIL: unknown untracked is hard blocker" >&2
  FAIL=$((FAIL + 1))
fi

# --- --skip-tests must not be accepted (script dies) ---
RELEASE_SH="${ROOT}/scripts/ios-release/release-ios.sh"
set +e
SKIP_OUT="$("$RELEASE_SH" --skip-tests 2>&1)"
SKIP_RC=$?
set -e
if [[ $SKIP_RC -eq 0 ]]; then
  echo "FAIL: --skip-tests should not succeed" >&2
  FAIL=$((FAIL + 1))
elif ! printf '%s\n' "$SKIP_OUT" | grep -Eqi 'not supported|skip-tests'; then
  echo "FAIL: --skip-tests error message unexpected: $SKIP_OUT" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: --skip-tests rejected"
  PASS=$((PASS + 1))
fi

# Help must not advertise --skip-tests as a valid option for production use
HELP_OUT="$("$RELEASE_SH" --help 2>&1)"
if printf '%s\n' "$HELP_OUT" | grep -q -- '--skip-tests'; then
  # Mentioning it only to say it is unsupported is ok if "not supported" nearby
  if ! printf '%s\n' "$HELP_OUT" | grep -qi 'no --skip-tests\|not supported\|always run'; then
    echo "FAIL: help still documents --skip-tests as usable" >&2
    FAIL=$((FAIL + 1))
  else
    echo "PASS: help does not offer --skip-tests as escape hatch"
    PASS=$((PASS + 1))
  fi
else
  echo "PASS: help omits --skip-tests"
  PASS=$((PASS + 1))
fi

# --- privacy manifest source check ---
BLOCKERS=()
NOTES=()
PRIV="${ROOT}/ios-native/Phrasa/Resources/PrivacyInfo.xcprivacy"
assert_ok "source privacy manifest parses" phrasa_check_privacy_manifest "$PRIV" "source"
assert_ok "source privacy left no blockers" bash -c '(( ${#BLOCKERS[@]} == 0 ))'

# --- build_setting_get uniqueness ---
FAKE_SETTINGS="${TMP_BASE}/settings.txt"
cat >"$FAKE_SETTINGS" <<'EOF'
    MARKETING_VERSION = 1.0
    CURRENT_PROJECT_VERSION = 14
    PRODUCT_BUNDLE_IDENTIFIER = com.phrasa.app
EOF
assert_ok "build_setting_get unique" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  v=\$(phrasa_build_setting_get '$FAKE_SETTINGS' MARKETING_VERSION)
  [[ \"\$v\" == '1.0' ]]
"
cat >"$FAKE_SETTINGS" <<'EOF'
    MARKETING_VERSION = 1.0
    MARKETING_VERSION = 2.0
EOF
assert_fail "build_setting_get ambiguous fails" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_build_setting_get '$FAKE_SETTINGS' MARKETING_VERSION >/dev/null
"

# --- export IPA path isolation (stub xcodebuild; no real archive/export) ---
# shellcheck source=../lib/build.sh
# constants.sh already sourced above (readonly); do not re-source it here.
source "${SCRIPT_DIR}/../lib/build.sh"

EXPORT_TEST_ROOT="${TMP_BASE}/export-stub"
FAKE_BIN="${EXPORT_TEST_ROOT}/bin"
EXPORT_RUN="${EXPORT_TEST_ROOT}/run"
EXPORT_OUT="${EXPORT_RUN}/artifacts/export"
ARCHIVE_FAKE="${EXPORT_RUN}/artifacts/Phrasa.xcarchive"
OPTS_FAKE="${EXPORT_RUN}/ExportOptions.generated.plist"
EXPORT_LOG="${EXPORT_RUN}/export.log"
mkdir -p "$FAKE_BIN" "$EXPORT_RUN/artifacts" "$ARCHIVE_FAKE"
: >"$OPTS_FAKE"

cat >"${FAKE_BIN}/xcodebuild" <<'XCODE'
#!/usr/bin/env bash
# Noisy stub: pollutes stdout/stderr like a real export tee would.
set -euo pipefail
export_path=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-exportPath" ]]; then
    export_path="$a"
  fi
  prev="$a"
done
echo "INFO: exporting archive to ${export_path}"
echo "noise line 1 from xcodebuild"
echo "Export Succeeded"
printf 'multiline\nnoise\n'
if [[ -z "$export_path" ]]; then
  echo "stub xcodebuild: missing -exportPath" >&2
  exit 2
fi
mkdir -p "$export_path"
# Single IPA (success case controlled by STUB_IPA_COUNT)
count="${STUB_IPA_COUNT:-1}"
i=0
while [[ $i -lt $count ]]; do
  i=$((i + 1))
  # Minimal placeholder bytes — not a real IPA
  printf 'PK\x03\x04stub-ipa-%s' "$i" >"${export_path}/App${i}.ipa"
done
echo "more trailing export noise"
exit 0
XCODE
chmod +x "${FAKE_BIN}/xcodebuild"

assert_ok "export sets PHRASA_EXPORTED_IPA_PATH without log contamination" bash -c "
  set -euo pipefail
  source '${SCRIPT_DIR}/../lib/common.sh'
  source '${SCRIPT_DIR}/../lib/constants.sh'
  source '${SCRIPT_DIR}/../lib/build.sh'
  export PATH='${FAKE_BIN}:'\"\$PATH\"
  export PHRASA_RUN_DIR='${EXPORT_RUN}'
  export STUB_IPA_COUNT=1
  PHRASA_EXPORTED_IPA_PATH=''
  # Must NOT use command substitution for the function call — that was the bug
  # (and would also hide the global in a subshell). Redirect logs to a file instead.
  OUT_FILE='${EXPORT_TEST_ROOT}/export-stdout.txt'
  phrasa_run_export '${ARCHIVE_FAKE}' '${EXPORT_OUT}' '${OPTS_FAKE}' '${EXPORT_LOG}' >\"\$OUT_FILE\" 2>&1 || exit 1
  OUT=\$(cat \"\$OUT_FILE\")
  # Global must be exactly one clean path (filesystem discovery, not log parse)
  [[ -n \"\${PHRASA_EXPORTED_IPA_PATH}\" ]]
  [[ -f \"\${PHRASA_EXPORTED_IPA_PATH}\" ]]
  [[ \"\${PHRASA_EXPORTED_IPA_PATH}\" == *.ipa ]]
  case \"\${PHRASA_EXPORTED_IPA_PATH}\" in
    *\$'\\n'*|*INFO:*|*noise*|*Export*) exit 1 ;;
  esac
  # Stdout is intentionally noisy; the API contract is the global, not stdout.
  [[ \"\${PHRASA_EXPORTED_IPA_PATH}\" != \"\$OUT\" ]]
  grep -q 'noise line 1' \"\$OUT_FILE\"
  # Global path is a single line / no newline contamination
  [[ \"\$(printf '%s' \"\${PHRASA_EXPORTED_IPA_PATH}\" | wc -l | tr -d ' ')\" -eq 0 ]]
  # Old anti-pattern would contaminate: prove noisy capture is not a valid path
  [[ ! -f \"\$OUT\" ]]
"

assert_fail "export refuses zero IPAs" bash -c "
  set -euo pipefail
  source '${SCRIPT_DIR}/../lib/common.sh'
  source '${SCRIPT_DIR}/../lib/constants.sh'
  source '${SCRIPT_DIR}/../lib/build.sh'
  export PATH='${FAKE_BIN}:'\"\$PATH\"
  export PHRASA_RUN_DIR='${EXPORT_RUN}'
  export STUB_IPA_COUNT=0
  PHRASA_EXPORTED_IPA_PATH=''
  phrasa_run_export '${ARCHIVE_FAKE}' '${EXPORT_OUT}' '${OPTS_FAKE}' '${EXPORT_LOG}-zero' 2>/dev/null
"

assert_fail "export refuses multiple IPAs" bash -c "
  set -euo pipefail
  source '${SCRIPT_DIR}/../lib/common.sh'
  source '${SCRIPT_DIR}/../lib/constants.sh'
  source '${SCRIPT_DIR}/../lib/build.sh'
  export PATH='${FAKE_BIN}:'\"\$PATH\"
  export PHRASA_RUN_DIR='${EXPORT_RUN}'
  export STUB_IPA_COUNT=2
  PHRASA_EXPORTED_IPA_PATH=''
  phrasa_run_export '${ARCHIVE_FAKE}' '${EXPORT_OUT}' '${OPTS_FAKE}' '${EXPORT_LOG}-multi' 2>/dev/null
"

# Prove caller-style assignment from global is clean after noisy export
assert_ok "caller IPA_PATH from global is single clean path" bash -c "
  set -euo pipefail
  source '${SCRIPT_DIR}/../lib/common.sh'
  source '${SCRIPT_DIR}/../lib/constants.sh'
  source '${SCRIPT_DIR}/../lib/build.sh'
  export PATH='${FAKE_BIN}:'\"\$PATH\"
  export PHRASA_RUN_DIR='${EXPORT_RUN}'
  export STUB_IPA_COUNT=1
  PHRASA_EXPORTED_IPA_PATH=''
  phrasa_run_export '${ARCHIVE_FAKE}' '${EXPORT_OUT}' '${OPTS_FAKE}' '${EXPORT_LOG}-caller' >/dev/null
  IPA_PATH=\"\${PHRASA_EXPORTED_IPA_PATH}\"
  [[ -f \"\$IPA_PATH\" ]]
  lines=\$(printf '%s' \"\$IPA_PATH\" | wc -l | tr -d ' ')
  # printf without trailing newline → 0 lines from wc -l, or 1 if newline; reject >1
  [[ \"\$lines\" -le 1 ]]
  [[ \"\$IPA_PATH\" != *\$'\\n'* ]]
  [[ \"\$(basename \"\$IPA_PATH\")\" == *.ipa ]]
"

# --- dir file hashes helper ---
HASH_DIR="${TMP_BASE}/hash-tree"
mkdir -p "${HASH_DIR}/nested"
echo alpha >"${HASH_DIR}/a.txt"
echo beta >"${HASH_DIR}/nested/b.txt"
HASH_OUT="${TMP_BASE}/hashes.txt"
assert_ok "write_dir_file_hashes is deterministic" bash -c "
  source '${SCRIPT_DIR}/../lib/common.sh'
  phrasa_write_dir_file_hashes '$HASH_OUT' '$HASH_DIR' 'test_path'
  phrasa_write_dir_file_hashes '${HASH_OUT}.2' '$HASH_DIR' 'test_path'
  cmp -s '$HASH_OUT' '${HASH_OUT}.2'
  grep -q 'test_path=' '$HASH_OUT'
  grep -q 'a.txt' '$HASH_OUT'
  grep -q 'nested/b.txt' '$HASH_OUT'
"

rm -rf "$TMP_BASE"

echo "---"
echo "helper/gate tests: pass=$PASS fail=$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
