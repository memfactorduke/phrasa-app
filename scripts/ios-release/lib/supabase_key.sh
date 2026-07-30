# shellcheck shell=bash
# Production Supabase publishable-key validation + redaction for the iOS release lane.
# Sourced by release-ios.sh. Never prints the key value. Portable to macOS Bash 3.2.

# Trim leading/trailing whitespace (no echo of secrets via xtrace-friendly path).
phrasa_trim() {
  local s="${1-}"
  # Leading
  s="${s#"${s%%[![:space:]]*}"}"
  # Trailing
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# Decode base64url payload segment to stdout. Returns 1 on failure.
# macOS base64 accepts -D and -d; prefer -D for older systems.
phrasa_base64url_decode() {
  local value="$1"
  local base64 pad
  base64="$(printf '%s' "$value" | tr '_-' '/+')"
  pad=$(( (4 - ${#base64} % 4) % 4 ))
  while ((pad > 0)); do
    base64="${base64}="
    pad=$((pad - 1))
  done
  if printf '%s' "$base64" | base64 -D 2>/dev/null; then
    return 0
  fi
  if printf '%s' "$base64" | base64 -d 2>/dev/null; then
    return 0
  fi
  return 1
}

# Print JWT "role" claim (lowercase) or empty if not a 3-part JWT / unreadable.
# Never prints the full token; callers should not log the return with the token.
phrasa_jwt_role() {
  local key="$1"
  local IFS='.'
  # shellcheck disable=SC2086
  set -f
  # shellcheck disable=SC2048
  set -- ${key}
  set +f
  if [[ $# -ne 3 ]]; then
    return 0
  fi
  local payload_json role
  payload_json="$(phrasa_base64url_decode "$2" 2>/dev/null || true)"
  if [[ -z "$payload_json" ]]; then
    return 0
  fi
  # Prefer python3 for robust JSON; fall back to a tight sed for {"role":"..."}.
  if command -v python3 >/dev/null 2>&1; then
    role="$(printf '%s' "$payload_json" | python3 -c '
import json,sys
try:
    obj=json.load(sys.stdin)
    r=obj.get("role")
    if isinstance(r,str):
        print(r.lower())
except Exception:
    pass
' 2>/dev/null || true)"
  else
    role="$(printf '%s' "$payload_json" \
      | tr -d '\n' \
      | sed -nE 's/.*"role"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' \
      | head -1 \
      | tr '[:upper:]' '[:lower:]')"
  fi
  printf '%s' "${role:-}"
}

# True if key looks privileged (secret prefix, service_role marker, or service_role JWT).
phrasa_supabase_key_is_privileged() {
  local key
  key="$(phrasa_trim "${1-}")"
  [[ -z "$key" ]] && return 1
  local lower
  lower="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    sb_secret_*) return 0 ;;
  esac
  if [[ "$lower" == *service_role* ]]; then
    return 0
  fi
  local role
  role="$(phrasa_jwt_role "$key")"
  if [[ "$role" == "service_role" ]]; then
    return 0
  fi
  return 1
}

# True if key is a modern publishable key or a legacy JWT anon client key.
phrasa_supabase_key_is_publishable_or_anon() {
  local key
  key="$(phrasa_trim "${1-}")"
  [[ -z "$key" ]] && return 1
  if phrasa_supabase_key_is_privileged "$key"; then
    return 1
  fi
  local lower
  lower="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    sb_publishable_*)
      # Require more than the bare prefix.
      if [[ ${#key} -gt 16 ]]; then
        return 0
      fi
      return 1
      ;;
  esac
  # Legacy Supabase anon JWT: three segments, role claim == anon.
  local role
  role="$(phrasa_jwt_role "$key")"
  if [[ "$role" == "anon" ]]; then
    return 0
  fi
  return 1
}

# Classify env PHRASA_SUPABASE_PUBLISHABLE_KEY without printing its value.
# Prints one of: missing | privileged | invalid | ok
# Sets PHRASA_SUPABASE_KEY_STATUS to the same token.
phrasa_supabase_publishable_key_status() {
  local key
  key="$(phrasa_trim "${PHRASA_SUPABASE_PUBLISHABLE_KEY-}")"
  if [[ -z "$key" ]]; then
    PHRASA_SUPABASE_KEY_STATUS="missing"
    printf '%s' "missing"
    return 0
  fi
  if phrasa_supabase_key_is_privileged "$key"; then
    PHRASA_SUPABASE_KEY_STATUS="privileged"
    printf '%s' "privileged"
    return 0
  fi
  if ! phrasa_supabase_key_is_publishable_or_anon "$key"; then
    PHRASA_SUPABASE_KEY_STATUS="invalid"
    printf '%s' "invalid"
    return 0
  fi
  PHRASA_SUPABASE_KEY_STATUS="ok"
  printf '%s' "ok"
  return 0
}

# Human-safe kind label for a validated key (never the value).
phrasa_supabase_key_kind_label() {
  local key
  key="$(phrasa_trim "${1-}")"
  if [[ -z "$key" ]]; then
    printf '%s' "empty"
    return 0
  fi
  local lower
  lower="$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')"
  case "$lower" in
    sb_publishable_*)
      printf '%s' "sb_publishable"
      return 0
      ;;
  esac
  local role
  role="$(phrasa_jwt_role "$key")"
  if [[ "$role" == "anon" ]]; then
    printf '%s' "legacy_anon_jwt"
    return 0
  fi
  if [[ "$role" == "service_role" ]] || phrasa_supabase_key_is_privileged "$key"; then
    printf '%s' "privileged"
    return 0
  fi
  printf '%s' "unknown"
}

# Fail closed for shipping --release / --validate / --upload.
# Does not print the key. Exit 1 via phrasa_die on any non-ok status.
phrasa_require_shipping_supabase_publishable_key() {
  local status
  status="$(phrasa_supabase_publishable_key_status)"
  case "$status" in
    ok)
      local kind
      kind="$(phrasa_supabase_key_kind_label "${PHRASA_SUPABASE_PUBLISHABLE_KEY}")"
      phrasa_info "shipping Supabase publishable key: present (kind=${kind}; value not printed)"
      return 0
      ;;
    missing)
      phrasa_die "PHRASA_SUPABASE_PUBLISHABLE_KEY is missing/empty; --release/--validate/--upload require a production publishable (or legacy anon) client key injected as a build-setting override"
      ;;
    privileged)
      phrasa_die "PHRASA_SUPABASE_PUBLISHABLE_KEY looks privileged (sb_secret_ / service_role); refusing shipping build (value not printed)"
      ;;
    invalid)
      phrasa_die "PHRASA_SUPABASE_PUBLISHABLE_KEY is not a publishable or legacy anon client key; refusing shipping build (value not printed)"
      ;;
    *)
      phrasa_die "PHRASA_SUPABASE_PUBLISHABLE_KEY failed validation (status=${status}; value not printed)"
      ;;
  esac
}

# Preflight: if env key is set, it must be a safe client key. Missing is OK for --preflight only.
# Never prints the key. Adds NOTES / BLOCKERS only.
phrasa_preflight_supabase_publishable_key_env() {
  local status
  status="$(phrasa_supabase_publishable_key_status)"
  case "$status" in
    missing)
      NOTES+=("PHRASA_SUPABASE_PUBLISHABLE_KEY unset/empty (allowed for --preflight; required for --release/--validate/--upload)")
      ;;
    ok)
      NOTES+=("PHRASA_SUPABASE_PUBLISHABLE_KEY present and looks like a publishable/legacy-anon client key (value not printed; not written to showBuildSettings dump)")
      ;;
    privileged)
      phrasa_blocker "PHRASA_SUPABASE_PUBLISHABLE_KEY looks privileged (sb_secret_/service_role); never inject into a shipping build (value not printed)"
      ;;
    invalid)
      phrasa_blocker "PHRASA_SUPABASE_PUBLISHABLE_KEY is set but is not a publishable or legacy anon client key (value not printed)"
      ;;
    *)
      phrasa_blocker "PHRASA_SUPABASE_PUBLISHABLE_KEY failed validation (status=${status}; value not printed)"
      ;;
  esac
}

