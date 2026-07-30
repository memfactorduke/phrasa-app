#!/usr/bin/env bash
# Physical-device Voice Follow UI QA orchestrator (NON-SHIPPING).
#
# - Uses authoritative ios-native/PhrasaNative.xcodeproj only
# - Debug instrumentation by default; separate shipping Release verification
# - Never archives or uploads
# - DerivedData under /private/tmp (avoids Documents Finder xattrs)
# - Does not erase device data
# - Watches for host-visible VOICE_QA_READY, then drives macOS `say` for 25s
#
# Usage:
#   ./scripts/ios-voice-uiqa/run-voice-uiqa.sh
#   ./scripts/ios-voice-uiqa/run-voice-uiqa.sh --release-device
#   ./scripts/ios-voice-uiqa/run-voice-uiqa.sh --sync-device
#   ./scripts/ios-voice-uiqa/run-voice-uiqa.sh --sync-delete-device
#   ./scripts/ios-voice-uiqa/run-voice-uiqa.sh --sync-conflict-device
#   ./scripts/ios-voice-uiqa/run-voice-uiqa.sh --smoke
#   ./scripts/ios-voice-uiqa/run-voice-uiqa.sh --build-only
#   ./scripts/ios-voice-uiqa/run-voice-uiqa.sh --release-build-only
#   PHRASA_VOICE_STIMULUS_FILE=/path/to/fetterman.txt ./scripts/ios-voice-uiqa/run-voice-uiqa.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Reuse the release lane's production project pin and exact publishable-key
# classifier. Do not maintain a weaker Voice-QA-only credential policy.
RELEASE_LIB="${ROOT}/scripts/ios-release/lib"
# shellcheck source=../ios-release/lib/constants.sh
source "${RELEASE_LIB}/constants.sh"
# shellcheck source=../ios-release/lib/common.sh
source "${RELEASE_LIB}/common.sh"
# shellcheck source=../ios-release/lib/supabase_key.sh
source "${RELEASE_LIB}/supabase_key.sh"

PROJECT_REL="${PHRASA_PROJECT_REL}"
PROJECT="${ROOT}/${PROJECT_REL}"
FORBIDDEN_PROJECT="${ROOT}/${PHRASA_FORBIDDEN_PROJECT_REL}"
SCHEME=""
CONFIG=""
DEVICE_UDID="${PHRASA_VOICE_DEVICE_UDID:-00008103-001145590A84A01E}"
DERIVED_DATA="${PHRASA_VOICE_DERIVED_DATA:-/private/tmp/phrasa-voice-uiqa-derived}"
LOG_DIR="${PHRASA_VOICE_LOG_DIR:-/private/tmp/phrasa-voice-uiqa-logs}"
SPEECH_WINDOW_SECONDS="${PHRASA_VOICE_SPEECH_WINDOW:-25}"
STIMULUS_FILE="${PHRASA_VOICE_STIMULUS_FILE:-}"
STIMULUS_TEXT="${PHRASA_VOICE_STIMULUS:-}"
SAY_VOICE="${PHRASA_VOICE_SAY_VOICE:-}"
SAY_RATE="${PHRASA_VOICE_SAY_RATE:-175}"
OUTPUT_DEVICE="${PHRASA_VOICE_OUTPUT_DEVICE:-}"
OUTPUT_VOLUME="${PHRASA_VOICE_OUTPUT_VOLUME:-}"
MODE="device"
PHYSICAL_CLOUD_MODE=0
CLOUD_XCCONFIG=""
SUPABASE_REDACTION_KEY=""
FIXTURE_BUILD_SETTINGS=()

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*" >&2; }

cleanup_cloud_material() {
  if [[ -n "$SUPABASE_REDACTION_KEY" && -n "${LOG:-}" && -f "${LOG}" ]]; then
    PHRASA_SUPABASE_PUBLISHABLE_KEY="$SUPABASE_REDACTION_KEY" \
      phrasa_redact_supabase_key_in_file "${LOG}"
  fi
  if [[ -n "$CLOUD_XCCONFIG" && -f "$CLOUD_XCCONFIG" ]]; then
    /bin/rm -f -- "$CLOUD_XCCONFIG"
  fi
  CLOUD_XCCONFIG=""
  SUPABASE_REDACTION_KEY=""
}

