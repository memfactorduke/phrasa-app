#!/usr/bin/env bash
# Fail-closed tests for production Supabase publishable-key injection hardening.
# Covers missing / privileged / invalid / valid keys and redaction of proof files.
# Never requires a real production secret — uses synthetic fixtures only.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
# shellcheck source=../lib/constants.sh
source "${SCRIPT_DIR}/../lib/constants.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/supabase_key.sh
source "${SCRIPT_DIR}/../lib/supabase_key.sh"

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

assert_eq() {
  local name="$1"
  local got="$2"
  local want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (got='$got' want='$want')" >&2
    FAIL=$((FAIL + 1))
  fi
}

# Synthetic fixtures — not real credentials.
VALID_PUBLISHABLE='sb_publishable_test_release_fixture_key_xyz'
# JWT payload {"role":"anon","ref":"test"} base64url
VALID_ANON_JWT='eyJhbGciOiJub25lIn0.eyJyb2xlIjoiYW5vbiIsInJlZiI6InRlc3QifQ.sig'
# JWT payload {"role":"service_role"} base64url
PRIV_SERVICE_JWT='eyJhbGciOiJub25lIn0.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.sig'
PRIV_SECRET='sb_secret_do_not_ship_this_value'
INVALID_RANDOM='not-a-supabase-client-key-at-all'
MARKER_KEY='sb_publishable_REDACTION_MARKER_9f3c2a1b'

# --- unit: privileged detection ---
assert_ok "sb_secret_ is privileged" \
  phrasa_supabase_key_is_privileged "$PRIV_SECRET"
assert_ok "service_role JWT is privileged" \
  phrasa_supabase_key_is_privileged "$PRIV_SERVICE_JWT"
assert_ok "literal service_role marker is privileged" \
  phrasa_supabase_key_is_privileged "prefix-service_role-suffix"
assert_fail "publishable key is not privileged" \
  phrasa_supabase_key_is_privileged "$VALID_PUBLISHABLE"
assert_fail "anon JWT is not privileged" \
  phrasa_supabase_key_is_privileged "$VALID_ANON_JWT"
assert_fail "empty is not privileged" \
  phrasa_supabase_key_is_privileged ""

# --- unit: publishable / legacy anon ---
assert_ok "sb_publishable_ accepted" \
  phrasa_supabase_key_is_publishable_or_anon "$VALID_PUBLISHABLE"
assert_ok "legacy anon JWT accepted" \
  phrasa_supabase_key_is_publishable_or_anon "$VALID_ANON_JWT"
assert_fail "sb_secret_ rejected as client key" \
  phrasa_supabase_key_is_publishable_or_anon "$PRIV_SECRET"
assert_fail "service_role JWT rejected as client key" \
  phrasa_supabase_key_is_publishable_or_anon "$PRIV_SERVICE_JWT"
assert_fail "random string rejected as client key" \
  phrasa_supabase_key_is_publishable_or_anon "$INVALID_RANDOM"
assert_fail "bare sb_publishable_ prefix too short" \
  phrasa_supabase_key_is_publishable_or_anon "sb_publishable_"
assert_fail "empty rejected as client key" \
  phrasa_supabase_key_is_publishable_or_anon ""

# --- status classifier via env ---
unset PHRASA_SUPABASE_PUBLISHABLE_KEY || true
assert_eq "status missing when unset" "$(phrasa_supabase_publishable_key_status)" "missing"

PHRASA_SUPABASE_PUBLISHABLE_KEY=""
assert_eq "status missing when empty" "$(phrasa_supabase_publishable_key_status)" "missing"

PHRASA_SUPABASE_PUBLISHABLE_KEY="   "
assert_eq "status missing when whitespace" "$(phrasa_supabase_publishable_key_status)" "missing"

PHRASA_SUPABASE_PUBLISHABLE_KEY="$PRIV_SECRET"
assert_eq "status privileged for sb_secret_" "$(phrasa_supabase_publishable_key_status)" "privileged"

PHRASA_SUPABASE_PUBLISHABLE_KEY="$PRIV_SERVICE_JWT"
assert_eq "status privileged for service_role JWT" "$(phrasa_supabase_publishable_key_status)" "privileged"

