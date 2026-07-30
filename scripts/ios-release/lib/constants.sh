# shellcheck shell=bash
# Phrasa iOS release lane — fixed candidate constants (build 14).
# Sourced by release-ios.sh; do not execute directly.

# Exact product source pin for this automation lane (app tree must match).
# HEAD may be a descendant (e.g. automation docs/scripts) only if product paths
# have zero diff against this commit.
# Pin includes the physical-device Voice Follow audio-session recovery that is
# installed in the build-14 release candidate. Later commits may change only
# tests, release automation, or documentation unless this pin is advanced again.
readonly PHRASA_EXPECTED_COMMIT="7fac6ea406341313a3f169fe2ae42b1e565d1da0"

# Expected candidate fingerprint for the pin (algorithm in common.sh
# phrasa_candidate_fingerprint). Material built via printf (internal newlines
# preserved); bash command-substitution strips a single trailing newline before
# hashing, matching live preflight. Material fields:
#   phrasa-candidate-v1
#   commit=<PHRASA_EXPECTED_COMMIT>
#   marketing=1.0 build=14 bundle=com.phrasa.app team=Q42MT7JA7Q
#   pbxproj=<PHRASA_EXPECTED_PBXPROJ_SHA256>
# Recompute and update both values whenever the product pin or pbxproj changes.
readonly PHRASA_EXPECTED_PBXPROJ_SHA256="3f4d3d4a7186b49777f1374206f0102d0807501040156a02ecd032f33ee0a091"
readonly PHRASA_EXPECTED_FINGERPRINT="344fd52de4a8dce9e53ac825e0a02746976019a994715e7ab34acb26cd229436"

# Local Submission packet validator (packet mode only — never claims Connect state).
readonly PHRASA_SUBMISSION_VALIDATE_REL="ios-native/AppStore/Submission/validate.sh"

readonly PHRASA_MARKETING_VERSION="1.0"
readonly PHRASA_BUILD_NUMBER="14"
readonly PHRASA_BUNDLE_ID="com.phrasa.app"
readonly PHRASA_TEAM_ID="Q42MT7JA7Q"
readonly PHRASA_PRODUCT_NAME="Phrasa"
readonly PHRASA_EXECUTABLE_NAME="Phrasa"
readonly PHRASA_CODE_SIGN_STYLE="Automatic"

# Authoritative Xcode project only — never glob or select alternates.
readonly PHRASA_PROJECT_REL="ios-native/PhrasaNative.xcodeproj"
# Historical primary Finder-duplicate name (always blocked). Numbered siblings
# like "PhrasaNative 3.xcodeproj" are also blocked by preflight pattern checks.
readonly PHRASA_FORBIDDEN_PROJECT_REL="ios-native/PhrasaNative 2.xcodeproj"
readonly PHRASA_SCHEME="Phrasa"
readonly PHRASA_TARGET="Phrasa"
readonly PHRASA_CONFIGURATION="Release"
readonly PHRASA_DESTINATION="generic/platform=iOS"

# Production Supabase project (must match CloudConfiguration.swift / project.yml).
# Publishable key is never stored in source; inject via PHRASA_SUPABASE_PUBLISHABLE_KEY
# as an xcodebuild build-setting override on shipping Release build/archive only.
readonly PHRASA_PRODUCTION_SUPABASE_HOST="uqkjidvqyngrnyftdazp.supabase.co"
readonly PHRASA_PRODUCTION_SUPABASE_URL="https://uqkjidvqyngrnyftdazp.supabase.co"
# Info.plist keys written by INFOPLIST_KEY_* / explicit plist entries.
readonly PHRASA_INFO_SUPABASE_URL_KEY="PhrasaSupabaseURL"
readonly PHRASA_INFO_SUPABASE_PUBLISHABLE_KEY_KEY="PhrasaSupabasePublishableKey"

# Evidence schema
readonly PHRASA_EVIDENCE_SCHEMA_VERSION="1"
readonly PHRASA_EVIDENCE_MAX_AGE_DAYS="30"

# Upload confirmation must be typed exactly (second gate after --upload).
readonly PHRASA_UPLOAD_CONFIRM_PHRASE="UPLOAD BUILD 14 TO APP STORE CONNECT"

# DEBUG-only identifiers that must not appear in the Release app binary.
# Sourced from VoicePipelineDiagnostics.swift (accessibility + file name).
# Do not add generic tokens (e.g. "status=", "health=") that appear in
# truthful Release product status code.
readonly PHRASA_RELEASE_FORBIDDEN_STRINGS=(
  "VoicePipelineDiagnostics"
  "voice-pipeline-diagnostics.json"
)

# Required app resources inside the product bundle.
readonly PHRASA_REQUIRED_RESOURCES=(
  "PrivacyInfo.xcprivacy"
  "OFL.txt"
  "AtkinsonHyperlegible-Regular.ttf"
)

# Privacy manifest assertions (parsed as plist, not grepped as text only).
readonly PHRASA_PRIVACY_TRACKING_EXPECTED="false"
readonly PHRASA_PRIVACY_REQUIRED_API_TYPE="NSPrivacyAccessedAPICategoryUserDefaults"
readonly PHRASA_PRIVACY_REQUIRED_API_REASON="CA92.1"

# Known pre-existing Finder-duplicate untracked files that may be tolerated
# ONLY when PHRASA_ALLOW_KNOWN_FINDER_DUPES=1 (main checkout operator election).
# The forbidden Xcode project duplicate is NEVER tolerated.
readonly PHRASA_KNOWN_FINDER_DUPES=(
  "ios-native/Phrasa/Design/VoiceTrustPresentation 2.swift"
  "ios-native/Phrasa/Reader/PrompterTextView 2.swift"
  "ios-native/Phrasa/Reader/ReaderView 2.swift"
  "ios-native/PhrasaMac/Reader/MacDisplaySleepGuard 2.swift"
)

# App Store Connect API key private-key lookup roots (filenames only; never read .p8).
readonly PHRASA_API_KEY_SEARCH_DIRS=(
  "${HOME}/.appstoreconnect/private_keys"
  "${HOME}/private_keys"
  "${HOME}/.private_keys"
)

# Default relative evidence path (operator fills a real file; never the template).
readonly PHRASA_DEFAULT_EVIDENCE_REL="ios-native/AppStore/evidence/VOICE_ACCEPTANCE_BUILD14.md"
readonly PHRASA_EVIDENCE_TEMPLATE_REL="ios-native/AppStore/evidence/VOICE_ACCEPTANCE_TEMPLATE.md"

# Allowed RECOGNITION_MODE values (evidence binding).
readonly PHRASA_RECOGNITION_MODES_ALLOWED="on_device apple_service both"

# Allowed DEVICE_DISPLAY_STATE values (human-attested physical preconditions).
# Only exact allowlisted tokens are accepted — not "true"/"awake"/"unlocked".
readonly PHRASA_DEVICE_DISPLAY_STATES_ALLOWED="on"

# Exact required OPERATOR_ATTESTATION string (character-for-character).
readonly PHRASA_OPERATOR_ATTESTATION_REQUIRED="I attest this evidence records a real physical-device voice acceptance for the stated candidate with unlocked device, display on/awake, no active call or VoIP, and Phrasa visibly foregrounded at full stimulus start; process residency alone is not proof; and this evidence is not fabricated."
