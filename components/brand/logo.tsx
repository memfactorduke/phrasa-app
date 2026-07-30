import Link from "next/link";

/**
 * Plain wordmark — no tally glow, no accent color. Editorial black/white.
 */
export function Logo({
  className = "",
  href = "/",
}: {
  className?: string;
  href?: string;
}) {
  return (
    <Link
      href={href}
      className={`inline-flex min-h-11 items-center text-[1.125rem] font-medium tracking-tight text-ink ${className}`.trim()}
      aria-label="Phrasa home"
    >
      Phrasa
    </Link>
  );
}