redact_physical_xcode_output() {
  PHRASA_SUPABASE_PUBLISHABLE_KEY="$SUPABASE_REDACTION_KEY" \
    phrasa_redact_supabase_key_stream
}

run_xcodebuild_without_cloud_env() {
  # The publishable key reaches xcodebuild only through the private physical
  # xcconfig. It must not leak through the inherited environment into simulator
  # or build-only modes. Disposable sync fixtures reach XCTest only through
  # explicit non-secret build-setting expansion in the Release QA scheme.
  env \
    -u PHRASA_SUPABASE_PUBLISHABLE_KEY \
    -u PHRASA_SYNC_DELETE_FIXTURE_TITLE \
    -u PHRASA_SYNC_CONFLICT_FIXTURE_TITLE \
    -u PHRASA_SYNC_CONFLICT_LOCAL_MARKER \
    -u PHRASA_SYNC_CONFLICT_CLOUD_MARKER \
    xcodebuild "$@"
}

require_safe_fixture_value() {
  local name="$1"
  local required_prefix="${2-}"
  local raw value
  local safe_re='^[A-Za-z0-9][A-Za-z0-9._: -]{0,199}$'

  raw="${!name-}"
  value="$(phrasa_trim "$raw")"
  [[ -n "$value" ]] \
    || die "${name} is required for ${MODE} (non-secret disposable QA fixture)"
  [[ "$value" =~ $safe_re ]] \
    || die "${name} must be 1-200 safe printable ASCII characters"
  if [[ -n "$required_prefix" && "$value" != "$required_prefix"* ]]; then
    die "${name} must start with '${required_prefix}' to protect non-fixture data"
  fi
  printf '%s' "$value"
}

prepare_sync_fixture_build_settings() {
  local title local_marker cloud_marker
  case "$MODE" in
    sync-delete-device)
      title="$(require_safe_fixture_value \
        PHRASA_SYNC_DELETE_FIXTURE_TITLE \
        'SYNC QA DELETE IPAD ')"
      FIXTURE_BUILD_SETTINGS=(
        "PHRASA_SYNC_DELETE_FIXTURE_TITLE=${title}"
      )
      ;;
    sync-conflict-device)
      title="$(require_safe_fixture_value \
        PHRASA_SYNC_CONFLICT_FIXTURE_TITLE \
        'SYNC QA CONFLICT ')"
      local_marker="$(require_safe_fixture_value \
        PHRASA_SYNC_CONFLICT_LOCAL_MARKER)"
      cloud_marker="$(require_safe_fixture_value \
        PHRASA_SYNC_CONFLICT_CLOUD_MARKER)"
      [[ "$local_marker" != "$cloud_marker" ]] \
        || die "conflict local and cloud markers must differ"
      FIXTURE_BUILD_SETTINGS=(
        "PHRASA_SYNC_CONFLICT_FIXTURE_TITLE=${title}"
        "PHRASA_SYNC_CONFLICT_LOCAL_MARKER=${local_marker}"
        "PHRASA_SYNC_CONFLICT_CLOUD_MARKER=${cloud_marker}"
      )
      ;;
    *)
      FIXTURE_BUILD_SETTINGS=()
      ;;
  esac
}

prepare_physical_cloud_xcconfig() {
  local key old_umask

  # Existing release policy rejects empty, privileged, service-role, and
  # malformed values without printing them.
  phrasa_require_shipping_supabase_publishable_key
  key="$(phrasa_trim "${PHRASA_SUPABASE_PUBLISHABLE_KEY-}")"

  # xcconfig values are not shell-escaped. Supabase publishable and legacy anon
  # keys use this client-safe alphabet; reject anything that could become an
  # xcconfig directive, substitution, comment, or newline.
  if [[ ! "$key" =~ ^[A-Za-z0-9._-]+$ ]]; then
    die "PHRASA_SUPABASE_PUBLISHABLE_KEY contains characters unsafe for physical QA injection (value not printed)"
  fi

  SUPABASE_REDACTION_KEY="$key"
  old_umask="$(umask)"
  umask 077
  CLOUD_XCCONFIG="$(mktemp "${TMPDIR:-/private/tmp}/phrasa-voice-cloud.XXXXXX")"
  umask "$old_umask"
  chmod 600 "$CLOUD_XCCONFIG"
  printf 'PHRASA_SUPABASE_PUBLISHABLE_KEY = %s\n' "$key" >"$CLOUD_XCCONFIG"

  # Do not let unrelated child processes inherit the key. The private xcconfig
  # remains the sole build input; the shell-only copy exists for live redaction.
  unset PHRASA_SUPABASE_PUBLISHABLE_KEY
  key=""
  info "physical cloud configuration ready (safe publishable/anon key; value not printed)"
}

