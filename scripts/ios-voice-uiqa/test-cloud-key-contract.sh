#!/usr/bin/env bash
# Synthetic, device-free tests for the physical Voice QA cloud-key contract.
# No production credential is read or used.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="${SCRIPT_DIR}/run-voice-uiqa.sh"
TMP="$(mktemp -d "${TMPDIR:-/private/tmp}/phrasa-voice-key-test.XXXXXX")"
FAKE_BIN="${TMP}/bin"
PUBLISHABLE_KIND='publishable_voice_qa_fixture_9f3c2a1b'
PRIVILEGED_KIND='secret_voice_qa_fixture_do_not_use'
VALID_KEY="sb_${PUBLISHABLE_KIND}"
PRIVILEGED_KEY="sb_${PRIVILEGED_KIND}"
INVALID_KEY='not-a-valid-supabase-client-key'
PASS=0
FAIL=0

cleanup() {
  /bin/rm -rf -- "$TMP"
}
trap cleanup EXIT

mkdir -p "$FAKE_BIN"

cat >"${FAKE_BIN}/xcodegen" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'xcodegen_invoked=1\n' >>"${TEST_TRACE:?}"
if [[ -n "${PHRASA_SUPABASE_PUBLISHABLE_KEY-}" ]]; then
  printf 'xcodegen_key_env=present\n' >>"${TEST_TRACE}"
else
  printf 'xcodegen_key_env=absent\n' >>"${TEST_TRACE}"
fi
for name in \
  PHRASA_SYNC_DELETE_FIXTURE_TITLE \
  PHRASA_SYNC_CONFLICT_FIXTURE_TITLE \
  PHRASA_SYNC_CONFLICT_LOCAL_MARKER \
  PHRASA_SYNC_CONFLICT_CLOUD_MARKER; do
  if [[ -n "${!name-}" ]]; then
    printf 'xcodegen_fixture_env_%s=present\n' "$name" >>"${TEST_TRACE}"
  else
    printf 'xcodegen_fixture_env_%s=absent\n' "$name" >>"${TEST_TRACE}"
  fi
done
SH

cat >"${FAKE_BIN}/xcodebuild" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${TEST_TRACE:?}"
printf 'xcodebuild_invoked=1\n' >>"$TEST_TRACE"
if [[ -n "${PHRASA_SUPABASE_PUBLISHABLE_KEY-}" ]]; then
  printf 'xcodebuild_key_env=present\n' >>"$TEST_TRACE"
else
  printf 'xcodebuild_key_env=absent\n' >>"$TEST_TRACE"
fi
for name in \
  PHRASA_SYNC_DELETE_FIXTURE_TITLE \
  PHRASA_SYNC_CONFLICT_FIXTURE_TITLE \
  PHRASA_SYNC_CONFLICT_LOCAL_MARKER \
  PHRASA_SYNC_CONFLICT_CLOUD_MARKER; do
  if [[ -n "${!name-}" ]]; then
    printf 'xcodebuild_fixture_env_%s=present\n' "$name" >>"$TEST_TRACE"
  else
    printf 'xcodebuild_fixture_env_%s=absent\n' "$name" >>"$TEST_TRACE"
  fi
done

xcconfig=""
prior=""
for arg in "$@"; do
  if [[ "$prior" == "-xcconfig" ]]; then
    xcconfig="$arg"
  fi
  if [[ "$prior" == "-scheme" ]]; then
    printf 'scheme=%s\n' "$arg" >>"$TEST_TRACE"
  fi
  if [[ "$prior" == "-configuration" ]]; then
    printf 'configuration=%s\n' "$arg" >>"$TEST_TRACE"
  fi
  case "$arg" in
    -only-testing:*)
      printf 'selected_test=%s\n' "$arg" >>"$TEST_TRACE"
      ;;
    PHRASA_SYNC_*=*)
      printf 'fixture_build_setting=%s\n' "$arg" >>"$TEST_TRACE"
      ;;
  esac
  prior="$arg"
done

if [[ -n "$xcconfig" ]]; then
  printf 'xcconfig_arg=present\n' >>"$TEST_TRACE"
  printf 'xcconfig_path=%s\n' "$xcconfig" >>"$TEST_TRACE"
  [[ -f "$xcconfig" ]] || {
    printf 'xcconfig_file=missing\n' >>"$TEST_TRACE"
    exit 91
  }
  mode="$(stat -f '%Lp' "$xcconfig" 2>/dev/null || stat -c '%a' "$xcconfig")"
  printf 'xcconfig_mode=%s\n' "$mode" >>"$TEST_TRACE"
  if grep -Fq "PHRASA_SUPABASE_PUBLISHABLE_KEY = ${TEST_EXPECTED_KEY:?}" "$xcconfig"; then
    printf 'xcconfig_key=present\n' >>"$TEST_TRACE"
  else
    printf 'xcconfig_key=missing\n' >>"$TEST_TRACE"
    exit 92
  fi
  # Deliberately emulate an xcodebuild echo. The runner must redact this before
  # either terminal output or its persistent log sees the fixture value.
  printf 'synthetic-xcode-echo: %s\n' "$TEST_EXPECTED_KEY"
