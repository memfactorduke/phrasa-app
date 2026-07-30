# Phrasa physical-device voice acceptance evidence (template)

**Do not submit this template as evidence.** Copy it to
`VOICE_ACCEPTANCE_BUILD14.md` (or set `PHRASA_VOICE_EVIDENCE_PATH`), replace every
`REPLACE_ME` value, set physical-device preconditions to the exact required tokens,
set every outcome to exactly `pass` only after real hardware proof, and keep
`OPERATOR_ATTESTATION` character-for-character as specified.

Automation is fail-closed: missing, template, incomplete, `fail`/`true`/`yes`,
stale, mismatched, **duplicate keys**, **unknown UPPER_SNAKE keys**, or
**non-exact physical-device preconditions** block archive/export/upload. The
release scripts never fabricate or auto-approve this file.

**Process residency alone is not proof.** A resident Phrasa or InCallService
process with `passcodeRequired=true`, display backlight off, or an active call
does **not** count. Preconditions below must be true at the moment the full
voice stimulus begins, and must be **human-attested** (automation does not
observe them from device APIs and must not invent them).

Bind evidence to the **exact** build-14 candidate:

| Field | Required value |
| --- | --- |
| SOURCE_COMMIT | `7fac6ea406341313a3f169fe2ae42b1e565d1da0` |
| MARKETING_VERSION | `1.0` |
| BUILD_NUMBER | `14` |
| BUNDLE_ID | `com.phrasa.app` |
| CANDIDATE_FINGERPRINT | `344fd52de4a8dce9e53ac825e0a02746976019a994715e7ab34acb26cd229436` (must match `release-ios.sh --preflight`) |

## Operator sequence (before recording outcomes)

Perform these steps on the **physical** device in order. Record precondition
`KEY=VALUE` lines only after each step is true at full stimulus start:

1. **End all active calls / VoIP** — Phone, FaceTime, Telegram, and any other
   call or audio-session contention. Confirm no green call or microphone
   status indicator. If call UI is stuck, **reboot** the device and re-check.
2. **Unlock the device** so passcode is not required for interaction
   (`DEVICE_PASSCODE_REQUIRED=false` exactly).
3. **Turn the display on and keep it awake** (`DEVICE_DISPLAY_STATE=on`
   exactly). Backlight must not be off.
4. **Open Phrasa so it is visibly foregrounded** — not merely a resident
   process (`PHRASA_VISIBLY_FOREGROUNDED=true` exactly).
5. Confirm **no active call/VoIP** (`ACTIVE_CALL_OR_VOIP=false` exactly).
6. **Run the actual full speech stimulus** and capture every outcome only when
   truly proven on this hardware for this candidate.

## Machine-readable fields (required)

Parser reads only `KEY=VALUE` lines. Markdown prose is ignored. Each known key
may appear **at most once** (no last-wins). Only the keys listed below are
accepted; any other `UPPER_SNAKE=…` line is rejected.