usage() {
  cat <<'EOF'
run-voice-uiqa.sh — non-shipping physical Voice Follow XCUITest orchestrator

Options:
  --device          Full instrumented Debug physical test (default)
  --release-device  Shipping Release physical progress/status verification
  --sync-device     Shipping Release physical Supabase retry/status verification
  --sync-delete-device
                    Delete exact disposable iPad fixture, then sync tombstone
  --sync-conflict-device
                    Edit exact disposable fixture, sync, prove conflict copy
  --smoke           Simulator library-launch smoke only (no speech)
  --build-only      Debug build-for-testing, no test execution
  --release-build-only
                    Release build-for-testing, no test execution
  -h, --help        Show help

Environment:
  PHRASA_VOICE_DEVICE_UDID     default 00008103-001145590A84A01E
  PHRASA_SUPABASE_PUBLISHABLE_KEY
                               required only for physical device modes;
                               safe publishable or legacy anon client key only
  PHRASA_SYNC_DELETE_FIXTURE_TITLE
                               required by --sync-delete-device; exact title
                               must begin "SYNC QA DELETE IPAD "
  PHRASA_SYNC_CONFLICT_FIXTURE_TITLE
                               required by --sync-conflict-device; exact title
                               must begin "SYNC QA CONFLICT "
  PHRASA_SYNC_CONFLICT_LOCAL_MARKER
                               required non-secret local body marker
  PHRASA_SYNC_CONFLICT_CLOUD_MARKER
                               required distinct non-secret cloud body marker
  PHRASA_VOICE_CONFIGURATION   optional assertion only: must match the selected
                               mode (Debug or Release), or the runner fails early
  PHRASA_VOICE_DERIVED_DATA    default /private/tmp/phrasa-voice-uiqa-derived
  PHRASA_VOICE_LOG_DIR         default /private/tmp/phrasa-voice-uiqa-logs
  PHRASA_VOICE_SPEECH_WINDOW   seconds after VOICE_QA_READY (default 25)
  PHRASA_VOICE_STIMULUS_FILE   text file spoken by `say` (Fetterman script body)
  PHRASA_VOICE_STIMULUS        inline stimulus if no file
  PHRASA_VOICE_SAY_VOICE       optional `say -v` voice name
  PHRASA_VOICE_SAY_RATE        words per minute for say (default 175)
  PHRASA_VOICE_OUTPUT_DEVICE   optional macOS output device to select immediately
                               before `say` (for example MacBook Pro Speakers)
  PHRASA_VOICE_OUTPUT_VOLUME   optional temporary macOS output volume, 0...100

Timing (physical Voice modes):
  1) xcodebuild test starts; harness opens library → Fetterman → Voice → Play
  2) harness handles mic then speech system prompts
  3) harness prints VOICE_QA_READY and waits PHRASA_VOICE_SPEECH_WINDOW seconds
  4) this script detects the marker and immediately runs `say` for the stimulus
  5) harness asserts material progress, pause/resume, background/foreground recovery

Proof split:
  --device          Debug counters prove mic → recognition → alignment → recovery
  --release-device  Release UI proves fresh visible progress + healthy status
  --sync-device     Release UI retries durable sync and reports before/after state
  --sync-delete-device
                    Release UI deletes only a prefix-guarded disposable fixture
  --sync-conflict-device
                    Release UI proves cloud original + preserved local conflict

All physical modes inject the validated production Supabase client key through
a private temporary xcconfig so the installed QA app can perform real cloud sync.
Simulator and build-only modes never inject the key, even when it is exported.