else
  printf 'xcconfig_arg=absent\n' >>"$TEST_TRACE"
fi

for arg in "$@"; do
  if [[ "$arg" == "-showdestinations" ]]; then
    printf '{ platform:iOS Simulator, id:FAKE-IPAD-DEST, OS:26.0, name:iPad Pro }\n'
    exit 0
  fi
done

printf 'synthetic xcodebuild completed\n'
SH

chmod 700 "${FAKE_BIN}/xcodegen" "${FAKE_BIN}/xcodebuild"

pass() {
  printf 'PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

assert_contains() {
  local name="$1" path="$2" expected="$3"
  if grep -Fq "$expected" "$path"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_not_contains() {
  local name="$1" path="$2" forbidden="$3"
  if grep -Fq "$forbidden" "$path"; then
    fail "$name"
  else
    pass "$name"
  fi
}

run_case() {
  local name="$1" mode="$2" key_state="$3" fixture_state="${4:-valid}"
  local case_dir="${TMP}/${name}"
  mkdir -p "$case_dir/logs" "$case_dir/derived"
  : >"${case_dir}/trace"
  local -a env_args
  env_args=(
    "PATH=${FAKE_BIN}:${PATH}"
    "TEST_TRACE=${case_dir}/trace"
    "TEST_EXPECTED_KEY=${VALID_KEY}"
    "PHRASA_VOICE_LOG_DIR=${case_dir}/logs"
    "PHRASA_VOICE_DERIVED_DATA=${case_dir}/derived"
  )
  if [[ "$fixture_state" == "valid" ]]; then
    case "$mode" in
      --sync-delete-device)
        env_args+=(
          "PHRASA_SYNC_DELETE_FIXTURE_TITLE=SYNC QA DELETE IPAD 20990101T000000Z"
        )
        ;;
      --sync-conflict-device)
        env_args+=(
          "PHRASA_SYNC_CONFLICT_FIXTURE_TITLE=SYNC QA CONFLICT 20990101T000000Z"
          "PHRASA_SYNC_CONFLICT_LOCAL_MARKER=LOCAL_MARKER_20990101"
          "PHRASA_SYNC_CONFLICT_CLOUD_MARKER=CLOUD_MARKER_20990101"
        )
        ;;
    esac
  fi
  case "$key_state" in
    missing)
      set +e
      env \
        -u PHRASA_SUPABASE_PUBLISHABLE_KEY \
        -u PHRASA_SYNC_DELETE_FIXTURE_TITLE \
        -u PHRASA_SYNC_CONFLICT_FIXTURE_TITLE \
        -u PHRASA_SYNC_CONFLICT_LOCAL_MARKER \
        -u PHRASA_SYNC_CONFLICT_CLOUD_MARKER \
        "${env_args[@]}" \
        "$RUNNER" "$mode" >"${case_dir}/output" 2>&1
      ;;
    valid)
      set +e
      env \
        -u PHRASA_SYNC_DELETE_FIXTURE_TITLE \
        -u PHRASA_SYNC_CONFLICT_FIXTURE_TITLE \
        -u PHRASA_SYNC_CONFLICT_LOCAL_MARKER \
        -u PHRASA_SYNC_CONFLICT_CLOUD_MARKER \
        "${env_args[@]}" PHRASA_SUPABASE_PUBLISHABLE_KEY="$VALID_KEY" \
        "$RUNNER" "$mode" >"${case_dir}/output" 2>&1
      ;;
    privileged)
      set +e
      env \
        -u PHRASA_SYNC_DELETE_FIXTURE_TITLE \
        -u PHRASA_SYNC_CONFLICT_FIXTURE_TITLE \
        -u PHRASA_SYNC_CONFLICT_LOCAL_MARKER \
        -u PHRASA_SYNC_CONFLICT_CLOUD_MARKER \
        "${env_args[@]}" PHRASA_SUPABASE_PUBLISHABLE_KEY="$PRIVILEGED_KEY" \
        "$RUNNER" "$mode" >"${case_dir}/output" 2>&1
      ;;
    invalid)
      set +e
      env \
        -u PHRASA_SYNC_DELETE_FIXTURE_TITLE \
        -u PHRASA_SYNC_CONFLICT_FIXTURE_TITLE \
        -u PHRASA_SYNC_CONFLICT_LOCAL_MARKER \
        -u PHRASA_SYNC_CONFLICT_CLOUD_MARKER \
        "${env_args[@]}" PHRASA_SUPABASE_PUBLISHABLE_KEY="$INVALID_KEY" \
        "$RUNNER" "$mode" >"${case_dir}/output" 2>&1
      ;;
    *)
      printf 'unknown key state: %s\n' "$key_state" >&2
      exit 2
      ;;
  esac
  CASE_RC=$?
  set -e
  CASE_DIR="$case_dir"
}

