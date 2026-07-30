import type { Metadata } from "next";
import Link from "next/link";
import {
  LegalPage,
  LegalSection,
  LegalList,
} from "@/components/site/legal-page";

const description =
  "How Phrasa stores scripts on your device, optional account sync, microphone and Apple Speech use, and what is not collected.";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description,
  alternates: { canonical: "/privacy" },
  openGraph: {
    title: "Privacy Policy · Phrasa",
    description,
  },
};

export default function PrivacyPage() {
  return (
    <LegalPage title="Privacy Policy" lastUpdated="July 29, 2026">
      <LegalSection title="The short version">
        <p>
          Phrasa is a local-first teleprompter for iPhone and iPad, with a
          prerelease Mac workspace and an optional web companion. Native
          library, editing, prompting, export, and backup work on your device
          without an account. The web companion keeps guest scripts in browser
          storage but does not provide native file backup/export or a guaranteed
          offline reload. An account is optional: if you sign in,
          Phrasa can send account and library content to a dedicated Supabase
          project solely for App Functionality and cross-device sync. After you
          opt in by signing in, scripts, folders, tags, and outlines synchronize
          automatically on launch and foreground, and shortly after you save
          library changes. A manual Sync now control is also available. There are
          no ads, tracking, analytics products, or sale of your data for
          marketing. When you use optional voice following on native apps,
          recognition stays on device when Apple Speech supports it; otherwise
          Apple services may process the audio. The Phrasa app uses recognized
          words in the moment to follow your place, but Phrasa&rsquo;s
          developer-operated servers and Supabase never receive microphone
          audio or speech recognition text. Voice Follow is offered on iPhone
          and iPad, not on Mac or web today.
        </p>
      </LegalSection>

      <LegalSection title="Who this applies to">
        <p>
          This policy covers the public Phrasa website (including the optional
          web companion at /app), the Phrasa apps for iPhone and iPad, and
          prerelease Mac builds.
          It is written in plain language so you can understand how data is
          handled. It is not legal advice and is not a certification under any
          particular privacy framework.
        </p>
      </LegalSection>

      <LegalSection title="This website">
        <p>
          The Phrasa website publishes product information, legal pages, and an
          optional web companion for scripts and speed prompting. Guest mode
          stores library data in your browser only. Sign-in and cloud sync run
          only when a Phrasa cloud project is configured. We do not set
          advertising cookies or run analytics pixels on these pages. Hosting
          providers may process standard server logs (such as IP address, user
          agent, and request path) to operate the site.
        </p>
      </LegalSection>

      <LegalSection title="Local storage on your device">
        <p>
          Scripts, folders, tags, outlines, reader settings, resume state, and
          rehearsal recaps are stored in a local database on your device. Library,
          editing, speed prompting, import, export, and backup work without an
          account or network connection. Reader settings, resume state, and
          rehearsal recaps stay on the device in this release. Scripts, folders,
          tags, and outlines stay on your device unless you opt in with an
          optional account; after sign-in they can sync to the dedicated Phrasa
          backend as described below. Unsaved drafts are not uploaded.
        </p>
        <p>
          Deleting the app, or deleting individual scripts in the library,
          removes that local data from that device according to the operating
          system and app controls. Local deletion does not by itself delete a
          cloud copy if you previously synced library content; use in-app account
          deletion or signed-in cloud controls for synced data.
        </p>
      </LegalSection>

      <LegalSection title="Optional account and cross-device sync">
        <p>
          No account is required for local use. Sign in is optional and exists so
          you can keep selected library content aligned across devices (for
          example Mac and iPad). Sign in with Apple is the primary sign-in path;
          email and password is a secondary option.
        </p>
        <p>
          Opting in means signing into an optional account. After sign-in, Phrasa
          automatically synchronizes scripts, folders, tags, and outlines on app
          launch, when authentication is restored, when the app returns to the
          foreground, and shortly after durable saved library changes (about
          800&nbsp;ms after a cloud-relevant save). You can also tap Sync now.
          Unsaved drafts are not uploaded. Reader settings remain local on each
          device and are not uploaded or downloaded in this release.
        </p>
        <p>
          When you are signed in for optional sync, Phrasa may send the following
          to the dedicated Phrasa Supabase project solely for App Functionality
          and cross-device sync:
        </p>
        <LegalList
          items={[
            "Email address, or the private relay address Apple provides when you use Sign in with Apple",
            "Supabase user UUID (account identifier)",
            "Scripts, folders, tags, and outlines linked to your account",
          ]}
        />
        <p>
          That account and library data is linked to your account. Phrasa does
          not use it for tracking, advertising, analytics products, or marketing,
          and does not sell it. Microphone audio and speech recognition text are
          never sent to Phrasa&rsquo;s developer-operated servers or Supabase.
        </p>
      </LegalSection>

      <LegalSection title="Microphone and speech recognition">
        <p>
          Voice following is optional. If you turn it on, Phrasa requests
          Microphone and Speech Recognition permission so it can listen while
          you read and advance the prompter.
        </p>
        <p>
          Recognition uses Apple Speech frameworks. Recognition stays on device
          when Apple Speech supports it; otherwise Apple services may process the
          audio under Apple&rsquo;s terms and privacy practices. The Phrasa app
          uses recognized words in the moment to follow your place.
          Phrasa&rsquo;s developer-operated servers and Supabase never receive
          microphone audio or speech recognition text.
        </p>
        <p>
          Phrasa uses recognized words only in the moment to follow your place
          in the script. The app does not store speech audio as a library of
          recordings for later review.
        </p>
        <p>
          If you deny microphone or speech permission, voice mode stops. You can
          keep presenting with speed mode, and you can change permissions later
          in system Settings.
        </p>
      </LegalSection>

      <LegalSection title="Files you import, export, or back up">
        <p>
          Imports (for example TXT, Markdown, or PDF), single-script exports,
          and full-library backups are user-initiated. You choose the files and
          destinations through the system share sheet or Files interfaces.
          Phrasa does not silently upload those files outside the optional sync
          path described above.
        </p>
      </LegalSection>

      <LegalSection title="What Phrasa does not do">
        <LegalList
          items={[
            "Require sign-in to write or present locally; native export and backup also work without an account.",
            "Include in-app purchases, subscriptions, or payment processing.",
            "Show ads or sell your scripts for advertising.",
            "Ship third-party advertising or analytics trackers in the app.",
            "Train third-party AI models on your scripts via this product.",
            "Upload guest browser scripts unless you explicitly sign in and choose optional sync.",
            "Send microphone audio or speech recognition text to Phrasa’s developer-operated servers or Supabase.",
          ]}
        />
      </LegalSection>

      <LegalSection title="Retention and deletion">
        <p>
          Local data remains on your device until you delete scripts, restore
          over them with a backup you choose, delete the app, or the operating
          system removes the app&rsquo;s data. Website hosting logs, if any, are
          retained only as long as the host needs them to operate the site.
        </p>
        <p>
          If you use optional sync, cloud copies linked to your account remain
          until you delete them through a working account-deletion control.
          Email-account deletion is designed to remove the Phrasa/Supabase
          account and associated synced library data. Accounts that use
          Sign&nbsp;in with Apple require a fresh Apple confirmation during
          deletion so Phrasa can request Apple token revocation on the server
          before the cloud account is removed. That Apple-linked server path is
          still awaiting live production verification; until it passes, it
          fails closed and does not remove data. Contact support if a deletion
          control reports that it could not complete.
        </p>
      </LegalSection>

      <LegalSection title="Children">
        <p>
          Phrasa is a general-purpose presentation tool. It is not directed at
          children under 13, and it does not knowingly collect personal
          information from children for advertising or tracking.
        </p>
      </LegalSection>

      <LegalSection title="Changes">
        <p>
          If this policy changes, we will update this page and the date above.
          Material product changes will require an updated privacy description
          before that behavior ships.
        </p>
      </LegalSection>

      <LegalSection title="Contact">
        <p>
          For help with the app and self-service recovery steps, see{" "}
          <Link
            href="/support"
            className="text-ink underline underline-offset-4"
          >
            Support
          </Link>
          . If you use Phrasa from the App Store, you can also use any support
          channel Apple shows for the listing.
        </p>
      </LegalSection>
    </LegalPage>
  );
}
