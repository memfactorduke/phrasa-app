# shellcheck shell=bash
# Strict parser/validator for physical-device voice acceptance evidence.
# Fail-closed: template/missing/incomplete/false/stale/mismatched => fail.
# Never fabricates or auto-approves evidence.
# Physical-device preconditions are human-attested only — automation does not
# observe passcode/display/call/foreground state; process residency is not proof.
# Bash 3.2 portable (no associative arrays).

# Required outcome keys (value must be exactly "pass").
PHRASA_EVIDENCE_OUTCOME_KEYS=(
  OUTCOME_PCM_NON_SILENT_AUDIO
  OUTCOME_RECOGNITION_CALLBACKS_WORDS
  OUTCOME_ALIGNMENT_OBSERVATIONS_ACCEPTED
  OUTCOME_TOKEN_PROGRESS_PERSISTENCE
  OUTCOME_RELAUNCH
  OUTCOME_PERMISSION_GRANT
  OUTCOME_PERMISSION_DENIAL
  OUTCOME_INTERRUPTION_BACKGROUND
  OUTCOME_REPEATED_START_STOP
)

# Required physical-device preconditions at the moment full voice stimulus begins.
# Exact values only; human-attested (not read by automation from device APIs).
PHRASA_EVIDENCE_PRECONDITION_KEYS=(
  DEVICE_PASSCODE_REQUIRED
  DEVICE_DISPLAY_STATE
  ACTIVE_CALL_OR_VOIP
  PHRASA_VISIBLY_FOREGROUNDED
)

# All machine-readable keys the parser accepts (required + known optional).
# Any other UPPER_SNAKE KEY=VALUE is rejected (could be mistaken for acceptance claims).
PHRASA_EVIDENCE_KNOWN_KEYS=(
  SCHEMA_VERSION
  SOURCE_COMMIT
  MARKETING_VERSION
  BUILD_NUMBER
  BUNDLE_ID
  CANDIDATE_FINGERPRINT
  DEVICE_NAME
  DEVICE_IDENTIFIER
  DEVICE_MODEL
  DEVICE_IOS_VERSION
  RECOGNITION_MODE
  DEVICE_PASSCODE_REQUIRED
  DEVICE_DISPLAY_STATE
  ACTIVE_CALL_OR_VOIP
  PHRASA_VISIBLY_FOREGROUNDED
  TESTED_AT_UTC
  SPEECH_STIMULUS
  OPERATOR_NAME
  OPERATOR_ATTESTATION
  "${PHRASA_EVIDENCE_OUTCOME_KEYS[@]}"
)

# Required keys (must be present and valid).
PHRASA_EVIDENCE_REQUIRED_KEYS=(
  SCHEMA_VERSION
  SOURCE_COMMIT
  MARKETING_VERSION
  BUILD_NUMBER
  BUNDLE_ID
  CANDIDATE_FINGERPRINT
  DEVICE_NAME
  DEVICE_IDENTIFIER
  DEVICE_MODEL
  DEVICE_IOS_VERSION
  RECOGNITION_MODE
  DEVICE_PASSCODE_REQUIRED
  DEVICE_DISPLAY_STATE
  ACTIVE_CALL_OR_VOIP
  PHRASA_VISIBLY_FOREGROUNDED
  TESTED_AT_UTC
  SPEECH_STIMULUS
  OPERATOR_NAME
  OPERATOR_ATTESTATION
  "${PHRASA_EVIDENCE_OUTCOME_KEYS[@]}"
)

# Parse KEY=VALUE lines from evidence file into EVIDENCE__KEY variables.
# Sets: EVIDENCE_PARSE_ERROR. Tracks seen keys in EVIDENCE_SEEN_KEYS (space-delimited).
phrasa_evidence_reset_parse() {
  local k
  EVIDENCE_PARSE_ERROR=""
  EVIDENCE_SEEN_KEYS=""
  for k in "${PHRASA_EVIDENCE_KNOWN_KEYS[@]}"; do
    unset "EVIDENCE__${k}" 2>/dev/null || true
  done
}

phrasa_evidence_set_field() {
  local key="$1"
  local value="$2"
  printf -v "EVIDENCE__${key}" '%s' "$value"
}

phrasa_evidence_get_field() {
  local key="$1"
  local var="EVIDENCE__${key}"
  printf '%s' "${!var-}"
}

