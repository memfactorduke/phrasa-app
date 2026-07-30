import {
  emptyLibrary,
  type LibrarySnapshot,
  type ScriptDocument,
  type ScriptFolder,
} from "@/lib/app/models/script";
import {
  DEFAULT_READER_SETTINGS,
  normalizeReaderSettings,
  type ReaderSettings,
} from "@/lib/app/models/reader-settings";
import {
  guestPrincipal,
  libraryStorageKey,
  principalFromUserId,
  readerSettingsStorageKey,
  type StoragePrincipal,
} from "./keys";

export type StorageLike = {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
};

export type PersistenceResult =
  | { ok: true }
  | { ok: false; error: string };

export type LibraryLoadResult =
  | { status: "empty"; library: LibrarySnapshot }
  | { status: "ok"; library: LibrarySnapshot }
  | {
      status: "corrupt";
      library: LibrarySnapshot;
      raw: string;
      recoveryKey: string | null;
      error: string;
    }
  | { status: "unavailable"; library: LibrarySnapshot; error: string };

function storageError(error: unknown, fallback: string): string {
  return error instanceof Error && error.message ? error.message : fallback;
}

function defaultStorage(): StorageLike | null {
  if (typeof window === "undefined") return null;
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

function isScript(value: unknown): value is ScriptDocument {
  if (!value || typeof value !== "object") return false;
  const s = value as Record<string, unknown>;
  return (
    typeof s.id === "string" &&
    typeof s.title === "string" &&
    typeof s.body === "string" &&
    typeof s.createdAt === "string" &&
    typeof s.updatedAt === "string"
  );
}

function isFolder(value: unknown): value is ScriptFolder {
  if (!value || typeof value !== "object") return false;
  const f = value as Record<string, unknown>;
  return (
    typeof f.id === "string" &&
    typeof f.name === "string" &&
    typeof f.createdAt === "string"
  );
}

function parseLibrarySnapshotStrict(
  raw: string | null,
): { ok: true; library: LibrarySnapshot; empty: boolean } | { ok: false; error: string } {
  if (!raw) return { ok: true, library: emptyLibrary(), empty: true };
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!parsed || typeof parsed !== "object") {
      return { ok: false, error: "Stored library is not an object." };
    }
    const obj = parsed as Record<string, unknown>;
    if (!Array.isArray(obj.scripts) || !Array.isArray(obj.folders)) {
      return { ok: false, error: "Stored library is missing scripts or folders." };
    }
    if (!obj.scripts.every(isScript) || !obj.folders.every(isFolder)) {
      return { ok: false, error: "Stored library contains an invalid script or folder." };
    }
    const scripts = obj.scripts.map((s) => ({
          ...s,
          source:
            s.source === "upload" || s.source === "gdrive" || s.source === "manual"
              ? s.source
              : "manual",
          folderId: s.folderId ?? null,
          tags: Array.isArray(s.tags)
            ? s.tags.filter((t): t is string => typeof t === "string")
            : [],
          outline: Array.isArray(s.outline) ? s.outline : [],
          lastOpenedAt:
            typeof s.lastOpenedAt === "string" ? s.lastOpenedAt : null,
          remoteUpdatedAtWire:
            typeof s.remoteUpdatedAtWire === "string"
              ? s.remoteUpdatedAtWire
              : null,
          remoteContentFingerprint:
            typeof s.remoteContentFingerprint === "string"
              ? s.remoteContentFingerprint
              : null,
        }));
    const folders = obj.folders;
    return { ok: true, library: { scripts, folders }, empty: false };
  } catch (error) {
    return {
      ok: false,
      error: storageError(error, "Stored library is not valid JSON."),
    };
  }
}

export function parseLibrarySnapshot(raw: string | null): LibrarySnapshot {
  const result = parseLibrarySnapshotStrict(raw);
  return result.ok ? result.library : emptyLibrary();
}

export function loadLibraryResult(
  principal: StoragePrincipal,
  storage: StorageLike | null = defaultStorage(),
): LibraryLoadResult {
  if (!storage) {
    return {
      status: "unavailable",
      library: emptyLibrary(),
      error: "Browser storage is unavailable.",
    };
  }
  const key = libraryStorageKey(principal);
  let raw: string | null;
  try {
    raw = storage.getItem(key);
  } catch (error) {
    return {
      status: "unavailable",
      library: emptyLibrary(),
      error: storageError(error, "Browser storage could not be read."),
    };
  }
  const parsed = parseLibrarySnapshotStrict(raw);
  if (parsed.ok) {
    return {
      status: parsed.empty ? "empty" : "ok",
      library: parsed.library,
    };
  }

  const corruptRaw = raw ?? "";
  const recoveryKey = `${key}.recovery`;
  let preservedKey: string | null = null;
  try {
    if (storage.getItem(recoveryKey) == null) {
      storage.setItem(recoveryKey, corruptRaw);
    }
    preservedKey = recoveryKey;
  } catch {
    // The raw payload is still returned to the UI for a recovery download.
  }
  return {
    status: "corrupt",
    library: emptyLibrary(),
    raw: corruptRaw,
    recoveryKey: preservedKey,
    error: parsed.error,
  };
}