PHRASA_SUPABASE_PUBLISHABLE_KEY="$INVALID_RANDOM"
assert_eq "status invalid for random" "$(phrasa_supabase_publishable_key_status)" "invalid"

PHRASA_SUPABASE_PUBLISHABLE_KEY="$VALID_PUBLISHABLE"
assert_eq "status ok for publishable" "$(phrasa_supabase_publishable_key_status)" "ok"

PHRASA_SUPABASE_PUBLISHABLE_KEY="$VALID_ANON_JWT"
assert_eq "status ok for legacy anon JWT" "$(phrasa_supabase_publishable_key_status)" "ok"

# --- require: fail closed without printing key ---
require_and_capture() {
  local key="${1-}"
  if [[ -n "${key+x}" ]]; then
    export PHRASA_SUPABASE_PUBLISHABLE_KEY="$key"
  else
    unset PHRASA_SUPABASE_PUBLISHABLE_KEY || true
  fi
  set +e
  OUT="$(phrasa_require_shipping_supabase_publishable_key 2>&1)"
  RC=$?
  set -e
  printf 'RC=%s\n' "$RC"
  printf '%s\n' "$OUT"
}

# missing
unset PHRASA_SUPABASE_PUBLISHABLE_KEY || true
set +e
MISS_OUT="$(phrasa_require_shipping_supabase_publishable_key 2>&1)"
MISS_RC=$?
set -e
assert_eq "require fails when missing" "$MISS_RC" "1"
if printf '%s' "$MISS_OUT" | grep -Eqi 'missing|empty|PHRASA_SUPABASE_PUBLISHABLE_KEY'; then
  echo "PASS: require missing message names the env var"
  PASS=$((PASS + 1))
else
  echo "FAIL: require missing message unclear: $MISS_OUT" >&2
  FAIL=$((FAIL + 1))
fi

# privileged: must not echo the secret
export PHRASA_SUPABASE_PUBLISHABLE_KEY="$PRIV_SECRET"
set +e
PRIV_OUT="$(phrasa_require_shipping_supabase_publishable_key 2>&1)"
PRIV_RC=$?
set -e
assert_eq "require fails when privileged" "$PRIV_RC" "1"
if printf '%s' "$PRIV_OUT" | grep -Fq "$PRIV_SECRET"; then
  echo "FAIL: privileged key value was printed" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: privileged key value not printed"
  PASS=$((PASS + 1))
fi
if printf '%s' "$PRIV_OUT" | grep -Eqi 'privileged|service_role|sb_secret'; then
  echo "PASS: privileged failure names the class of problem"
  PASS=$((PASS + 1))
else
  echo "FAIL: privileged failure message weak: $PRIV_OUT" >&2
  FAIL=$((FAIL + 1))
fi

# invalid: must not echo
export PHRASA_SUPABASE_PUBLISHABLE_KEY="$INVALID_RANDOM"
set +e
INV_OUT="$(phrasa_require_shipping_supabase_publishable_key 2>&1)"
INV_RC=$?
set -e
assert_eq "require fails when invalid" "$INV_RC" "1"
if printf '%s' "$INV_OUT" | grep -Fq "$INVALID_RANDOM"; then
  echo "FAIL: invalid key value was printed" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: invalid key value not printed"
  PASS=$((PASS + 1))
fi

# valid publishable
export PHRASA_SUPABASE_PUBLISHABLE_KEY="$VALID_PUBLISHABLE"
set +e
OK_OUT="$(phrasa_require_shipping_supabase_publishable_key 2>&1)"
OK_RC=$?
set -e
assert_eq "require succeeds for publishable" "$OK_RC" "0"
if printf '%s' "$OK_OUT" | grep -Fq "$VALID_PUBLISHABLE"; then
  echo "FAIL: valid publishable key was printed" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: valid publishable key not printed on success"
  PASS=$((PASS + 1))
fi
if printf '%s' "$OK_OUT" | grep -Fq "len="; then
  echo "FAIL: valid publishable key length was printed" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: valid publishable key length not printed"
  PASS=$((PASS + 1))
fi

