# Voice acceptance evidence

Physical-device voice acceptance is a **hard gate** before archive, export,
validation, or upload of native iOS build **14**.

| File | Role |
| --- | --- |
| [VOICE_ACCEPTANCE_TEMPLATE.md](./VOICE_ACCEPTANCE_TEMPLATE.md) | Template only — never accepted as evidence |
| `VOICE_ACCEPTANCE_BUILD14.md` | Operator-filled evidence (complete on 2026-07-29, local, and intentionally ignored because it contains a real device identifier) |

The real build-14 record must never be committed. Securely transfer it between
release Macs, or keep it at another protected path and export
`PHRASA_VOICE_EVIDENCE_PATH=/absolute/protected/path/VOICE_ACCEPTANCE_BUILD14.md`.
The tracked `Submission/voice-gate.yaml` records the high-level pass but does
not replace this detailed preflight artifact.

## Workflow

1. Confirm local packet completeness, then note the expected fingerprint
   (or copy `candidate_fingerprint=…` from a preflight log):

   ```bash
   ios-native/AppStore/Submission/validate.sh --mode packet
   scripts/ios-release/release-ios.sh --preflight
   ```

   Expected for product pin `7fac6ea406341313a3f169fe2ae42b1e565d1da0`:
   `344fd52de4a8dce9e53ac825e0a02746976019a994715e7ab34acb26cd229436`.

   Preflight writes only under the isolated gitignored directory
   `ios-native/build/release-runs/<timestamp>/` (log + showBuildSettings dump).
   It does not alter tracked files, DerivedData product trees, archives, IPAs,
   or App Store Connect state. Preflight re-runs Submission packet mode as a
   required local source check (not Connect proof).

2. Copy the template to `VOICE_ACCEPTANCE_BUILD14.md` (or another path via
   `PHRASA_VOICE_EVIDENCE_PATH`).

3. On a **physical** iPhone or iPad, prepare a valid session, then exercise the
   full microphone → recognition → alignment path for marketing version `1.0`,
   build `14`, bundle `com.phrasa.app`, source commit
   `7fac6ea406341313a3f169fe2ae42b1e565d1da0`.

   **Operator sequence (required before outcomes):**

   1. End all active Phone / FaceTime / Telegram / VoIP calls; clear green
      call/mic indicators. Reboot if call UI is stuck.
   2. Unlock so `DEVICE_PASSCODE_REQUIRED=false` exactly.
   3. Display on and kept awake: `DEVICE_DISPLAY_STATE=on` exactly.
   4. Open Phrasa so it is **visibly foregrounded**:
      `PHRASA_VISIBLY_FOREGROUNDED=true` exactly.
   5. Confirm `ACTIVE_CALL_OR_VOIP=false` exactly.
   6. Run the actual full speech stimulus and record outcomes.

   **Process residency alone is not proof.** A resident Phrasa process with the
   lock screen up, backlight off, or an active call does not count. These
   precondition fields are **human-attested**; automation does not observe them
   from the device and must not fabricate them.

4. Fill every `KEY=VALUE` field, including:
   - `DEVICE_IOS_VERSION` (e.g. `18.5`)
   - `RECOGNITION_MODE` (`on_device` / `apple_service` / `both`)
   - Physical preconditions with exact tokens only (`false` / `on` / `false` /
     `true` as specified above)
   - Every `OUTCOME_*=pass` only when truly proven
   - `OPERATOR_ATTESTATION` character-for-character as in the template

   Duplicate keys and unknown `UPPER_SNAKE` keys are rejected (fail-closed).

5. Re-run `--preflight`. Evidence errors are reported as blockers.

Automation **never** fabricates or auto-approves this file. Default, missing,
template, incomplete, non-`pass`, stale (>30 days), duplicate, unknown-key,
non-exact precondition, or mismatched evidence fails closed.
