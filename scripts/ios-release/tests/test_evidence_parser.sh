#!/usr/bin/env bash
# Automated tests for evidence parser (fail-closed).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=../lib/constants.sh
source "${SCRIPT_DIR}/../lib/constants.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/evidence.sh
source "${SCRIPT_DIR}/../lib/evidence.sh"

PASS=0
FAIL=0
FIXTURES="${SCRIPT_DIR}/fixtures"
mkdir -p "$FIXTURES"

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

assert_fail_msg() {
  local name="$1"
  local needle="$2"
  shift 2
  local out
  set +e
  out="$("$@" 2>&1)"
  local rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "FAIL: $name (expected failure)" >&2
    FAIL=$((FAIL + 1))
  elif ! printf '%s\n' "$out" | grep -Fq "$needle"; then
    echo "FAIL: $name (expected message containing: $needle; got: $out)" >&2
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $name"
    PASS=$((PASS + 1))
  fi
}

EXPECTED_COMMIT="$PHRASA_EXPECTED_COMMIT"
PBX="${ROOT}/ios-native/PhrasaNative.xcodeproj/project.pbxproj"
PBX_HASH="$(phrasa_sha256_file "$PBX")"
FP="$(phrasa_candidate_fingerprint \
  "$EXPECTED_COMMIT" \
  "$PHRASA_MARKETING_VERSION" \
  "$PHRASA_BUILD_NUMBER" \
  "$PHRASA_BUNDLE_ID" \
  "$PHRASA_TEAM_ID" \
  "$PBX_HASH")"

NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
ATTEST="$PHRASA_OPERATOR_ATTESTATION_REQUIRED"

write_good() {
  local path="$1"
  cat >"$path" <<EOF
# good evidence fixture
SCHEMA_VERSION=1
SOURCE_COMMIT=${EXPECTED_COMMIT}
MARKETING_VERSION=1.0
BUILD_NUMBER=14
BUNDLE_ID=com.phrasa.app
CANDIDATE_FINGERPRINT=${FP}
DEVICE_NAME=Test iPhone
DEVICE_IDENTIFIER=00008110-001A2B3C4D5E6F70
DEVICE_MODEL=iPhone16,1
DEVICE_IOS_VERSION=18.5
RECOGNITION_MODE=on_device
DEVICE_PASSCODE_REQUIRED=false
DEVICE_DISPLAY_STATE=on
ACTIVE_CALL_OR_VOIP=false
PHRASA_VISIBLY_FOREGROUNDED=true
TESTED_AT_UTC=${NOW}
SPEECH_STIMULUS=This is a full multi-sentence speech stimulus used on device for voice following acceptance of Phrasa build fourteen.
OPERATOR_NAME=Test Operator
OPERATOR_ATTESTATION=${ATTEST}
OUTCOME_PCM_NON_SILENT_AUDIO=pass
OUTCOME_RECOGNITION_CALLBACKS_WORDS=pass
OUTCOME_ALIGNMENT_OBSERVATIONS_ACCEPTED=pass
OUTCOME_TOKEN_PROGRESS_PERSISTENCE=pass
OUTCOME_RELAUNCH=pass
OUTCOME_PERMISSION_GRANT=pass
OUTCOME_PERMISSION_DENIAL=pass
OUTCOME_INTERRUPTION_BACKGROUND=pass
OUTCOME_REPEATED_START_STOP=pass
EOF
}

GOOD="${FIXTURES}/good.evidence.md"
write_good "$GOOD"
assert_ok "good evidence validates" \
  phrasa_evidence_check_file "$GOOD" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

assert_fail "missing file fails" \
  phrasa_evidence_check_file "${FIXTURES}/nope.md" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_TMPL="${FIXTURES}/bad-template.evidence.md"
write_good "$BAD_TMPL"
echo 'DEVICE_NAME=REPLACE_ME' >>"$BAD_TMPL"
assert_fail "template placeholder fails" \
  phrasa_evidence_check_file "$BAD_TMPL" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_COMMIT="${FIXTURES}/bad-commit.evidence.md"
