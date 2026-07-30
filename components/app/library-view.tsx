"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { useRouter } from "next/navigation";
import { previewText, wordCount } from "@/lib/app/models/metrics";
import { useApp } from "./app-provider";
import { AppShell } from "./app-shell";

export function LibraryView() {
  const router = useRouter();
  const { ready, library, createNewScript, deleteScript, duplicateScript } =
    useApp();
  const [query, setQuery] = useState("");

  const filtered = useMemo(() => {
    const q = query.trim().toLowerCase();
    if (!q) return library.scripts;
    return library.scripts.filter((s) => {
      const hay = `${s.title}\n${s.body}\n${s.tags.join(" ")}`.toLowerCase();
      return hay.includes(q);
    });
  }, [library.scripts, query]);

  return (
    <AppShell
      title="Library"
      actions={
        <button
          type="button"
          data-testid="new-script"
          className="inline-flex min-h-11 items-center justify-center rounded-md bg-ink px-3 text-sm font-medium text-canvas"
          onClick={() => {
            const script = createNewScript();
            router.push(`/app/scripts/${script.id}`);
          }}
        >
          New script
        </button>
      }
    >
      <div className="space-y-5">
        <label className="block">
          <span className="sr-only">Search scripts</span>
          <input
            type="search"
            data-testid="library-search"
            placeholder="Search title, body, or tags"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            className="w-full min-h-11 rounded-md border border-divider bg-surface px-3 text-sm text-ink placeholder:text-ink-muted"
          />
        </label>

        {!ready ? (
          <p className="text-sm text-ink-muted">Loading…</p>
        ) : filtered.length === 0 ? (
          <div className="rounded-md border border-divider p-6 text-sm text-ink-muted">
            <p>No scripts match.</p>
            <button
              type="button"
              className="mt-3 inline-flex min-h-11 items-center text-ink underline-offset-4 hover:underline"
              onClick={() => {
                const script = createNewScript();
                router.push(`/app/scripts/${script.id}`);
              }}
            >
              Create one
            </button>
          </div>
        ) : (
          <ul className="divide-y divide-divider border-y border-divider">
            {filtered.map((script) => (
              <li key={script.id} className="py-4">
                <div className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
                  <div className="min-w-0 flex-1">
                    <Link
                      href={`/app/scripts/${script.id}`}
                      className="text-base font-medium text-ink hover:underline"
                      data-testid={`script-link-${script.id}`}
                    >
                      {script.title}
                    </Link>
                    <p className="mt-1 line-clamp-2 text-sm text-ink-muted">
                      {previewText(script.body) || "Empty script"}
                    </p>
                    <p className="mt-2 text-xs text-ink-muted">
                      {wordCount(script.body)} words · updated{" "}
                      {new Date(script.updatedAt).toLocaleString()}
                    </p>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    <Link
                      href={`/app/scripts/${script.id}/read`}
                      className="inline-flex min-h-11 items-center rounded-md border border-divider px-3 text-sm text-ink"
                      data-testid={`present-${script.id}`}
                    >
                      Present
                    </Link>
                    <button
                      type="button"
                      className="inline-flex min-h-11 items-center rounded-md border border-divider px-3 text-sm text-ink-muted"
                      onClick={() => {
                        const copy = duplicateScript(script.id);
                        if (copy) router.push(`/app/scripts/${copy.id}`);
                      }}
                    >
                      Duplicate
                    </button>
                    <button
                      type="button"
                      className="inline-flex min-h-11 items-center rounded-md border border-divider px-3 text-sm text-danger"
                      onClick={() => {
                        if (
                          window.confirm(
                            `Delete “${script.title}”? This cannot be undone in this browser.`,
                          )
                        ) {
                          deleteScript(script.id);
                        }
                      }}
                    >
                      Delete
                    </button>
                  </div>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </AppShell>
  );
}
