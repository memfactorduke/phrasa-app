import { Logo } from "@/components/brand/logo";
import { SiteNav } from "@/components/site/site-nav";
import { sourceCodeUrl } from "@/lib/site";

export function SiteFooter() {
  return (
    <footer className="mt-auto border-t border-divider">
      <div className="mx-auto flex max-w-3xl flex-col items-start justify-between gap-6 px-5 py-10 sm:flex-row sm:items-center">
        <div>
          <Logo />
          <p className="mt-2 text-sm text-ink-muted">
            Local-first teleprompter for Apple platforms.
          </p>
          <a
            href={sourceCodeUrl}
            target="_blank"
            rel="noreferrer"
            className="mt-2 inline-flex min-h-11 items-center text-sm text-ink-muted underline-offset-4 hover:text-ink hover:underline"
          >
            Open-source code
          </a>
        </div>
        <SiteNav label="Footer" />
      </div>
    </footer>
  );
}
