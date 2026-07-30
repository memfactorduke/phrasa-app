# Fresh Mac release handoff

This checklist reconstructs the Phrasa **1.0 (14)** release lane from Git
without copying build caches or Finder-created duplicate projects. The tested
release toolchain on 2026-07-29 was Xcode **26.6 (17F113)**, Swift **6.3.3**,
XcodeGen **2.45.4**, Node **22**, and Python 3.

The authoritative build-14 candidate is:

- product source pin:
  `7fac6ea406341313a3f169fe2ae42b1e565d1da0`
- candidate fingerprint:
  `344fd52de4a8dce9e53ac825e0a02746976019a994715e7ab34acb26cd229436`
- marketing version / build: **1.0 (14)**
- bundle ID / team: `com.phrasa.app` / `Q42MT7JA7Q`
- Xcode project: `ios-native/PhrasaNative.xcodeproj`

`scripts/ios-release/lib/constants.sh` remains the machine-authoritative source
for these values.

## 1. Clone only the real repository state

```bash
git clone <repository-url> phrasa_rebuild
cd phrasa_rebuild
git switch codex/phrasa-rebuild
git status --short
git rev-parse HEAD
git rev-parse origin/codex/phrasa-rebuild
```

Start from a clean checkout. Do **not** copy untracked Finder duplicates from
the old Mac. In particular, never build an Xcode project whose name contains a
numbered suffix such as `PhrasaNative 2.xcodeproj`. Those local duplicates are
not release source and the release scripts intentionally reject them.

## 2. Install the tested toolchain

1. Install Xcode **26.6** and open it once to accept its license and install
   components.
2. Select it for command-line builds:

   ```bash
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   xcodebuild -version
   swift --version
   ```

3. Install Node 22, then restore the locked web dependencies:

   ```bash
   nvm use
   npm ci
   ```

4. Install Python 3. The submission validator uses only the standard library
   plus macOS `sips`.
5. Install XcodeGen **2.45.4** only if `project.yml` must be regenerated.

The canonical `ios-native/PhrasaNative.xcodeproj` and its SwiftPM
`Package.resolved` are tracked. A normal build can open that project directly:

```bash
open ios-native/PhrasaNative.xcodeproj
```

Do not regenerate it merely to build. If native project structure changes,
regenerate with the tested XcodeGen version and commit both `project.yml` and
the generated project changes together.

## 3. Restore Apple signing without putting credentials in Git

On the new Mac:

1. Sign in to the Memorable Factor Apple Developer account in Xcode and select
   team `Q42MT7JA7Q`.
2. Import the Apple Distribution certificate **with its private key** into the
   login keychain.
3. Let Xcode fetch, or securely transfer, the App Store provisioning profile
   for `com.phrasa.app`.
4. Securely transfer the App Store Connect API private key to:

   ```text
   ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8
   ```

5. Export only the key ID and issuer ID in the release shell:

   ```bash
   export ASC_KEY_ID="<key-id>"
   export ASC_ISSUER_ID="<issuer-uuid>"
   ```

Never commit the `.p8`, a certificate private key, an App Store Connect secret,
or their contents. The release can still pause for macOS Keychain authorization;
approve access locally when the system prompt appears.

## 4. Restore the Supabase publishable configuration

The project URL is tracked. Supply the production **publishable** key only at
build time:

```bash
export PHRASA_SUPABASE_PUBLISHABLE_KEY="<production-publishable-key>"
```

Never commit the key or place a service-role key in the native app, browser
bundle, shell history, or repository. Supabase CLI state under
`supabase/.temp/` is machine-local and must not be copied. Install and link the
Supabase CLI only when administering migrations, Auth, or Edge Functions; it is
not required to build the app from the tracked Xcode project.

## 5. Securely transfer the ignored Voice acceptance record

Physical Voice Follow and real Mac-to-iPad Supabase sync passed on
2026-07-29. The detailed physical Voice record contains a real device
identifier and operator evidence, so
`ios-native/AppStore/evidence/VOICE_ACCEPTANCE_BUILD14.md` is deliberately
ignored by Git.

Transfer that file securely from the release Mac, preserving it outside Git,
then either place it at the ignored default path above or point preflight to
its secure location:

```bash
export PHRASA_VOICE_EVIDENCE_PATH="/absolute/secure/path/VOICE_ACCEPTANCE_BUILD14.md"
```

Do not commit the evidence file, device UDID, operator-private data, or a
fabricated replacement. `Submission/voice-gate.yaml` records the public
high-level pass but does not replace the detailed evidence required by
preflight.

## 6. Reproduce and continue the release

```bash
# Repository and packet checks
npm test
ios-native/AppStore/Submission/validate.sh --mode packet
python3 -m unittest ios-native/AppStore/Submission/test_validate_packet.py -v

# Read-only release readiness
scripts/ios-release/release-ios.sh --preflight
```

The signed Release archive for **1.0 (14)** succeeded on 2026-07-29. The same
candidate was exported, uploaded, processed, and selected in App Store Connect:

- Apple ID: `6780259086`
- build ID: `9570010d-0625-403c-9955-c9d0d51e2306`
- review submission ID: `1ef88310-ff57-49d8-a02e-5a5c71ad07c5`
- current state: **Waiting for Review**
- release mode: **manual**

No upload action is needed for this already-submitted build. After Apple
approval, perform the manual release in App Store Connect. For a future build,
increment `CURRENT_PROJECT_VERSION` above **14**, repeat the release checks, and
use the documented `--release --validate --upload` lane with fresh evidence.

Do not claim Apple-linked account-deletion end-to-end acceptance unless it is
separately verified on the live account and both native platforms.
