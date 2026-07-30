# shellcheck shell=bash
# Archive and IPA inspection helpers (fail-closed).
# Archive: prove team identity via codesign and/or embedded profile; reject ad-hoc.
# IPA: require Apple Distribution + matching TeamIdentifier (App Store path).

# Collect team ID from codesign -dvvv output (TeamIdentifier=...).
phrasa_codesign_team() {
  local subject="$1"
  local cs_out team
  cs_out="$(codesign -dvvv "$subject" 2>&1 || true)"
  team="$(printf '%s\n' "$cs_out" | awk -F= '/^TeamIdentifier=/ {print $2; exit}' | tr -d '[:space:]')"
  printf '%s' "$team"
}

# True if codesign output indicates ad-hoc signing.
phrasa_codesign_is_adhoc() {
  local cs_out="$1"
  if printf '%s\n' "$cs_out" | grep -Eqi 'Signature=adhoc|flags=0x2\(adhoc\)|flags=0x2 \(adhoc\)'; then
    return 0
  fi
  # Empty TeamIdentifier with no Authority lines is also ad-hoc-like
  if ! printf '%s\n' "$cs_out" | grep -q 'Authority='; then
    if ! printf '%s\n' "$cs_out" | grep -q 'TeamIdentifier='; then
      return 0
    fi
  fi
  return 1
}

# True if Apple Distribution appears in Authority chain.
phrasa_codesign_has_distribution() {
  local cs_out="$1"
  printf '%s\n' "$cs_out" | grep -q 'Authority=Apple Distribution'
}

# True if only Apple Development (no Distribution) appears.
phrasa_codesign_development_only() {
  local cs_out="$1"
  if printf '%s\n' "$cs_out" | grep -q 'Authority=Apple Development'; then
    if ! phrasa_codesign_has_distribution "$cs_out"; then
      return 0
    fi
  fi
  return 1
}

phrasa_team_from_embedded_profile() {
  local emb="$1"
  if [[ ! -f "$emb" ]]; then
    return 1
  fi
  security cms -D -i "$emb" 2>/dev/null | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null
}

# Check executable for forbidden DEBUG diagnostic identifiers.
phrasa_check_release_binary_strings() {
  local exe="$1"
  local label="$2"
  local s
  local found=0
  for s in "${PHRASA_RELEASE_FORBIDDEN_STRINGS[@]}"; do
    if strings "$exe" 2>/dev/null | grep -F -q -- "$s"; then
      printf 'BLOCKER: %s executable contains forbidden DEBUG diagnostic string: %s\n' "$label" "$s"
      found=1
    fi
  done
  return $found
}

