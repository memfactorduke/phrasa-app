# shellcheck shell=bash
# Test + build + archive + export steps for gated release path.
# Always runs package tests and iOS XCTest — no production skip hatch.

phrasa_pick_ios_simulator_destination() {
  # Use the first concrete iPhone simulator reported by this Xcode install.
  # Simulator display names are user-defined and change across Xcode releases,
  # so bind to the stable UDID instead of assuming a stock "iPhone 16" exists.
  local dest
  dest="$(xcodebuild -showdestinations -project "$1" -scheme "$PHRASA_SCHEME" 2>/dev/null \
    | grep -E 'platform:iOS Simulator' \
    | grep -E 'name:[^,}]*iPhone' \
    | grep -E 'id:[0-9A-Fa-f-]+' \
    | head -1 \
    | sed -E 's/.*id:([^,}]+).*/id=\1/' || true)"
  if [[ -n "$dest" && "$dest" == id=* ]]; then
    printf 'platform=iOS Simulator,%s' "$dest"
    return 0
  fi
  phrasa_die "no concrete iPhone simulator is available for release XCTest"
}

phrasa_run_package_tests() {
  local root="$1"
  local log_file="$2"
  local pkg
  # PhrasaSync is part of the shipping app and includes the Supabase adapter.
  # Keep it in the fail-closed release matrix with the foundational packages.
  for pkg in PhrasaCore PhrasaDomain PhrasaPersistence PhrasaSync; do
    phrasa_info "swift test --package-path Packages/${pkg}"
    if ! phrasa_tee_log "$log_file" \
      swift test --package-path "${root}/ios-native/Packages/${pkg}" --parallel; then
      phrasa_die "package tests failed: $pkg (see $log_file)"
    fi
  done
}

phrasa_run_ios_xctest() {
  local root="$1"
  local derived="$2"
  local result_bundle="$3"
  local log_file="$4"
  local project="${root}/${PHRASA_PROJECT_REL}"
  local dest
  local result_parent

  # Ensure result bundle parent exists (xcodebuild does not always create it).
  result_parent="$(dirname "$result_bundle")"
  phrasa_ensure_dir "$result_parent"
  # Remove stale result bundle only if under PHRASA_RUN_DIR
  if [[ -e "$result_bundle" && -n "${PHRASA_RUN_DIR:-}" ]]; then
    phrasa_safe_rm_rf "$result_bundle" "$PHRASA_RUN_DIR"
  fi

  dest="$(phrasa_pick_ios_simulator_destination "$project")"
  phrasa_info "xcodebuild test destination=$dest"
  if ! phrasa_tee_log "$log_file" \
    xcodebuild test \
      -project "$project" \
      -scheme "$PHRASA_SCHEME" \
      -destination "$dest" \
      -derivedDataPath "$derived" \
      -resultBundlePath "$result_bundle" \
      CODE_SIGNING_ALLOWED=YES; then
    phrasa_die "iOS XCTest suite failed (see $log_file)"
  fi
}

# Build-setting override for shipping Phrasa Release build/archive only.
# Does not print the key. Caller must already have required a valid key.
phrasa_shipping_supabase_key_build_setting() {
  local key
  key="$(phrasa_trim "${PHRASA_SUPABASE_PUBLISHABLE_KEY-}")"
  if [[ -z "$key" ]]; then
    phrasa_die "internal: shipping xcodebuild invoked without PHRASA_SUPABASE_PUBLISHABLE_KEY"
  fi
  # Single KEY=value token for xcodebuild; never echo this return value in logs.
  printf 'PHRASA_SUPABASE_PUBLISHABLE_KEY=%s' "$key"
}

phrasa_run_release_build() {
  local root="$1"
  local derived="$2"
  local log_file="$3"
  local project="${root}/${PHRASA_PROJECT_REL}"
  local key_setting
  key_setting="$(phrasa_shipping_supabase_key_build_setting)"
  phrasa_info "Release generic-device build (no archive yet; Supabase publishable key injected as build setting, value not printed)"
  if ! phrasa_tee_log "$log_file" \
    xcodebuild build \
      -project "$project" \
      -scheme "$PHRASA_SCHEME" \
      -configuration "$PHRASA_CONFIGURATION" \
      -destination "$PHRASA_DESTINATION" \
      -derivedDataPath "$derived" \
      -allowProvisioningUpdates \
      "${key_setting}"; then
    phrasa_redact_supabase_key_in_file "$log_file"
    phrasa_die "Release generic-device build failed (see $log_file)"
  fi
  phrasa_redact_supabase_key_in_file "$log_file"
}

phrasa_run_archive() {
  local root="$1"
  local archive_path="$2"
  local derived="$3"
  local log_file="$4"
  local project="${root}/${PHRASA_PROJECT_REL}"
  local run_dir="${PHRASA_RUN_DIR:-}"
  local key_setting
  key_setting="$(phrasa_shipping_supabase_key_build_setting)"

  phrasa_info "archiving to $archive_path (Supabase publishable key injected as build setting, value not printed)"
  if [[ -z "$run_dir" ]]; then
    phrasa_die "PHRASA_RUN_DIR unset; refusing archive cleanup outside a unique run directory"
  fi
  if [[ -e "$archive_path" ]]; then
    phrasa_safe_rm_rf "$archive_path" "$run_dir"
  fi
  # Ensure parent of archive exists inside run dir
  phrasa_ensure_dir "$(dirname "$archive_path")"

  if ! phrasa_tee_log "$log_file" \
    xcodebuild archive \
      -project "$project" \
      -scheme "$PHRASA_SCHEME" \
      -configuration "$PHRASA_CONFIGURATION" \
      -destination "$PHRASA_DESTINATION" \
      -archivePath "$archive_path" \
      -derivedDataPath "$derived" \
      -allowProvisioningUpdates \
      "${key_setting}"; then
    phrasa_redact_supabase_key_in_file "$log_file"
    phrasa_die "archive failed (see $log_file)"
  fi
  phrasa_redact_supabase_key_in_file "$log_file"
}

