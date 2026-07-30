import { SiteShell } from "@/components/site/site-shell";

function slugify(title: string): string {
  return title
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/(^-|-$)/g, "");
}

export function LegalPage({
  title,
  lastUpdated,
  children,
}: {
  title: string;
  lastUpdated: string;
  children: React.ReactNode;
}) {
  const headingId = "legal-page-title";

  return (
    <SiteShell>
      <article
        className="mx-auto max-w-3xl px-5 py-14 sm:py-16"
        aria-labelledby={headingId}
      >
        <header>
          <h1
            id={headingId}
            className="text-3xl font-medium tracking-tight sm:text-4xl"
          >
            {title}
          </h1>
          <p className="mt-3 text-xs uppercase tracking-[0.16em] text-ink-muted">
            Last updated {lastUpdated}
          </p>
        </header>
        <div className="mt-10">{children}</div>
      </article>
    </SiteShell>
  );
}

export function LegalSection({
  title,
  children,
  id,
}: {
  title: string;
  children: React.ReactNode;
  /** Optional stable id; defaults to a slug of the section title. */
  id?: string;
}) {
  const sectionId = id ?? slugify(title);
  const headingId = `${sectionId}-heading`;

  return (
    <section className="mt-10 first:mt-0" id={sectionId} aria-labelledby={headingId}>
      <h2
        id={headingId}
        className="text-xl font-medium tracking-tight sm:text-2xl"
      >
        {title}
      </h2>
      <div className="mt-3 space-y-3 text-base leading-relaxed text-ink-muted">
        {children}
      </div>
    </section>
  );
}

export function LegalList({ items }: { items: React.ReactNode[] }) {
  return (
    <ul className="list-disc space-y-2 pl-5">
      {items.map((item, i) => (
        <li key={i}>{item}</li>
      ))}
    </ul>
  );
}