write_good "$BAD_COMMIT"
sed -i '' "s/${EXPECTED_COMMIT}/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/" "$BAD_COMMIT"
assert_fail "wrong commit fails" \
  phrasa_evidence_check_file "$BAD_COMMIT" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_OUT="${FIXTURES}/bad-outcome.evidence.md"
write_good "$BAD_OUT"
sed -i '' 's/OUTCOME_RELAUNCH=pass/OUTCOME_RELAUNCH=fail/' "$BAD_OUT"
assert_fail "outcome fail fails closed" \
  phrasa_evidence_check_file "$BAD_OUT" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_TRUE="${FIXTURES}/bad-true.evidence.md"
write_good "$BAD_TRUE"
sed -i '' 's/OUTCOME_PERMISSION_GRANT=pass/OUTCOME_PERMISSION_GRANT=true/' "$BAD_TRUE"
assert_fail "outcome true not accepted" \
  phrasa_evidence_check_file "$BAD_TRUE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_FP="${FIXTURES}/bad-fp.evidence.md"
write_good "$BAD_FP"
sed -i '' "s/${FP}/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/" "$BAD_FP"
assert_fail "wrong fingerprint fails" \
  phrasa_evidence_check_file "$BAD_FP" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_STALE="${FIXTURES}/bad-stale.evidence.md"
write_good "$BAD_STALE"
sed -i '' 's/TESTED_AT_UTC=.*/TESTED_AT_UTC=2020-01-01T00:00:00Z/' "$BAD_STALE"
assert_fail "stale evidence fails" \
  phrasa_evidence_check_file "$BAD_STALE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_STIM="${FIXTURES}/bad-stimulus.evidence.md"
write_good "$BAD_STIM"
sed -i '' 's/SPEECH_STIMULUS=.*/SPEECH_STIMULUS=too short/' "$BAD_STIM"
assert_fail "short stimulus fails" \
  phrasa_evidence_check_file "$BAD_STIM" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

TMPL_NAME="${FIXTURES}/VOICE_ACCEPTANCE_TEMPLATE.md"
write_good "$TMPL_NAME"
assert_fail "template filename refused" \
  phrasa_evidence_check_file "$TMPL_NAME" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_BUILD="${FIXTURES}/bad-build.evidence.md"
write_good "$BAD_BUILD"
sed -i '' 's/BUILD_NUMBER=14/BUILD_NUMBER=12/' "$BAD_BUILD"
assert_fail "wrong build fails" \
  phrasa_evidence_check_file "$BAD_BUILD" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_ATT="${FIXTURES}/bad-attestation.evidence.md"
write_good "$BAD_ATT"
sed -i '' 's/OPERATOR_ATTESTATION=.*/OPERATOR_ATTESTATION=I pinky swear/' "$BAD_ATT"
assert_fail "wrong attestation fails" \
  phrasa_evidence_check_file "$BAD_ATT" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_MISS="${FIXTURES}/bad-missing.evidence.md"
write_good "$BAD_MISS"
sed -i '' '/DEVICE_MODEL=/d' "$BAD_MISS"
assert_fail "missing key fails" \
  phrasa_evidence_check_file "$BAD_MISS" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

# Duplicate recognized key: fail-closed (no last-wins)
BAD_DUP="${FIXTURES}/bad-duplicate.evidence.md"
write_good "$BAD_DUP"
echo 'OUTCOME_RELAUNCH=pass' >>"$BAD_DUP"
assert_fail_msg "duplicate key rejected" "duplicate" \
  phrasa_evidence_check_file "$BAD_DUP" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

# Unknown uppercase key that could look like an acceptance claim
BAD_UNK="${FIXTURES}/bad-unknown-key.evidence.md"
write_good "$BAD_UNK"
echo 'OUTCOME_OVERALL_ACCEPTANCE=pass' >>"$BAD_UNK"
assert_fail_msg "unknown key rejected" "unknown machine-readable key" \
  phrasa_evidence_check_file "$BAD_UNK" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

