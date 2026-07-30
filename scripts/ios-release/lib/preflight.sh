# shellcheck shell=bash
# Preflight checks for Phrasa iOS release.
#
# Side effects: only creates/writes under the isolated, gitignored run directory
# passed via PHRASA_RUN_DIR (proof log + showBuildSettings dump). Never archives,
# exports, App Store Connect validates/uploads, or modifies tracked source/
# release/App Store state. Local Submission packet and release-ready validation
# are allowed and required (read-only; no Connect mutation).
#
# "Read-only" means: no product/release mutation. A preserved proof path is allowed.

# Populate BLOCKERS, UPLOAD_BLOCKERS, and NOTES arrays.
# Exit 0 only when both blocker lists are empty (lane fully ready including upload).
# --release uses hard gates for archive; missing/invalid evidence is always hard.

phrasa_run_preflight() {
  BLOCKERS=()
  UPLOAD_BLOCKERS=()
  NOTES=()
  local root project forbidden
  root="$(phrasa_repo_root)"
  project="${root}/${PHRASA_PROJECT_REL}"
  forbidden="${root}/${PHRASA_FORBIDDEN_PROJECT_REL}"

  phrasa_info "=== Phrasa iOS release preflight (build ${PHRASA_BUILD_NUMBER}) ==="
  phrasa_info "repo_root=$root"
  phrasa_info "time_utc=$(phrasa_iso_utc_now)"
  phrasa_info "preflight_side_effects=isolated_gitignored_proof_dir_only (no archive/export/IPA/DerivedData product builds)"

  # --- 1. Authoritative project path ---
  if [[ ! -d "$project" ]]; then
    phrasa_blocker "authoritative project missing: ${PHRASA_PROJECT_REL}"
  else
    NOTES+=("authoritative project present: ${PHRASA_PROJECT_REL}")
  fi

  if [[ -e "$forbidden" ]]; then
    phrasa_blocker "forbidden Finder-duplicate project exists: ${PHRASA_FORBIDDEN_PROJECT_REL} (hard failure)"
  fi

  # Any numbered PhrasaNative N.xcodeproj (2, 3, …) or other * N.xcodeproj
  # under ios-native hard-fails. Authoritative PhrasaNative.xcodeproj only.
  local dup
  while IFS= read -r dup; do
    [[ -z "$dup" ]] && continue
    local rel="${dup#"$root"/}"
    local base
    base="$(basename "$rel")"
    if [[ "$base" == "PhrasaNative.xcodeproj" ]]; then
      continue
    fi
    phrasa_blocker "forbidden duplicate Xcode project (never archive/select): $rel"
  done < <(
    find "${root}/ios-native" -maxdepth 1 \( \
      -name 'PhrasaNative *.xcodeproj' -o \
      -name '* [0-9].xcodeproj' -o \
      -name '* [0-9][0-9].xcodeproj' \
    \) 2>/dev/null || true
  )

  # --- 2. Exact product source commit (pin) ---
  # The automation commit may sit on top of the product pin. Require either:
  #   HEAD == pin, or pin is an ancestor of HEAD and product paths match pin exactly.
  local head
  head="$(git -C "$root" rev-parse HEAD 2>/dev/null || true)"
  if [[ -z "$head" ]]; then
    phrasa_blocker "unable to read git HEAD"
  elif ! git -C "$root" cat-file -e "${PHRASA_EXPECTED_COMMIT}^{commit}" 2>/dev/null; then
    phrasa_blocker "expected product commit not found in repo: $PHRASA_EXPECTED_COMMIT"
  elif [[ "$head" == "$PHRASA_EXPECTED_COMMIT" ]]; then
    NOTES+=("HEAD equals product pin $PHRASA_EXPECTED_COMMIT")
  elif git -C "$root" merge-base --is-ancestor "$PHRASA_EXPECTED_COMMIT" "$head" 2>/dev/null; then
    NOTES+=("HEAD $head is descendant of product pin $PHRASA_EXPECTED_COMMIT")
    local product_paths=(
      "ios-native/Phrasa"
      "ios-native/PhrasaTests"
      "ios-native/PhrasaMac"
      "ios-native/PhrasaMacTests"
      "ios-native/PhrasaNative.xcodeproj"
      "ios-native/project.yml"
      "ios-native/Packages"
      "ios-native/ExportOptions.plist"
    )
    local diff_out
    if ! diff_out="$(git -C "$root" diff --name-only "$PHRASA_EXPECTED_COMMIT" HEAD -- "${product_paths[@]}" 2>/dev/null)"; then
      phrasa_blocker "unable to diff product paths against pin $PHRASA_EXPECTED_COMMIT"
    elif [[ -n "$diff_out" ]]; then
      phrasa_blocker "product sources differ from pin $PHRASA_EXPECTED_COMMIT: $(echo "$diff_out" | tr '\n' ' ')"
    else
      NOTES+=("product paths match pin $PHRASA_EXPECTED_COMMIT (no diff vs HEAD)")
    fi
  else
    phrasa_blocker "HEAD $head is not the product pin and does not contain it as ancestor ($PHRASA_EXPECTED_COMMIT)"
  fi

  # --- 3. Clean tracked worktree + untracked policy ---
  phrasa_check_worktree_clean "$root"

  # --- 4. Resolved Phrasa target Release build settings (authoritative) ---
  # showBuildSettings is intentionally run WITHOUT the publishable-key override
  # so the key never lands in the proof dump (project keeps the empty placeholder).
  phrasa_check_project_settings "$root"

  # --- 4b. Shipping Supabase publishable key env (value never printed/persisted) ---
  # Missing is allowed for --preflight only; --release fails closed via require.
  # Privileged / non-client forms hard-block even during preflight.
  phrasa_preflight_supabase_publishable_key_env

  # --- 5. Candidate fingerprint ---
  local pbx_hash fingerprint
  if [[ -f "${root}/ios-native/PhrasaNative.xcodeproj/project.pbxproj" ]]; then
    pbx_hash="$(phrasa_sha256_file "${root}/ios-native/PhrasaNative.xcodeproj/project.pbxproj")"
  else
    pbx_hash="missing"
  fi
  fingerprint="$(phrasa_candidate_fingerprint \
    "$PHRASA_EXPECTED_COMMIT" \
    "$PHRASA_MARKETING_VERSION" \
    "$PHRASA_BUILD_NUMBER" \
    "$PHRASA_BUNDLE_ID" \
    "$PHRASA_TEAM_ID" \
    "$pbx_hash")"
  NOTES+=("candidate_fingerprint=$fingerprint")
  NOTES+=("pbxproj_sha256=$pbx_hash")
  PHRASA_COMPUTED_FINGERPRINT="$fingerprint"
  PHRASA_PBXPROJ_SHA256="$pbx_hash"

  if [[ "$pbx_hash" != "$PHRASA_EXPECTED_PBXPROJ_SHA256" ]]; then
    phrasa_blocker "pbxproj sha256 mismatch: got $pbx_hash expected $PHRASA_EXPECTED_PBXPROJ_SHA256 (product pin / project drift)"
  else
    NOTES+=("pbxproj sha256 matches expected pin value")
  fi
  if [[ "$fingerprint" != "$PHRASA_EXPECTED_FINGERPRINT" ]]; then
    phrasa_blocker "candidate fingerprint mismatch: got $fingerprint expected $PHRASA_EXPECTED_FINGERPRINT"
  else
    NOTES+=("candidate fingerprint matches expected pin value")
  fi

  # --- 6. Local Submission packet + pre-archive validation (not Connect) ---
  phrasa_check_submission_packet "$root"

  # --- 7. Voice acceptance evidence (hard gate) ---
  local evidence_path
  evidence_path="${PHRASA_VOICE_EVIDENCE_PATH:-${root}/${PHRASA_DEFAULT_EVIDENCE_REL}}"
  NOTES+=("evidence_path=$evidence_path")
  if [[ ! -f "$evidence_path" ]]; then
    phrasa_blocker "physical voice-acceptance evidence missing: $evidence_path (hard gate before archive/export/upload)"
  else
    local ev_errors
    if ! ev_errors="$(phrasa_evidence_check_file \
      "$evidence_path" \
      "$PHRASA_EXPECTED_COMMIT" \
      "$PHRASA_MARKETING_VERSION" \
      "$PHRASA_BUILD_NUMBER" \
      "$PHRASA_BUNDLE_ID" \
      "$fingerprint" \
      "$PHRASA_EVIDENCE_MAX_AGE_DAYS")"; then
      while IFS= read -r line; do
        [[ -n "$line" ]] && phrasa_blocker "evidence: $line"
      done <<<"$ev_errors"
    else
      NOTES+=("voice-acceptance evidence valid for this candidate")
    fi
  fi

  # --- 8. Tooling ---
  if ! command -v xcodebuild >/dev/null 2>&1; then
    phrasa_blocker "xcodebuild not found"
  else
    NOTES+=("xcodebuild: $(xcodebuild -version 2>/dev/null | tr '\n' ' ')")
  fi
  if ! command -v xcrun >/dev/null 2>&1; then
    phrasa_blocker "xcrun not found"
  fi
  if ! command -v swift >/dev/null 2>&1; then
    phrasa_blocker "swift not found (needed for package tests)"
  fi

  # --- 9. Signing / provisioning / API key metadata audit (no secrets) ---
  phrasa_audit_signing_metadata

  # --- 10. Required source resources present ---
  local res
  for res in \
    "ios-native/Phrasa/Resources/PrivacyInfo.xcprivacy" \
    "ios-native/Phrasa/Resources/Fonts/OFL.txt" \
    "ios-native/Phrasa/Resources/Fonts/AtkinsonHyperlegible-Regular.ttf" \
    "ios-native/Phrasa/Info.plist"; do
    if [[ ! -f "${root}/${res}" ]]; then
      phrasa_blocker "required source resource missing: $res"
    fi
  done

  # Info.plist encryption flag in source
  if ! grep -q 'ITSAppUsesNonExemptEncryption' "${root}/ios-native/Phrasa/Info.plist" 2>/dev/null; then
    phrasa_blocker "Info.plist missing ITSAppUsesNonExemptEncryption"
  else
    if grep -A1 'ITSAppUsesNonExemptEncryption' "${root}/ios-native/Phrasa/Info.plist" | grep -q '<false/>'; then
      NOTES+=("Info.plist ITSAppUsesNonExemptEncryption=false")
    else
      phrasa_blocker "Info.plist ITSAppUsesNonExemptEncryption is not false"
    fi
  fi

  # Source privacy manifest sanity (full plist parse also happens on archive/IPA)
  local src_privacy="${root}/ios-native/Phrasa/Resources/PrivacyInfo.xcprivacy"
  if [[ -f "$src_privacy" ]]; then
    if ! phrasa_check_privacy_manifest "$src_privacy" "source"; then
      :
    fi
  fi

  # --- Summary ---
  phrasa_info "=== preflight notes ==="
  local n
  for n in "${NOTES[@]+"${NOTES[@]}"}"; do
    phrasa_info "  - $n"
  done

  local hard_n=${#BLOCKERS[@]}
  local upload_n=${#UPLOAD_BLOCKERS[@]}

  if ((hard_n > 0)); then
    phrasa_info "=== HARD BLOCKERS (${hard_n}) — block archive/export ==="
    local b
    for b in "${BLOCKERS[@]}"; do
      printf '  * %s\n' "$b" >&2
    done
  fi
  if ((upload_n > 0)); then
    phrasa_info "=== UPLOAD/VALIDATE BLOCKERS (${upload_n}) — block --validate/--upload only ==="
    local u
    for u in "${UPLOAD_BLOCKERS[@]}"; do
      printf '  * %s\n' "$u" >&2
    done
  fi

  if ((hard_n + upload_n > 0)); then
    phrasa_info "preflight result: FAIL (no archive/export/upload performed; only isolated proof dir written)"
    return 1
  fi

  phrasa_info "preflight result: PASS (lane ready for gated release including upload credentials)"
  return 0
}

# True (return 0) when archive/export hard gates are clear (upload blockers OK).
phrasa_hard_gates_clear() {
  ((${#BLOCKERS[@]} == 0))
}

phrasa_upload_gates_clear() {
  ((${#UPLOAD_BLOCKERS[@]} == 0))
}

# Run the machine-ready Submission packet validator in packet mode and then
# release-ready mode. One-way integration: release preflight requires both
# local packet completeness and the explicit pre-archive owner/voice/signing
# gate. It never runs submission-ready (post-upload Connect evidence) and never
# claims App Store Connect state.
# Non-circular: packet validator never invokes release automation.
phrasa_check_submission_packet() {
  local root="$1"
  local validator="${root}/${PHRASA_SUBMISSION_VALIDATE_REL}"
  if [[ ! -f "$validator" ]]; then
    phrasa_blocker "submission packet validator missing: ${PHRASA_SUBMISSION_VALIDATE_REL}"
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    phrasa_blocker "python3 not found (required for Submission packet validator)"
    return 0
  fi

  # Do not toggle `set -e` here — re-enabling it would break the caller's
  # set +e wrapper around phrasa_run_preflight (non-zero return would abort).
  local out rc=0
  out="$(bash "$validator" --mode packet 2>&1)" || rc=$?

  if ((rc != 0)); then
    phrasa_blocker "submission packet --mode packet failed (exit ${rc})"
    # Surface a few ERR lines without dumping the whole report into every note.
    local err_line count=0
    while IFS= read -r err_line; do
      [[ -z "$err_line" ]] && continue
      case "$err_line" in
        ERR\ *|FAIL*|error:*|Error:*)
          phrasa_blocker "submission packet: ${err_line}"
          count=$((count + 1))
          if ((count >= 8)); then
            break
          fi
          ;;
      esac
    done <<<"$out"
    NOTES+=("submission packet --mode packet FAILED (local completeness only; not Connect state)")
    return 0
  fi

  NOTES+=("submission packet --mode packet OK (local completeness; not Connect upload/save proof)")

  rc=0
  out="$(bash "$validator" --mode release-ready 2>&1)" || rc=$?
  if ((rc != 0)); then
    phrasa_blocker "submission packet --mode release-ready failed (exit ${rc})"
    local ready_err ready_count=0
    while IFS= read -r ready_err; do
      [[ -z "$ready_err" ]] && continue
      case "$ready_err" in
        ERR\ *|FAIL*|error:*|Error:*)
          phrasa_blocker "submission release-ready: ${ready_err}"
          ready_count=$((ready_count + 1))
          if ((ready_count >= 8)); then
            break
          fi
          ;;
      esac
    done <<<"$out"
    NOTES+=("submission packet --mode release-ready FAILED (pre-archive gate; not Connect state)")
  else
    NOTES+=("submission packet --mode release-ready OK (explicit pre-archive gate; not post-upload Connect proof)")
  fi
}

phrasa_upload_blocker() {
  local msg="$1"
  UPLOAD_BLOCKERS+=("$msg")
  printf 'UPLOAD_BLOCKER: %s\n' "$msg" >&2
}

phrasa_check_worktree_clean() {
  local root="$1"
  local porcelain status_line path xy
  porcelain="$(git -C "$root" status --porcelain=v1 2>/dev/null || true)"

  while IFS= read -r status_line; do
    [[ -z "$status_line" ]] && continue
    xy="${status_line:0:2}"
    path="${status_line:3}"
    if [[ "$xy" == "??" ]]; then
      phrasa_evaluate_untracked "$path"
      continue
    fi
    phrasa_blocker "tracked worktree not clean: '$xy' $path"
  done <<<"$porcelain"
}

phrasa_evaluate_untracked() {
  local path="$1"
  path="${path%/}"

  # Numbered Finder-duplicate projects (PhrasaNative 2/3/… .xcodeproj) — never tolerate.
  case "$path" in
    ios-native/PhrasaNative\ [0-9]*.xcodeproj|ios-native/PhrasaNative\ [0-9]*.xcodeproj/*|*"PhrasaNative "[0-9]*.xcodeproj*)
      phrasa_blocker "forbidden untracked project: $path"
      return
      ;;
  esac

  local known=0
  local d
  for d in "${PHRASA_KNOWN_FINDER_DUPES[@]}"; do
    if [[ "$path" == "$d" ]]; then
      known=1
      break
    fi
  done

  if ((known)); then
    if [[ "${PHRASA_ALLOW_KNOWN_FINDER_DUPES:-0}" == "1" ]]; then
      NOTES+=("tolerating known Finder-duplicate untracked file (operator elected): $path")
    else
      phrasa_blocker "untracked known Finder duplicate present: $path (set PHRASA_ALLOW_KNOWN_FINDER_DUPES=1 to tolerate only the four source files; the fifth protected duplicate, PhrasaNative 2.xcodeproj, is never tolerated)"
    fi
    return
  fi

  phrasa_blocker "unexpected untracked path: $path (reject; only the four documented Finder source duplicates may be tolerated with PHRASA_ALLOW_KNOWN_FINDER_DUPES=1; the fifth protected project duplicate remains forbidden)"
}

# Assert resolved Phrasa *target* Release build settings via xcodebuild -showBuildSettings.
# Does not archive. Writes dump under PHRASA_RUN_DIR when set (gitignored proof path).
phrasa_check_project_settings() {
  local root="$1"
  local project="${root}/${PHRASA_PROJECT_REL}"
  local yml="${root}/ios-native/project.yml"
  local settings_file=""
  local run_dir="${PHRASA_RUN_DIR:-}"

  if [[ ! -d "$project" ]]; then
    phrasa_blocker "cannot showBuildSettings: project missing"
    return
  fi

  if ! command -v xcodebuild >/dev/null 2>&1; then
    phrasa_blocker "cannot showBuildSettings: xcodebuild missing"
    return
  fi

  if [[ -n "$run_dir" ]]; then
    settings_file="${run_dir}/phrasa-release-showBuildSettings.txt"
  else
    settings_file="$(mktemp -t phrasa-showBuildSettings.XXXXXX)"
  fi

  phrasa_info "resolving Phrasa target Release build settings (xcodebuild -showBuildSettings)…"
  # Authoritative: exact project, target, configuration, destination. No archive.
  # Do NOT pass PHRASA_SUPABASE_PUBLISHABLE_KEY here — proof dumps must never
  # retain the production publishable key (shipping injection is build/archive only).
  if ! xcodebuild -showBuildSettings \
      -project "$project" \
      -target "$PHRASA_TARGET" \
      -configuration "$PHRASA_CONFIGURATION" \
      -destination "$PHRASA_DESTINATION" \
      >"$settings_file" 2>"${settings_file}.err"; then
    phrasa_scrub_settings_dump_of_supabase_key "$settings_file"
    phrasa_redact_supabase_key_in_file "${settings_file}.err"
    phrasa_blocker "xcodebuild -showBuildSettings failed for target ${PHRASA_TARGET} ${PHRASA_CONFIGURATION} (see ${settings_file}.err)"
    return
  fi
  # Belt-and-suspenders: scrub any non-empty publishable key assignment from the dump.
  phrasa_scrub_settings_dump_of_supabase_key "$settings_file"
  phrasa_redact_supabase_key_in_file "${settings_file}.err"
  NOTES+=("showBuildSettings dump: $settings_file (Supabase publishable key not injected; scrubbed if present)")

  local mv cv team bid pname ename style excluded
  local rc

  mv="$(phrasa_build_setting_get "$settings_file" "MARKETING_VERSION")"
  rc=$?
  if [[ $rc -ne 0 || "$mv" != "$PHRASA_MARKETING_VERSION" ]]; then
    phrasa_blocker "resolved Phrasa Release MARKETING_VERSION='$mv' (expected $PHRASA_MARKETING_VERSION; rc=$rc)"
  else
    NOTES+=("resolved MARKETING_VERSION=$mv")
  fi

  cv="$(phrasa_build_setting_get "$settings_file" "CURRENT_PROJECT_VERSION")"
  rc=$?
  if [[ $rc -ne 0 || "$cv" != "$PHRASA_BUILD_NUMBER" ]]; then
    phrasa_blocker "resolved Phrasa Release CURRENT_PROJECT_VERSION='$cv' (expected $PHRASA_BUILD_NUMBER; rc=$rc)"
  else
    NOTES+=("resolved CURRENT_PROJECT_VERSION=$cv")
  fi

  bid="$(phrasa_build_setting_get "$settings_file" "PRODUCT_BUNDLE_IDENTIFIER")"
  rc=$?
  if [[ $rc -ne 0 || "$bid" != "$PHRASA_BUNDLE_ID" ]]; then
    phrasa_blocker "resolved Phrasa Release PRODUCT_BUNDLE_IDENTIFIER='$bid' (expected $PHRASA_BUNDLE_ID; rc=$rc)"
  else
    NOTES+=("resolved PRODUCT_BUNDLE_IDENTIFIER=$bid")
  fi

  team="$(phrasa_build_setting_get "$settings_file" "DEVELOPMENT_TEAM")"
  rc=$?
  if [[ $rc -ne 0 || "$team" != "$PHRASA_TEAM_ID" ]]; then
    phrasa_blocker "resolved Phrasa Release DEVELOPMENT_TEAM='$team' (expected $PHRASA_TEAM_ID; rc=$rc)"
  else
    NOTES+=("resolved DEVELOPMENT_TEAM=$team")
  fi

  pname="$(phrasa_build_setting_get "$settings_file" "PRODUCT_NAME")"
  rc=$?
  if [[ $rc -ne 0 || "$pname" != "$PHRASA_PRODUCT_NAME" ]]; then
    phrasa_blocker "resolved Phrasa Release PRODUCT_NAME='$pname' (expected $PHRASA_PRODUCT_NAME; rc=$rc)"
  else
    NOTES+=("resolved PRODUCT_NAME=$pname")
  fi

  ename="$(phrasa_build_setting_get "$settings_file" "EXECUTABLE_NAME")"
  rc=$?
  if [[ $rc -ne 0 || "$ename" != "$PHRASA_EXECUTABLE_NAME" ]]; then
    phrasa_blocker "resolved Phrasa Release EXECUTABLE_NAME='$ename' (expected $PHRASA_EXECUTABLE_NAME; rc=$rc)"
  else
    NOTES+=("resolved EXECUTABLE_NAME=$ename")
  fi

  style="$(phrasa_build_setting_get "$settings_file" "CODE_SIGN_STYLE")"
  rc=$?
  if [[ $rc -ne 0 || "$style" != "$PHRASA_CODE_SIGN_STYLE" ]]; then
    phrasa_blocker "resolved Phrasa Release CODE_SIGN_STYLE='$style' (expected $PHRASA_CODE_SIGN_STYLE; rc=$rc)"
  else
    NOTES+=("resolved CODE_SIGN_STYLE=$style")
  fi

  # Release must exclude DEBUG diagnostics source (string may include quotes/spaces)
  excluded="$(phrasa_build_setting_get "$settings_file" "EXCLUDED_SOURCE_FILE_NAMES" || true)"
  if [[ -z "$excluded" || "$excluded" != *"VoicePipelineDiagnostics.swift"* ]]; then
    phrasa_blocker "resolved Phrasa Release EXCLUDED_SOURCE_FILE_NAMES must include VoicePipelineDiagnostics.swift; got '$excluded'"
  else
    NOTES+=("resolved EXCLUDED_SOURCE_FILE_NAMES includes VoicePipelineDiagnostics.swift")
  fi

  # Secondary consistency: project.yml should still match (not a substitute for showBuildSettings)
  if [[ -f "$yml" ]]; then
    if ! grep -q "CURRENT_PROJECT_VERSION: \"${PHRASA_BUILD_NUMBER}\"" "$yml" && \
       ! grep -q "CURRENT_PROJECT_VERSION: ${PHRASA_BUILD_NUMBER}" "$yml"; then
      phrasa_blocker "project.yml CURRENT_PROJECT_VERSION is not ${PHRASA_BUILD_NUMBER}"
    fi
    if ! grep -q "MARKETING_VERSION: \"${PHRASA_MARKETING_VERSION}\"" "$yml"; then
      phrasa_blocker "project.yml MARKETING_VERSION is not ${PHRASA_MARKETING_VERSION}"
    fi
    if ! grep -q "DEVELOPMENT_TEAM: ${PHRASA_TEAM_ID}" "$yml"; then
      phrasa_blocker "project.yml DEVELOPMENT_TEAM is not ${PHRASA_TEAM_ID}"
    fi
    if ! grep -q "PRODUCT_BUNDLE_IDENTIFIER: ${PHRASA_BUNDLE_ID}" "$yml"; then
      phrasa_blocker "project.yml PRODUCT_BUNDLE_IDENTIFIER is not ${PHRASA_BUNDLE_ID}"
    fi
  else
    phrasa_blocker "project.yml missing"
  fi

  if [[ ! -f "${root}/ios-native/PhrasaNative.xcodeproj/xcshareddata/xcschemes/${PHRASA_SCHEME}.xcscheme" ]]; then
    phrasa_blocker "shared scheme missing: ${PHRASA_SCHEME}.xcscheme"
  fi
}

# Parse PrivacyInfo.xcprivacy as a plist; assert tracking=false + required reason API.
# mode is a label for messages. Uses blockers when mode is "source"; returns 1 and
# prints reasons when used from inspect (caller collects). Sets PHRASA_PRIVACY_LAST_ERRORS.
phrasa_check_privacy_manifest() {
  local privacy_path="$1"
  local mode="${2:-check}"
  local tracking api_blob reason_ok=0 type_ok=0
  PHRASA_PRIVACY_LAST_ERRORS=()

  if [[ ! -f "$privacy_path" ]]; then
    PHRASA_PRIVACY_LAST_ERRORS+=("PrivacyInfo.xcprivacy missing: $privacy_path")
    if [[ "$mode" == "source" ]]; then
      phrasa_blocker "PrivacyInfo.xcprivacy missing: $privacy_path"
    fi
    return 1
  fi

  if ! plutil -lint "$privacy_path" >/dev/null 2>&1; then
    PHRASA_PRIVACY_LAST_ERRORS+=("PrivacyInfo.xcprivacy is not a valid plist: $privacy_path")
    if [[ "$mode" == "source" ]]; then
      phrasa_blocker "PrivacyInfo.xcprivacy is not a valid plist"
    fi
    return 1
  fi

  tracking="$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' "$privacy_path" 2>/dev/null || echo missing)"
  # PlistBuddy prints true/false for booleans
  if [[ "$tracking" != "false" && "$tracking" != "0" ]]; then
    PHRASA_PRIVACY_LAST_ERRORS+=("NSPrivacyTracking must be false, got '$tracking'")
    if [[ "$mode" == "source" ]]; then
      phrasa_blocker "PrivacyInfo NSPrivacyTracking must be false, got '$tracking'"
    fi
  else
    if [[ "$mode" == "source" ]]; then
      NOTES+=("PrivacyInfo NSPrivacyTracking=false ($mode)")
    fi
  fi

  # Required reason API: UserDefaults CA92.1
  api_blob="$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes' "$privacy_path" 2>/dev/null || true)"
  if printf '%s' "$api_blob" | grep -Fq "$PHRASA_PRIVACY_REQUIRED_API_TYPE"; then
    type_ok=1
  fi
  if printf '%s' "$api_blob" | grep -Fq "$PHRASA_PRIVACY_REQUIRED_API_REASON"; then
    reason_ok=1
  fi
  if ((type_ok == 0)); then
    PHRASA_PRIVACY_LAST_ERRORS+=("PrivacyInfo missing required API type $PHRASA_PRIVACY_REQUIRED_API_TYPE")
    if [[ "$mode" == "source" ]]; then
      phrasa_blocker "PrivacyInfo missing required API type $PHRASA_PRIVACY_REQUIRED_API_TYPE"
    fi
  fi
  if ((reason_ok == 0)); then
    PHRASA_PRIVACY_LAST_ERRORS+=("PrivacyInfo missing required API reason $PHRASA_PRIVACY_REQUIRED_API_REASON")
    if [[ "$mode" == "source" ]]; then
      phrasa_blocker "PrivacyInfo missing required API reason $PHRASA_PRIVACY_REQUIRED_API_REASON"
    fi
  fi

  if ((${#PHRASA_PRIVACY_LAST_ERRORS[@]} > 0)); then
    return 1
  fi
  return 0
}

# Expected App Store application-identifier (team + bundle, exact).
phrasa_expected_application_identifier() {
  printf '%s.%s' "${PHRASA_TEAM_ID}" "${PHRASA_BUNDLE_ID}"
}

# Both roots Xcode may use (modern Xcode 16+/26, legacy MobileDevice).
# Override with PHRASA_PROVISIONING_PROFILE_ROOTS (newline-separated) for tests.
phrasa_provisioning_profile_roots() {
  if [[ -n "${PHRASA_PROVISIONING_PROFILE_ROOTS:-}" ]]; then
    printf '%s\n' "${PHRASA_PROVISIONING_PROFILE_ROOTS}"
    return 0
  fi
  printf '%s\n' \
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles" \
    "${HOME}/Library/MobileDevice/Provisioning Profiles"
}

# Convert profile ExpirationDate (plutil raw) to epoch seconds. Prints epoch or fails.
phrasa_profile_expiration_epoch() {
  local exp="$1"
  local epoch
  if [[ -z "$exp" || "$exp" == "unknown" ]]; then
    return 1
  fi
  # Common plutil raw form: 2027-07-17T23:11:26Z
  if epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$exp" "+%s" 2>/dev/null)"; then
    printf '%s' "$epoch"
    return 0
  fi
  # Alternate: 2027-07-17 23:11:26 +0000
  if epoch="$(date -j -u -f "%Y-%m-%d %H:%M:%S %z" "$exp" "+%s" 2>/dev/null)"; then
    printf '%s' "$epoch"
    return 0
  fi
  # Strip fractional seconds if present: 2027-07-17T23:11:26.123Z
  local trimmed="${exp%%.*}"
  if [[ "$trimmed" != "$exp" ]]; then
    if [[ "$exp" == *Z ]]; then
      trimmed="${trimmed}Z"
    fi
    if epoch="$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$trimmed" "+%s" 2>/dev/null)"; then
      printf '%s' "$epoch"
      return 0
    fi
  fi
  return 1
}

# Classify distribution kind from decoded profile metadata (no secrets).
# Sets: PHRASA_PROF_KIND = appstore|development|adhoc|enterprise|unknown
phrasa_classify_profile_kind() {
  local get_task_allow="$1" has_devices="$2" provisions_all="$3"
  if [[ "$provisions_all" == "true" || "$provisions_all" == "1" || "$provisions_all" == "YES" ]]; then
    PHRASA_PROF_KIND="enterprise"
    return 0
  fi
  if ((has_devices)); then
    if [[ "$get_task_allow" == "true" || "$get_task_allow" == "1" || "$get_task_allow" == "YES" ]]; then
      PHRASA_PROF_KIND="development"
    else
      PHRASA_PROF_KIND="adhoc"
    fi
    return 0
  fi
  if [[ "$get_task_allow" == "true" || "$get_task_allow" == "1" || "$get_task_allow" == "YES" ]]; then
    PHRASA_PROF_KIND="development"
    return 0
  fi
  # App Store: no ProvisionedDevices, ProvisionsAllDevices not true, get-task-allow false/absent
  PHRASA_PROF_KIND="appstore"
  return 0
}

# Evaluate a decoded provisioning profile plist (XML/binary). Never prints payload.
# Populates PHRASA_PROF_* globals:
#   NAME, TEAM, APP_ID, EXPIRATION, KIND, MATCH (0|1), REASON
# Returns 0 always (evaluation completed); MATCH indicates hard-gate clearance for this file.
phrasa_evaluate_decoded_provisioning_profile() {
  local plist="$1"
  local expected_app_id
  expected_app_id="$(phrasa_expected_application_identifier)"

  PHRASA_PROF_NAME="unknown"
  PHRASA_PROF_TEAM="unknown"
  PHRASA_PROF_APP_ID="unknown"
  PHRASA_PROF_EXPIRATION="unknown"
  PHRASA_PROF_KIND="unknown"
  PHRASA_PROF_MATCH=0
  PHRASA_PROF_REASON="unreadable"

  if [[ -z "$plist" || ! -f "$plist" ]]; then
    PHRASA_PROF_REASON="unreadable_missing_plist"
    return 0
  fi
  if ! plutil -lint "$plist" >/dev/null 2>&1; then
    PHRASA_PROF_REASON="unreadable_invalid_plist"
    return 0
  fi

  PHRASA_PROF_NAME="$(plutil -extract Name raw -o - "$plist" 2>/dev/null || echo unknown)"
  PHRASA_PROF_TEAM="$(plutil -extract TeamIdentifier.0 raw -o - "$plist" 2>/dev/null || echo unknown)"
  PHRASA_PROF_APP_ID="$(plutil -extract Entitlements.application-identifier raw -o - "$plist" 2>/dev/null || echo unknown)"
  PHRASA_PROF_EXPIRATION="$(plutil -extract ExpirationDate raw -o - "$plist" 2>/dev/null || echo unknown)"

  local get_task_allow="false"
  get_task_allow="$(plutil -extract Entitlements.get-task-allow raw -o - "$plist" 2>/dev/null || echo false)"

  local has_devices=0
  if plutil -extract ProvisionedDevices raw -o - "$plist" >/dev/null 2>&1; then
    has_devices=1
  fi

  local provisions_all="false"
  provisions_all="$(plutil -extract ProvisionsAllDevices raw -o - "$plist" 2>/dev/null || echo false)"

  phrasa_classify_profile_kind "$get_task_allow" "$has_devices" "$provisions_all"

  if [[ "$PHRASA_PROF_TEAM" != "$PHRASA_TEAM_ID" ]]; then
    PHRASA_PROF_REASON="team_mismatch"
    return 0
  fi
  if [[ "$PHRASA_PROF_APP_ID" != "$expected_app_id" ]]; then
    PHRASA_PROF_REASON="app_id_mismatch"
    return 0
  fi
  if [[ "$PHRASA_PROF_KIND" != "appstore" ]]; then
    PHRASA_PROF_REASON="not_app_store_${PHRASA_PROF_KIND}"
    return 0
  fi

  local exp_epoch now_epoch
  if ! exp_epoch="$(phrasa_profile_expiration_epoch "$PHRASA_PROF_EXPIRATION")"; then
    PHRASA_PROF_REASON="expiration_unparseable"
    return 0
  fi
  now_epoch="$(date -u +%s)"
  if ! ((exp_epoch > now_epoch)); then
    PHRASA_PROF_REASON="expired"
    return 0
  fi

  PHRASA_PROF_MATCH=1
  PHRASA_PROF_REASON="exact_appstore_match"
  return 0
}

# Decode a profile file to a temporary plist path printed on stdout (caller deletes).
# Uses security cms -D; never prints decoded body to the console.
phrasa_decode_provisioning_profile_to_temp() {
  local src="$1"
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/phrasa-prov-XXXXXX.plist")" || return 1
  if ! security cms -D -i "$src" >"$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 1
  fi
  printf '%s' "$tmp"
  return 0
}

# Audit both provisioning roots. Hard blocker only when no exact valid App Store match.
# Logs non-secret metadata only. Independent of Apple Distribution identity.
phrasa_audit_provisioning_profiles() {
  local expected_app_id count match
  expected_app_id="$(phrasa_expected_application_identifier)"
  count=0
  match=0

  local root
  while IFS= read -r root; do
    [[ -z "$root" ]] && continue
    if [[ ! -d "$root" ]]; then
      NOTES+=("provisioning root absent: $root")
      continue
    fi
    NOTES+=("provisioning root present: $root")

    local p bas decoded
    # Any regular file — Xcode may use .mobileprovision or other extensions.
    while IFS= read -r p; do
      [[ -z "$p" ]] && continue
      [[ -f "$p" ]] || continue
      # Skip directories / non-regular
      [[ -L "$p" && ! -f "$p" ]] && continue
      count=$((count + 1))
      bas="$(basename "$p")"

      decoded=""
      if ! decoded="$(phrasa_decode_provisioning_profile_to_temp "$p")"; then
        NOTES+=("provisioning profile: source='$root' file='$bas' status=unreadable reason=cms_decode_failed")
        continue
      fi

      phrasa_evaluate_decoded_provisioning_profile "$decoded"
      rm -f "$decoded"

      NOTES+=("provisioning profile: source='$root' file='$bas' name='${PHRASA_PROF_NAME}' team='${PHRASA_PROF_TEAM}' app_id='${PHRASA_PROF_APP_ID}' kind='${PHRASA_PROF_KIND}' expiration='${PHRASA_PROF_EXPIRATION}' match=${PHRASA_PROF_MATCH} reason=${PHRASA_PROF_REASON}")

      if ((PHRASA_PROF_MATCH == 1)); then
        match=1
      fi
    done < <(find "$root" -maxdepth 1 -type f ! -name '.*' 2>/dev/null | LC_ALL=C sort || true)
  done < <(phrasa_provisioning_profile_roots)

  NOTES+=("provisioning_profile_count=$count")
  NOTES+=("provisioning_profile_exact_appstore_match=$match")
  NOTES+=("provisioning_expected team=${PHRASA_TEAM_ID} application-identifier=${expected_app_id}")

  if ((count == 0)); then
    phrasa_blocker "no provisioning profiles installed under modern (~/Library/Developer/Xcode/UserData/Provisioning Profiles) or legacy (~/Library/MobileDevice/Provisioning Profiles) roots (archive/export may still attempt -allowProvisioningUpdates; not guaranteed)"
  elif ((match == 0)); then
    phrasa_blocker "no installed App Store provisioning profile exactly matches team ${PHRASA_TEAM_ID} application-identifier ${expected_app_id} (unexpired, get-task-allow false, no ProvisionedDevices, not enterprise)"
  fi
}

phrasa_audit_signing_metadata() {
  local has_dist=0 has_dev=0
  local identity_out
  identity_out="$(security find-identity -v -p codesigning 2>/dev/null || true)"

  # Apple Distribution identity is an independent hard blocker — a valid profile
  # must never mask a missing distribution certificate/identity.
  if printf '%s\n' "$identity_out" | grep -q 'Apple Distribution'; then
    has_dist=1
    while IFS= read -r line; do
      NOTES+=("codesign identity: $(echo "$line" | sed -E 's/.*"([^"]+)".*/\1/')")
    done < <(printf '%s\n' "$identity_out" | grep 'Apple Distribution')
  else
    phrasa_blocker "no Apple Distribution identity in keychain (required for App Store export/upload)"
  fi

  if printf '%s\n' "$identity_out" | grep -q 'Apple Development'; then
    has_dev=1
    NOTES+=("Apple Development identity present (dev only; not sufficient for App Store upload)")
  fi

  phrasa_audit_provisioning_profiles

  local key_found=0
  local dir f base
  for dir in "${HOME}/.appstoreconnect/private_keys" "${HOME}/private_keys" "${HOME}/.private_keys"; do
    if [[ -d "$dir" ]]; then
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        base="$(basename "$f")"
        if [[ "$base" =~ ^AuthKey_[A-Z0-9]+\.p8$ ]]; then
          key_found=1
          NOTES+=("ASC API key file present (name only): $dir/$base")
        else
          NOTES+=("nonstandard key-like file ignored: $dir/$base")
        fi
      done < <(find "$dir" -maxdepth 1 -name 'AuthKey_*.p8' 2>/dev/null || true)
    fi
  done

  if [[ -n "${ASC_KEY_ID:-}" ]]; then
    NOTES+=("ASC_KEY_ID env is set (value not printed)")
    local expected_name="AuthKey_${ASC_KEY_ID}.p8"
    local found_named=0
    for dir in "${HOME}/.appstoreconnect/private_keys" "${HOME}/private_keys" "${HOME}/.private_keys"; do
      if [[ -f "$dir/$expected_name" ]]; then
        found_named=1
        NOTES+=("ASC key file for ASC_KEY_ID present by name: $expected_name")
      fi
    done
    if ((found_named == 0)); then
      phrasa_upload_blocker "ASC_KEY_ID set but AuthKey_\${ASC_KEY_ID}.p8 not found in standard private_keys directories"
    fi
  else
    NOTES+=("ASC_KEY_ID env not set")
    phrasa_upload_blocker "ASC_KEY_ID env not set (required for --validate/--upload)"
  fi

  if [[ -n "${ASC_ISSUER_ID:-}" ]]; then
    NOTES+=("ASC_ISSUER_ID env is set (value not printed)")
  else
    NOTES+=("ASC_ISSUER_ID env not set")
    phrasa_upload_blocker "ASC_ISSUER_ID env not set (required for --validate/--upload)"
  fi

  if ((key_found == 0)); then
    phrasa_upload_blocker "no App Store Connect API key file (AuthKey_*.p8) found in standard locations; validate/upload unavailable"
  fi

  NOTES+=("upload/validate not claimed ready unless UPLOAD_BLOCKERS is empty")

  if xcrun --find altool >/dev/null 2>&1; then
    NOTES+=("xcrun altool available")
  else
    phrasa_upload_blocker "xcrun altool not found (validation/upload path unavailable)"
  fi
}
