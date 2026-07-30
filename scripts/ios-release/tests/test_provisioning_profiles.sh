#!/usr/bin/env bash
# Regression tests for provisioning profile audit (synthetic fixtures only).
# Never reads or depends on real keychain/profile contents.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
FIX="${SCRIPT_DIR}/fixtures/provisioning"
mkdir -p "$FIX"

# shellcheck source=../lib/constants.sh
source "${SCRIPT_DIR}/../lib/constants.sh"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/preflight.sh
source "${SCRIPT_DIR}/../lib/preflight.sh"

PASS=0
FAIL=0

# Synthetic decoded plists only (gitignored under fixtures/; never real profiles).
write_prof() {
  local out="$1" name="$2" team="$3" appid="$4" exp="$5" gta="$6"
  local devices_xml="${7:-}" all_devices="${8:-}"
  {
    echo '<?xml version="1.0" encoding="UTF-8"?>'
    echo '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'
    echo '<plist version="1.0"><dict>'
    echo "  <key>Name</key><string>${name}</string>"
    echo '  <key>TeamIdentifier</key><array>'
    echo "    <string>${team}</string>"
    echo '  </array>'
    echo '  <key>Entitlements</key><dict>'
    echo "    <key>application-identifier</key><string>${appid}</string>"
    echo "    <key>get-task-allow</key><${gta}/>"
    echo '  </dict>'
    echo "  <key>ExpirationDate</key><date>${exp}</date>"
    if [[ -n "$devices_xml" ]]; then
      echo '  <key>ProvisionedDevices</key>'
      echo "$devices_xml"
    fi
    if [[ -n "$all_devices" ]]; then
      echo "  <key>ProvisionsAllDevices</key><${all_devices}/>"
    fi
    echo '  <key>UUID</key><string>00000000-0000-4000-8000-000000000001</string>'
    echo '</dict></plist>'
  } >"$out"
  plutil -lint "$out" >/dev/null
}

write_prof "${FIX}/valid-appstore.plist" \
  "iOS Team Store Provisioning Profile: com.phrasa.app" \
  "Q42MT7JA7Q" "Q42MT7JA7Q.com.phrasa.app" \
  "2027-07-17T23:11:26Z" "false"
write_prof "${FIX}/wrong-team.plist" \
  "Store Profile Wrong Team" \
  "AAAAAAAAAA" "AAAAAAAAAA.com.phrasa.app" \
  "2027-07-17T23:11:26Z" "false"
write_prof "${FIX}/wrong-appid.plist" \
  "Store Profile Other App" \
  "Q42MT7JA7Q" "Q42MT7JA7Q.com.other.app" \
  "2027-07-17T23:11:26Z" "false"
write_prof "${FIX}/wildcard-appid.plist" \
  "iOS Team Store Provisioning Profile: *" \
  "Q42MT7JA7Q" "Q42MT7JA7Q.*" \
  "2027-07-17T23:11:26Z" "false"
write_prof "${FIX}/expired-appstore.plist" \
  "iOS Team Store Provisioning Profile: com.phrasa.app" \
  "Q42MT7JA7Q" "Q42MT7JA7Q.com.phrasa.app" \
  "2020-01-01T00:00:00Z" "false"
write_prof "${FIX}/development.plist" \
  "iOS Team Provisioning Profile: com.phrasa.app" \
  "Q42MT7JA7Q" "Q42MT7JA7Q.com.phrasa.app" \
  "2027-07-17T23:11:26Z" "true" \
  '<array><string>00008030-001A1234567890AB</string></array>'
write_prof "${FIX}/adhoc.plist" \
  "Ad Hoc Profile: com.phrasa.app" \
  "Q42MT7JA7Q" "Q42MT7JA7Q.com.phrasa.app" \
  "2027-07-17T23:11:26Z" "false" \
  '<array><string>00008030-001A1234567890AB</string></array>'
write_prof "${FIX}/enterprise.plist" \
  "Enterprise Profile: com.phrasa.app" \
  "Q42MT7JA7Q" "Q42MT7JA7Q.com.phrasa.app" \
  "2027-07-17T23:11:26Z" "false" "" "true"
echo 'this is not a plist' >"${FIX}/malformed.plist"
: >"${FIX}/empty.plist"

assert_eq() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $name (got='$got' want='$want')" >&2
    FAIL=$((FAIL + 1))
  fi
}