export function loadLibrary(
  principal: StoragePrincipal,
  storage: StorageLike | null = defaultStorage(),
): LibrarySnapshot {
  return loadLibraryResult(principal, storage).library;
}

export function saveLibrary(
  principal: StoragePrincipal,
  library: LibrarySnapshot,
  storage: StorageLike | null = defaultStorage(),
): PersistenceResult {
  if (!storage) return { ok: false, error: "Browser storage is unavailable." };
  try {
    storage.setItem(
      libraryStorageKey(principal),
      JSON.stringify({
        scripts: library.scripts,
        folders: library.folders,
      }),
    );
    return { ok: true };
  } catch (error) {
    return {
      ok: false,
      error: storageError(error, "Browser storage could not save the library."),
    };
  }
}

export function clearLibrary(
  principal: StoragePrincipal,
  storage: StorageLike | null = defaultStorage(),
): PersistenceResult {
  if (!storage) return { ok: false, error: "Browser storage is unavailable." };
  try {
    const key = libraryStorageKey(principal);
    storage.removeItem(key);
    storage.removeItem(`${key}.recovery`);
    return { ok: true };
  } catch (error) {
    return {
      ok: false,
      error: storageError(error, "Browser storage could not clear the library."),
    };
  }
}

export function loadReaderSettings(
  principal: StoragePrincipal,
  storage: StorageLike | null = defaultStorage(),
): ReaderSettings {
  if (!storage) return { ...DEFAULT_READER_SETTINGS };
  let raw: string | null;
  try {
    raw = storage.getItem(readerSettingsStorageKey(principal));
  } catch {
    return { ...DEFAULT_READER_SETTINGS };
  }
  if (!raw) return { ...DEFAULT_READER_SETTINGS };
  try {
    return normalizeReaderSettings(JSON.parse(raw) as Partial<ReaderSettings>);
  } catch {
    return { ...DEFAULT_READER_SETTINGS };
  }
}

export function saveReaderSettings(
  principal: StoragePrincipal,
  settings: ReaderSettings,
  storage: StorageLike | null = defaultStorage(),
): PersistenceResult {
  if (!storage) return { ok: false, error: "Browser storage is unavailable." };
  try {
    storage.setItem(
      readerSettingsStorageKey(principal),
      JSON.stringify(normalizeReaderSettings(settings)),
    );
    return { ok: true };
  } catch (error) {
    return {
      ok: false,
      error: storageError(error, "Browser storage could not save reader settings."),
    };
  }
}

export function clearReaderSettings(
  principal: StoragePrincipal,
  storage: StorageLike | null = defaultStorage(),
): PersistenceResult {
  if (!storage) return { ok: false, error: "Browser storage is unavailable." };
  try {
    storage.removeItem(readerSettingsStorageKey(principal));
    return { ok: true };
  } catch (error) {
    return {
      ok: false,
      error: storageError(error, "Browser storage could not clear reader settings."),
    };
  }
}

/**
 * Load library for the active session principal only.
 * Never falls back to another user id — sign-out must not reveal prior account data.
 */
export function loadActiveLibrary(
  userId: string | null | undefined,
  storage: StorageLike | null = defaultStorage(),
): LibrarySnapshot {
  return loadLibrary(principalFromUserId(userId), storage);
}

export function loadGuestLibrary(
  storage: StorageLike | null = defaultStorage(),
): LibrarySnapshot {
  return loadLibrary(guestPrincipal(), storage);
}

/**
 * Clear guest library only after every imported script was upserted remotely.
 * Callers must pass the list that succeeded; partial failures leave guest data intact.
 */
export function clearGuestLibraryAfterSuccessfulImport(
  importedScriptIds: string[],
  expectedIds: string[],
  storage: StorageLike | null = defaultStorage(),
): { cleared: boolean; reason?: string } {
  const expected = new Set(expectedIds);
  const imported = new Set(importedScriptIds);
  if (expected.size === 0) {
    return { cleared: false, reason: "nothing to import" };
  }
  for (const id of expected) {
    if (!imported.has(id)) {
      return {
        cleared: false,
        reason: "not all guest scripts were successfully upserted",
      };
    }
  }
  const cleared = clearLibrary(guestPrincipal(), storage);
  return cleared.ok
    ? { cleared: true }
    : { cleared: false, reason: cleared.error };
}

export function memoryStorage(
  initial: Record<string, string> = {},
): StorageLike & { data: Record<string, string> } {
  const data = { ...initial };
  return {
    data,
    getItem(key: string) {
      return Object.prototype.hasOwnProperty.call(data, key) ? data[key]! : null;
    },
    setItem(key: string, value: string) {
      data[key] = value;
    },
    removeItem(key: string) {
      delete data[key];
    },
  };
}