# Missing iOS version / recognition mode
BAD_IOS="${FIXTURES}/bad-missing-ios.evidence.md"
write_good "$BAD_IOS"
sed -i '' '/DEVICE_IOS_VERSION=/d' "$BAD_IOS"
assert_fail_msg "missing DEVICE_IOS_VERSION" "DEVICE_IOS_VERSION" \
  phrasa_evidence_check_file "$BAD_IOS" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_MODE="${FIXTURES}/bad-recognition-mode.evidence.md"
write_good "$BAD_MODE"
sed -i '' 's/RECOGNITION_MODE=on_device/RECOGNITION_MODE=simulator/' "$BAD_MODE"
assert_fail_msg "invalid RECOGNITION_MODE" "RECOGNITION_MODE" \
  phrasa_evidence_check_file "$BAD_MODE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_IOS_FMT="${FIXTURES}/bad-ios-format.evidence.md"
write_good "$BAD_IOS_FMT"
sed -i '' 's/DEVICE_IOS_VERSION=18.5/DEVICE_IOS_VERSION=latest/' "$BAD_IOS_FMT"
assert_fail_msg "placeholder-like iOS version" "DEVICE_IOS_VERSION" \
  phrasa_evidence_check_file "$BAD_IOS_FMT" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

# --- Physical-device preconditions: missing ---
for key in DEVICE_PASSCODE_REQUIRED DEVICE_DISPLAY_STATE ACTIVE_CALL_OR_VOIP PHRASA_VISIBLY_FOREGROUNDED; do
  BAD_PRE_MISS="${FIXTURES}/bad-missing-${key}.evidence.md"
  write_good "$BAD_PRE_MISS"
  sed -i '' "/^${key}=/d" "$BAD_PRE_MISS"
  assert_fail_msg "missing ${key}" "missing required field: ${key}" \
    phrasa_evidence_check_file "$BAD_PRE_MISS" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30
done

# --- DEVICE_PASSCODE_REQUIRED: non-exact / false cases ---
BAD_PASS_TRUE="${FIXTURES}/bad-passcode-true.evidence.md"
write_good "$BAD_PASS_TRUE"
sed -i '' 's/DEVICE_PASSCODE_REQUIRED=false/DEVICE_PASSCODE_REQUIRED=true/' "$BAD_PASS_TRUE"
assert_fail_msg "DEVICE_PASSCODE_REQUIRED=true rejected" "DEVICE_PASSCODE_REQUIRED must be exactly 'false'" \
  phrasa_evidence_check_file "$BAD_PASS_TRUE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_PASS_CASE="${FIXTURES}/bad-passcode-False.evidence.md"
write_good "$BAD_PASS_CASE"
sed -i '' 's/DEVICE_PASSCODE_REQUIRED=false/DEVICE_PASSCODE_REQUIRED=False/' "$BAD_PASS_CASE"
assert_fail_msg "DEVICE_PASSCODE_REQUIRED=False rejected" "DEVICE_PASSCODE_REQUIRED must be exactly 'false'" \
  phrasa_evidence_check_file "$BAD_PASS_CASE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_PASS_ZERO="${FIXTURES}/bad-passcode-zero.evidence.md"
write_good "$BAD_PASS_ZERO"
sed -i '' 's/DEVICE_PASSCODE_REQUIRED=false/DEVICE_PASSCODE_REQUIRED=0/' "$BAD_PASS_ZERO"
assert_fail_msg "DEVICE_PASSCODE_REQUIRED=0 rejected" "DEVICE_PASSCODE_REQUIRED must be exactly 'false'" \
  phrasa_evidence_check_file "$BAD_PASS_ZERO" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_PASS_NO="${FIXTURES}/bad-passcode-no.evidence.md"
write_good "$BAD_PASS_NO"
sed -i '' 's/DEVICE_PASSCODE_REQUIRED=false/DEVICE_PASSCODE_REQUIRED=no/' "$BAD_PASS_NO"
assert_fail_msg "DEVICE_PASSCODE_REQUIRED=no rejected" "DEVICE_PASSCODE_REQUIRED must be exactly 'false'" \
  phrasa_evidence_check_file "$BAD_PASS_NO" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