# valid legacy anon
export PHRASA_SUPABASE_PUBLISHABLE_KEY="$VALID_ANON_JWT"
set +e
OK2_OUT="$(phrasa_require_shipping_supabase_publishable_key 2>&1)"
OK2_RC=$?
set -e
assert_eq "require succeeds for legacy anon JWT" "$OK2_RC" "0"
if printf '%s' "$OK2_OUT" | grep -Fq "$VALID_ANON_JWT"; then
  echo "FAIL: valid anon JWT was printed" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: valid anon JWT not printed on success"
  PASS=$((PASS + 1))
fi

# --- kind labels ---
assert_eq "kind sb_publishable" "$(phrasa_supabase_key_kind_label "$VALID_PUBLISHABLE")" "sb_publishable"
assert_eq "kind legacy_anon_jwt" "$(phrasa_supabase_key_kind_label "$VALID_ANON_JWT")" "legacy_anon_jwt"
assert_eq "kind privileged secret" "$(phrasa_supabase_key_kind_label "$PRIV_SECRET")" "privileged"

# --- redaction of proof files ---
TMP="$(mktemp -d "${TMPDIR:-/tmp}/phrasa-key-test.XXXXXX")"
PROOF="${TMP}/showBuildSettings.txt"
export PHRASA_SUPABASE_PUBLISHABLE_KEY="$MARKER_KEY"
cat >"$PROOF" <<EOF
    MARKETING_VERSION = 1.0
    PHRASA_SUPABASE_PUBLISHABLE_KEY = ${MARKER_KEY}
    PHRASA_SUPABASE_URL = ${PHRASA_PRODUCTION_SUPABASE_URL}
    OTHER = keeps-${MARKER_KEY}-inline
EOF
phrasa_scrub_settings_dump_of_supabase_key "$PROOF"
if grep -Fq "$MARKER_KEY" "$PROOF"; then
  echo "FAIL: marker key still present after scrub" >&2
  cat "$PROOF" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: scrub removed publishable key from settings dump"
  PASS=$((PASS + 1))
fi
if grep -Eq 'PHRASA_SUPABASE_PUBLISHABLE_KEY.*=.*(redacted)' "$PROOF"; then
  echo "PASS: scrub left redacted placeholder on setting line"
  PASS=$((PASS + 1))
else
  echo "FAIL: scrub did not mark setting line redacted" >&2
  cat "$PROOF" >&2
  FAIL=$((FAIL + 1))
fi
if grep -Fq "$PHRASA_PRODUCTION_SUPABASE_URL" "$PROOF"; then
  echo "PASS: production URL retained after scrub (public)"
  PASS=$((PASS + 1))
else
  echo "FAIL: production URL incorrectly removed" >&2
  FAIL=$((FAIL + 1))
fi

# redact helper alone
LOGF="${TMP}/build.log"
echo "xcodebuild PHRASA_SUPABASE_PUBLISHABLE_KEY=${MARKER_KEY} started" >"$LOGF"
phrasa_redact_supabase_key_in_file "$LOGF"
if grep -Fq "$MARKER_KEY" "$LOGF"; then
  echo "FAIL: redact_supabase_key_in_file left marker" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: redact_supabase_key_in_file removed marker"
  PASS=$((PASS + 1))
fi

# Streaming redaction must remove every literal occurrence before output is
# eligible for a terminal or tee log.
STREAM_OUT="$(
  printf 'before=%s after=kept-%s\n' "$MARKER_KEY" "$MARKER_KEY" \
    | phrasa_redact_supabase_key_stream
)"
if printf '%s' "$STREAM_OUT" | grep -Fq "$MARKER_KEY"; then
  echo "FAIL: redact_supabase_key_stream printed marker" >&2
  FAIL=$((FAIL + 1))
elif printf '%s' "$STREAM_OUT" \
  | grep -Fq "(redacted-supabase-publishable-key)"; then
  echo "PASS: redact_supabase_key_stream removed marker before output"
  PASS=$((PASS + 1))
else
  echo "FAIL: redact_supabase_key_stream omitted redaction marker" >&2
  FAIL=$((FAIL + 1))
fi