assert_true() {
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

assert_false() {
  local name="$1"
  shift
  if "$@"; then
    echo "FAIL: $name (expected false)" >&2
    FAIL=$((FAIL + 1))
  else
    echo "PASS: $name"
    PASS=$((PASS + 1))
  fi
}

# Join NOTES/BLOCKERS for assertions (arrays not visible in bash -c subshells).
notes_text() { printf '%s\n' "${NOTES[@]+"${NOTES[@]}"}"; }
blockers_text() { printf '%s\n' "${BLOCKERS[@]+"${BLOCKERS[@]}"}"; }
notes_has() { notes_text | grep -Eq "$1"; }
blockers_has() { blockers_text | grep -Eqi "$1"; }

# --- evaluate decoded fixtures ---
eval_fixture() {
  local path="$1"
  phrasa_evaluate_decoded_provisioning_profile "$path"
}

eval_fixture "${FIX}/valid-appstore.plist"
assert_eq "valid appstore match=1" "$PHRASA_PROF_MATCH" "1"
assert_eq "valid appstore kind" "$PHRASA_PROF_KIND" "appstore"
assert_eq "valid appstore team" "$PHRASA_PROF_TEAM" "Q42MT7JA7Q"
assert_eq "valid appstore app_id" "$PHRASA_PROF_APP_ID" "Q42MT7JA7Q.com.phrasa.app"
assert_eq "valid appstore reason" "$PHRASA_PROF_REASON" "exact_appstore_match"
assert_eq "valid appstore name" "$PHRASA_PROF_NAME" "iOS Team Store Provisioning Profile: com.phrasa.app"

eval_fixture "${FIX}/wrong-team.plist"
assert_eq "wrong team match=0" "$PHRASA_PROF_MATCH" "0"
assert_eq "wrong team reason" "$PHRASA_PROF_REASON" "team_mismatch"

eval_fixture "${FIX}/wrong-appid.plist"
assert_eq "wrong app id match=0" "$PHRASA_PROF_MATCH" "0"
assert_eq "wrong app id reason" "$PHRASA_PROF_REASON" "app_id_mismatch"

eval_fixture "${FIX}/wildcard-appid.plist"
assert_eq "wildcard app id match=0" "$PHRASA_PROF_MATCH" "0"
assert_eq "wildcard app id reason" "$PHRASA_PROF_REASON" "app_id_mismatch"

eval_fixture "${FIX}/expired-appstore.plist"
assert_eq "expired match=0" "$PHRASA_PROF_MATCH" "0"
assert_eq "expired kind still appstore" "$PHRASA_PROF_KIND" "appstore"
assert_eq "expired reason" "$PHRASA_PROF_REASON" "expired"

eval_fixture "${FIX}/development.plist"
assert_eq "development match=0" "$PHRASA_PROF_MATCH" "0"
assert_eq "development kind" "$PHRASA_PROF_KIND" "development"
assert_eq "development reason" "$PHRASA_PROF_REASON" "not_app_store_development"

eval_fixture "${FIX}/adhoc.plist"
assert_eq "adhoc match=0" "$PHRASA_PROF_MATCH" "0"
assert_eq "adhoc kind" "$PHRASA_PROF_KIND" "adhoc"
assert_eq "adhoc reason" "$PHRASA_PROF_REASON" "not_app_store_adhoc"

eval_fixture "${FIX}/enterprise.plist"
assert_eq "enterprise match=0" "$PHRASA_PROF_MATCH" "0"
assert_eq "enterprise kind" "$PHRASA_PROF_KIND" "enterprise"
assert_eq "enterprise reason" "$PHRASA_PROF_REASON" "not_app_store_enterprise"

eval_fixture "${FIX}/malformed.plist"
assert_eq "malformed match=0" "$PHRASA_PROF_MATCH" "0"
if [[ "$PHRASA_PROF_REASON" == unreadable* ]]; then
  echo "PASS: malformed reason unreadable"
  PASS=$((PASS + 1))
else
  echo "FAIL: malformed reason unreadable (got=$PHRASA_PROF_REASON)" >&2
  FAIL=$((FAIL + 1))
fi

eval_fixture "${FIX}/empty.plist"
assert_eq "empty match=0" "$PHRASA_PROF_MATCH" "0"
if [[ "$PHRASA_PROF_REASON" == unreadable* ]]; then
  echo "PASS: empty reason unreadable"
  PASS=$((PASS + 1))
else
  echo "FAIL: empty reason unreadable (got=$PHRASA_PROF_REASON)" >&2
  FAIL=$((FAIL + 1))
fi

# Missing path
eval_fixture "${FIX}/does-not-exist.plist"
assert_eq "missing path match=0" "$PHRASA_PROF_MATCH" "0"
assert_eq "missing path reason" "$PHRASA_PROF_REASON" "unreadable_missing_plist"

# --- roots helper lists modern then legacy ---
ROOTS_OUT="$(phrasa_provisioning_profile_roots)"
if printf '%s\n' "$ROOTS_OUT" | grep -Fq 'Library/Developer/Xcode/UserData/Provisioning Profiles'; then
  echo "PASS: roots include modern Xcode path"
  PASS=$((PASS + 1))
else
  echo "FAIL: roots include modern Xcode path" >&2
  FAIL=$((FAIL + 1))
fi
if printf '%s\n' "$ROOTS_OUT" | grep -Fq 'Library/MobileDevice/Provisioning Profiles'; then
  echo "PASS: roots include legacy MobileDevice path"
  PASS=$((PASS + 1))
else
  echo "FAIL: roots include legacy MobileDevice path" >&2
  FAIL=$((FAIL + 1))
fi

# --- audit with synthetic roots + security stub (plain plist fixtures as profiles) ---
TMP_BASE="$(mktemp -d "${TMPDIR:-/tmp}/phrasa-prov-test-XXXXXX")"
STUB_BIN="${TMP_BASE}/bin"
MODERN="${TMP_BASE}/modern"
LEGACY="${TMP_BASE}/legacy"
mkdir -p "$STUB_BIN" "$MODERN" "$LEGACY"

# security stub: cms -D -i <file> copies the file (fixtures are already decoded plists)
cat >"${STUB_BIN}/security" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "cms" && "${2:-}" == "-D" && "${3:-}" == "-i" ]]; then
  src="${4:-}"
  if [[ -z "$src" || ! -f "$src" ]]; then
    exit 1
  fi
  # Unreadable: refuse non-plist content so audit marks unreadable
  if ! plutil -lint "$src" >/dev/null 2>&1; then
    exit 1
  fi
  cat "$src"
  exit 0