# --- DEVICE_DISPLAY_STATE: non-allowlisted ---
BAD_DISP_OFF="${FIXTURES}/bad-display-off.evidence.md"
write_good "$BAD_DISP_OFF"
sed -i '' 's/DEVICE_DISPLAY_STATE=on/DEVICE_DISPLAY_STATE=off/' "$BAD_DISP_OFF"
assert_fail_msg "DEVICE_DISPLAY_STATE=off rejected" "DEVICE_DISPLAY_STATE must be one of" \
  phrasa_evidence_check_file "$BAD_DISP_OFF" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_DISP_AWAKE="${FIXTURES}/bad-display-awake.evidence.md"
write_good "$BAD_DISP_AWAKE"
sed -i '' 's/DEVICE_DISPLAY_STATE=on/DEVICE_DISPLAY_STATE=awake/' "$BAD_DISP_AWAKE"
assert_fail_msg "DEVICE_DISPLAY_STATE=awake rejected" "DEVICE_DISPLAY_STATE must be one of" \
  phrasa_evidence_check_file "$BAD_DISP_AWAKE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_DISP_TRUE="${FIXTURES}/bad-display-true.evidence.md"
write_good "$BAD_DISP_TRUE"
sed -i '' 's/DEVICE_DISPLAY_STATE=on/DEVICE_DISPLAY_STATE=true/' "$BAD_DISP_TRUE"
assert_fail_msg "DEVICE_DISPLAY_STATE=true rejected" "DEVICE_DISPLAY_STATE must be one of" \
  phrasa_evidence_check_file "$BAD_DISP_TRUE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_DISP_ONCASE="${FIXTURES}/bad-display-On.evidence.md"
write_good "$BAD_DISP_ONCASE"
sed -i '' 's/DEVICE_DISPLAY_STATE=on/DEVICE_DISPLAY_STATE=On/' "$BAD_DISP_ONCASE"
assert_fail_msg "DEVICE_DISPLAY_STATE=On rejected" "DEVICE_DISPLAY_STATE must be one of" \
  phrasa_evidence_check_file "$BAD_DISP_ONCASE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

# --- ACTIVE_CALL_OR_VOIP: non-exact ---
BAD_CALL_TRUE="${FIXTURES}/bad-call-true.evidence.md"
write_good "$BAD_CALL_TRUE"
sed -i '' 's/ACTIVE_CALL_OR_VOIP=false/ACTIVE_CALL_OR_VOIP=true/' "$BAD_CALL_TRUE"
assert_fail_msg "ACTIVE_CALL_OR_VOIP=true rejected" "ACTIVE_CALL_OR_VOIP must be exactly 'false'" \
  phrasa_evidence_check_file "$BAD_CALL_TRUE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_CALL_YES="${FIXTURES}/bad-call-yes.evidence.md"
write_good "$BAD_CALL_YES"
sed -i '' 's/ACTIVE_CALL_OR_VOIP=false/ACTIVE_CALL_OR_VOIP=yes/' "$BAD_CALL_YES"
assert_fail_msg "ACTIVE_CALL_OR_VOIP=yes rejected" "ACTIVE_CALL_OR_VOIP must be exactly 'false'" \
  phrasa_evidence_check_file "$BAD_CALL_YES" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_CALL_FALSECASE="${FIXTURES}/bad-call-False.evidence.md"
write_good "$BAD_CALL_FALSECASE"
sed -i '' 's/ACTIVE_CALL_OR_VOIP=false/ACTIVE_CALL_OR_VOIP=False/' "$BAD_CALL_FALSECASE"
assert_fail_msg "ACTIVE_CALL_OR_VOIP=False rejected" "ACTIVE_CALL_OR_VOIP must be exactly 'false'" \
  phrasa_evidence_check_file "$BAD_CALL_FALSECASE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

# --- PHRASA_VISIBLY_FOREGROUNDED: non-exact ---
BAD_FG_FALSE="${FIXTURES}/bad-foreground-false.evidence.md"
write_good "$BAD_FG_FALSE"
sed -i '' 's/PHRASA_VISIBLY_FOREGROUNDED=true/PHRASA_VISIBLY_FOREGROUNDED=false/' "$BAD_FG_FALSE"
assert_fail_msg "PHRASA_VISIBLY_FOREGROUNDED=false rejected" "PHRASA_VISIBLY_FOREGROUNDED must be exactly 'true'" \
  phrasa_evidence_check_file "$BAD_FG_FALSE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_FG_YES="${FIXTURES}/bad-foreground-yes.evidence.md"
