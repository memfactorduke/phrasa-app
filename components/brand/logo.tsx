import Link from "next/link";

/**
 * The app icon beside the wordmark. The icon is the app's own
 * (public/icon.svg, made by ExpoPhrasa's distribution/app-store/icon).
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
      className={`inline-flex min-h-11 items-center gap-2.5 text-[1.125rem] font-medium tracking-tight text-ink ${className}`.trim()}
      aria-label="Phrasa home"
    >
      {/* eslint-disable-next-line @next/next/no-img-element -- a fixed-size SVG needs no optimizing */}
      <img src="/icon.svg" alt="" width={28} height={28} className="size-7" />
      Phrasa
    </Link>
  );
}
