import { appStoreUrl } from "@/lib/site";

/**
 * Honest App Store CTA: live link when a public URL is configured,
 * otherwise a non-interactive coming-soon state (no fake store badge).
 */
export function StoreCta({ className = "" }: { className?: string }) {
  if (appStoreUrl) {
    return (
      <a
        href={appStoreUrl}
        className={`inline-flex min-h-11 items-center justify-center rounded-[var(--radius-md)] bg-ink px-6 text-sm font-medium text-canvas transition-opacity hover:opacity-90 focus-visible:outline focus-visible:outline-2 focus-visible:outline-offset-3 focus-visible:outline-ink ${className}`.trim()}
        rel="noopener noreferrer"
      >
        Download on the App Store
      </a>
    );
  }

  return (
    <p
      className={`inline-flex min-h-11 items-center justify-center rounded-[var(--radius-md)] border border-divider bg-surface px-6 text-sm font-medium text-ink ${className}`.trim()}
      role="status"
    >
      Coming soon on the App Store
    </p>
  );
}
