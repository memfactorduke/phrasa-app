import { estimatedSecondsRounded, wordCount } from "./metrics";

export type ScriptSource = "manual" | "upload" | "gdrive";

export type OutlinePoint = {
  id: string;
  text: string;
  note: string;
};

export type ScriptDocument = {
  id: string;
  title: string;
  body: string;
  source: ScriptSource;
  folderId: string | null;
  tags: string[];
  outline: OutlinePoint[];
  lastOpenedAt: string | null;
  createdAt: string;
  updatedAt: string;
  /** Exact remote `updated_at` wire string for OCC when known. */
  remoteUpdatedAtWire?: string | null;
  /** Content baseline acknowledged by the server, independent of wall clocks. */
  remoteContentFingerprint?: string | null;
};

export type ScriptFolder = {
  id: string;
  name: string;
  createdAt: string;
};

export type LibrarySnapshot = {
  scripts: ScriptDocument[];
  folders: ScriptFolder[];
};

export function newId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === "x" ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

export function normalizeTitle(title: string): string {
  const t = title.trim();
  return t.length === 0 ? "Untitled script" : t;
}

export function normalizeFolderName(name: string): string {
  const t = name.trim();
  return t.length === 0 ? "Untitled folder" : t;
}

export function createScript(
  partial: Partial<ScriptDocument> & { title?: string; body?: string } = {},
): ScriptDocument {
  const now = new Date().toISOString();
  return {
    id: partial.id ?? newId(),
    title: normalizeTitle(partial.title ?? "Untitled script"),
    body: partial.body ?? "",
    source: partial.source ?? "manual",
    folderId: partial.folderId ?? null,
    tags: partial.tags ?? [],
    outline: partial.outline ?? [],
    lastOpenedAt: partial.lastOpenedAt ?? null,
    createdAt: partial.createdAt ?? now,
    updatedAt: partial.updatedAt ?? now,
    remoteUpdatedAtWire: partial.remoteUpdatedAtWire ?? null,
    remoteContentFingerprint: partial.remoteContentFingerprint ?? null,
  };
}

export function createFolder(
  name: string,
  partial: Partial<ScriptFolder> = {},
): ScriptFolder {
  return {
    id: partial.id ?? newId(),
    name: normalizeFolderName(name),
    createdAt: partial.createdAt ?? new Date().toISOString(),
  };
}

export function scriptWordCount(script: ScriptDocument): number {
  return wordCount(script.body);
}

export function scriptEstSeconds(script: ScriptDocument): number {
  return estimatedSecondsRounded(script.body);
}

export function emptyLibrary(): LibrarySnapshot {
  return { scripts: [], folders: [] };
}

export const DEFAULT_WELCOME_SCRIPT_TITLE = "Welcome to Phrasa";
export const DEFAULT_WELCOME_SCRIPT_BODY = [
  "Write freely. Present calmly.",
  "",
  "This is your web companion: create scripts, edit them, and open the speed teleprompter.",
  "",
  "Guest mode stores everything in this browser. Sign in when you want optional cloud sync with your native Phrasa library.",
  "",
  "Voice Follow stays native-only in this release — the web reader is speed mode only.",
  "",
  "Space plays and pauses. Adjust words per minute in reader settings. Finish when you are ready.",
].join("\n");

export function createWelcomeScript(): ScriptDocument {
  return createScript({
    title: DEFAULT_WELCOME_SCRIPT_TITLE,
    body: DEFAULT_WELCOME_SCRIPT_BODY,
  });
}

export function isUntouchedWelcomeScript(script: ScriptDocument): boolean {
  return (
    script.title === DEFAULT_WELCOME_SCRIPT_TITLE &&
    script.body === DEFAULT_WELCOME_SCRIPT_BODY &&
    script.remoteUpdatedAtWire == null
  );
}