Exact say command (within the 25s window after VOICE_QA_READY):
  say -r 175 -f "$PHRASA_VOICE_STIMULUS_FILE"
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) MODE="device"; shift ;;
    --release-device) MODE="release-device"; shift ;;
    --sync-device) MODE="sync-device"; shift ;;
    --sync-delete-device) MODE="sync-delete-device"; shift ;;
    --sync-conflict-device) MODE="sync-conflict-device"; shift ;;
    --smoke) MODE="smoke"; shift ;;
    --build-only) MODE="build-only"; shift ;;
    --release-build-only) MODE="release-build-only"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

case "$MODE" in
  device|smoke|build-only)
    SCHEME="PhrasaVoiceUIQA"
    CONFIG="Debug"
    ;;
  release-device|sync-device|sync-delete-device|sync-conflict-device|release-build-only)
    SCHEME="PhrasaVoiceReleaseUIQA"
    CONFIG="Release"
    ;;
  *)
    die "unknown mode: $MODE"
    ;;
esac

case "$MODE" in
  device|release-device|sync-device|sync-delete-device|sync-conflict-device)
    PHYSICAL_CLOUD_MODE=1
    ;;
  smoke|build-only|release-build-only) PHYSICAL_CLOUD_MODE=0 ;;
  *) die "unknown mode: $MODE" ;;
esac

if [[ -n "${PHRASA_VOICE_CONFIGURATION:-}" \
  && "${PHRASA_VOICE_CONFIGURATION}" != "$CONFIG" ]]
then
  die "mode ${MODE} requires ${CONFIG}; PHRASA_VOICE_CONFIGURATION=${PHRASA_VOICE_CONFIGURATION}"
fi

prepare_sync_fixture_build_settings

trap cleanup_cloud_material EXIT
trap 'exit 130' HUP INT TERM
if ((PHYSICAL_CLOUD_MODE)); then
  prepare_physical_cloud_xcconfig
else
  # An operator may keep the production key exported. Do not inherit it into a
  # simulator or build-only xcodebuild process.
  unset PHRASA_SUPABASE_PUBLISHABLE_KEY || true
fi

if [[ -e "$FORBIDDEN_PROJECT" ]]; then
  info "note: forbidden alternate project path exists; ignoring it (using $PROJECT_REL only)"
fi
[[ -d "$PROJECT" ]] || die "missing authoritative project: $PROJECT_REL"
case "$(basename "$PROJECT")" in
  *" 2"*) die "refusing project basename containing space-2" ;;
esac

command -v xcodebuild >/dev/null || die "xcodebuild not found"
mkdir -p "$DERIVED_DATA" "$LOG_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
LOG="${LOG_DIR}/voice-uiqa-${MODE}-${STAMP}.log"
RESULT_BUNDLE="${LOG_DIR}/voice-uiqa-${MODE}-${STAMP}.xcresult"

info "project=$PROJECT"
info "scheme=$SCHEME config=$CONFIG"
info "derivedData=$DERIVED_DATA"
info "log=$LOG"
info "mode=$MODE"

if command -v xcodegen >/dev/null 2>&1; then
  info "xcodegen generate (ios-native)"
  (cd "${ROOT}/ios-native" \
    && env \
      -u PHRASA_SUPABASE_PUBLISHABLE_KEY \
      -u PHRASA_SYNC_DELETE_FIXTURE_TITLE \
      -u PHRASA_SYNC_CONFLICT_FIXTURE_TITLE \
      -u PHRASA_SYNC_CONFLICT_LOCAL_MARKER \
      -u PHRASA_SYNC_CONFLICT_CLOUD_MARKER \
      xcodegen generate)
else
  info "xcodegen not found; using existing PhrasaNative.xcodeproj"
fi

[[ -f "${PROJECT}/xcshareddata/xcschemes/${SCHEME}.xcscheme" ]] \
  || die "missing scheme ${SCHEME}.xcscheme — run xcodegen in ios-native"