fi
if [[ "${1:-}" == "find-identity" ]]; then
  # Default: no Apple Distribution (independent blocker tests)
  if [[ -n "${STUB_FIND_IDENTITY_OUT:-}" ]]; then
    printf '%s\n' "$STUB_FIND_IDENTITY_OUT"
  else
    printf '%s\n' '     0 valid identities found'
  fi
  exit 0
fi
echo "stub security: unsupported $*" >&2
exit 2
STUB
chmod +x "${STUB_BIN}/security"

export PATH="${STUB_BIN}:${PATH}"
export PHRASA_PROVISIONING_PROFILE_ROOTS="${MODERN}
${LEGACY}"

# Case: empty roots → blocker
BLOCKERS=()
NOTES=()
UPLOAD_BLOCKERS=()
phrasa_audit_provisioning_profiles
if notes_has 'provisioning_profile_count=0'; then
  echo "PASS: empty roots count note"; PASS=$((PASS + 1))
else
  echo "FAIL: empty roots count note" >&2; FAIL=$((FAIL + 1))
fi
if blockers_has 'no provisioning profiles installed'; then
  echo "PASS: empty roots hard blocker"; PASS=$((PASS + 1))
else
  echo "FAIL: empty roots hard blocker" >&2; FAIL=$((FAIL + 1))
fi

# Case: modern root only with valid App Store match
cp "${FIX}/valid-appstore.plist" "${MODERN}/valid.mobileprovision"
BLOCKERS=()
NOTES=()
phrasa_audit_provisioning_profiles
if notes_has 'provisioning_profile_exact_appstore_match=1'; then
  echo "PASS: modern valid: match note"; PASS=$((PASS + 1))
else
  echo "FAIL: modern valid: match note" >&2; FAIL=$((FAIL + 1))
fi
if notes_text | grep -F "source='${MODERN}'" | grep -q 'match=1'; then
  echo "PASS: modern valid: profile logged from modern source"; PASS=$((PASS + 1))
else
  echo "FAIL: modern valid: profile logged from modern source" >&2; FAIL=$((FAIL + 1))
fi
assert_eq "modern valid: no profile blockers" "${#BLOCKERS[@]}" "0"
if notes_has "kind='appstore'"; then
  echo "PASS: modern valid: logs kind appstore"; PASS=$((PASS + 1))
else
  echo "FAIL: modern valid: logs kind appstore" >&2; FAIL=$((FAIL + 1))
fi

# Case: legacy root only with valid match
rm -f "${MODERN}/valid.mobileprovision"
cp "${FIX}/valid-appstore.plist" "${LEGACY}/legacy-valid.mobileprovision"
BLOCKERS=()
NOTES=()
phrasa_audit_provisioning_profiles
if notes_has 'provisioning_profile_exact_appstore_match=1'; then
  echo "PASS: legacy valid: match"; PASS=$((PASS + 1))