# Exercise the last-resort sed redaction path with Python and Perl absent.
FALLBACK_BIN="${TMP}/fallback-bin"
mkdir -p "$FALLBACK_BIN"
ln -s "$(command -v sed)" "${FALLBACK_BIN}/sed"
ln -s "$(command -v mktemp)" "${FALLBACK_BIN}/mktemp"
ln -s "$(command -v mv)" "${FALLBACK_BIN}/mv"
ln -s "$(command -v rm)" "${FALLBACK_BIN}/rm"
FALLBACK_LOG="${TMP}/fallback.log"
printf 'value=%s\n' "$MARKER_KEY" >"$FALLBACK_LOG"
(
  PATH="$FALLBACK_BIN"
  export PATH
  phrasa_redact_supabase_key_in_file "$FALLBACK_LOG"
)
if grep -Fq "$MARKER_KEY" "$FALLBACK_LOG"; then
  echo "FAIL: sed fallback left marker" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: sed fallback removed marker"
  PASS=$((PASS + 1))
fi

# --- Info.plist cloud assertions (synthetic plists) ---
GOOD_PLIST="${TMP}/good.Info.plist"
BAD_EMPTY_KEY="${TMP}/empty-key.Info.plist"
BAD_URL="${TMP}/bad-url.Info.plist"
BAD_PRIV_KEY="${TMP}/priv-key.Info.plist"
UNRESOLVED="${TMP}/unresolved.Info.plist"

write_plist() {
  local path="$1" url="$2" key="$3"
  cat >"$path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PhrasaSupabaseURL</key>
	<string>${url}</string>
	<key>PhrasaSupabasePublishableKey</key>
	<string>${key}</string>
</dict>
</plist>
EOF
}

write_plist "$GOOD_PLIST" "$PHRASA_PRODUCTION_SUPABASE_URL" "$VALID_PUBLISHABLE"
write_plist "$BAD_EMPTY_KEY" "$PHRASA_PRODUCTION_SUPABASE_URL" ""
write_plist "$BAD_URL" "https://evil.example.com" "$VALID_PUBLISHABLE"
write_plist "$BAD_PRIV_KEY" "$PHRASA_PRODUCTION_SUPABASE_URL" "$PRIV_SECRET"
write_plist "$UNRESOLVED" '$(PHRASA_SUPABASE_URL)' '$(PHRASA_SUPABASE_PUBLISHABLE_KEY)'

set +e
GOOD_OUT="$(phrasa_assert_shipping_cloud_info_plist "$GOOD_PLIST" "test" 2>&1)"
GOOD_RC=$?
set -e
assert_eq "assert cloud ok for good plist" "$GOOD_RC" "0"
if printf '%s' "$GOOD_OUT" | grep -Fq "$VALID_PUBLISHABLE"; then
  echo "FAIL: assert printed publishable key for good plist" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: assert does not print key for good plist"
  PASS=$((PASS + 1))
fi
if printf '%s' "$GOOD_OUT" | grep -q 'CLOUD_OK'; then
  echo "PASS: good plist emits CLOUD_OK"
  PASS=$((PASS + 1))
else
  echo "FAIL: good plist missing CLOUD_OK: $GOOD_OUT" >&2
  FAIL=$((FAIL + 1))
fi
if printf '%s' "$GOOD_OUT" | grep -Fq "$PHRASA_PRODUCTION_SUPABASE_URL"; then
  echo "PASS: good plist reports production URL"
  PASS=$((PASS + 1))
else
  echo "FAIL: good plist did not report production URL" >&2
  FAIL=$((FAIL + 1))
fi

set +e
EMPTY_OUT="$(phrasa_assert_shipping_cloud_info_plist "$BAD_EMPTY_KEY" "test" 2>&1)"
EMPTY_RC=$?
set -e
assert_eq "assert fails empty key" "$EMPTY_RC" "1"
if printf '%s' "$EMPTY_OUT" | grep -q 'CLOUD_BLOCKER:'; then
  echo "PASS: empty key emits CLOUD_BLOCKER"
  PASS=$((PASS + 1))
else
  echo "FAIL: empty key no blocker: $EMPTY_OUT" >&2
  FAIL=$((FAIL + 1))
fi

set +e
URL_OUT="$(phrasa_assert_shipping_cloud_info_plist "$BAD_URL" "test" 2>&1)"
URL_RC=$?
set -e
assert_eq "assert fails wrong URL" "$URL_RC" "1"
if printf '%s' "$URL_OUT" | grep -Fq "evil.example.com"; then
  echo "PASS: wrong URL is reported (public)"
  PASS=$((PASS + 1))