phrasa_inspect_archive() {
  local archive_path="$1"
  local log_file="${2:-/dev/null}"
  local app_path info_plist app_info exe privacy
  local blockers=()
  local inspect_rc=0

  {
    echo "=== inspect archive: $archive_path ==="
    if [[ ! -d "$archive_path" ]]; then
      echo "archive missing"
      inspect_rc=1
    else
      info_plist="${archive_path}/Info.plist"
      if [[ ! -f "$info_plist" ]]; then
        blockers+=("archive Info.plist missing")
      else
        plutil -p "$info_plist" | head -40 || true
      fi

      app_path="$(find "${archive_path}/Products/Applications" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -1)"
      if [[ -z "$app_path" || ! -d "$app_path" ]]; then
        blockers+=("no .app in archive Products/Applications")
      else
        echo "app_path=$app_path"
        app_info="${app_path}/Info.plist"
        local short ver bid enc
        short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_info" 2>/dev/null || true)"
        ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_info" 2>/dev/null || true)"
        bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_info" 2>/dev/null || true)"
        enc="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$app_info" 2>/dev/null || echo missing)"
        echo "CFBundleShortVersionString=$short"
        echo "CFBundleVersion=$ver"
        echo "CFBundleIdentifier=$bid"
        echo "ITSAppUsesNonExemptEncryption=$enc"

        [[ "$short" == "$PHRASA_MARKETING_VERSION" ]] || blockers+=("archive app marketing version '$short' != $PHRASA_MARKETING_VERSION")
        [[ "$ver" == "$PHRASA_BUILD_NUMBER" ]] || blockers+=("archive app build '$ver' != $PHRASA_BUILD_NUMBER")
        [[ "$bid" == "$PHRASA_BUNDLE_ID" ]] || blockers+=("archive app bundle id '$bid' != $PHRASA_BUNDLE_ID")
        if [[ "$enc" != "false" && "$enc" != "0" ]]; then
          blockers+=("ITSAppUsesNonExemptEncryption must be false, got '$enc'")
        fi

        local ename
        ename="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_info" 2>/dev/null || echo Phrasa)"
        exe="${app_path}/${ename}"
        if [[ ! -f "$exe" ]]; then
          blockers+=("app executable missing")
        else
          echo "executable=$exe"
          local s
          for s in "${PHRASA_RELEASE_FORBIDDEN_STRINGS[@]}"; do
            if strings "$exe" 2>/dev/null | grep -F -q -- "$s"; then
              blockers+=("Release executable contains forbidden DEBUG diagnostic string: $s")
            fi
          done
        fi

        privacy="${app_path}/PrivacyInfo.xcprivacy"
        if [[ ! -f "$privacy" ]]; then
          privacy="$(find "$app_path" -name 'PrivacyInfo.xcprivacy' 2>/dev/null | head -1)"
        fi
        if [[ -z "$privacy" || ! -f "$privacy" ]]; then
          blockers+=("PrivacyInfo.xcprivacy missing from app bundle")
        else
          echo "privacy_manifest=$privacy"
          if ! phrasa_check_privacy_manifest "$privacy" "archive"; then
            local pe
            for pe in "${PHRASA_PRIVACY_LAST_ERRORS[@]+"${PHRASA_PRIVACY_LAST_ERRORS[@]}"}"; do
              blockers+=("archive $pe")
            done
          fi
        fi

        local r
        for r in OFL.txt AtkinsonHyperlegible-Regular.ttf; do
          if [[ ! -f "${app_path}/${r}" ]] && ! find "$app_path" -name "$r" 2>/dev/null | grep -q .; then
            blockers+=("required resource missing from app: $r")
          else
            echo "resource_ok=$r"
          fi
        done

        # --- Signing / team identity (archive) ---
        # Xcode .xcarchive often retains Development signing until export re-signs
        # for App Store. We still require a real team identity and reject ad-hoc.
        # Apple Distribution is enforced on the exported IPA, not the archive.
        local cs_out team_cs team_prof emb
        cs_out="$(codesign -dvvv "$app_path" 2>&1 || true)"
        echo "--- codesign (archive app) ---"
        printf '%s\n' "$cs_out" | grep -E 'Authority|TeamIdentifier|Signature|Identifier|flags=' || true

        if phrasa_codesign_is_adhoc "$cs_out"; then
          blockers+=("archive app is ad-hoc signed; reject (need team-signed archive for App Store path)")
        fi

        team_cs="$(printf '%s\n' "$cs_out" | awk -F= '/^TeamIdentifier=/ {print $2; exit}' | tr -d '[:space:]')"
        emb="${app_path}/embedded.mobileprovision"
        team_prof=""
        if [[ -f "$emb" ]]; then
          team_prof="$(phrasa_team_from_embedded_profile "$emb" || true)"
          echo "embedded.mobileprovision present; team=$team_prof"
        else
          echo "embedded.mobileprovision absent in archive app (common before export; team must still come from codesign)"
        fi

        if [[ -n "$team_cs" && "$team_cs" != "not set" && "$team_cs" != "-" ]]; then
          echo "codesign TeamIdentifier=$team_cs"
          if [[ "$team_cs" != "$PHRASA_TEAM_ID" ]]; then
            blockers+=("archive codesign TeamIdentifier '$team_cs' != $PHRASA_TEAM_ID")
          fi
        elif [[ -n "$team_prof" ]]; then
          echo "team from embedded profile only: $team_prof"
          if [[ "$team_prof" != "$PHRASA_TEAM_ID" ]]; then
            blockers+=("archive embedded.mobileprovision team '$team_prof' != $PHRASA_TEAM_ID")
          fi
        else
          blockers+=("archive team identity unproven: codesign TeamIdentifier missing/unset and embedded.mobileprovision absent or unreadable")
        fi

        if [[ -n "$team_cs" && -n "$team_prof" && "$team_cs" != "$team_prof" ]]; then
          blockers+=("archive codesign team '$team_cs' disagrees with embedded profile team '$team_prof'")
        fi

        if phrasa_codesign_development_only "$cs_out"; then
          echo "NOTE: archive is Development-signed only — expected for many Xcode archives; IPA must re-sign with Apple Distribution"
        fi
        if phrasa_codesign_has_distribution "$cs_out"; then
          echo "NOTE: archive already has Apple Distribution authority"
        fi

        # --- Shipping cloud Info.plist (URL exact production; key present + safe) ---
        # Never print the publishable key value.
        echo "--- shipping cloud Info.plist (archive) ---"
        local cloud_out cloud_line
        cloud_out="$(phrasa_assert_shipping_cloud_info_plist "$app_info" "archive" 2>&1 || true)"
        while IFS= read -r cloud_line; do
          [[ -z "$cloud_line" ]] && continue
          case "$cloud_line" in
            CLOUD_BLOCKER:*)
              blockers+=("${cloud_line#CLOUD_BLOCKER:}")
              echo "BLOCKER: ${cloud_line#CLOUD_BLOCKER:}"
              ;;
            CLOUD_OK)
              echo "cloud_info_plist=OK"
              ;;
            *)
              echo "$cloud_line"
              ;;
          esac
        done <<<"$cloud_out"
      fi
    fi

    if ((${#blockers[@]} > 0)); then
      echo "ARCHIVE_INSPECT_FAIL"
      local b
      for b in "${blockers[@]}"; do
        echo "BLOCKER: $b"
      done
      inspect_rc=1
    else
      echo "ARCHIVE_INSPECT_OK"
      inspect_rc=0
    fi
  } | tee -a "$log_file"
  # PIPESTATUS[0] is the pipeline's first command ({...}); with tee, use the
  # captured inspect_rc via a side file when needed. Prefer PIPESTATUS if the
  # compound group return propagates — on bash 3.2 the group's return is lost
  # through the pipe, so re-scan the log for FAIL marker as fail-closed backup.
  if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
    return 1
  fi
  if grep -q 'ARCHIVE_INSPECT_FAIL' "$log_file" 2>/dev/null; then
    return 1
  fi
  if ! grep -q 'ARCHIVE_INSPECT_OK' "$log_file" 2>/dev/null; then
    return 1
  fi
  return 0
}

phrasa_inspect_ipa() {
  local ipa_path="$1"
  local work_dir="$2"
  local log_file="${3:-/dev/null}"
  local blockers=()
  local unpack="${work_dir}/ipa_unpack"
  local run_dir="${PHRASA_RUN_DIR:-$work_dir}"

  {
    echo "=== inspect IPA: $ipa_path ==="
    if [[ ! -f "$ipa_path" ]]; then
      echo "IPA missing"
      echo "IPA_INSPECT_FAIL"
    else
      # Safe cleanup of unpack dir: must be under run/work dir
      if [[ -e "$unpack" ]]; then
        phrasa_safe_rm_rf "$unpack" "$run_dir"
      fi
      mkdir -p "$unpack"
      unzip -q "$ipa_path" -d "$unpack"

      local app_path
      app_path="$(find "${unpack}/Payload" -maxdepth 1 -name '*.app' -type d 2>/dev/null | head -1)"
      if [[ -z "$app_path" ]]; then
        blockers+=("IPA has no Payload/*.app")
      else
        local app_info short ver bid enc
        app_info="${app_path}/Info.plist"
        short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_info" 2>/dev/null || true)"
        ver="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app_info" 2>/dev/null || true)"
        bid="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_info" 2>/dev/null || true)"
        enc="$(/usr/libexec/PlistBuddy -c 'Print :ITSAppUsesNonExemptEncryption' "$app_info" 2>/dev/null || echo missing)"
        echo "ipa CFBundleShortVersionString=$short"
        echo "ipa CFBundleVersion=$ver"
        echo "ipa CFBundleIdentifier=$bid"
        echo "ipa ITSAppUsesNonExemptEncryption=$enc"

        [[ "$short" == "$PHRASA_MARKETING_VERSION" ]] || blockers+=("IPA marketing version mismatch")
        [[ "$ver" == "$PHRASA_BUILD_NUMBER" ]] || blockers+=("IPA build mismatch")
        [[ "$bid" == "$PHRASA_BUNDLE_ID" ]] || blockers+=("IPA bundle id mismatch")
        if [[ "$enc" != "false" && "$enc" != "0" ]]; then
          blockers+=("IPA ITSAppUsesNonExemptEncryption not false")
        fi

        local exe ename
        ename="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_info" 2>/dev/null || echo Phrasa)"
        exe="${app_path}/${ename}"
        if [[ -f "$exe" ]]; then
          local s
          for s in "${PHRASA_RELEASE_FORBIDDEN_STRINGS[@]}"; do
            if strings "$exe" 2>/dev/null | grep -F -q -- "$s"; then
              blockers+=("IPA executable contains forbidden string: $s")
            fi
          done
        else
          blockers+=("IPA executable missing")
        fi

        local privacy
        privacy="${app_path}/PrivacyInfo.xcprivacy"
        if [[ ! -f "$privacy" ]]; then
          privacy="$(find "$app_path" -name 'PrivacyInfo.xcprivacy' 2>/dev/null | head -1)"
        fi
        if [[ -z "$privacy" || ! -f "$privacy" ]]; then
          blockers+=("IPA PrivacyInfo.xcprivacy missing")
        else
          if ! phrasa_check_privacy_manifest "$privacy" "ipa"; then
            local pe
            for pe in "${PHRASA_PRIVACY_LAST_ERRORS[@]+"${PHRASA_PRIVACY_LAST_ERRORS[@]}"}"; do
              blockers+=("IPA $pe")
            done
          fi
        fi

        local r
        for r in OFL.txt AtkinsonHyperlegible-Regular.ttf; do
          if [[ ! -f "${app_path}/${r}" ]] && ! find "$app_path" -name "$r" 2>/dev/null | grep -q .; then
            blockers+=("IPA missing resource: $r")
          fi
        done

        # IPA must be Apple Distribution signed with matching team
        local cs_out team team_prof emb
        cs_out="$(codesign -dvvv "$app_path" 2>&1 || true)"
        echo "--- codesign (IPA app) ---"
        printf '%s\n' "$cs_out" | grep -E 'Authority|TeamIdentifier|Signature|Identifier|flags=' || true

        if phrasa_codesign_is_adhoc "$cs_out"; then
          blockers+=("IPA is ad-hoc signed; App Store requires Apple Distribution")
        fi
        if ! phrasa_codesign_has_distribution "$cs_out"; then
          blockers+=("IPA not signed with Apple Distribution authority")
        fi
        if phrasa_codesign_development_only "$cs_out"; then
          blockers+=("IPA appears Development-signed only; App Store requires Apple Distribution")
        fi

        team="$(printf '%s\n' "$cs_out" | awk -F= '/^TeamIdentifier=/ {print $2; exit}' | tr -d '[:space:]')"
        echo "codesign TeamIdentifier=$team"
        if [[ -z "$team" || "$team" == "not set" || "$team" == "-" ]]; then
          blockers+=("IPA codesign TeamIdentifier missing")
        elif [[ "$team" != "$PHRASA_TEAM_ID" ]]; then
          blockers+=("codesign TeamIdentifier '$team' != $PHRASA_TEAM_ID")
        fi

        emb="${app_path}/embedded.mobileprovision"
        if [[ ! -f "$emb" ]]; then
          blockers+=("IPA missing embedded.mobileprovision (required for App Store distribution proof)")
        else
          team_prof="$(phrasa_team_from_embedded_profile "$emb" || true)"
          echo "embedded_profile_team=$team_prof"
          if [[ -z "$team_prof" ]]; then
            blockers+=("IPA embedded.mobileprovision TeamIdentifier unreadable")
          elif [[ "$team_prof" != "$PHRASA_TEAM_ID" ]]; then
            blockers+=("IPA embedded.mobileprovision team '$team_prof' != $PHRASA_TEAM_ID")
          fi
        fi

        # --- Shipping cloud Info.plist (URL exact production; key present + safe) ---
        echo "--- shipping cloud Info.plist (IPA) ---"
        local cloud_out cloud_line
        cloud_out="$(phrasa_assert_shipping_cloud_info_plist "$app_info" "IPA" 2>&1 || true)"
        while IFS= read -r cloud_line; do
          [[ -z "$cloud_line" ]] && continue
          case "$cloud_line" in
            CLOUD_BLOCKER:*)
              blockers+=("${cloud_line#CLOUD_BLOCKER:}")
              echo "BLOCKER: ${cloud_line#CLOUD_BLOCKER:}"
              ;;
            CLOUD_OK)
              echo "cloud_info_plist=OK"
              ;;
            *)
              echo "$cloud_line"
              ;;
          esac
        done <<<"$cloud_out"
      fi

      if ((${#blockers[@]} > 0)); then
        echo "IPA_INSPECT_FAIL"
        local b
        for b in "${blockers[@]}"; do
          echo "BLOCKER: $b"
        done
      else
        echo "IPA_INSPECT_OK"
      fi
    fi
  } | tee -a "$log_file"

  if grep -q 'IPA_INSPECT_FAIL' "$log_file" 2>/dev/null; then
    return 1
  fi
  if ! grep -q 'IPA_INSPECT_OK' "$log_file" 2>/dev/null; then
    return 1
  fi
  return 0
}

phrasa_write_temp_export_options() {
  local out_path="$1"
  cat >"$out_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>destination</key>
	<string>export</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>method</key>
	<string>app-store-connect</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>stripSwiftSymbols</key>
	<true/>
	<key>teamID</key>
	<string>${PHRASA_TEAM_ID}</string>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF
}
