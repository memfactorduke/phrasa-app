# Screenshot plan — Phrasa 1.0 (iPhone & iPad)

**Status:** primary required sets **captured** (local assets only). Screenshots have
**not** been uploaded to App Store Connect, and Connect acceptance is not claimed.

Capture was done with the **local-only** build. Use dark canvas (#000) product
chrome and real sample content—no mock cloud UI, pricing, or invented website
chrome.

Prefer the seeded welcome/sample script or a short original monologue. Avoid
customer PII.

## Captured assets (verified)

Ten JPEGs under `Screenshots/`. Inspected with `file` and `sips`: each is
`public.jpeg` / `format: jpeg`, RGB, `hasAlpha: no`.

### iPhone 6.9" — 1320 × 2868

| File | Shot | Role |
| --- | --- | --- |
| `Screenshots/iPhone-6.9/01-library.jpg` | Library | Core / required |
| `Screenshots/iPhone-6.9/02-editor.jpg` | Editor | Core / required |
| `Screenshots/iPhone-6.9/03-speed-reader.jpg` | Speed reader | Core / required |
| `Screenshots/iPhone-6.9/04-onboarding.jpg` | Onboarding | Core / required |
| `Screenshots/iPhone-6.9/05-voice-reader.jpg` | Voice reader (static) | Core / required |

- Pixel size: **1320 × 2868** (all five)
- Type: **JPEG** (JFIF, baseline, 8-bit, 3 components)
- Alpha: **none** (`hasAlpha: no`)

### iPad 13" — 2064 × 2752

| File | Shot | Role |
| --- | --- | --- |
| `Screenshots/iPad-13/01-library.jpg` | Library | Core / required |
| `Screenshots/iPad-13/02-editor.jpg` | Editor | Core / required |
| `Screenshots/iPad-13/03-speed-reader.jpg` | Speed reader | Core / required |
| `Screenshots/iPad-13/04-onboarding.jpg` | Onboarding | Core / required |
| `Screenshots/iPad-13/05-voice-reader.jpg` | Voice reader (static) | Core / required |

- Pixel size: **2064 × 2752** (all five)
- Type: **JPEG** (JFIF, baseline, 8-bit, 3 components)
- Alpha: **none** (`hasAlpha: no`)

### Voice reader frame — proof boundary (required)

**Voice reader is a core/required frame for both the iPhone 6.9" and iPad 13"
sets** (not optional). Capture the same seeded sample script on the static
Voice-mode stage:

- Mode segment: **Voice** selected
- Status: **Voice paused** (or equivalent idle trust label)
- Playback control shows **Play** (do **not** tap Play for the store frame)
- Sample / non-PII script body only

A static screenshot proves the **Voice reader UI** (mode chrome, trust/status
affordance, stage layout)—**not** live speech recognition, mic capture, or
voice-follow progress. Do not imply recognition is active; do not stage fake
waveforms or live transcripts.

### Not yet captured (optional)

These remain optional and are **not** present under `Screenshots/`:

- **Reader settings / appearance** — themes, pace, or mirror controls
- **Outline presenter** — ordered points on stage

## App Store Connect upload constraints

Per Apple’s current App Store Connect rules:

- **Count:** each display-size set accepts **1 through 10** screenshots (not zero;
  max 10 per size). The captured sets use **5** frames each (within range).
- **iPhone (preferred source set):** capture the **highest-resolution 6.9-inch
  iPhone class** and upload that as the primary iPhone screenshot set. Apple may
  scale it for smaller iPhone display sizes when appropriate.
- **iPad (required for this binary):** the shipping app supports iPad
  (`TARGETED_DEVICE_FAMILY` includes iPad). Include the **required 13-inch iPad**
  screenshot set.

Official references:

- [Upload app previews and screenshots](https://developer.apple.com/help/app-store-connect/manage-app-information/upload-app-previews-and-screenshots)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications)

## Required device sizes (this app)

| Priority | Display size | Role | Local status |
| --- | --- | --- | --- |
| Required | **6.9" iPhone** (highest-resolution class) | Preferred iPhone source set for App Store Connect | **5 frames captured** at 1320×2868 (includes required Voice reader) |
| Required | **13" iPad** | Required because the binary supports iPad | **5 frames captured** at 2064×2752 (includes required Voice reader) |
| Optional | 6.1" iPhone (or other sizes) | Marketing / TestFlight notes only; not a substitute for the 6.9" or 13" sets | Not captured |

Exact pixel dimensions change with hardware generations—always match the current
tables in Apple’s [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications).

## Shot list (order)

Captured primary set uses **5 frames** per required size (within the 1–10
Connect limit). Suggested captions are optional overlay text for the store
frame, not in-app UI.

**Intended App Store Connect upload order puts Voice first** (filename numbers
below are capture labels, not Connect slot order).

### Captured (intended upload / store order) — all core / required

1. **Voice reader** (`05-voice-reader.jpg`) — Same stage with Voice mode selected
   and idle/static chrome (e.g. “Voice paused”). **Core/required for both iPhone
   and iPad sets.** Static capture proves Voice reader UI only—not live speech
   recognition. Caption: “Or let the text follow your voice.” (UI presence, not a
   claim of a live session in the frame.)
2. **Library** (`01-library.jpg`) — Script list with search chrome; folders/tags
   visible if natural. Caption: “Your scripts, on this device.”
3. **Editor** (`02-editor.jpg`) — Script body mid-edit with title; outline section
   if space allows. Caption: “Write and autosave.”
4. **Speed reader** (`03-speed-reader.jpg`) — Full-screen prompter mid-scroll,
   clean stage, minimal chrome. Caption: “Steady speed prompting.”
5. **Onboarding** (`04-onboarding.jpg`) — First-run / welcome framing for the
   local-only product. Caption: optional; keep copy honest to local-only scope.

### Optional — not yet captured

6. **Reader settings / appearance** — Themes, pace, or mirror controls that ship.
   Caption: “Stage controls when you need them.”
7. **Outline presenter** — Ordered points on stage (iPad landscape preferred).
   Caption: “Talking points, step by step.”
8. **Import or backup** (optional) — System file picker aftermath or backup
   confirmation using honest local copy. Caption: “Import, export, full backup.”

Do **not** screenshot Account & sync as a selling point for this candidate; if
included for internal QA only, it must show the offline-only message.

## Orientation

- iPhone: primarily portrait for library/editor; one landscape reader shot if
  mirror/stage looks strong.
- iPad: at least one landscape library/editor split and one landscape reader.

## Visual rules

- Monochrome product UI only (black/white editorial system).
- No device bezels with competing wallpapers that clash; prefer neutral.
- Dynamic Type at default size unless demonstrating accessibility (optional
  extra set, not required for first submission).
- Status bar: clean (full signal/wifi/battery) or use Xcode status-bar overrides.

## TestFlight screenshots

Reuse App Store frames 1–5 for beta testing notes. No separate cloud story.
**Local capture complete; upload / Connect acceptance not claimed.**