phrasa_evidence_is_known_key() {
  local key="$1"
  local k
  for k in "${PHRASA_EVIDENCE_KNOWN_KEYS[@]}"; do
    if [[ "$k" == "$key" ]]; then
      return 0
    fi
  done
  return 1
}

phrasa_evidence_key_seen() {
  local key="$1"
  case " ${EVIDENCE_SEEN_KEYS} " in
    *" ${key} "*) return 0 ;;
    *) return 1 ;;
  esac
}

phrasa_evidence_mark_seen() {
  local key="$1"
  if [[ -z "${EVIDENCE_SEEN_KEYS}" ]]; then
    EVIDENCE_SEEN_KEYS="${key}"
  else
    EVIDENCE_SEEN_KEYS="${EVIDENCE_SEEN_KEYS} ${key}"
  fi
}

# Returns 0 if parse OK (fields extracted); sets EVIDENCE_PARSE_ERROR on hard parse fail.
phrasa_evidence_parse_file() {
  local path="$1"
  local line key value
  phrasa_evidence_reset_parse

  if [[ ! -f "$path" ]]; then
    EVIDENCE_PARSE_ERROR="evidence file not found: $path"
    return 1
  fi

  if [[ ! -s "$path" ]]; then
    EVIDENCE_PARSE_ERROR="evidence file is empty: $path"
    return 1
  fi

  # Reject obvious template files by content markers
  if grep -q 'REPLACE_ME\|TODO_OPERATOR\|__FILL_IN__\|\[required\]\|example-only' "$path" 2>/dev/null; then
    EVIDENCE_PARSE_ERROR="evidence still contains template placeholders (REPLACE_ME/TODO_OPERATOR/__FILL_IN__/etc.)"
    return 1
  fi

  # If path is the committed template, hard fail
  if [[ "$(basename "$path")" == "VOICE_ACCEPTANCE_TEMPLATE.md" ]]; then
    EVIDENCE_PARSE_ERROR="refusing to accept the template file itself as evidence"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Skip comments and blanks
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Skip pure markdown headings / table chrome
    [[ "$line" =~ ^[[:space:]]*\| ]] && continue
    [[ "$line" =~ ^[[:space:]]*[-*][[:space:]] ]] && continue
    [[ "$line" =~ ^[[:space:]]*={3,} ]] && continue

    # Accept KEY=VALUE only (key is UPPER_SNAKE)
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      value="${BASH_REMATCH[2]}"
      # Strip optional surrounding double quotes
      if [[ "$value" =~ ^\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
      fi
      # Trim leading/trailing whitespace
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      if [[ -z "$value" ]]; then
        EVIDENCE_PARSE_ERROR="empty value for key: $key"
        return 1
      fi
      if ! phrasa_evidence_is_known_key "$key"; then
        EVIDENCE_PARSE_ERROR="unknown machine-readable key rejected (fail-closed): $key"
        return 1
      fi
      if phrasa_evidence_key_seen "$key"; then
        EVIDENCE_PARSE_ERROR="duplicate required/known key rejected (fail-closed, no last-wins): $key"
        return 1
      fi
      phrasa_evidence_mark_seen "$key"
      phrasa_evidence_set_field "$key" "$value"
    fi
  done <"$path"

  return 0
}

# Validate parsed fields against expected candidate. Prints blockers to stdout as lines.
# Returns 0 if valid, 1 if invalid. Does not exit.
phrasa_evidence_validate() {
  local expected_commit="$1"
  local expected_marketing="$2"
  local expected_build="$3"
  local expected_bundle="$4"
  local expected_fingerprint="$5"
  local max_age_days="${6:-30}"
  local errors=()
  local k val att

  if [[ -n "${EVIDENCE_PARSE_ERROR:-}" ]]; then
    errors+=("$EVIDENCE_PARSE_ERROR")
    printf '%s\n' "${errors[@]}"
    return 1
  fi

  for k in "${PHRASA_EVIDENCE_REQUIRED_KEYS[@]}"; do
    val="$(phrasa_evidence_get_field "$k")"
    if [[ -z "$val" ]]; then
      errors+=("missing required field: $k")
    fi
  done

  val="$(phrasa_evidence_get_field SCHEMA_VERSION)"
  if [[ -n "$val" && "$val" != "${PHRASA_EVIDENCE_SCHEMA_VERSION}" ]]; then
    errors+=("SCHEMA_VERSION mismatch: got '$val' expected '${PHRASA_EVIDENCE_SCHEMA_VERSION}'")
  fi

  val="$(phrasa_evidence_get_field SOURCE_COMMIT)"
  if [[ -n "$val" && "$val" != "$expected_commit" ]]; then
    errors+=("SOURCE_COMMIT mismatch: got '$val' expected '$expected_commit'")
  fi
  if [[ -n "$val" && ! "$val" =~ ^[0-9a-f]{40}$ ]]; then
    errors+=("SOURCE_COMMIT must be full 40-char lowercase hex, got '$val'")
  fi

  val="$(phrasa_evidence_get_field MARKETING_VERSION)"
  if [[ -n "$val" && "$val" != "$expected_marketing" ]]; then
    errors+=("MARKETING_VERSION mismatch: got '$val' expected '$expected_marketing'")
  fi

  val="$(phrasa_evidence_get_field BUILD_NUMBER)"
  if [[ -n "$val" && "$val" != "$expected_build" ]]; then
    errors+=("BUILD_NUMBER mismatch: got '$val' expected '$expected_build'")
  fi

  val="$(phrasa_evidence_get_field BUNDLE_ID)"
  if [[ -n "$val" && "$val" != "$expected_bundle" ]]; then
    errors+=("BUNDLE_ID mismatch: got '$val' expected '$expected_bundle'")
  fi

  val="$(phrasa_evidence_get_field CANDIDATE_FINGERPRINT)"
  if [[ -n "$val" && "$val" != "$expected_fingerprint" ]]; then
    errors+=("CANDIDATE_FINGERPRINT mismatch: got '$val' expected '$expected_fingerprint'")
  fi
  if [[ -n "$val" && ! "$val" =~ ^[0-9a-f]{64}$ ]]; then
    errors+=("CANDIDATE_FINGERPRINT must be 64-char lowercase hex sha256")
  fi

  # Device identity: non-placeholder
  for k in DEVICE_NAME DEVICE_IDENTIFIER DEVICE_MODEL DEVICE_IOS_VERSION; do
    val="$(phrasa_evidence_get_field "$k")"
    if [[ -n "$val" ]]; then
      case "$val" in
        unknown|UNKNOWN|n/a|N/A|none|None|simulator|Simulator|"")
          errors+=("$k looks invalid/placeholder: '$val'")
          ;;
      esac
      if [[ "$val" == *"REPLACE"* || "$val" == *"example"* ]]; then
        errors+=("$k looks like a template value: '$val'")
      fi
    fi
  done
  val="$(phrasa_evidence_get_field DEVICE_IDENTIFIER)"
  if [[ -n "$val" && ${#val} -lt 8 ]]; then
    errors+=("DEVICE_IDENTIFIER too short to be a real device id")
  fi

  # iOS version: require dotted numeric form (e.g. 18.5 or 17.0.1), not free text placeholder
  val="$(phrasa_evidence_get_field DEVICE_IOS_VERSION)"
  if [[ -n "$val" && ! "$val" =~ ^[0-9]{1,2}(\.[0-9]{1,3}){1,3}$ ]]; then
    errors+=("DEVICE_IOS_VERSION must look like an iOS version (e.g. 18.5), got '$val'")
  fi

  # Recognition mode: explicit binding for on-device vs Apple service path
  val="$(phrasa_evidence_get_field RECOGNITION_MODE)"
  if [[ -n "$val" ]]; then
    case " ${PHRASA_RECOGNITION_MODES_ALLOWED} " in
      *" ${val} "*)
        ;;
      *)
        errors+=("RECOGNITION_MODE must be one of: ${PHRASA_RECOGNITION_MODES_ALLOWED}; got '$val'")
        ;;
    esac
  fi

  # Physical-device preconditions at full voice stimulus start (human-attested only).
  # Process residency / InCallService presence is NOT proof of a valid session.
  val="$(phrasa_evidence_get_field DEVICE_PASSCODE_REQUIRED)"
  if [[ -n "$val" && "$val" != "false" ]]; then
    errors+=("DEVICE_PASSCODE_REQUIRED must be exactly 'false' (device physically unlocked); got '$val'")
  fi

  val="$(phrasa_evidence_get_field DEVICE_DISPLAY_STATE)"
  if [[ -n "$val" ]]; then
    case " ${PHRASA_DEVICE_DISPLAY_STATES_ALLOWED} " in
      *" ${val} "*)
        ;;
      *)
        errors+=("DEVICE_DISPLAY_STATE must be one of: ${PHRASA_DEVICE_DISPLAY_STATES_ALLOWED}; got '$val'")
        ;;
    esac
  fi

  val="$(phrasa_evidence_get_field ACTIVE_CALL_OR_VOIP)"
  if [[ -n "$val" && "$val" != "false" ]]; then
    errors+=("ACTIVE_CALL_OR_VOIP must be exactly 'false' (no Phone/FaceTime/Telegram/VoIP/call audio-session contention or green call/mic indicator); got '$val'")
  fi

  val="$(phrasa_evidence_get_field PHRASA_VISIBLY_FOREGROUNDED)"
  if [[ -n "$val" && "$val" != "true" ]]; then
    errors+=("PHRASA_VISIBLY_FOREGROUNDED must be exactly 'true' (Phrasa visibly foregrounded; process residency alone is not proof); got '$val'")
  fi

  # Speech stimulus must be substantial (full script / multi-sentence)
  val="$(phrasa_evidence_get_field SPEECH_STIMULUS)"
  if [[ -n "$val" && ${#val} -lt 40 ]]; then
    errors+=("SPEECH_STIMULUS too short (${#val} chars); require full speech stimulus text (>=40)" )
  fi

  # Outcomes must be exactly pass (not true/yes/PASS/fail)
  for k in "${PHRASA_EVIDENCE_OUTCOME_KEYS[@]}"; do
    val="$(phrasa_evidence_get_field "$k")"
    if [[ -n "$val" && "$val" != "pass" ]]; then
      errors+=("$k must be exactly 'pass' (fail-closed); got '$val'")
    fi
  done

  # Operator attestation must be the exact required phrase
  att="$(phrasa_evidence_get_field OPERATOR_ATTESTATION)"
  local required_attestation="${PHRASA_OPERATOR_ATTESTATION_REQUIRED}"
  if [[ -n "$att" && "$att" != "$required_attestation" ]]; then
    errors+=("OPERATOR_ATTESTATION must match the required attestation string exactly")
  fi

  val="$(phrasa_evidence_get_field OPERATOR_NAME)"
  if [[ -n "$val" && ${#val} -lt 2 ]]; then
    errors+=("OPERATOR_NAME too short")
  fi

  # Timestamp checks: ISO-8601 UTC ending in Z; not future; not older than max_age_days
  val="$(phrasa_evidence_get_field TESTED_AT_UTC)"
  if [[ -n "$val" ]]; then
    if [[ ! "$val" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
      errors+=("TESTED_AT_UTC must be YYYY-MM-DDTHH:MM:SSZ, got '$val'")
    else
      local tested_epoch now_epoch age_sec max_sec
      tested_epoch="$(phrasa_utc_to_epoch "$val" 2>/dev/null || echo "")"
      now_epoch="$(date -u +%s)"
      if [[ -z "$tested_epoch" ]]; then
        errors+=("TESTED_AT_UTC could not be parsed: $val")
      else
        if (( tested_epoch > now_epoch + 300 )); then
          errors+=("TESTED_AT_UTC is in the future: $val")
        fi
        age_sec=$((now_epoch - tested_epoch))
        max_sec=$((max_age_days * 86400))
        if (( age_sec > max_sec )); then
          errors+=("TESTED_AT_UTC is stale (>${max_age_days} days): $val")
        fi
      fi
    fi
  fi

  if ((${#errors[@]} > 0)); then
    printf '%s\n' "${errors[@]}"
    return 1
  fi
  return 0
}

phrasa_utc_to_epoch() {
  local iso="$1"
  # macOS date
  if date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null; then
    return 0
  fi
  # GNU date fallback
  date -u -d "${iso/Z/+0000}" +%s 2>/dev/null
}

# High-level: parse + validate a path. Prints errors; returns status.
phrasa_evidence_check_file() {
  local path="$1"
  local expected_commit="$2"
  local expected_marketing="$3"
  local expected_build="$4"
  local expected_bundle="$5"
  local expected_fingerprint="$6"
  local max_age_days="${7:-30}"

  if ! phrasa_evidence_parse_file "$path"; then
    printf '%s\n' "${EVIDENCE_PARSE_ERROR:-parse failed}"
    return 1
  fi
  phrasa_evidence_validate \
    "$expected_commit" \
    "$expected_marketing" \
    "$expected_build" \
    "$expected_bundle" \
    "$expected_fingerprint" \
    "$max_age_days"
}
