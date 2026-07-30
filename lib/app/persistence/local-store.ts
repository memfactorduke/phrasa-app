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
  syncStateStorageKey,
  type StoragePrincipal,
} from "./keys";
import {
  emptyWebSyncState,
  parseWebSyncState,
  type WebSyncState,
} from "@/lib/app/sync/durable-state";

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
  | {
      status: "recovery";
      library: LibrarySnapshot;
      raw: string;
      recoveryKey: string;
      error: string;
    }
  | { status: "unavailable"; library: LibrarySnapshot; error: string };

export type SyncStateLoadResult =
  | { status: "empty"; state: WebSyncState }
  | { status: "ok"; state: WebSyncState }
  | {
      status: "corrupt";
      state: WebSyncState;
      raw: string;
      recoveryKey: string | null;
      error: string;
    }
  | {
      status: "recovery";
      state: WebSyncState;
      raw: string;
      recoveryKey: string;
      error: string;
    }
  | { status: "unavailable"; state: WebSyncState; error: string };

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

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.trim().length > 0;
}

function isDateString(value: unknown): value is string {
  return (
    typeof value === "string" &&
    /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2})$/.test(
      value,
    ) &&
    Number.isFinite(Date.parse(value))
  );
}

function isOutlinePoint(value: unknown): boolean {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const point = value as Record<string, unknown>;
  return (
    isNonEmptyString(point.id) &&
    typeof point.text === "string" &&
    (point.note === undefined || typeof point.note === "string")
  );
}

function isScript(value: unknown): value is ScriptDocument {
  if (!value || typeof value !== "object") return false;
  const s = value as Record<string, unknown>;
  const outlineIsValid =
    s.outline === undefined ||
    (Array.isArray(s.outline) &&
      s.outline.every(isOutlinePoint) &&
      new Set(
        s.outline.map((point) =>
          typeof point === "object" && point !== null && "id" in point
            ? (point as { id: unknown }).id
            : null,
        ),
      ).size === s.outline.length);
  return (
    isNonEmptyString(s.id) &&
    typeof s.title === "string" &&
    typeof s.body === "string" &&
    (s.source === undefined ||
      s.source === "manual" ||
      s.source === "upload" ||
      s.source === "gdrive") &&
    (s.folderId === undefined ||
      s.folderId === null ||
      isNonEmptyString(s.folderId)) &&
    (s.tags === undefined ||
      (Array.isArray(s.tags) &&
        s.tags.every((tag) => typeof tag === "string"))) &&
    outlineIsValid &&
    (s.lastOpenedAt === undefined ||
      s.lastOpenedAt === null ||
      isDateString(s.lastOpenedAt)) &&
    isDateString(s.createdAt) &&
    isDateString(s.updatedAt) &&
    (s.remoteUpdatedAtWire === undefined ||
      s.remoteUpdatedAtWire === null ||
      isDateString(s.remoteUpdatedAtWire)) &&
    (s.remoteContentFingerprint === undefined ||
      s.remoteContentFingerprint === null ||
      isNonEmptyString(s.remoteContentFingerprint))
  );
}

function isFolder(value: unknown): value is ScriptFolder {
  if (!value || typeof value !== "object") return false;
  const f = value as Record<string, unknown>;
  return (
    isNonEmptyString(f.id) &&
    typeof f.name === "string" &&
    isDateString(f.createdAt)
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
    const scriptIDs = obj.scripts.map((script) => script.id);
    const folderIDs = obj.folders.map((folder) => folder.id);
    if (
      new Set(scriptIDs).size !== scriptIDs.length ||
      new Set(folderIDs).size !== folderIDs.length
    ) {
      return { ok: false, error: "Stored library contains duplicate ids." };
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
          outline: Array.isArray(s.outline)
            ? s.outline.map((point) => ({
                id: point.id,
                text: point.text,
                note: point.note ?? "",
              }))
            : [],
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
    try {
      const recoveryKey = `${key}.recovery`;
      const recoveryRaw = storage.getItem(recoveryKey);
      if (recoveryRaw !== null) {
        return {
          status: "recovery",
          library: parsed.library,
          raw: recoveryRaw,
          recoveryKey,
          error:
            "A preserved recovery copy still needs an explicit download or clear.",
        };
      }
    } catch {
      // The primary library is valid; ordinary read handling remains available.
    }
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

function preserveCorruptRaw(
  storage: StorageLike,
  key: string,
  raw: string,
): string | null {
  const recoveryKey = `${key}.recovery`;
  try {
    if (storage.getItem(recoveryKey) == null) {
      storage.setItem(recoveryKey, raw);
    }
    return recoveryKey;
  } catch {
    return null;
  }
}

export function loadSyncStateResult(
  principal: StoragePrincipal,
  storage: StorageLike | null = defaultStorage(),
): SyncStateLoadResult {
  if (!storage) {
    return {
      status: "unavailable",
      state: emptyWebSyncState(),
      error: "Browser storage is unavailable.",
    };
  }
  const key = syncStateStorageKey(principal);
  let raw: string | null;
  try {
    raw = storage.getItem(key);
  } catch (error) {
    return {
      status: "unavailable",
      state: emptyWebSyncState(),
      error: storageError(error, "Browser sync state could not be read."),
    };
  }
  if (raw === null) {
    return { status: "empty", state: emptyWebSyncState() };
  }

  let parsedJSON: unknown;
  try {
    parsedJSON = JSON.parse(raw) as unknown;
  } catch (error) {
    return {
      status: "corrupt",
      state: emptyWebSyncState(),
      raw,
      recoveryKey: preserveCorruptRaw(storage, key, raw),
      error: storageError(error, "Stored sync state is not valid JSON."),
    };
  }
  const parsed = parseWebSyncState(parsedJSON);
  if (!parsed.ok) {
    return {
      status: "corrupt",
      state: emptyWebSyncState(),
      raw,
      recoveryKey: preserveCorruptRaw(storage, key, raw),
      error: parsed.error,
    };
  }
  try {
    const recoveryKey = `${key}.recovery`;
    const recoveryRaw = storage.getItem(recoveryKey);
    if (recoveryRaw !== null) {
      return {
        status: "recovery",
        state: parsed.state,
        raw: recoveryRaw,
        recoveryKey,
        error:
          "A preserved sync recovery copy still needs an explicit download or clear.",
      };
    }
  } catch {
    // Valid primary sync state remains usable.
  }
  return { status: "ok", state: parsed.state };
}

export function loadSyncState(
  principal: StoragePrincipal,
  storage: StorageLike | null = defaultStorage(),
): WebSyncState {
  return loadSyncStateResult(principal, storage).state;
}

export function saveSyncState(
  principal: StoragePrincipal,
  state: WebSyncState,
  storage: StorageLike | null = defaultStorage(),
): PersistenceResult {
  if (!storage) return { ok: false, error: "Browser storage is unavailable." };
  const validated = parseWebSyncState(state);
  if (!validated.ok) return { ok: false, error: validated.error };
  try {
    storage.setItem(syncStateStorageKey(principal), JSON.stringify(state));
    return { ok: true };
  } catch (error) {
    return {
      ok: false,
      error: storageError(error, "Browser sync state could not be saved."),
    };
  }
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
    const syncKey = syncStateStorageKey(principal);
    storage.removeItem(syncKey);
    storage.removeItem(`${syncKey}.recovery`);
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