else
  echo "FAIL: wrong URL not mentioned: $URL_OUT" >&2
  FAIL=$((FAIL + 1))
fi

set +e
PRIV_PLIST_OUT="$(phrasa_assert_shipping_cloud_info_plist "$BAD_PRIV_KEY" "test" 2>&1)"
PRIV_PLIST_RC=$?
set -e
assert_eq "assert fails privileged key in plist" "$PRIV_PLIST_RC" "1"
if printf '%s' "$PRIV_PLIST_OUT" | grep -Fq "$PRIV_SECRET"; then
  echo "FAIL: privileged plist key was printed" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: privileged plist key not printed"
  PASS=$((PASS + 1))
fi

set +e
UNRES_OUT="$(phrasa_assert_shipping_cloud_info_plist "$UNRESOLVED" "test" 2>&1)"
UNRES_RC=$?
set -e
assert_eq "assert fails unresolved placeholders" "$UNRES_RC" "1"

# --- build-setting helper ---
export PHRASA_SUPABASE_PUBLISHABLE_KEY="$VALID_PUBLISHABLE"
# shellcheck source=../lib/build.sh
source "${SCRIPT_DIR}/../lib/build.sh"
SETTING="$(phrasa_shipping_supabase_key_build_setting)"
assert_eq "build setting token form" "$SETTING" "PHRASA_SUPABASE_PUBLISHABLE_KEY=${VALID_PUBLISHABLE}"

unset PHRASA_SUPABASE_PUBLISHABLE_KEY || true
set +e
BS_OUT="$(phrasa_shipping_supabase_key_build_setting 2>&1)"
BS_RC=$?
set -e
assert_eq "build setting fails when key missing" "$BS_RC" "1"

