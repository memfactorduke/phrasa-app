#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_ROOT="${REPO_ROOT}/ios-native"
ACCOUNT_VIEW="${IOS_ROOT}/PhrasaMac/Cloud/MacCloudAccountView.swift"
ENTITLEMENTS="${IOS_ROOT}/PhrasaMac/PhrasaMac.entitlements"
PROJECT_YML="${IOS_ROOT}/project.yml"

require_text() {
  local file="$1"
  local text="$2"
  if ! rg -F -q -- "${text}" "${file}"; then
    echo "Missing required Mac cloud hygiene text in ${file}: ${text}" >&2
    exit 1
  fi
}

forbid_text() {
  local file="$1"
  local text="$2"
  if rg -F -q -- "${text}" "${file}"; then
    echo "Forbidden Mac cloud hygiene text in ${file}: ${text}" >&2
    exit 1
  fi
}

require_text "${ACCOUNT_VIEW}" "SignInWithAppleButton"
require_text "${ACCOUNT_VIEW}" "signInWithApple"
require_text "${ACCOUNT_VIEW}" "AppleSignInSupport"
require_text "${ACCOUNT_VIEW}" "AppleSignInPresentation.primarySectionHeader"
require_text "${ACCOUNT_VIEW}" "AppleSignInPresentation.secondarySectionHeader"
require_text "${ACCOUNT_VIEW}" 'accessibilityLabel("Sign in with Apple")'
forbid_text "${ACCOUNT_VIEW}" "Sign in with Apple is not offered"
forbid_text "${ACCOUNT_VIEW}" "Email/password only"

require_text "${ACCOUNT_VIEW}" "Explicit adoption is deferred"
require_text "${ACCOUNT_VIEW}" "never claims them for this account automatically"
forbid_text "${ACCOUNT_VIEW}" "automatically claim"
forbid_text "${ACCOUNT_VIEW}" "claimAllUnowned"

require_text "${ENTITLEMENTS}" "com.apple.security.network.client"
require_text "${ENTITLEMENTS}" "com.apple.security.app-sandbox"
require_text "${ENTITLEMENTS}" "com.apple.developer.applesignin"
require_text "${ENTITLEMENTS}" "Default"
require_text "${PROJECT_YML}" "com.phrasa.mac.auth"
require_text "${PROJECT_YML}" "phrasa"
require_text "${PROJECT_YML}" 'PHRASA_SUPABASE_PUBLISHABLE_KEY: ""'

RAW_MATCHES="$(
  rg -n \
    -e "SUPABASE_SERVICE_ROLE" \
    -e "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9\\." \
    -e "service_role" \
    -e "sb_secret_" \
    "${IOS_ROOT}/PhrasaMac" \
    "${IOS_ROOT}/Phrasa/Cloud" \
    "${IOS_ROOT}/Packages/PhrasaSync" \
    "${PROJECT_YML}" \
    --glob '!**/*Tests*/**' \
    --glob '!**/*Hygiene*' \
    || true
)"

UNSAFE_MATCHES="$(
  printf '%s\n' "${RAW_MATCHES}" \
    | rg -v 'CloudConfiguration\.swift:.*(service_role|sb_secret_)' \
    | rg -v 'project\.yml:.*eyJhbGci' \
    || true
)"

if [[ -n "${UNSAFE_MATCHES}" ]]; then
  echo "Potential committed privileged credential material found:" >&2
  printf '%s\n' "${UNSAFE_MATCHES}" >&2
  exit 1
fi

echo "Mac cloud source hygiene passed."