else
  echo "FAIL: legacy valid: match" >&2; FAIL=$((FAIL + 1))
fi
assert_eq "legacy valid: no profile blockers" "${#BLOCKERS[@]}" "0"
if notes_text | grep -F "source='${LEGACY}'" | grep -q 'match=1'; then
  echo "PASS: legacy valid: source is legacy"; PASS=$((PASS + 1))
else
  echo "FAIL: legacy valid: source is legacy" >&2; FAIL=$((FAIL + 1))
fi

# Case: only development profile → blocker
rm -f "${LEGACY}/legacy-valid.mobileprovision"
cp "${FIX}/development.plist" "${MODERN}/dev.mobileprovision"
BLOCKERS=()
NOTES=()
phrasa_audit_provisioning_profiles
if notes_has 'provisioning_profile_exact_appstore_match=0'; then
  echo "PASS: dev only: no match"; PASS=$((PASS + 1))
else
  echo "FAIL: dev only: no match" >&2; FAIL=$((FAIL + 1))
fi
if blockers_has 'no installed App Store provisioning profile'; then
  echo "PASS: dev only: hard blocker"; PASS=$((PASS + 1))
else
  echo "FAIL: dev only: hard blocker" >&2; FAIL=$((FAIL + 1))
fi

# Case: adhoc only
rm -f "${MODERN}/dev.mobileprovision"
cp "${FIX}/adhoc.plist" "${MODERN}/adhoc.mobileprovision"
BLOCKERS=()
NOTES=()
phrasa_audit_provisioning_profiles
if blockers_has 'no installed App Store provisioning profile'; then
  echo "PASS: adhoc only: blocker"; PASS=$((PASS + 1))
else
  echo "FAIL: adhoc only: blocker" >&2; FAIL=$((FAIL + 1))
fi

# Case: enterprise only
rm -f "${MODERN}/adhoc.mobileprovision"
cp "${FIX}/enterprise.plist" "${MODERN}/ent.mobileprovision"
BLOCKERS=()
NOTES=()
phrasa_audit_provisioning_profiles
if blockers_has 'no installed App Store provisioning profile'; then
  echo "PASS: enterprise only: blocker"; PASS=$((PASS + 1))
else
  echo "FAIL: enterprise only: blocker" >&2; FAIL=$((FAIL + 1))
fi

# Case: wrong team / expired / wrong appid do not match
rm -f "${MODERN}/ent.mobileprovision"
cp "${FIX}/wrong-team.plist" "${MODERN}/wt.mobileprovision"
cp "${FIX}/expired-appstore.plist" "${MODERN}/exp.mobileprovision"
cp "${FIX}/wrong-appid.plist" "${MODERN}/wa.mobileprovision"
BLOCKERS=()
NOTES=()
phrasa_audit_provisioning_profiles
if notes_has 'provisioning_profile_exact_appstore_match=1'; then
  echo "FAIL: mismatches: no match flag" >&2; FAIL=$((FAIL + 1))
else
  echo "PASS: mismatches: no match flag"; PASS=$((PASS + 1))
fi
if blockers_has 'no installed App Store provisioning profile'; then
  echo "PASS: mismatches: hard blocker"; PASS=$((PASS + 1))
else
  echo "FAIL: mismatches: hard blocker" >&2; FAIL=$((FAIL + 1))
fi