assert_rejected_before_build() {
  local name="$1" mode="$2" key_state="$3" raw_value="$4"
  run_case "$name" "$mode" "$key_state"
  if ((CASE_RC != 0)); then
    pass "$name fails closed"
  else
    fail "$name fails closed"
  fi
  assert_not_contains "$name does not invoke xcodebuild" "$CASE_DIR/trace" \
    'xcodebuild_invoked=1'
  assert_not_contains "$name does not print rejected value" "$CASE_DIR/output" \
    "$raw_value"
}

assert_rejected_before_build missing-device --device missing "$VALID_KEY"
assert_contains "missing key error names required variable" \
  "$CASE_DIR/output" 'PHRASA_SUPABASE_PUBLISHABLE_KEY is missing/empty'

assert_rejected_before_build privileged-release --release-device privileged \
  "$PRIVILEGED_KEY"
assert_contains "privileged key error names unsafe class" \
  "$CASE_DIR/output" 'looks privileged'

assert_rejected_before_build invalid-device --device invalid "$INVALID_KEY"
assert_contains "invalid key error names invalid class" \
  "$CASE_DIR/output" 'is not a publishable or legacy anon client key'

run_case missing-delete-fixture --sync-delete-device valid missing
if ((CASE_RC != 0)); then
  pass "--sync-delete-device rejects a missing fixture title"
else
  fail "--sync-delete-device rejects a missing fixture title"
fi
assert_not_contains "--sync-delete-device missing fixture stops before xcodebuild" \
  "$CASE_DIR/trace" 'xcodebuild_invoked=1'
assert_contains "--sync-delete-device explains the missing fixture" \
  "$CASE_DIR/output" 'PHRASA_SYNC_DELETE_FIXTURE_TITLE is required'

run_case missing-conflict-fixtures --sync-conflict-device valid missing
if ((CASE_RC != 0)); then
  pass "--sync-conflict-device rejects missing fixture inputs"
else
  fail "--sync-conflict-device rejects missing fixture inputs"
fi
assert_not_contains "--sync-conflict-device missing fixtures stop before xcodebuild" \
  "$CASE_DIR/trace" 'xcodebuild_invoked=1'
assert_contains "--sync-conflict-device explains the missing fixture" \
  "$CASE_DIR/output" 'PHRASA_SYNC_CONFLICT_FIXTURE_TITLE is required'