write_good "$BAD_FG_YES"
sed -i '' 's/PHRASA_VISIBLY_FOREGROUNDED=true/PHRASA_VISIBLY_FOREGROUNDED=yes/' "$BAD_FG_YES"
assert_fail_msg "PHRASA_VISIBLY_FOREGROUNDED=yes rejected" "PHRASA_VISIBLY_FOREGROUNDED must be exactly 'true'" \
  phrasa_evidence_check_file "$BAD_FG_YES" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_FG_TRUECASE="${FIXTURES}/bad-foreground-True.evidence.md"
write_good "$BAD_FG_TRUECASE"
sed -i '' 's/PHRASA_VISIBLY_FOREGROUNDED=true/PHRASA_VISIBLY_FOREGROUNDED=True/' "$BAD_FG_TRUECASE"
assert_fail_msg "PHRASA_VISIBLY_FOREGROUNDED=True rejected" "PHRASA_VISIBLY_FOREGROUNDED must be exactly 'true'" \
  phrasa_evidence_check_file "$BAD_FG_TRUECASE" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

BAD_FG_RESIDENT="${FIXTURES}/bad-foreground-resident.evidence.md"
write_good "$BAD_FG_RESIDENT"
sed -i '' 's/PHRASA_VISIBLY_FOREGROUNDED=true/PHRASA_VISIBLY_FOREGROUNDED=process_resident/' "$BAD_FG_RESIDENT"
assert_fail_msg "PHRASA_VISIBLY_FOREGROUNDED=process_resident rejected" "PHRASA_VISIBLY_FOREGROUNDED must be exactly 'true'" \
  phrasa_evidence_check_file "$BAD_FG_RESIDENT" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

# --- Duplicate precondition key ---
BAD_PRE_DUP="${FIXTURES}/bad-duplicate-precondition.evidence.md"
write_good "$BAD_PRE_DUP"
echo 'DEVICE_PASSCODE_REQUIRED=false' >>"$BAD_PRE_DUP"
assert_fail_msg "duplicate DEVICE_PASSCODE_REQUIRED rejected" "duplicate" \
  phrasa_evidence_check_file "$BAD_PRE_DUP" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

# --- Template-like value in a precondition key (caught by REPLACE_ME scanner) ---
BAD_PRE_TMPL="${FIXTURES}/bad-precondition-template.evidence.md"
write_good "$BAD_PRE_TMPL"
# Avoid REPLACE_ME in the sed replacement string itself being scanned as template
# after write; inject a known template marker the parser rejects.
sed -i '' 's/DEVICE_DISPLAY_STATE=on/DEVICE_DISPLAY_STATE=REPLACE_ME_on/' "$BAD_PRE_TMPL"
assert_fail_msg "template value in DEVICE_DISPLAY_STATE rejected" "template placeholders" \
  phrasa_evidence_check_file "$BAD_PRE_TMPL" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

# --- Stale attestation without process-residency clause ---
BAD_ATT_OLD="${FIXTURES}/bad-attestation-old.evidence.md"
write_good "$BAD_ATT_OLD"
sed -i '' 's/OPERATOR_ATTESTATION=.*/OPERATOR_ATTESTATION=I attest this evidence records a real physical-device voice acceptance for the stated candidate and is not fabricated./' "$BAD_ATT_OLD"
assert_fail_msg "old attestation without residency clause rejected" "OPERATOR_ATTESTATION must match" \
  phrasa_evidence_check_file "$BAD_ATT_OLD" "$EXPECTED_COMMIT" "1.0" "14" "com.phrasa.app" "$FP" 30

echo "---"
echo "evidence parser tests: pass=$PASS fail=$FAIL"
if (( FAIL > 0 )); then
  exit 1
fi
exit 0
