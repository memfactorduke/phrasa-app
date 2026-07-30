# Physical Voice Follow QA

This harness keeps two different Voice Follow proofs separate and also exposes
a focused physical sync diagnostic. All preserve the iPad library, account,
app container, and current permission state. None archives or uploads an app.

## 1. Full instrumented Debug proof

```bash
./scripts/ios-voice-uiqa/run-voice-uiqa.sh --device
```

This runs `PhrasaVoiceUIQA` in **Debug**. It requires the privacy-safe
`VoicePipelineDiagnostics` surface and proves the physical microphone produced
non-silent buffers, speech recognition produced words, alignment accepted
observations, committed progress advanced, and Voice recovered after
pause/resume plus background/foreground.

The test fails immediately with a configuration error if it is compiled as
Release or if the diagnostic surface is missing. Release excludes that file by
design, so a missing diagnostic value must never be interpreted as zero audio.

## 2. Shipping Release behavior proof

```bash
./scripts/ios-voice-uiqa/run-voice-uiqa.sh --release-device
```

This runs `PhrasaVoiceReleaseUIQA` in **Release**, matching the shipping app
configuration. It never queries Debug diagnostics. After the 25-second spoken
stimulus, it taps the reader stage to reveal the intentionally auto-hidden
chrome, re-queries fresh visible progress and Voice status, and requires:

- progress after speech is materially greater than the captured baseline;
- Voice status is present and active (`Listening`, `Following`, or
  `Finding place`), not blocked, denied, restricted, unavailable, or cancelled.

If this path reports no progress while status is healthy, verify that macOS
audio is coming from speakers beside the iPad rather than AirPods and that the
spoken text matches the selected QA script.

## Host audio

Use the built-in Mac speakers explicitly when available:

```bash
PHRASA_VOICE_OUTPUT_DEVICE="MacBook Pro Speakers" \
PHRASA_VOICE_OUTPUT_VOLUME=80 \
./scripts/ios-voice-uiqa/run-voice-uiqa.sh --device
```

The same variables work with `--release-device`. The runner restores the prior
volume afterward. `PHRASA_VOICE_STIMULUS_FILE` selects an exact script body;
otherwise the bundled Welcome script is spoken.

## Cloud key contract

The physical modes install an app that can use Phrasa's real Supabase
project for Mac-to-iPad sync QA. Export the production **publishable** client
key before running a physical command:

```bash
export PHRASA_SUPABASE_PUBLISHABLE_KEY='sb_publishable_...'
./scripts/ios-voice-uiqa/run-voice-uiqa.sh --device
```

A legacy Supabase `anon` JWT is also accepted. A missing or malformed value,
an `sb_secret_` key, or a `service_role` JWT fails before `xcodebuild` runs.
The runner never prints the value.

For a physical run, the validated key is written to a private mode-600
temporary xcconfig, removed from the child-process environment, streamed
through literal output redaction, scrubbed from the final log again, and
deleted when the runner exits. A publishable/anon key is intended for client
apps; authorization still comes from Supabase row-level security.

Simulator and build-only modes intentionally ignore and unset this environment
variable even if it remains exported. Their builds keep the project's empty
non-shipping default rather than silently producing another cloud-capable app.

The device-free contract suite uses only synthetic fixtures:

```bash
./scripts/ios-voice-uiqa/test-cloud-key-contract.sh
```

## Physical Mac-to-iPad sync diagnostic

```bash
export PHRASA_SUPABASE_PUBLISHABLE_KEY='sb_publishable_...'
./scripts/ios-voice-uiqa/run-voice-uiqa.sh --sync-device
```

This builds and installs the Release configuration, opens the existing
`Account & sync` surface, taps `Sync now`, and runs only
`testPhysicalSyncRetryAndReport`. It preserves the app container and reports
`SYNC_QA_STATUS_BEFORE` and `SYNC_QA_STATUS_AFTER` for host-side Supabase
verification. It uses the same private xcconfig, environment scrubbing,
streaming redaction, and cleanup contract as the two physical Voice modes.
It does not start the host speech watcher.

## Disposable delete propagation diagnostic

The delete lane is intentionally destructive, but only to one exact,
externally prepared QA fixture. The runner refuses to start unless the title
begins with `SYNC QA DELETE IPAD `:

```bash
export PHRASA_SUPABASE_PUBLISHABLE_KEY='sb_publishable_...'
export PHRASA_SYNC_DELETE_FIXTURE_TITLE='SYNC QA DELETE IPAD 20990101T000000Z'
./scripts/ios-voice-uiqa/run-voice-uiqa.sh --sync-delete-device
```

This runs only `testPhysicalSyncDeleteAndReport`. It searches for the exact
title, deletes that row through the shipping UI, confirms `Delete permanently`,
taps `Sync now`, requires a successful `Synced ·` presentation, and proves the
exact title remains absent afterward. The host must create the disposable
Supabase/local fixture and verify its tombstone or cloud absence separately.
Never point this mode at a real user script.

## Disposable divergent-conflict diagnostic

The conflict lane also requires an exact externally prepared fixture plus two
distinct, non-secret body markers:

```bash
export PHRASA_SUPABASE_PUBLISHABLE_KEY='sb_publishable_...'
export PHRASA_SYNC_CONFLICT_FIXTURE_TITLE='SYNC QA CONFLICT 20990101T000000Z'
export PHRASA_SYNC_CONFLICT_LOCAL_MARKER='LOCAL_MARKER_20990101'
export PHRASA_SYNC_CONFLICT_CLOUD_MARKER='CLOUD_MARKER_20990101'
./scripts/ios-voice-uiqa/run-voice-uiqa.sh --sync-conflict-device
```

This runs only `testPhysicalSyncConflictAndReport`. It replaces the exact
fixture's iPad body with the local marker, waits for the edit to become durable,
syncs explicitly, then requires:

- the original title to contain the cloud marker; and
- `<exact title> — Local conflict` to contain the local marker.

The runner refuses titles outside the `SYNC QA CONFLICT ` namespace, missing
markers, unsafe fixture characters, overlong values, or identical markers.
The host is responsible for staging the cloud-side divergent edit before this
lane runs and for cleaning up both disposable rows afterward.

Both disposable modes use the same Release scheme, private mode-600 Supabase
xcconfig, output redaction, and cleanup guarantees as `--sync-device`. Fixture
values are non-secret and reach XCTest only through explicit Release-scheme
build-setting expansion; they are removed from inherited `xcodegen` and
`xcodebuild` environments.

## Non-device validation

```bash
./scripts/ios-voice-uiqa/run-voice-uiqa.sh --build-only
./scripts/ios-voice-uiqa/run-voice-uiqa.sh --release-build-only
./scripts/ios-voice-uiqa/run-voice-uiqa.sh --smoke
```

`--build-only` validates the Debug scheme. `--release-build-only` validates the
Release scheme. `--smoke` only proves the library launches in a Debug simulator;
it does not prove Voice Follow.

`PHRASA_VOICE_CONFIGURATION` is not an override. If supplied, it must match the
selected mode. For example, `PHRASA_VOICE_CONFIGURATION=Release --device`
fails before `xcodebuild`, preventing a structurally invalid physical run.

## Complete acceptance

Call physical Voice Follow green only after both `--device` and
`--release-device` pass on the intended signed candidate. Do not uninstall the
app, reset privacy permissions, erase the device, or use a Finder-duplicate
Xcode project to prepare either run.
