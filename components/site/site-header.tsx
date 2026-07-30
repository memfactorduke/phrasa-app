import { Logo } from "@/components/brand/logo";
import { SiteNav } from "@/components/site/site-nav";

export function SiteHeader() {
  return (
    <header className="border-b border-divider">
      <div className="mx-auto flex min-h-14 max-w-3xl items-center justify-between gap-4 px-5 py-1 sm:min-h-16">
        <Logo />
        <SiteNav label="Primary" />
      </div>
    </header>
  );
}
