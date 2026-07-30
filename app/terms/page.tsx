import type { Metadata } from "next";
import Link from "next/link";
import {
  LegalPage,
  LegalSection,
  LegalList,
} from "@/components/site/legal-page";

const description =
  "License terms for the Phrasa apps: your content stays yours, optional sync, what we provide, and what we ask.";

export const metadata: Metadata = {
  title: "Terms of Service",
  description,
  alternates: { canonical: "/terms" },
};

export default function TermsPage() {
  return (
    <LegalPage title="Terms of Service" lastUpdated="July 30, 2026">
      <LegalSection title="The short version">
        <p>
          Phrasa is a native teleprompter for Apple platforms, with an optional
          web companion for scripts and speed prompting. Your scripts are yours.
          Use the apps reasonably. The software is provided as-is — if you
          present live, keep a fallback, as any app can have a bad day.
        </p>
      </LegalSection>

      <LegalSection title="The product">
        <p>
          Phrasa lets you write or import scripts, present them with speed or
          (on native apps) voice prompting, manage a local library on your
          device or in the browser companion, and export or back up that library
          yourself on native apps. An account is optional for cross-device sync
          of selected library content. The public website also hosts the web
          companion at /app. By downloading or using the apps or web companion
          you agree to these terms; if you do not agree, do not use them.
        </p>
      </LegalSection>

      <LegalSection title="Your content">
        <p>
          You keep all rights to scripts, outlines, and files you create or
          import. You grant only the limited permission needed for the app to
          store them on device and, if you sign in to an optional account, to
          store and sync scripts, folders, tags, and outlines through the
          dedicated Phrasa backend solely for App Functionality. After sign-in,
          that library content can sync automatically on launch, foreground, and
          shortly after saved changes, and via Sync now. Unsaved drafts are not
          uploaded. Reader settings stay on each device in this release. You are
          responsible for having the rights to any material you import.
        </p>
      </LegalSection>

      <LegalSection title="License">
        <p>
          Phrasa&rsquo;s source code is available under the Apache License 2.0,
          which permits inspection, modification, redistribution, and
          commercial use subject to its notice and attribution requirements.
          The App Store copy is also subject to Apple&rsquo;s applicable terms.
          The source license does not grant permission to use the Phrasa name,
          logo, or other Memorable Factor trademarks for a different product.
        </p>
      </LegalSection>

      <LegalSection title="No account required for local use">
        <p>
          Core features work without an account. Library, editing, prompting,
          export, and backup work offline on a single device. Optional sign-in
          (Sign in with Apple primary; email and password secondary) opts you
          into cross-device sync of scripts, folders, tags, and outlines. After
          sign-in, that content synchronizes automatically on launch, foreground,
          and shortly after saved library changes; Sync now is also available.
          Unsaved drafts are not uploaded. Reader settings remain local on each
          device. If you use optional sync, you are responsible for keeping your
          credentials secure and for using account deletion controls when you
          want cloud data removed.
        </p>
      </LegalSection>

      <LegalSection title="Acceptable use">
        <p>Do not:</p>
        <LegalList
          items={[
            "use the apps to violate the law or others' rights;",
            "attack, bypass authorization for, or disrupt developer-operated accounts, sync, or related systems;",
            "impersonate Phrasa or claim endorsement by Memorable Factor;",
            "abuse optional accounts or sync (for example, attempt to access another person's library).",
          ]}
        />
      </LegalSection>

      <LegalSection title="No warranty">
        <p>
          The apps and this website are provided{" "}
          <strong className="font-medium text-ink">&ldquo;as is&rdquo;</strong>{" "}
          and{" "}
          <strong className="font-medium text-ink">
            &ldquo;as available&rdquo;
          </strong>
          , without warranties of any kind, express or implied. We do not
          guarantee uninterrupted operation, perfect speech recognition,
          uninterrupted sync, or fitness for a particular broadcast or stage
          use.
        </p>
      </LegalSection>

      <LegalSection title="Limitation of liability">
        <p>
          To the maximum extent permitted by law, we are not liable for
          indirect, incidental, special, or consequential damages — including
          lost profits or a disrupted live read — arising from your use of the
          apps or this site. Our total liability for any claim is limited to
          the amount you paid us for the app in the twelve months before the
          claim, or zero if you paid nothing.
        </p>
      </LegalSection>

      <LegalSection title="Changes and termination">
        <p>
          We may update these terms as the product evolves. The date at the top
          of this page will change when we do. You may stop using the apps at
          any time by deleting them. Removing the app removes its local data
          from that device according to the operating system. If you used
          optional sync, use a working in-app account-deletion control to remove
          cloud library data linked to your account. If an Apple-linked deletion
          reports that it could not complete, contact support; that path fails
          closed instead of claiming deletion succeeded.
        </p>
      </LegalSection>

      <LegalSection title="Contact">
        <p>
          Questions about these terms can start on the{" "}
          <Link
            href="/support"
            className="text-ink underline underline-offset-4"
          >
            Support
          </Link>{" "}
          page for self-service help and the published support contact.
        </p>
      </LegalSection>
    </LegalPage>
  );
}