# --- preflight env gate: privileged hard-blocks; missing only notes ---
# shellcheck source=../lib/preflight.sh
# Need blocker helpers; source preflight after arrays.
BLOCKERS=()
UPLOAD_BLOCKERS=()
NOTES=()
export PHRASA_SUPABASE_PUBLISHABLE_KEY="$PRIV_SECRET"
phrasa_preflight_supabase_publishable_key_env
if ((${#BLOCKERS[@]} > 0)); then
  echo "PASS: preflight hard-blocks privileged env key"
  PASS=$((PASS + 1))
else
  echo "FAIL: preflight did not block privileged env key" >&2
  FAIL=$((FAIL + 1))
fi
# Ensure blocker text does not include the secret
joined="${BLOCKERS[*]-}"
if printf '%s' "$joined" | grep -Fq "$PRIV_SECRET"; then
  echo "FAIL: preflight blocker printed privileged key" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: preflight blocker redacts privileged key value"
  PASS=$((PASS + 1))
fi

BLOCKERS=()
NOTES=()
unset PHRASA_SUPABASE_PUBLISHABLE_KEY || true
phrasa_preflight_supabase_publishable_key_env
if ((${#BLOCKERS[@]} == 0)); then
  echo "PASS: preflight allows missing key (release path requires it)"
  PASS=$((PASS + 1))
else
  echo "FAIL: preflight blocked missing key unexpectedly: ${BLOCKERS[*]}" >&2
  FAIL=$((FAIL + 1))
fi
if printf '%s\n' "${NOTES[@]+"${NOTES[@]}"}" | grep -Eq 'unset/empty|required for --release'; then
  echo "PASS: preflight notes missing key is release-required"
  PASS=$((PASS + 1))
else
  echo "FAIL: preflight missing-key note unclear: ${NOTES[*]-}" >&2
  FAIL=$((FAIL + 1))
fi

BLOCKERS=()
NOTES=()
export PHRASA_SUPABASE_PUBLISHABLE_KEY="$VALID_PUBLISHABLE"
phrasa_preflight_supabase_publishable_key_env
if ((${#BLOCKERS[@]} == 0)); then
  echo "PASS: preflight accepts valid publishable env key"
  PASS=$((PASS + 1))
else
  echo "FAIL: preflight blocked valid key: ${BLOCKERS[*]}" >&2
  FAIL=$((FAIL + 1))
fi
if printf '%s\n' "${NOTES[@]+"${NOTES[@]}"}" | grep -Fq "$VALID_PUBLISHABLE"; then
  echo "FAIL: preflight notes printed the key" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: preflight notes do not print valid key"
  PASS=$((PASS + 1))
fi

# --- constants pin matches product ---
assert_eq "production host constant" "$PHRASA_PRODUCTION_SUPABASE_HOST" "uqkjidvqyngrnyftdazp.supabase.co"
assert_eq "production URL constant" "$PHRASA_PRODUCTION_SUPABASE_URL" "https://uqkjidvqyngrnyftdazp.supabase.co"

# --- release-ios.sh sources supabase_key and documents the env ---
RELEASE_SH="${ROOT}/scripts/ios-release/release-ios.sh"
if grep -q 'supabase_key.sh' "$RELEASE_SH" \
  && grep -q 'phrasa_require_shipping_supabase_publishable_key' "$RELEASE_SH" \
  && grep -q 'PHRASA_SUPABASE_PUBLISHABLE_KEY' "$RELEASE_SH"; then
  echo "PASS: release-ios.sh wires require + supabase_key + env docs"
  PASS=$((PASS + 1))
else
  echo "FAIL: release-ios.sh missing key-injection wiring" >&2
  FAIL=$((FAIL + 1))
fi

# build.sh must inject only on release build + archive (not test)
if grep -q 'phrasa_shipping_supabase_key_build_setting' "${SCRIPT_DIR}/../lib/build.sh" \
  && grep -q 'key_setting=' "${SCRIPT_DIR}/../lib/build.sh" \
  && grep -q 'PHRASA_SUPABASE_PUBLISHABLE_KEY' "${SCRIPT_DIR}/../lib/build.sh"; then
  echo "PASS: build.sh references shipping key injection"
  PASS=$((PASS + 1))
else
  echo "FAIL: build.sh missing key injection" >&2
  FAIL=$((FAIL + 1))
fi
# Ensure xctest path does not inject the key setting helper call nearby
if grep -A20 'phrasa_run_ios_xctest' "${SCRIPT_DIR}/../lib/build.sh" \
  | grep -q 'phrasa_shipping_supabase_key_build_setting'; then
  echo "FAIL: XCTest path injects shipping publishable key" >&2
  FAIL=$((FAIL + 1))
else
  echo "PASS: XCTest path does not inject shipping publishable key"
  PASS=$((PASS + 1))
fi

# inspect.sh must assert cloud plist
if grep -q 'phrasa_assert_shipping_cloud_info_plist' "${SCRIPT_DIR}/../lib/inspect.sh"; then
  echo "PASS: inspect.sh asserts shipping cloud Info.plist"
  PASS=$((PASS + 1))
else
  echo "FAIL: inspect.sh missing cloud assertions" >&2
  FAIL=$((FAIL + 1))
fi

# preflight must scrub showBuildSettings and not inject key
if grep -q 'phrasa_scrub_settings_dump_of_supabase_key' "${SCRIPT_DIR}/../lib/preflight.sh" \
  && grep -q 'Do NOT pass PHRASA_SUPABASE_PUBLISHABLE_KEY' "${SCRIPT_DIR}/../lib/preflight.sh"; then
  echo "PASS: preflight documents no key injection + scrubs dump"
  PASS=$((PASS + 1))
else
  echo "FAIL: preflight missing scrub / no-injection note" >&2
  FAIL=$((FAIL + 1))
fi

# bash -n syntax
for f in \
  "${SCRIPT_DIR}/../lib/supabase_key.sh" \
  "${SCRIPT_DIR}/../lib/build.sh" \
  "${SCRIPT_DIR}/../lib/preflight.sh" \
  "${SCRIPT_DIR}/../lib/inspect.sh" \
  "${SCRIPT_DIR}/../lib/constants.sh" \
  "$RELEASE_SH" \
  "${BASH_SOURCE[0]}"; do
  if bash -n "$f"; then
    echo "PASS: bash -n $(basename "$f")"
    PASS=$((PASS + 1))
  else
    echo "FAIL: bash -n $(basename "$f")" >&2
    FAIL=$((FAIL + 1))
  fi
done

rm -rf "$TMP"

echo
echo "Results: PASS=$PASS FAIL=$FAIL"
if ((FAIL > 0)); then
  exit 1
fi
exit 0