scheme_file="${PROJECT}/xcshareddata/xcschemes/${SCHEME}.xcscheme"
if command -v xmllint >/dev/null 2>&1; then
  scheme_test_config="$(xmllint --xpath 'string(/Scheme/TestAction/@buildConfiguration)' "$scheme_file")"
  [[ "$scheme_test_config" == "$CONFIG" ]] \
    || die "scheme ${SCHEME} TestAction is ${scheme_test_config:-unset}; expected ${CONFIG}"
fi

COMMON_ARGS=(
  -project "$PROJECT"
  -scheme "$SCHEME"
  -configuration "$CONFIG"
  -derivedDataPath "$DERIVED_DATA"
  -allowProvisioningUpdates
  CODE_SIGN_STYLE=Automatic
)

resolve_sim_destination() {
  local line id
  line="$(run_xcodebuild_without_cloud_env \
    -showdestinations -project "$PROJECT" -scheme "$SCHEME" 2>/dev/null \
    | grep -E 'platform:iOS Simulator' \
    | grep -i 'iPad' \
    | head -1 || true)"
  if [[ -n "$line" ]]; then
    id="$(printf '%s' "$line" | sed -E 's/.*id:([^,}]+).*/\1/')"
    if [[ -n "$id" ]]; then
      printf 'platform=iOS Simulator,id=%s' "$id"
      return 0
    fi
  fi
  printf '%s' 'platform=iOS Simulator,name=iPad'
}

default_stimulus() {
  cat <<'EOF'
Welcome to Phrasa. This is a sample script, so you can try the prompter right now.
Here is how it works. Start speaking, and the prompter listens to your voice and keeps the line you are reading centered on the screen.
You can pause, ad-lib, or stumble, and it follows along. If you would rather not use your voice, switch to speed mode for a steady, adjustable crawl.
EOF
}

load_stimulus() {
  if [[ -n "$STIMULUS_FILE" ]]; then
    [[ -f "$STIMULUS_FILE" ]] || die "stimulus file not found: $STIMULUS_FILE"
    cat "$STIMULUS_FILE"
    return
  fi
  if [[ -n "$STIMULUS_TEXT" ]]; then
    printf '%s\n' "$STIMULUS_TEXT"
    return
  fi
  default_stimulus
}

run_say_stimulus() {
  local tmp prior_volume
  tmp="$(mktemp /private/tmp/phrasa-voice-stimulus.XXXXXX)"
  load_stimulus >"$tmp"
  if [[ -n "$OUTPUT_DEVICE" ]]; then
    local switch_audio="/opt/homebrew/bin/SwitchAudioSource"
    if [[ ! -x "$switch_audio" ]]; then
      die "SwitchAudioSource is required for PHRASA_VOICE_OUTPUT_DEVICE"
    fi
    "$switch_audio" -s "$OUTPUT_DEVICE" >/dev/null
    info "macOS output=$("$switch_audio" -c)"
  fi
  if [[ -n "$OUTPUT_VOLUME" ]]; then
    if [[ ! "$OUTPUT_VOLUME" =~ ^[0-9]+$ ]] || (( OUTPUT_VOLUME > 100 )); then
      die "PHRASA_VOICE_OUTPUT_VOLUME must be an integer from 0 through 100"
    fi
    prior_volume="$(/usr/bin/osascript -e 'output volume of (get volume settings)')"
    /usr/bin/osascript -e "set volume output volume ${OUTPUT_VOLUME}" >/dev/null
    info "macOS output volume=${OUTPUT_VOLUME}% (will restore ${prior_volume}%)"
  fi
  info "VOICE_QA_READY observed — speaking stimulus for ~${SPEECH_WINDOW_SECONDS}s via macOS say"
  info "exact: say -r ${SAY_RATE} -f ${tmp}"
  local -a say_args
  say_args=(-r "$SAY_RATE" -f "$tmp")
  if [[ -n "$SAY_VOICE" ]]; then
    say_args=(-v "$SAY_VOICE" "${say_args[@]}")
  fi
  # Kick off speech immediately; harness holds the mic open for SPEECH_WINDOW_SECONDS.
  say "${say_args[@]}" || info "say exited non-zero (harness window continues)"
  if [[ -n "$prior_volume" ]]; then
    /usr/bin/osascript -e "set volume output volume ${prior_volume}" >/dev/null
  fi
  rm -f "$tmp"
}

