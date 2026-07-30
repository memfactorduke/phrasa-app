import Link from "next/link";

const links = [
  { href: "/app", label: "Web app" },
  { href: "/support", label: "Support" },
  { href: "/privacy", label: "Privacy" },
  { href: "/terms", label: "Terms" },
] as const;

/**
 * Shared legal/support links. Pass a unique aria-label when both header and
 * footer render a nav so landmarks stay distinguishable.
 */
export function SiteNav({
  className = "",
  label = "Site",
}: {
  className?: string;
  label?: string;
}) {
  return (
    <nav
      aria-label={label}
      className={`flex flex-wrap items-center gap-x-5 gap-y-2 text-sm text-ink-muted ${className}`.trim()}
    >
      {links.map((link) => (
        <Link
          key={link.href}
          href={link.href}
          className="inline-flex min-h-11 items-center justify-center transition-colors hover:text-ink focus-visible:text-ink"
        >
          {link.label}
        </Link>
      ))}
    </nav>
  );
}