# Redact every occurrence of the current env key value in a file (if set and non-empty).
# Safe no-op when missing. Uses a temp file; does not print the key.
phrasa_redact_supabase_key_in_file() {
  local path="$1"
  local key
  key="$(phrasa_trim "${PHRASA_SUPABASE_PUBLISHABLE_KEY-}")"
  if [[ -z "$key" || ! -f "$path" ]]; then
    return 0
  fi
  # Prefer python for literal substring replace (no regex metachar hazards).
  if command -v python3 >/dev/null 2>&1; then
    PHRASA_REDACT_KEY="$key" python3 - "$path" <<'PY'
import os, sys
path = sys.argv[1]
key = os.environ.get("PHRASA_REDACT_KEY", "")
if not key:
    raise SystemExit(0)
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    data = fh.read()
if key not in data:
    raise SystemExit(0)
with open(path, "w", encoding="utf-8") as fh:
    fh.write(data.replace(key, "(redacted-supabase-publishable-key)"))
PY
    unset PHRASA_REDACT_KEY
    return 0
  fi
  # Fallback: Perl literal replacement avoids regex and delimiter hazards.
  if command -v perl >/dev/null 2>&1; then
    PHRASA_REDACT_KEY="$key" perl -0pi -e '
      BEGIN { $key = $ENV{"PHRASA_REDACT_KEY"} // ""; }
      s/\Q$key\E/(redacted-supabase-publishable-key)/g if length $key;
    ' "$path"
    unset PHRASA_REDACT_KEY
    return 0
  fi

  # Last-resort sed path for the known client-key character set.
  local escaped
  escaped="$(printf '%s' "$key" | sed -e 's/[][\\.^$*|/]/\\&/g')"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/phrasa-redact.XXXXXX")" || return 0
  if sed "s/${escaped}/(redacted-supabase-publishable-key)/g" "$path" >"$tmp" 2>/dev/null; then
    mv "$tmp" "$path"
  else
    rm -f "$tmp"
  fi
}

# Redact the current env key from a text stream before it reaches a terminal or
# tee log. This is used when xcodebuild receives cloud configuration through a
# private xcconfig: post-run file scrubbing alone would leave a live-output race.
phrasa_redact_supabase_key_stream() {
  local key
  key="$(phrasa_trim "${PHRASA_SUPABASE_PUBLISHABLE_KEY-}")"
  if [[ -z "$key" ]]; then
    cat
    return 0
  fi

  # Literal replacement only. Never interpolate the key into program source or
  # a regular expression.
  if command -v python3 >/dev/null 2>&1; then
    PHRASA_REDACT_KEY="$key" python3 -c '
import os
import sys

key = os.environ.get("PHRASA_REDACT_KEY", "")
replacement = "(redacted-supabase-publishable-key)"
for line in sys.stdin:
    sys.stdout.write(line.replace(key, replacement))
    sys.stdout.flush()
'
    return $?
  fi
  if command -v perl >/dev/null 2>&1; then
    PHRASA_REDACT_KEY="$key" perl -pe '
      BEGIN { $key = $ENV{"PHRASA_REDACT_KEY"} // ""; }
      s/\Q$key\E/(redacted-supabase-publishable-key)/g;
    '
    return $?
  fi

  # Failing is safer than passing a potentially key-bearing stream through.
  printf '%s\n' \
    "ERROR: cannot safely redact Supabase publishable key stream (python3/perl unavailable)" \
    >&2
  return 1
}

# Scrub showBuildSettings / proof text dumps so a non-empty publishable key value
# never persists. Also blanks expanded INFOPLIST lines that might echo the key.
phrasa_scrub_settings_dump_of_supabase_key() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    return 0
  fi
  phrasa_redact_supabase_key_in_file "$path"
  # Additionally redact any non-empty assignment to the build setting name even
  # if the env value differed (defense in depth for leaked local xcconfig).
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$path" <<'PY'
import re, sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8", errors="replace") as fh:
    lines = fh.readlines()
out = []
pat = re.compile(
    r"^(\s*(?:PHRASA_SUPABASE_PUBLISHABLE_KEY|PhrasaSupabasePublishableKey)\s*=\s*)(\S.*)$"
)
for line in lines:
    m = pat.match(line.rstrip("\n"))
    if m and m.group(2).strip() not in ("", '""', "''"):
        out.append(m.group(1) + "(redacted)\n")
    else:
        out.append(line)
with open(path, "w", encoding="utf-8") as fh:
    fh.writelines(out)
PY
  fi
}

# True if value still looks like an unresolved Xcode $(SETTING) placeholder.
phrasa_is_unresolved_build_placeholder() {
  local value
  value="$(phrasa_trim "${1-}")"
  [[ ${#value} -gt 3 && "$value" == '$('* && "$value" == *')' ]]
}

# Validate expanded Info.plist cloud keys for a shipping app bundle.
# Prints non-secret summary lines to stdout. Returns 0 on success, 1 on failure.
# Emits CLOUD_OK or CLOUD_BLOCKER:<msg> markers. Never prints the key value.
phrasa_assert_shipping_cloud_info_plist() {
  local app_info="$1"
  local label="${2:-app}"
  local url key kind fail=0

  if [[ ! -f "$app_info" ]]; then
    printf 'CLOUD_BLOCKER:%s Info.plist missing for cloud assertions\n' "$label"
    return 1
  fi

  url="$(/usr/libexec/PlistBuddy -c "Print :${PHRASA_INFO_SUPABASE_URL_KEY}" "$app_info" 2>/dev/null || true)"
  key="$(/usr/libexec/PlistBuddy -c "Print :${PHRASA_INFO_SUPABASE_PUBLISHABLE_KEY_KEY}" "$app_info" 2>/dev/null || true)"
  url="$(phrasa_trim "$url")"
  key="$(phrasa_trim "$key")"

  # URL must be exactly the production project URL (scheme+host pin).
  if [[ -z "$url" ]]; then
    printf 'CLOUD_BLOCKER:%s %s is empty/missing\n' "$label" "$PHRASA_INFO_SUPABASE_URL_KEY"
    fail=1
  elif phrasa_is_unresolved_build_placeholder "$url"; then
    printf 'CLOUD_BLOCKER:%s %s is an unresolved build-setting placeholder\n' \
      "$label" "$PHRASA_INFO_SUPABASE_URL_KEY"
    fail=1
  elif [[ "$url" != "$PHRASA_PRODUCTION_SUPABASE_URL" ]]; then
    # URL is public; safe to print the mismatched value for diagnosis.
    printf 'CLOUD_BLOCKER:%s %s must be exactly %s (got %s)\n' \
      "$label" "$PHRASA_INFO_SUPABASE_URL_KEY" "$PHRASA_PRODUCTION_SUPABASE_URL" "$url"
    fail=1
  else
    # Also require host pin (exact URL already implies host).
    printf 'cloud_url_ok=%s host=%s\n' "$PHRASA_PRODUCTION_SUPABASE_URL" "$PHRASA_PRODUCTION_SUPABASE_HOST"
  fi

  if [[ -z "$key" ]]; then
    printf 'CLOUD_BLOCKER:%s %s is empty/missing (shipping build must inject a publishable key)\n' \
      "$label" "$PHRASA_INFO_SUPABASE_PUBLISHABLE_KEY_KEY"
    fail=1
  elif phrasa_is_unresolved_build_placeholder "$key"; then
    printf 'CLOUD_BLOCKER:%s %s is an unresolved build-setting placeholder\n' \
      "$label" "$PHRASA_INFO_SUPABASE_PUBLISHABLE_KEY_KEY"
    fail=1
  elif phrasa_supabase_key_is_privileged "$key"; then
    printf 'CLOUD_BLOCKER:%s %s looks privileged; refuse shipping binary (value not printed)\n' \
      "$label" "$PHRASA_INFO_SUPABASE_PUBLISHABLE_KEY_KEY"
    fail=1
  elif ! phrasa_supabase_key_is_publishable_or_anon "$key"; then
    printf 'CLOUD_BLOCKER:%s %s is not a publishable/legacy-anon client key (value not printed)\n' \
      "$label" "$PHRASA_INFO_SUPABASE_PUBLISHABLE_KEY_KEY"
    fail=1
  else
    kind="$(phrasa_supabase_key_kind_label "$key")"
    printf 'cloud_publishable_key_ok=1 kind=%s len=%s (value not printed)\n' "$kind" "${#key}"
  fi

  if ((fail)); then
    return 1
  fi
  printf 'CLOUD_OK\n'
  return 0
}