watch_ready_and_speak() {
  local log_file="$1"
  local max_wait=360
  local start now
  start="$(date +%s)"
  info "watching ${log_file} for VOICE_QA_READY (max ${max_wait}s)"
  while true; do
    if [[ -f "$log_file" ]] && grep -Fq 'VOICE_QA_READY' "$log_file" 2>/dev/null; then
      run_say_stimulus
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= max_wait )); then
      info "timeout waiting for VOICE_QA_READY (say not started)"
      return 1
    fi
    sleep 0.4
  done
}

case "$MODE" in
  build-only|release-build-only)
    dest="$(resolve_sim_destination)"
    info "build-for-testing destination=$dest"
    run_xcodebuild_without_cloud_env build-for-testing \
      "${COMMON_ARGS[@]}" \
      -destination "$dest" \
      2>&1 | tee "$LOG"
    info "build-for-testing OK"
    exit 0
    ;;
  smoke)
    dest="$(resolve_sim_destination)"
    info "simulator smoke destination=$dest"
    set +e
    run_xcodebuild_without_cloud_env test \
      "${COMMON_ARGS[@]}" \
      -destination "$dest" \
      -only-testing:PhrasaUITests/VoiceFollowPhysicalUITests/testLibraryLaunchSmoke \
      -resultBundlePath "$RESULT_BUNDLE" \
      2>&1 | tee "$LOG"
    status=${PIPESTATUS[0]}
    set -e
    info "smoke exit=$status log=$LOG"
    exit "$status"
    ;;
  device|release-device|sync-device|sync-delete-device|sync-conflict-device)
    dest="platform=iOS,id=${DEVICE_UDID}"
    info "physical destination=$dest (data preserved; no erase)"

    : >"$LOG"
    watcher_pid=""
    if [[ "$MODE" == "device" || "$MODE" == "release-device" ]]; then
      info "manual fallback after VOICE_QA_READY (within ${SPEECH_WINDOW_SECONDS}s):"
      info "  say -r ${SAY_RATE} -f \"\${PHRASA_VOICE_STIMULUS_FILE}\""
      watch_ready_and_speak "$LOG" &
      watcher_pid=$!
    else
      info "sync diagnostic: Release build, production cloud, no speech stimulus"
    fi

    set +e
    case "$MODE" in
      device)
        selected_test="testVoiceFollowPhysicalStimulusProgressAndRecovery"
        ;;
      release-device)
        selected_test="testVoiceFollowShippingReleaseProgress"
        ;;
      sync-device)
        selected_test="testPhysicalSyncRetryAndReport"
        ;;
      sync-delete-device)
        selected_test="testPhysicalSyncDeleteAndReport"
        ;;
      sync-conflict-device)
        selected_test="testPhysicalSyncConflictAndReport"
        ;;
      *)
        die "unknown physical mode: $MODE"
        ;;
    esac

    run_xcodebuild_without_cloud_env test \
      "${COMMON_ARGS[@]}" \
      -destination "$dest" \
      -xcconfig "$CLOUD_XCCONFIG" \
      ${FIXTURE_BUILD_SETTINGS[@]+"${FIXTURE_BUILD_SETTINGS[@]}"} \
      "-only-testing:PhrasaUITests/VoiceFollowPhysicalUITests/${selected_test}" \
      -resultBundlePath "$RESULT_BUNDLE" \
      2>&1 | redact_physical_xcode_output | tee -a "$LOG"
    pipeline_status=("${PIPESTATUS[@]}")
    status="${pipeline_status[0]}"
    if [[ "${pipeline_status[1]}" -ne 0 || "${pipeline_status[2]}" -ne 0 ]]; then
      status=1
    fi
    set -e

    PHRASA_SUPABASE_PUBLISHABLE_KEY="$SUPABASE_REDACTION_KEY" \
      phrasa_redact_supabase_key_in_file "$LOG"

    if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
      kill "$watcher_pid" 2>/dev/null || true
      wait "$watcher_pid" 2>/dev/null || true
    fi

    info "device test exit=$status log=$LOG result=$RESULT_BUNDLE"
    exit "$status"
    ;;
  *)
    die "unknown mode: $MODE"
    ;;
esac