```
# Phrasa voice acceptance evidence — schema 1
SCHEMA_VERSION=1
SOURCE_COMMIT=REPLACE_ME_FULL_40_CHAR_COMMIT
MARKETING_VERSION=1.0
BUILD_NUMBER=14
BUNDLE_ID=com.phrasa.app
CANDIDATE_FINGERPRINT=REPLACE_ME_64_CHAR_HEX_FROM_PREFLIGHT
DEVICE_NAME=REPLACE_ME
DEVICE_IDENTIFIER=REPLACE_ME_UDID_OR_COREDEVICE_ID
DEVICE_MODEL=REPLACE_ME_e.g._iPhone16,1
DEVICE_IOS_VERSION=REPLACE_ME_e.g._18.5
RECOGNITION_MODE=REPLACE_ME_on_device_or_apple_service_or_both
DEVICE_PASSCODE_REQUIRED=REPLACE_ME_false
DEVICE_DISPLAY_STATE=REPLACE_ME_on
ACTIVE_CALL_OR_VOIP=REPLACE_ME_false
PHRASA_VISIBLY_FOREGROUNDED=REPLACE_ME_true
TESTED_AT_UTC=REPLACE_ME_YYYY-MM-DDTHH:MM:SSZ
SPEECH_STIMULUS=REPLACE_ME_FULL_SCRIPT_OR_MULTI_SENTENCE_STIMULUS_ACTUALLY_SPOKEN
OPERATOR_NAME=REPLACE_ME
OPERATOR_ATTESTATION=I attest this evidence records a real physical-device voice acceptance for the stated candidate with unlocked device, display on/awake, no active call or VoIP, and Phrasa visibly foregrounded at full stimulus start; process residency alone is not proof; and this evidence is not fabricated.
OUTCOME_PCM_NON_SILENT_AUDIO=REPLACE_ME_pass
OUTCOME_RECOGNITION_CALLBACKS_WORDS=REPLACE_ME_pass
OUTCOME_ALIGNMENT_OBSERVATIONS_ACCEPTED=REPLACE_ME_pass
OUTCOME_TOKEN_PROGRESS_PERSISTENCE=REPLACE_ME_pass
OUTCOME_RELAUNCH=REPLACE_ME_pass
OUTCOME_PERMISSION_GRANT=REPLACE_ME_pass
OUTCOME_PERMISSION_DENIAL=REPLACE_ME_pass
OUTCOME_INTERRUPTION_BACKGROUND=REPLACE_ME_pass
OUTCOME_REPEATED_START_STOP=REPLACE_ME_pass
```

### Binding fields (non-placeholder)

| Key | Rule |
| --- | --- |
| DEVICE_IOS_VERSION | Real iOS version string (e.g. `18.5`, `17.0.1`) |
| RECOGNITION_MODE | Exactly one of: `on_device`, `apple_service`, `both` |

### Physical-device preconditions (exact tokens only; human-attested)

Record these for the moment the **full voice stimulus begins**. Automation does
**not** observe these fields from the device; do not fabricate them.

| Key | Exact required value | Meaning |
| --- | --- | --- |
| DEVICE_PASSCODE_REQUIRED | `false` | Device physically unlocked (passcode not blocking interaction) |
| DEVICE_DISPLAY_STATE | `on` | Display/backlight on and kept awake |
| ACTIVE_CALL_OR_VOIP | `false` | No Phone/FaceTime/Telegram/other VoIP/call audio-session contention; no green call/mic indicator |
| PHRASA_VISIBLY_FOREGROUNDED | `true` | Phrasa visibly in the foreground (not inferred from a resident process) |

Any other token (`true`/`True`/`yes`/`0`/`off`/`awake`/template text) is rejected.

## Outcome definitions (all must be exactly `pass`)

| Key | What you must prove on physical hardware |
| --- | --- |
| OUTCOME_PCM_NON_SILENT_AUDIO | Supported PCM path produces non-silent audio energy while speaking |
| OUTCOME_RECOGNITION_CALLBACKS_WORDS | Speech recognition callbacks deliver words for the stimulus |
| OUTCOME_ALIGNMENT_OBSERVATIONS_ACCEPTED | Alignment observes and accepts progress through the script |
| OUTCOME_TOKEN_PROGRESS_PERSISTENCE | Committed token / progress persists as designed |
| OUTCOME_RELAUNCH | After force-quit or cold launch, state behavior matches product rules |
| OUTCOME_PERMISSION_GRANT | Mic + speech permission grant allows voice following |
| OUTCOME_PERMISSION_DENIAL | Denial leaves speed mode available; no crash/hang |
| OUTCOME_INTERRUPTION_BACKGROUND | Interruption / background / foreground handled safely |
| OUTCOME_REPEATED_START_STOP | Repeated start/stop of voice following remains stable |

Simulator success, unit tests, DEBUG harness screenshots, and **process
residency alone** are **not** sufficient. Record the real device name, model,
identifier, iOS version, recognition mode, and physical-device preconditions
actually observed by the operator.

## Operator notes (optional free text)

Describe device setup anomalies or extra context. Optional notes are not parsed
and must not use `UPPER_SNAKE=value` lines (those are reserved for known keys).
