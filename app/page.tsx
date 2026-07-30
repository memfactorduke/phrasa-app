import type { Metadata } from "next";
import Link from "next/link";
import { SiteShell } from "@/components/site/site-shell";
import { StoreCta } from "@/components/site/store-cta";
import { platforms, sourceCodeUrl } from "@/lib/site";

export const metadata: Metadata = {
  alternates: { canonical: "/" },
};

const pillars = [
  {
    title: "Write and import",
    body: "Create a script, paste from elsewhere, or bring in TXT, Markdown, or PDF on native apps. The web companion keeps a script library and editor in your browser. Everything autosaves locally; native apps also support folders, tags, and durable device storage.",
  },
  {
    title: "Speed and voice",
    body: "Scroll at a steady pace you control on every surface. On iPhone and iPad you can also let the prompter follow your speech. Recognition stays on device when Apple Speech supports it; otherwise Apple services may process the audio. Phrasa and developer servers never receive audio or transcripts. Mac and web prompting are speed-only today.",
  },
  {
    title: "Local first, optional sync",
    body: "Native library, editing, prompting, import, export, and backup work offline. No account is required for local use. Sign in only if you want optional cross-device sync of scripts, folders, tags, and outlines; sync is automatic after sign-in, with a Sync now control available. The web companion keeps guest scripts in local browser storage and can sync an existing account when cloud is configured; opening or reloading the web app itself can still require a network connection.",
  },
] as const;

export default function HomePage() {
  return (
    <SiteShell>
      <section className="mx-auto max-w-3xl px-5 pb-20 pt-16 sm:pb-28 sm:pt-24">
        <p className="text-xs font-medium uppercase tracking-[0.18em] text-ink-muted">
          {platforms.join(" · ")}
        </p>
        <h1 className="mt-5 max-w-xl text-4xl font-medium leading-[1.08] tracking-tight sm:text-5xl">
          Read like you&rsquo;re not reading.
        </h1>
        <p className="mt-6 max-w-lg text-lg leading-relaxed text-ink-muted">
          Phrasa is a calm, local-first teleprompter for iPhone and iPad, with a
          browser companion and a native Mac workspace in prerelease development.
          Write or import a script, open a distraction-free stage, and either read
          at a dependable speed or let the text follow your voice on iOS. The
          complete product is open source.
        </p>

        <div className="mt-10 flex flex-col items-start gap-4 sm:flex-row sm:items-center">
          <StoreCta />
          <Link
            href="/app"
            className="inline-flex min-h-11 items-center rounded-md border border-divider px-4 text-sm font-medium text-ink transition-colors hover:bg-surface"
          >
            Open web companion
          </Link>
          <Link
            href="/support"
            className="inline-flex min-h-11 items-center text-sm text-ink-muted underline-offset-4 transition-colors hover:text-ink hover:underline"
          >
            Support and help
          </Link>
          <a
            href={sourceCodeUrl}
            target="_blank"
            rel="noreferrer"
            className="inline-flex min-h-11 items-center text-sm text-ink-muted underline-offset-4 transition-colors hover:text-ink hover:underline"
          >
            View source
          </a>
        </div>

        <p className="mt-4 max-w-md text-sm text-ink-muted">
          iPhone and iPad are the full native product. Voice Follow is native-only
          on those iOS devices.
          The web companion offers local browser scripts, an editor, and speed
          prompting. Mac is speed-only and remains prerelease.
        </p>
      </section>

      <section
        aria-labelledby="open-source"
        className="border-t border-divider"
      >
        <div className="mx-auto max-w-3xl px-5 py-16 sm:py-20">
          <p className="text-xs font-medium uppercase tracking-[0.18em] text-ink-muted">
            Open source
          </p>
          <h2
            id="open-source"
            className="mt-4 max-w-xl text-2xl font-medium tracking-tight sm:text-3xl"
          >
            Trust the tool you read from.
          </h2>
          <p className="mt-4 max-w-2xl leading-relaxed text-ink-muted">
            Phrasa&rsquo;s complete app, web companion, sync, and test source is
            public under the Apache License 2.0. Read how your scripts are
            handled, audit the privacy claims, report an issue, or contribute an
            improvement.
          </p>
          <a
            href={sourceCodeUrl}
            target="_blank"
            rel="noreferrer"
            className="mt-6 inline-flex min-h-11 items-center rounded-md border border-divider px-4 text-sm font-medium text-ink transition-colors hover:bg-surface"
          >
            Explore Phrasa on GitHub
          </a>
        </div>
      </section>

      <section
        aria-labelledby="what-it-does"
        className="border-t border-divider"
      >
        <div className="mx-auto max-w-3xl px-5 py-16 sm:py-20">
          <h2
            id="what-it-does"
            className="text-2xl font-medium tracking-tight sm:text-3xl"
          >
            What it does
          </h2>
          <ul className="mt-10 grid gap-10 sm:grid-cols-1">
            {pillars.map((item) => (
              <li key={item.title} className="border-t border-divider pt-6">
                <h3 className="text-lg font-medium text-ink">{item.title}</h3>
                <p className="mt-2 max-w-prose leading-relaxed text-ink-muted">
                  {item.body}
                </p>
              </li>
            ))}
          </ul>
        </div>
      </section>

      <section
        aria-labelledby="platforms"
        className="border-t border-divider"
      >
        <div className="mx-auto max-w-3xl px-5 py-16 sm:py-20">
          <h2
            id="platforms"
            className="text-2xl font-medium tracking-tight sm:text-3xl"
          >
            Built for Apple platforms
          </h2>
          <dl className="mt-10 grid gap-8 sm:grid-cols-2">
            <div>
              <dt className="text-sm font-medium text-ink">iPhone</dt>
              <dd className="mt-2 text-sm leading-relaxed text-ink-muted">
                Full-screen library, push editor, and touch-first reader with
                no accidental edge dismissal.
              </dd>
            </div>
            <div>
              <dt className="text-sm font-medium text-ink">iPad</dt>
              <dd className="mt-2 text-sm leading-relaxed text-ink-muted">
                Split view for folders and scripts, landscape-first stage, and
                hardware keyboard or remote control.
              </dd>
            </div>
            <div>
              <dt className="text-sm font-medium text-ink">Mac</dt>
              <dd className="mt-2 text-sm leading-relaxed text-ink-muted">
                A native multi-pane workspace, reader window, menus, clicker
                support, and speed prompting are in prerelease development.
                There is no public Mac download yet. Voice on Mac will ship only
                after it meets the same reliability bar as iOS.
              </dd>
            </div>
            <div>
              <dt className="text-sm font-medium text-ink">Web</dt>
              <dd className="mt-2 text-sm leading-relaxed text-ink-muted">
                Browser companion for library, editor, and speed teleprompter.
                Guest data stays in local browser storage. Existing accounts can
                sign in when sync is configured. Voice Follow, file import,
                export, and full-library backup remain native features.
              </dd>
            </div>
          </dl>
        </div>
      </section>
    </SiteShell>
  );
}
