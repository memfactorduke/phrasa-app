import { readFileSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

const root = join(__dirname, "../..");

function readAppPage(rel: string): string {
  return readFileSync(join(root, rel), "utf8");
}

/** Collapse JSX/source whitespace so phrase checks survive line wraps. */
function flat(src: string): string {
  return src.replace(/\s+/g, " ");
}

const privacy = readAppPage("app/privacy/page.tsx");
const support = readAppPage("app/support/page.tsx");
const terms = readAppPage("app/terms/page.tsx");
const home = readAppPage("app/page.tsx");
const legalSurfaces = [privacy, support, terms];
const privacyFlat = flat(privacy);
const supportFlat = flat(support);
const termsFlat = flat(terms);
const homeFlat = flat(home);

/** Internal release-note / legalistic hedge language must not appear publicly. */
const releaseNoteBanList = [
  /local-only/i,
  /\bcandidate\b/i,
  /\bthis build\b/i,
  /build configuration/i,
  /not represented here/i,
  /no invented support email/i,
  /missing email/i,
  /undeployed/i,
  /App Store Connect/i,
  /does not claim that any particular domain/i,
  /not yet (live|deployed|published)/i,
  /blocker/i,
  // Legalistic hedges and absolute-on-device phrasing (no exemptions).
  /does not claim/i,
  /do not claim/i,
  /never claims/i,
  /always on[- ]device/i,
  /always fully on[- ]device/i,
  /all speech recognition is always/i,
];

describe("privacy and support truth constraints", () => {
  it("publishes only the monitored support@phrasa.app mailto on Support", () => {
    expect(support).toMatch(/mailto:support@phrasa\.app/);
    expect(supportFlat).toMatch(/support@phrasa\.app/);
    // No alternate invented addresses on Support.
    expect(support).not.toMatch(/mailto:(?!support@phrasa\.app)[^"'>\s]+/i);
    expect(support).not.toMatch(/hello@/i);
    expect(support).not.toMatch(/contact@/i);
    // Privacy and Terms still route to Support and do not invent mail contacts.
    for (const src of [privacy, terms]) {
      expect(src).not.toMatch(/mailto:/i);
      expect(src).not.toMatch(/[\w.+-]+@[\w.-]+\.[a-z]{2,}/i);
      expect(src).not.toMatch(/support@/i);
      expect(src).not.toMatch(/hello@/i);
      expect(src).not.toMatch(/contact@/i);
    }
  });

  it("does not put deployment claims or live-domain marketing on public legal pages", () => {
    for (const src of legalSurfaces) {
      expect(src).not.toMatch(/https?:\/\/[a-z0-9.-]+\.[a-z]{2,}/i);
      expect(src).not.toMatch(/phrasa\.app is (live|deployed|public)/i);
      expect(src).not.toMatch(/visit (us at |https?:\/\/)?phrasa\.app/i);
      expect(src).not.toMatch(/deployed at/i);
    }
    // Privacy and Terms must not mention the domain except via Support routing.
    for (const src of [privacy, terms]) {
      expect(src).not.toMatch(/phrasa\.app/i);
    }
    // Support may use support@phrasa.app only (mailto address), not a site URL claim.
    expect(support).not.toMatch(/https?:\/\/phrasa\.app/i);
  });

  it("public privacy and support pages avoid internal release-note phrasing", () => {
    for (const src of [privacyFlat, supportFlat]) {
      for (const pattern of releaseNoteBanList) {
        expect(src).not.toMatch(pattern);
      }
    }
  });

  it("forbids legalistic speech hedges and absolute always-on-device claims", () => {
    for (const src of [privacyFlat, supportFlat]) {
      expect(src).not.toMatch(/does not claim that all speech recognition is always on-device/i);
      expect(src).not.toMatch(/does not claim that recognition is always/i);
      expect(src).not.toMatch(/always on[- ]device/i);
      expect(src).not.toMatch(/always fully on[- ]device/i);
      expect(src).not.toMatch(/does not claim/i);
      // Absolute marketing claims without the supported/otherwise branch.
      expect(src).not.toMatch(
        /all speech recognition is (always )?on[- ]device/i,
      );
      expect(src).not.toMatch(
        /microphone audio is (always )?processed (entirely )?on your device/i,
      );
      expect(src).not.toMatch(/100% on[- ]device/i);
      expect(src).not.toMatch(/entirely on[- ]device/i);
    }
  });

  it("states accurate direct Apple Speech privacy wording", () => {
    for (const src of [privacyFlat, supportFlat]) {
      expect(src).toMatch(
        /Recognition stays on device when Apple Speech supports it/i,
      );
      expect(src).toMatch(/Apple services may process the audio/i);
      expect(src).toMatch(
        /Phrasa and developer servers never receive audio or transcripts/i,
      );
    }
  });

  it("describes local-first use with optional opt-in then automatic-after-sign-in sync", () => {
    expect(privacyFlat).toMatch(
      /scripts and settings stay on your device|Documents and settings stay on your device|stored in a local database on your device|Scripts, folders, tags, outlines, reader settings/i,
    );
    expect(privacyFlat).toMatch(/optional/i);
    expect(privacyFlat).toMatch(/Sign in with Apple/i);
    expect(privacyFlat).toMatch(/Supabase/i);
    expect(privacyFlat).toMatch(/App Functionality/i);
    expect(privacyFlat).toMatch(
      /email address|private relay address/i,
    );
    expect(privacyFlat).toMatch(/user UUID|account identifier/i);
    // Shipping cloud content only (reader settings are local-only).
    expect(privacyFlat).toMatch(
      /Scripts, folders, tags, and outlines linked to your account/i,
    );
    expect(privacyFlat).toMatch(
      /Reader settings remain local|not uploaded or downloaded in this release/i,
    );
    expect(privacyFlat).not.toMatch(
      /Scripts, folders, tags, outlines, and reader settings linked/i,
    );
    // Opt-in by sign-in, then automatic triggers + Sync now.
    expect(privacyFlat).toMatch(/opt(?:ing|s)? in by signing in|After you opt in by signing in|After sign-in/i);
    expect(privacyFlat).toMatch(/automatically synchroniz/i);
    expect(privacyFlat).toMatch(/launch/i);
    expect(privacyFlat).toMatch(/foreground/i);
    expect(privacyFlat).toMatch(/800/i);
    expect(privacyFlat).toMatch(/Sync now/i);
    expect(privacyFlat).toMatch(/Unsaved drafts are not uploaded/i);
    // Must not claim user-initiated-only / not automatic sync model.
    expect(privacyFlat).not.toMatch(/Sync is user-initiated, not automatic/i);
    expect(privacyFlat).not.toMatch(/it is not automatic background upload/i);
    expect(privacyFlat).toMatch(/no ads|There are no ads/i);
    expect(privacyFlat).toMatch(/tracking/i);
    expect(privacyFlat).toMatch(/in-app purchases|payment/i);
    expect(privacyFlat).toMatch(/advertising/i);
    expect(privacyFlat).toMatch(
      /microphone audio or speech recognition text are never sent to Phrasa or Supabase|never receive microphone audio or speech recognition text/i,
    );
    // Must not falsely claim there is no account/sync product surface.
    expect(privacyFlat).not.toMatch(
      /does not include a Phrasa account, cloud sync, ads, tracking, or payments/i,
    );
    expect(privacyFlat).not.toMatch(
      /Create a Phrasa cloud account or offer remote library sync/i,
    );
    expect(supportFlat).toMatch(/Optional account and sync/i);
    expect(supportFlat).toMatch(/automatically on launch and foreground/i);
    expect(supportFlat).toMatch(/Sync now/i);
    expect(supportFlat).toMatch(/Unsaved drafts are not uploaded/i);
    expect(supportFlat).toMatch(/Sign in with Apple is primary/i);
    expect(supportFlat).toMatch(/Account deletion|account deletion/i);
    expect(supportFlat).toMatch(
      /Reader settings stay on each device|not uploaded or downloaded/i,
    );
    expect(supportFlat).not.toMatch(
      /scripts, folders, tags, outlines, and reader settings/i,
    );
    expect(supportFlat).not.toMatch(/Sync is user-initiated, not automatic/i);
    expect(termsFlat).toMatch(/optional.*sync|No account required for local use/i);
    expect(termsFlat).toMatch(/automatically on launch|Reader settings remain local/i);
    expect(termsFlat).toMatch(/Unsaved drafts are not uploaded/i);
    expect(termsFlat).not.toMatch(
      /scripts, folders, tags, outlines, and reader settings/i,
    );
    expect(termsFlat).not.toMatch(/Sync is user-initiated, not automatic/i);
    expect(homeFlat).toMatch(/optional.*sync|Local first, optional sync/i);
    expect(homeFlat).toMatch(/No account is required for local use/i);
    expect(homeFlat).toMatch(/scripts, folders, tags, and outlines/i);
    expect(homeFlat).toMatch(/automatic after sign-in|Sync now/i);
    expect(homeFlat).toMatch(/web companion|Open web companion/i);
    expect(homeFlat).toMatch(/Voice Follow is native-only|native-only/i);
    expect(homeFlat).toMatch(/open source/i);
    expect(home).toMatch(/sourceCodeUrl/);
    expect(termsFlat).toMatch(/Apache License 2\.0/i);
    expect(termsFlat).not.toMatch(/may not reverse engineer/i);
  });

  it("covers required support self-service topics", () => {
    expect(support).toMatch(/Create and import documents/i);
    expect(support).toMatch(/Web companion/i);
    expect(support).toMatch(/Speed mode/i);
    expect(support).toMatch(/Voice following/i);
    expect(support).toMatch(/Optional account and sync/i);
    expect(support).toMatch(/Backup and restore/i);
    expect(support).toMatch(/Offline use/i);
    expect(support).toMatch(/Feedback for beta testers/i);
    expect(supportFlat).toMatch(
      /If you (received Phrasa through TestFlight|are a TestFlight beta tester)/i,
    );
    expect(supportFlat).toMatch(
      /Public App Store users are not expected to use TestFlight/i,
    );
    // No circular "use the App Store Support URL/channel" loop.
    expect(supportFlat).not.toMatch(
      /Support URL or contact channel Apple shows/i,
    );
    expect(supportFlat).not.toMatch(
      /any support channel Apple shows for the listing/i,
    );
  });

  it("states accurate offline use with conditional voice following", () => {
    // Core library features work offline unconditionally.
    expect(supportFlat).toMatch(
      /Library, editing, speed mode, import, export, and backup work offline/i,
    );
    // Voice following is offline only when Apple Speech is on-device.
    expect(supportFlat).toMatch(
      /Voice following works offline only when Apple Speech provides on-device recognition/i,
    );
    expect(supportFlat).toMatch(/may need an internet connection/i);
    // Forbid blanket offline-voice claims that ignore network speech fallback.
    expect(supportFlat).not.toMatch(
      /optional voice following[^.]*work without a network/i,
    );
    expect(supportFlat).not.toMatch(
      /voice following[^.]*designed to work without a network/i,
    );
    expect(supportFlat).not.toMatch(
      /voice following[^.]*subject to device speech availability/i,
    );
  });

  it("covers required privacy topics and routes contact to Support", () => {
    expect(privacy).toMatch(/Local storage on your device/i);
    expect(privacy).toMatch(/Optional account and cross-device sync/i);
    expect(privacy).toMatch(/Microphone and speech recognition/i);
    expect(privacy).toMatch(/Files you import, export, or back up/i);
    expect(privacy).toMatch(/What Phrasa does not do/i);
    expect(privacy).toMatch(/Retention and deletion/i);
    expect(privacy).toMatch(/Children/i);
    expect(privacy).toMatch(/Changes/i);
    expect(privacy).toMatch(/Contact/i);
    expect(privacyFlat).toMatch(/href="\/support"/);
    expect(privacyFlat).toMatch(/see Support|Support/i);
    // Honest incomplete-revocation disclosure (not claiming token revoke is done).
    expect(privacyFlat).toMatch(/token revocation/i);
  });

  it("exports route metadata for privacy and support", () => {
    for (const src of [privacy, support]) {
      expect(src).toMatch(/export const metadata/);
      expect(src).toMatch(/alternates:\s*\{\s*canonical:/);
      expect(src).toMatch(/title:/);
      expect(src).toMatch(/description/);
    }
  });
});