# Export archive to IPA. Logs stay on the normal stdout/stderr path (and tee log).
# Does NOT print the IPA path on stdout (callers must not capture the function).
# On success sets PHRASA_EXPORTED_IPA_PATH to the single validated IPA path.
phrasa_run_export() {
  local archive_path="$1"
  local export_path="$2"
  local export_options="$3"
  local log_file="$4"
  local run_dir="${PHRASA_RUN_DIR:-}"
  local ipa_count ipa_path

  # Clear any stale value so callers cannot read a previous run's path on failure.
  PHRASA_EXPORTED_IPA_PATH=""

  phrasa_info "exporting archive to $export_path"
  if [[ -z "$run_dir" ]]; then
    phrasa_die "PHRASA_RUN_DIR unset; refusing export cleanup outside a unique run directory"
  fi
  if [[ -e "$export_path" ]]; then
    phrasa_safe_rm_rf "$export_path" "$run_dir"
  fi
  phrasa_ensure_dir "$export_path"

  if ! phrasa_tee_log "$log_file" \
    xcodebuild -exportArchive \
      -archivePath "$archive_path" \
      -exportPath "$export_path" \
      -exportOptionsPlist "$export_options" \
      -allowProvisioningUpdates; then
    phrasa_die "exportArchive failed (see $log_file)"
  fi

  # Discover IPA via filesystem only — never parse export log/stdout for the path.
  ipa_count="$(find "$export_path" -maxdepth 1 -name '*.ipa' -type f | wc -l | tr -d ' ')"
  if [[ "$ipa_count" != "1" ]]; then
    phrasa_die "expected exactly one IPA in $export_path, found $ipa_count"
  fi
  ipa_path="$(find "$export_path" -maxdepth 1 -name '*.ipa' -type f | head -1)"
  if [[ -z "$ipa_path" || ! -f "$ipa_path" ]]; then
    phrasa_die "IPA discovery failed under $export_path"
  fi
  # Paths must be single-line absolute (no log contamination possible via this channel).
  case "$ipa_path" in
    *$'\n'*|*$'\r'*)
      phrasa_die "IPA path contains newline; refusing contaminated path"
      ;;
  esac
  if [[ "$ipa_path" != /* ]]; then
    ipa_path="$(phrasa_abspath "$ipa_path")"
  fi
  if [[ ! -f "$ipa_path" ]]; then
    phrasa_die "validated IPA path is not a regular file: $ipa_path"
  fi

  PHRASA_EXPORTED_IPA_PATH="$ipa_path"
  phrasa_info "exported_ipa=$PHRASA_EXPORTED_IPA_PATH"
}

# Validate IPA via altool (requires ASC_KEY_ID + ASC_ISSUER_ID; never prints key contents).
phrasa_run_validate() {
  local ipa_path="$1"
  local log_file="$2"
  if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
    phrasa_die "validation requires ASC_KEY_ID and ASC_ISSUER_ID env vars (private key looked up by convention; never pass .p8 contents)"
  fi
  local key_file=""
  local dir
  for dir in "${HOME}/.appstoreconnect/private_keys" "${HOME}/private_keys" "${HOME}/.private_keys"; do
    if [[ -f "${dir}/AuthKey_${ASC_KEY_ID}.p8" ]]; then
      key_file="${dir}/AuthKey_${ASC_KEY_ID}.p8"
      break
    fi
  done
  if [[ -z "$key_file" ]]; then
    phrasa_die "AuthKey_${ASC_KEY_ID}.p8 not found in standard private_keys directories (filename check only)"
  fi
  NOTES+=("using API key file by name only: $(basename "$key_file")")
  phrasa_info "validating IPA with altool (apiKey by id; p8 not read by this script)"
  if ! phrasa_tee_log "$log_file" \
    xcrun altool --validate-app \
      --type ios \
      --file "$ipa_path" \
      --apiKey "$ASC_KEY_ID" \
      --apiIssuer "$ASC_ISSUER_ID"; then
    phrasa_die "altool validate-app failed (see $log_file)"
  fi
}

phrasa_run_upload() {
  local ipa_path="$1"
  local log_file="$2"
  if [[ -z "${ASC_KEY_ID:-}" || -z "${ASC_ISSUER_ID:-}" ]]; then
    phrasa_die "upload requires ASC_KEY_ID and ASC_ISSUER_ID"
  fi
  local key_file=""
  local dir
  for dir in "${HOME}/.appstoreconnect/private_keys" "${HOME}/private_keys" "${HOME}/.private_keys"; do
    if [[ -f "${dir}/AuthKey_${ASC_KEY_ID}.p8" ]]; then
      key_file="${dir}/AuthKey_${ASC_KEY_ID}.p8"
      break
    fi
  done
  if [[ -z "$key_file" ]]; then
    phrasa_die "AuthKey_${ASC_KEY_ID}.p8 not found (filename check only)"
  fi
  phrasa_info "uploading IPA with altool (apiKey by id; p8 not read by this script)"
  if ! phrasa_tee_log "$log_file" \
    xcrun altool --upload-app \
      --type ios \
      --file "$ipa_path" \
      --apiKey "$ASC_KEY_ID" \
      --apiIssuer "$ASC_ISSUER_ID"; then
    phrasa_die "altool upload-app failed (see $log_file)"
  fi
}
