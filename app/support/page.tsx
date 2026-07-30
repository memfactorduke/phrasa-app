import type { Metadata } from "next";
import Link from "next/link";
import {
  LegalPage,
  LegalSection,
  LegalList,
} from "@/components/site/legal-page";

const description =
  "Self-service help for Phrasa: documents, speed mode, voice permissions, optional sync, backups, offline use, and feedback.";

export const metadata: Metadata = {
  title: "Support",
  description,
  alternates: { canonical: "/support" },
  openGraph: {
    title: "Support · Phrasa",
    description,
  },
};

export default function SupportPage() {
  return (
    <LegalPage title="Support" lastUpdated="July 29, 2026">
      <LegalSection title="How to get help">
        <p>
          Use this page for common setup and recovery questions. The steps below
          cover the day-to-day Phrasa experience on your device and in the web
          companion—creating scripts, presenting, permissions, optional sync,
          and backups.
        </p>
        <LegalList
          items={[
            "Start with the topics below for self-service fixes.",
            "For privacy details, open the Privacy Policy.",
            "If you received Phrasa through TestFlight as a beta tester, you can send feedback through TestFlight with a screenshot and a short description of what you expected.",
            <>
              Email{" "}
              <a
                href="mailto:support@phrasa.app"
                className="text-ink underline underline-offset-4"
              >
                support@phrasa.app
              </a>{" "}
              when self-service steps do not solve the issue.
            </>,
          ]}
        />
      </LegalSection>

      <LegalSection title="Create and import documents">
        <p>
          From the library you can create a new script, open the sample, or
          import a file. Native apps support common text formats such as TXT and
          Markdown, and PDF import when offered. The web companion focuses on
          create, edit, search, and present in the browser.
        </p>
        <LegalList
          items={[
            "Create a script, edit the title and body, and trust autosave on device or in the browser.",
            "Organize with folders, tags, search, and sort as your library grows (fullest on native).",
            "Import from Files on native apps when you already have a script elsewhere.",
            "Export a single script as text or Phrasa JSON on native apps when you need a copy outside the app.",
          ]}
        />
      </LegalSection>

      <LegalSection title="Web companion">
        <p>
          Open /app for the browser library, editor, and speed teleprompter.
          Guest mode stores scripts in this browser with no cloud configuration.
          When cloud is configured, Sign in with Apple is primary and email and
          password is secondary. Voice Follow is not available on the web.
        </p>
        <LegalList
          items={[
            "Create and edit scripts; they autosave in local browser storage namespaced by guest or account.",
            "Present with speed mode, countdown Off/5/15 (default 5), WPM, font size, focus line, margins, and mirrors.",
            "After sign-in, you may import guest scripts only when remote upload succeeds; guest copies clear only after successful upsert.",
            "Sign out returns you to guest mode and never shows the previous account’s cached library.",
          ]}
        />
      </LegalSection>

      <LegalSection title="Speed mode">
        <p>
          Speed mode scrolls the script at a pace you control and does not need
          the microphone. Use it for rehearsal or live reads when voice is
          unavailable, denied, or simply not preferred. The web companion is
          speed mode only.
        </p>
        <LegalList
          items={[
            "Open a script, enter the reader, and start speed mode after the countdown if one is enabled.",
            "Pause, scrub, adjust words-per-minute, and use blackout when you need a blank stage.",
            "Finish a run to see a short rehearsal recap on device (native) or a simple completion notice on web.",
          ]}
        />
      </LegalSection>

      <LegalSection title="Voice following">
        <p>
          Voice following is available in the native iPhone and iPad apps. The
          prerelease Mac workspace and web companion use speed prompting and do
          not show voice controls.
        </p>
        <p>If voice following will not start or will not track on a device:</p>
        <LegalList
          items={[
            "Confirm Phrasa has Microphone and Speech Recognition permission in iOS Settings.",
            "Quit and reopen the app after changing permissions.",
            "Read clearly near the device mic; very noisy rooms can reduce recognition quality.",
            "Fall back to speed mode so you can still present while speech is unavailable.",
          ]}
        />
        <p>
          Recognition stays on device when Apple Speech supports it; otherwise
          Apple services may process the audio. Phrasa uses recognized words in
          the app only to follow your place; Phrasa&rsquo;s developer-operated
          servers never receive microphone audio or speech recognition text.
        </p>
      </LegalSection>

      <LegalSection title="Optional account and sync">
        <p>
          No account is required for local use. Optional sign-in opts you into
          cross-device sync of scripts, folders, tags, and outlines. Sign in with
          Apple is primary; email and password is secondary. After you sign in,
          those items synchronize automatically on launch and foreground, and
          shortly after you save library changes. You can also use Sync now.
          Unsaved drafts are not uploaded. Reader settings stay on each device
          and are not uploaded or downloaded in this release.
        </p>
        <LegalList
          items={[
            "Open Account & sync when you want the same scripts, folders, tags, and outlines on more than one device.",
            "Prefer Sign in with Apple; use email and password only if you need that path.",
            "After sign-in, automatic sync runs when the app launches, returns to the foreground, or shortly after durable library saves; Sync now forces a pass when you want one.",
            "Save edits before expecting them on another device—unsaved drafts stay local.",
            "Offline use continues for local library features, including local reader settings, even if you are signed out.",
            "To remove cloud data for your account, use in-app account deletion. Sign in with Apple accounts require a second Apple confirmation so Phrasa can revoke Apple access on the server before deleting the cloud account; that server step must be configured and verified before production use.",
          ]}
        />
      </LegalSection>

      <LegalSection title="Backup and restore">
        <p>
          Backups are user-initiated. Export a versioned library backup from the
          app, store it somewhere you control, then restore with merge or replace
          when you need to recover. Prefer an explicit backup before major device
          migrations or OS upgrades.
        </p>
        <LegalList
          items={[
            "If a restore fails, your previous on-device library should remain intact.",
            "Replace is destructive of the current library contents—confirm before proceeding.",
            "Optional sync is separate from file backups; keep an export if you want a copy you control outside the account.",
          ]}
        />
      </LegalSection>

      <LegalSection title="Offline use">
        <p>
          In native apps, library, editing, speed mode, import, export, and
          backup work offline and without signing in. In the web companion,
          scripts are kept in local browser storage, but a fresh load or reload
          can still need a network connection because there is no installed
          offline web app shell. Optional signed-in sync always needs a network
          connection.
          Voice following works offline only when Apple Speech provides on-device
          recognition; otherwise it may need an internet connection. Airplane
          mode is a valid way to present.
        </p>
      </LegalSection>

      <LegalSection title="Feedback for beta testers">
        <p>
          If you are a TestFlight beta tester, the most useful reports include
          device model and iOS version, whether you used speed or voice, steps to
          reproduce, and what you expected instead. Especially useful topics:
        </p>
        <LegalList
          items={[
            "Voice tracking that jumps backward or stalls mid-read",
            "Lost edits after backgrounding or force-quit",
            "Import, export, or backup restore failures",
            "Optional sync or sign-in problems across Mac and iPad",
            "Reader controls that are hard to reach in landscape or on iPad",
          ]}
        />
        <p>
          Public App Store users are not expected to use TestFlight. Use the
          self-service steps above, or email{" "}
          <a
            href="mailto:support@phrasa.app"
            className="text-ink underline underline-offset-4"
          >
            support@phrasa.app
          </a>
          .
        </p>
      </LegalSection>

      <LegalSection title="Privacy and data">
        <p>
          Documents and reader settings stay on your device for local use. If you
          sign in to an optional account, account data plus scripts, folders,
          tags, and outlines can be sent to the dedicated Phrasa Supabase project
          for App Functionality and cross-device sync only—automatically after
          sign-in on launch, foreground, and shortly after saved library changes,
          and via Sync now. Unsaved drafts are not uploaded. Reader settings are
          not synced in this release. For microphone, speech, retention, and what
          is not collected, read the{" "}
          <Link
            href="/privacy"
            className="text-ink underline underline-offset-4"
          >
            Privacy Policy
          </Link>
          .
        </p>
      </LegalSection>

      <LegalSection title="Platforms">
        <p>
          Phrasa targets iPhone and iPad (iOS/iPadOS 17+). The native Mac
          workspace is prerelease and has no public download yet. The web
          companion provides a browser library, editor, and speed teleprompter.
          There is no Android or Windows app.
        </p>
      </LegalSection>
    </LegalPage>
  );
}
