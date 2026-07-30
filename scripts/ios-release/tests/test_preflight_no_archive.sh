#!/usr/bin/env bash
# Prove --preflight does not archive/export/upload and exits nonzero when blockers exist.
# Also prove --release refuses tests/build/archive when hard gates fail.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
RELEASE_SH="${ROOT}/scripts/ios-release/release-ios.sh"

echo "Running --preflight (expect blockers on this machine/worktree)..."
set +e
OUT="$("${RELEASE_SH}" --preflight 2>&1)"
RC=$?
set -e

echo "$OUT" | tail -60

# Must not have started archive/export/upload/tests product path
if echo "$OUT" | grep -Eiq 'archiving to |exporting archive|upload-app|validate-app|xcodebuild archive|swift test --package-path|Release generic-device build'; then
  echo "FAIL: preflight appears to have archived/exported/validated/uploaded/built" >&2
  exit 1
fi

if ! echo "$OUT" | grep -Eq 'BLOCKER:|preflight result: FAIL|preflight result: PASS'; then
  echo "FAIL: preflight did not report a result" >&2
  exit 1
fi

LOG="$(ls -1dt "${ROOT}/ios-native/build/release-runs"/*/preflight.log 2>/dev/null | head -1 || true)"
if [[ -z "$LOG" || ! -f "$LOG" ]]; then
  echo "FAIL: preflight.log not written under ios-native/build/release-runs/" >&2
  exit 1
fi
echo "preflight_log=$LOG"
echo "preflight_exit=$RC"

RUN_DIR="$(dirname "$LOG")"
if find "$RUN_DIR" \( -name '*.xcarchive' -o -name '*.ipa' \) 2>/dev/null | grep -q .; then
  echo "FAIL: found archive/ipa under preflight run dir $RUN_DIR" >&2
  exit 1
fi
if [[ -d "${RUN_DIR}/DerivedData" || -d "${RUN_DIR}/artifacts" ]]; then
  echo "FAIL: preflight created DerivedData/artifacts under $RUN_DIR" >&2
  exit 1
fi

# showBuildSettings dump is allowed in proof dir
if [[ -f "${RUN_DIR}/phrasa-release-showBuildSettings.txt" ]]; then
  echo "NOTE: showBuildSettings dump present (allowed proof artifact)"
fi

if [[ "$RC" -eq 0 ]]; then
  echo "NOTE: preflight passed (unexpected on stock machine without evidence/signing); still no archive"
else
  echo "PASS: preflight exited nonzero with blockers and did not archive"
fi

echo "PASS: preflight produced isolated proof log only, no archive/ipa/DerivedData"

# --- --release must refuse before tests when evidence/signing missing ---
echo "Running --release (expect hard-gate refusal before tests/archive)..."
set +e
REL_OUT="$("${RELEASE_SH}" --release 2>&1)"
REL_RC=$?
set -e

echo "$REL_OUT" | tail -30

if [[ "$REL_RC" -eq 0 ]]; then
  echo "FAIL: --release succeeded unexpectedly without evidence/signing" >&2
  exit 1
fi

if echo "$REL_OUT" | grep -Eiq 'archiving to |xcodebuild archive|exporting archive|swift test --package-path|Release generic-device build'; then
  echo "FAIL: --release reached tests/build/archive despite hard blockers" >&2
  exit 1
fi

if ! echo "$REL_OUT" | grep -Eqi 'hard preflight blockers|refusing tests/build/archive'; then
  echo "FAIL: --release did not report hard-gate refusal" >&2
  exit 1
fi

echo "PASS: --release refused tests/build/archive when hard gates fail"

# No new archives/ipas from either invocation under latest two run dirs
if find "${ROOT}/ios-native/build/release-runs" \( -name '*.xcarchive' -o -name '*.ipa' \) 2>/dev/null | grep -q .; then
  echo "FAIL: found .xcarchive or .ipa under release-runs after preflight/release refusal" >&2
  find "${ROOT}/ios-native/build/release-runs" \( -name '*.xcarchive' -o -name '*.ipa' \) 2>/dev/null
  exit 1
fi

echo "PASS: no .xcarchive/.ipa created"
exit 0