# Case: malformed/unreadable counted, not matched
rm -f "${MODERN}"/*
cp "${FIX}/malformed.plist" "${MODERN}/bad.mobileprovision"
cp "${FIX}/empty.plist" "${MODERN}/empty.mobileprovision"
BLOCKERS=()
NOTES=()
phrasa_audit_provisioning_profiles
if notes_has 'provisioning_profile_count=2'; then
  echo "PASS: unreadable: count=2"; PASS=$((PASS + 1))
else
  echo "FAIL: unreadable: count=2" >&2; FAIL=$((FAIL + 1))
fi
if notes_has 'status=unreadable|cms_decode_failed|unreadable_invalid|reason=unreadable'; then
  echo "PASS: unreadable: status logged"; PASS=$((PASS + 1))
else
  echo "FAIL: unreadable: status logged notes=$(notes_text)" >&2; FAIL=$((FAIL + 1))
fi
if blockers_has 'no installed App Store|exactly matches'; then
  echo "PASS: unreadable: hard blocker"; PASS=$((PASS + 1))
else
  echo "FAIL: unreadable: hard blocker" >&2; FAIL=$((FAIL + 1))
fi

# Case: valid profile present but Apple Distribution identity missing remains blocked
rm -f "${MODERN}"/*
cp "${FIX}/valid-appstore.plist" "${MODERN}/valid.mobileprovision"
BLOCKERS=()
NOTES=()
UPLOAD_BLOCKERS=()
# full signing audit: stub has no Apple Distribution
export STUB_FIND_IDENTITY_OUT='     0 valid identities found'
phrasa_audit_signing_metadata
if blockers_has 'no Apple Distribution identity'; then
  echo "PASS: valid profile + no dist: distribution blocker present"; PASS=$((PASS + 1))
else
  echo "FAIL: valid profile + no dist: distribution blocker present" >&2; FAIL=$((FAIL + 1))
fi
if blockers_has 'no installed App Store provisioning profile|no provisioning profiles installed'; then
  echo "FAIL: valid profile + no dist: profile blocker should be absent" >&2; FAIL=$((FAIL + 1))
else
  echo "PASS: valid profile + no dist: profile blocker absent"; PASS=$((PASS + 1))
fi
if notes_has 'provisioning_profile_exact_appstore_match=1'; then
  echo "PASS: valid profile + no dist: match noted"; PASS=$((PASS + 1))
else
  echo "FAIL: valid profile + no dist: match noted" >&2; FAIL=$((FAIL + 1))
fi

# Case: valid profile + distribution identity → no hard signing blockers from identity/profile
# (upload blockers may still exist — ASC keys)
BLOCKERS=()
NOTES=()
UPLOAD_BLOCKERS=()
export STUB_FIND_IDENTITY_OUT='  1) AABBCCDDEEFF00112233445566778899AABBCCDD "Apple Distribution: Memorable Factor (Q42MT7JA7Q)"'
phrasa_audit_signing_metadata
HARD_SIGN=0
for b in "${BLOCKERS[@]+"${BLOCKERS[@]}"}"; do
  case "$b" in
    *"Apple Distribution"*|*"provisioning profile"*|*"provisioning profiles"*) HARD_SIGN=1 ;;
  esac
done
assert_eq "valid profile + dist identity: no identity/profile hard blockers" "$HARD_SIGN" "0"
if notes_has 'provisioning_profile_exact_appstore_match=1'; then
  echo "PASS: valid profile + dist: match noted"; PASS=$((PASS + 1))
else
  echo "FAIL: valid profile + dist: match noted" >&2; FAIL=$((FAIL + 1))
fi

# Both roots scanned when files in each
rm -f "${MODERN}"/* "${LEGACY}"/* 2>/dev/null || true
cp "${FIX}/development.plist" "${MODERN}/dev.mobileprovision"
cp "${FIX}/valid-appstore.plist" "${LEGACY}/store.mobileprovision"
BLOCKERS=()
NOTES=()
phrasa_audit_provisioning_profiles
if notes_has 'provisioning_profile_count=2'; then
  echo "PASS: both roots: count=2"; PASS=$((PASS + 1))
else
  echo "FAIL: both roots: count=2" >&2; FAIL=$((FAIL + 1))
fi
if notes_has 'provisioning_profile_exact_appstore_match=1'; then
  echo "PASS: both roots: match from legacy"; PASS=$((PASS + 1))
else
  echo "FAIL: both roots: match from legacy" >&2; FAIL=$((FAIL + 1))
fi
assert_eq "both roots: no blocker when one matches" "${#BLOCKERS[@]}" "0"

# Non-secret logging: NOTES must not contain private key material markers / CMS blobs
NOTES_BLOB="$(notes_text)"
if printf '%s' "$NOTES_BLOB" | grep -q 'BEGIN CERTIFICATE'; then
  echo "FAIL: notes omit BEGIN CERTIFICATE" >&2; FAIL=$((FAIL + 1))
else
  echo "PASS: notes omit BEGIN CERTIFICATE"; PASS=$((PASS + 1))
fi
if printf '%s' "$NOTES_BLOB" | grep -q 'DeveloperCertificates'; then
  echo "FAIL: notes omit DeveloperCertificates payload keys dumped" >&2; FAIL=$((FAIL + 1))
else
  echo "PASS: notes omit DeveloperCertificates payload keys dumped"; PASS=$((PASS + 1))
fi

rm -rf "$TMP_BASE"

echo "---"
echo "provisioning profile tests: pass=$PASS fail=$FAIL"
if ((FAIL > 0)); then
  exit 1
fi
exit 0