for mode in \
  --device \
  --release-device \
  --sync-device \
  --sync-delete-device \
  --sync-conflict-device; do
  name="valid-${mode#--}"
  run_case "$name" "$mode" valid
  if ((CASE_RC == 0)); then
    pass "$mode accepts a valid synthetic publishable key"
  else
    fail "$mode accepts a valid synthetic publishable key"
  fi
  assert_contains "$mode invokes xcodebuild" "$CASE_DIR/trace" \
    'xcodebuild_invoked=1'
  assert_contains "$mode scrubs key from xcodebuild environment" "$CASE_DIR/trace" \
    'xcodebuild_key_env=absent'
  assert_contains "$mode scrubs key from xcodegen environment" "$CASE_DIR/trace" \
    'xcodegen_key_env=absent'
  for fixture_name in \
    PHRASA_SYNC_DELETE_FIXTURE_TITLE \
    PHRASA_SYNC_CONFLICT_FIXTURE_TITLE \
    PHRASA_SYNC_CONFLICT_LOCAL_MARKER \
    PHRASA_SYNC_CONFLICT_CLOUD_MARKER; do
    assert_contains "$mode scrubs $fixture_name from xcodebuild environment" \
      "$CASE_DIR/trace" "xcodebuild_fixture_env_${fixture_name}=absent"
    assert_contains "$mode scrubs $fixture_name from xcodegen environment" \
      "$CASE_DIR/trace" "xcodegen_fixture_env_${fixture_name}=absent"
  done
  assert_contains "$mode supplies a private xcconfig" "$CASE_DIR/trace" \
    'xcconfig_arg=present'
  assert_contains "$mode xcconfig contains the expected fixture" "$CASE_DIR/trace" \
    'xcconfig_key=present'
  assert_contains "$mode xcconfig permissions are 600" "$CASE_DIR/trace" \
    'xcconfig_mode=600'
  assert_not_contains "$mode terminal output redacts the key" "$CASE_DIR/output" \
    "$VALID_KEY"
  assert_contains "$mode terminal output has a redaction marker" "$CASE_DIR/output" \
    '(redacted-supabase-publishable-key)'
  if find "$CASE_DIR/logs" -type f -name '*.log' -exec grep -Fl "$VALID_KEY" {} + \
    | grep -q .; then
    fail "$mode persistent log redacts the key"
  else
    pass "$mode persistent log redacts the key"
  fi
  xcconfig_path="$(sed -n 's/^xcconfig_path=//p' "$CASE_DIR/trace" | tail -1)"
  if [[ -n "$xcconfig_path" && ! -e "$xcconfig_path" ]]; then
    pass "$mode removes its temporary xcconfig"
  else
    fail "$mode removes its temporary xcconfig"
  fi
  if [[ "$mode" == "--sync-device" ]]; then
    assert_contains "--sync-device uses the Release scheme" "$CASE_DIR/trace" \
      'scheme=PhrasaVoiceReleaseUIQA'
    assert_contains "--sync-device uses Release configuration" "$CASE_DIR/trace" \
      'configuration=Release'
    assert_contains "--sync-device selects only the physical sync diagnostic" \
      "$CASE_DIR/trace" \
      'selected_test=-only-testing:PhrasaUITests/VoiceFollowPhysicalUITests/testPhysicalSyncRetryAndReport'
    assert_not_contains "--sync-device never starts the speech watcher" \
      "$CASE_DIR/output" 'watching '
  fi
  if [[ "$mode" == "--sync-delete-device" ]]; then
    assert_contains "--sync-delete-device uses the Release scheme" "$CASE_DIR/trace" \
      'scheme=PhrasaVoiceReleaseUIQA'
    assert_contains "--sync-delete-device uses Release configuration" \
      "$CASE_DIR/trace" 'configuration=Release'
    assert_contains "--sync-delete-device selects only the destructive sync diagnostic" \
      "$CASE_DIR/trace" \
      'selected_test=-only-testing:PhrasaUITests/VoiceFollowPhysicalUITests/testPhysicalSyncDeleteAndReport'
    assert_contains "--sync-delete-device passes the exact guarded fixture setting" \
      "$CASE_DIR/trace" \
      'fixture_build_setting=PHRASA_SYNC_DELETE_FIXTURE_TITLE=SYNC QA DELETE IPAD 20990101T000000Z'
    assert_not_contains "--sync-delete-device never starts the speech watcher" \
      "$CASE_DIR/output" 'watching '
  fi
  if [[ "$mode" == "--sync-conflict-device" ]]; then
    assert_contains "--sync-conflict-device uses the Release scheme" "$CASE_DIR/trace" \
      'scheme=PhrasaVoiceReleaseUIQA'
    assert_contains "--sync-conflict-device uses Release configuration" \
      "$CASE_DIR/trace" 'configuration=Release'
    assert_contains "--sync-conflict-device selects only the conflict diagnostic" \
      "$CASE_DIR/trace" \
      'selected_test=-only-testing:PhrasaUITests/VoiceFollowPhysicalUITests/testPhysicalSyncConflictAndReport'
    assert_contains "--sync-conflict-device passes the exact guarded title setting" \
      "$CASE_DIR/trace" \
      'fixture_build_setting=PHRASA_SYNC_CONFLICT_FIXTURE_TITLE=SYNC QA CONFLICT 20990101T000000Z'
    assert_contains "--sync-conflict-device passes the local marker setting" \
      "$CASE_DIR/trace" \
      'fixture_build_setting=PHRASA_SYNC_CONFLICT_LOCAL_MARKER=LOCAL_MARKER_20990101'
    assert_contains "--sync-conflict-device passes the cloud marker setting" \
      "$CASE_DIR/trace" \
      'fixture_build_setting=PHRASA_SYNC_CONFLICT_CLOUD_MARKER=CLOUD_MARKER_20990101'
    assert_not_contains "--sync-conflict-device never starts the speech watcher" \
      "$CASE_DIR/output" 'watching '
  fi
done

for mode in --smoke --build-only --release-build-only; do
  name="nonphysical-${mode#--}"
  run_case "$name" "$mode" valid
  if ((CASE_RC == 0)); then
    pass "$mode succeeds while a key is exported"
  else
    fail "$mode succeeds while a key is exported"
  fi
  assert_contains "$mode scrubs key from every xcodebuild call" "$CASE_DIR/trace" \
    'xcodebuild_key_env=absent'
  assert_contains "$mode does not pass an xcconfig" "$CASE_DIR/trace" \
    'xcconfig_arg=absent'
  assert_not_contains "$mode output does not contain the exported key" \
    "$CASE_DIR/output" "$VALID_KEY"
done

printf '\nResults: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
((FAIL == 0))
