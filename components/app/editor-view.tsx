"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState } from "react";
import { useRouter } from "next/navigation";
import { wordCount } from "@/lib/app/models/metrics";
import { useApp } from "./app-provider";
import { AppShell } from "./app-shell";

function EditorForm({
  scriptId,
  initialTitle,
  initialBody,
}: {
  scriptId: string;
  initialTitle: string;
  initialBody: string;
}) {
  const router = useRouter();
  const { updateScript, deleteScript, touchOpened, library } = useApp();
  const [title, setTitle] = useState(initialTitle);
  const [body, setBody] = useState(initialBody);
  const locallySubmittedTitle = useRef(initialTitle);
  const locallySubmittedBody = useRef(initialBody);
  const script = useMemo(
    () => library.scripts.find((s) => s.id === scriptId),
    [library.scripts, scriptId],
  );

  useEffect(() => {
    touchOpened(scriptId);
  }, [scriptId, touchOpened]);

  useEffect(() => {
    // A cloud/cross-tab replacement is authoritative once it reaches the
    // provider. Local keystrokes are persisted synchronously below, so there is
    // no debounce-only draft to preserve here.
    if (!script) return;
    if (
      script.title !==
      (locallySubmittedTitle.current.trim() || "Untitled script")
    ) {
      locallySubmittedTitle.current = script.title;
      // This effect is the subscription boundary for provider/cloud changes.
      setTitle(script.title);
    }
    if (script.body !== locallySubmittedBody.current) {
      locallySubmittedBody.current = script.body;
      // This effect is the subscription boundary for provider/cloud changes.
      setBody(script.body);
    }
  }, [script]);

  return (
    <AppShell
      title="Editor"
      actions={
        <>
          <Link
            href={`/app/scripts/${scriptId}/read`}
            data-testid="open-reader"
            className="inline-flex min-h-11 items-center justify-center rounded-md bg-ink px-3 text-sm font-medium text-canvas"
          >
            Present
          </Link>
          <button
            type="button"
            className="inline-flex min-h-11 items-center justify-center rounded-md border border-divider px-3 text-sm text-ink-muted"
            onClick={() => router.push("/app")}
          >
            Library
          </button>
        </>
      }
    >
      <div className="space-y-4">
        <label className="block">
          <span className="mb-1 block text-xs text-ink-muted">Title</span>
          <input
            data-testid="script-title"
            value={title}
            onChange={(e) => {
              const nextTitle = e.target.value;
              locallySubmittedTitle.current = nextTitle;
              setTitle(nextTitle);
              // Local durability is synchronous; the provider separately
              // debounces cloud transport. Immediate navigation can therefore
              // never discard the last title keystrokes.
              updateScript(scriptId, { title: nextTitle });
            }}
            className="w-full min-h-11 rounded-md border border-divider bg-surface px-3 text-base font-medium text-ink"
          />
        </label>
        <label className="block">
          <span className="mb-1 block text-xs text-ink-muted">Script</span>
          <textarea
            data-testid="script-body"
            value={body}
            onChange={(e) => {
              const nextBody = e.target.value;
              locallySubmittedBody.current = nextBody;
              setBody(nextBody);
              updateScript(scriptId, { body: nextBody });
            }}
            rows={18}
            className="w-full resize-y rounded-md border border-divider bg-surface px-3 py-3 font-sans text-base leading-relaxed text-ink"
            spellCheck
          />
        </label>
        <div className="flex flex-wrap items-center justify-between gap-3 text-xs text-ink-muted">
          <p>
            {wordCount(body)} words · autosaves in this browser
            {script?.remoteUpdatedAtWire ? " · linked to cloud row" : ""}
          </p>
          <button
            type="button"
            className="inline-flex min-h-11 items-center text-danger underline-offset-4 hover:underline"
            onClick={() => {
              if (window.confirm(`Delete “${title}”?`)) {
                deleteScript(scriptId);
                router.push("/app");
              }
            }}
          >
            Delete script
          </button>
        </div>
      </div>
    </AppShell>
  );
}

export function EditorView({ scriptId }: { scriptId: string }) {
  const { ready, library } = useApp();
  const script = useMemo(
    () => library.scripts.find((s) => s.id === scriptId),
    [library.scripts, scriptId],
  );

  if (!ready) {
    return (
      <AppShell title="Editor">
        <p className="text-sm text-ink-muted">Loading…</p>
      </AppShell>
    );
  }

  if (!script) {
    return (
      <AppShell title="Editor">
        <div className="space-y-3">
          <p className="text-sm text-ink-muted">Script not found in this library.</p>
          <Link href="/app" className="text-sm text-ink underline-offset-4 hover:underline">
            Back to library
          </Link>
        </div>
      </AppShell>
    );
  }

  // Remount form when switching scripts so local draft state stays honest.
  return (
    <EditorForm
      key={script.id}
      scriptId={script.id}
      initialTitle={script.title}
      initialBody={script.body}
    />
  );
}
