import type {
  ScriptDocument,
  ScriptFolder,
} from "@/lib/app/models/script";
import { synchronizedContentFingerprintMatches } from "./remote-map";

export const WEB_SYNC_STATE_VERSION = 1 as const;

export type WebScriptDeletionTombstone = {
  scriptId: string;
  deletedAt: string;
  /**
   * Last acknowledged cloud content when known; otherwise the deleted local
   * content. A changed cloud generation must be restored, never erased.
   */
  expectedRemoteContentFingerprint: string;
};

export type WebFolderBaseline = {
  folderId: string;
  name: string;
  createdAt: string;
};

export type WebFolderDeletionTombstone = {
  folderId: string;
  deletedAt: string;
  baseline: WebFolderBaseline | null;
};

export type WebSyncState = {
  version: typeof WEB_SYNC_STATE_VERSION;
  scriptTombstones: WebScriptDeletionTombstone[];
  folderBaselines: WebFolderBaseline[];
  folderTombstones: WebFolderDeletionTombstone[];
};

export function emptyWebSyncState(): WebSyncState {
  return {
    version: WEB_SYNC_STATE_VERSION,
    scriptTombstones: [],
    folderBaselines: [],
    folderTombstones: [],
  };
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

function isFolderBaseline(value: unknown): value is WebFolderBaseline {
  if (!value || typeof value !== "object") return false;
  const baseline = value as Record<string, unknown>;
  return (
    isNonEmptyString(baseline.folderId) &&
    typeof baseline.name === "string" &&
    isDateString(baseline.createdAt)
  );
}

export function parseWebSyncState(
  value: unknown,
): { ok: true; state: WebSyncState } | { ok: false; error: string } {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return { ok: false, error: "Stored sync state is not an object." };
  }
  const state = value as Record<string, unknown>;
  if (
    state.version !== WEB_SYNC_STATE_VERSION ||
    !Array.isArray(state.scriptTombstones) ||
    !Array.isArray(state.folderBaselines) ||
    !Array.isArray(state.folderTombstones)
  ) {
    return {
      ok: false,
      error: "Stored sync state has an unsupported or incomplete shape.",
    };
  }

  const scriptTombstones: WebScriptDeletionTombstone[] = [];
  const seenScriptIDs = new Set<string>();
  for (const value of state.scriptTombstones) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return { ok: false, error: "Stored script tombstone is invalid." };
    }
    const tombstone = value as Record<string, unknown>;
    if (
      !isNonEmptyString(tombstone.scriptId) ||
      !isDateString(tombstone.deletedAt) ||
      !isNonEmptyString(tombstone.expectedRemoteContentFingerprint) ||
      seenScriptIDs.has(tombstone.scriptId)
    ) {
      return { ok: false, error: "Stored script tombstone is invalid." };
    }
    seenScriptIDs.add(tombstone.scriptId);
    scriptTombstones.push({
      scriptId: tombstone.scriptId,
      deletedAt: tombstone.deletedAt,
      expectedRemoteContentFingerprint:
        tombstone.expectedRemoteContentFingerprint,
    });
  }

  const folderBaselines: WebFolderBaseline[] = [];
  const seenBaselineIDs = new Set<string>();
  for (const value of state.folderBaselines) {
    if (
      !isFolderBaseline(value) ||
      seenBaselineIDs.has(value.folderId)
    ) {
      return { ok: false, error: "Stored folder baseline is invalid." };
    }
    seenBaselineIDs.add(value.folderId);
    folderBaselines.push(value);
  }

  const folderTombstones: WebFolderDeletionTombstone[] = [];
  const seenFolderTombstoneIDs = new Set<string>();
  for (const value of state.folderTombstones) {
    if (!value || typeof value !== "object" || Array.isArray(value)) {
      return { ok: false, error: "Stored folder tombstone is invalid." };
    }
    const tombstone = value as Record<string, unknown>;
    if (
      !isNonEmptyString(tombstone.folderId) ||
      !isDateString(tombstone.deletedAt) ||
      (tombstone.baseline !== null &&
        !isFolderBaseline(tombstone.baseline)) ||
      seenFolderTombstoneIDs.has(tombstone.folderId)
    ) {
      return { ok: false, error: "Stored folder tombstone is invalid." };
    }
    seenFolderTombstoneIDs.add(tombstone.folderId);
    folderTombstones.push({
      folderId: tombstone.folderId,
      deletedAt: tombstone.deletedAt,
      baseline:
        tombstone.baseline === null
          ? null
          : (tombstone.baseline as WebFolderBaseline),
    });
  }

  return {
    ok: true,
    state: {
      version: WEB_SYNC_STATE_VERSION,
      scriptTombstones,
      folderBaselines,
      folderTombstones,
    },
  };
}

export function upsertScriptTombstone(
  state: WebSyncState,
  tombstone: WebScriptDeletionTombstone,
): WebSyncState {
  return {
    ...state,
    scriptTombstones: [
      tombstone,
      ...state.scriptTombstones.filter(
        (candidate) => candidate.scriptId !== tombstone.scriptId,
      ),
    ],
  };
}

export function removeScriptTombstone(
  state: WebSyncState,
  scriptId: string,
): WebSyncState {
  return {
    ...state,
    scriptTombstones: state.scriptTombstones.filter(
      (candidate) => candidate.scriptId !== scriptId,
    ),
  };
}

export type ScriptTombstoneResolution =
  | { action: "acknowledge-absence" }
  | { action: "delete"; expectedRemote: ScriptDocument }
  | { action: "restore"; changedRemote: ScriptDocument };

export function resolveScriptTombstone(
  tombstone: WebScriptDeletionTombstone,
  remote: ScriptDocument | null,
): ScriptTombstoneResolution {
  if (!remote) return { action: "acknowledge-absence" };
  return synchronizedContentFingerprintMatches(
    remote,
    tombstone.expectedRemoteContentFingerprint,
  )
    ? { action: "delete", expectedRemote: remote }
    : { action: "restore", changedRemote: remote };
}

export function upsertFolderTombstone(
  state: WebSyncState,
  tombstone: WebFolderDeletionTombstone,
): WebSyncState {
  return {
    ...state,
    folderTombstones: [
      tombstone,
      ...state.folderTombstones.filter(
        (candidate) => candidate.folderId !== tombstone.folderId,
      ),
    ],
  };
}

export function folderBaseline(folder: ScriptFolder): WebFolderBaseline {
  return {
    folderId: folder.id,
    name: folder.name,
    createdAt: folder.createdAt,
  };
}

export function folderMatchesBaseline(
  folder: ScriptFolder,
  baseline: WebFolderBaseline,
): boolean {
  return (
    folder.id === baseline.folderId &&
    folder.name === baseline.name &&
    Date.parse(folder.createdAt) === Date.parse(baseline.createdAt)
  );
}

export type FolderWrite = {
  desired: ScriptFolder;
  expectedRemote: ScriptFolder | null;
};

export type FolderRemoteDeletion = {
  tombstone: WebFolderDeletionTombstone;
  expectedRemote: ScriptFolder;
};

export type FolderReconciliationResult =
  | {
      ok: true;
      folders: ScriptFolder[];
      state: WebSyncState;
      writes: FolderWrite[];
      remoteDeletes: FolderRemoteDeletion[];
      removedFolderIDs: Set<string>;
    }
  | { ok: false; error: string };

/**
 * Clock-independent three-way folder reconciliation. A remote absence only
 * means deletion for a folder with an exact acknowledged baseline and a
 * successful point verification.
 */
export function reconcileFolders(
  localFolders: readonly ScriptFolder[],
  remoteFolders: readonly ScriptFolder[],
  state: WebSyncState,
  verifiedRemoteAbsenceIDs: ReadonlySet<string>,
): FolderReconciliationResult {
  const localByID = new Map(localFolders.map((folder) => [folder.id, folder]));
  const remoteByID = new Map(remoteFolders.map((folder) => [folder.id, folder]));
  const baselines = new Map(
    state.folderBaselines.map((baseline) => [baseline.folderId, baseline]),
  );
  const tombstones = new Map(
    state.folderTombstones.map((tombstone) => [
      tombstone.folderId,
      tombstone,
    ]),
  );
  const folders = new Map<string, ScriptFolder>();
  const writes: FolderWrite[] = [];
  const remoteDeletes: FolderRemoteDeletion[] = [];
  const removedFolderIDs = new Set<string>();
  const allIDs = new Set([
    ...localByID.keys(),
    ...remoteByID.keys(),
    ...baselines.keys(),
    ...tombstones.keys(),
  ]);

  for (const id of allIDs) {
    const local = localByID.get(id);
    const remote = remoteByID.get(id);
    const baseline = baselines.get(id);
    const tombstone = tombstones.get(id);

    if (tombstone) {
      if (!remote) {
        if (!baseline || verifiedRemoteAbsenceIDs.has(id)) {
          tombstones.delete(id);
          baselines.delete(id);
          removedFolderIDs.add(id);
        }
        continue;
      }
      const expected = tombstone.baseline ?? baseline;
      if (expected && folderMatchesBaseline(remote, expected)) {
        remoteDeletes.push({ tombstone, expectedRemote: remote });
        continue;
      }
      // The cloud folder changed or was recreated after the local delete.
      // Preserve that generation and retire the stale deletion intent.
      tombstones.delete(id);
      baselines.set(id, folderBaseline(remote));
      folders.set(id, remote);
      continue;
    }

    if (local && remote) {
      if (folderMatchesBaseline(local, folderBaseline(remote))) {
        folders.set(id, remote);
        baselines.set(id, folderBaseline(remote));
        continue;
      }
      if (!baseline) {
        return {
          ok: false,
          error:
            `Folder “${local.name}” differs from the cloud copy and has no ` +
            "trusted shared baseline. Nothing was overwritten.",
        };
      }
      const localMatches = folderMatchesBaseline(local, baseline);
      const remoteMatches = folderMatchesBaseline(remote, baseline);
      if (localMatches && !remoteMatches) {
        folders.set(id, remote);
        baselines.set(id, folderBaseline(remote));
      } else if (!localMatches && remoteMatches) {
        folders.set(id, local);
        writes.push({ desired: local, expectedRemote: remote });
      } else {
        return {
          ok: false,
          error:
            `Folder “${local.name}” and its cloud copy were both renamed. ` +
            "Nothing was overwritten.",
        };
      }
      continue;
    }

    if (local) {
      if (baseline && verifiedRemoteAbsenceIDs.has(id)) {
        if (folderMatchesBaseline(local, baseline)) {
          baselines.delete(id);
          removedFolderIDs.add(id);
          continue;
        }
        return {
          ok: false,
          error:
            `Folder “${local.name}” was renamed here but deleted from the cloud. ` +
            "Nothing was recreated or discarded.",
        };
      }
      folders.set(id, local);
      if (!baseline) {
        writes.push({ desired: local, expectedRemote: null });
      }
      continue;
    }

    if (remote) {
      // Absence without an explicit durable tombstone is never a local delete.
      folders.set(id, remote);
      baselines.set(id, folderBaseline(remote));
      continue;
    }

    if (verifiedRemoteAbsenceIDs.has(id)) {
      baselines.delete(id);
      tombstones.delete(id);
      removedFolderIDs.add(id);
    }
  }

  return {
    ok: true,
    folders: Array.from(folders.values()).sort((left, right) =>
      left.name.localeCompare(right.name),
    ),
    state: {
      ...state,
      folderBaselines: Array.from(baselines.values()).sort((left, right) =>
        left.folderId.localeCompare(right.folderId),
      ),
      folderTombstones: Array.from(tombstones.values()).sort((left, right) =>
        left.folderId.localeCompare(right.folderId),
      ),
    },
    writes,
    remoteDeletes,
    removedFolderIDs,
  };
}

export function removeScriptsCoveredByTombstones(
  scripts: readonly ScriptDocument[],
  state: WebSyncState,
): ScriptDocument[] {
  const deletedIDs = new Set(
    state.scriptTombstones.map((tombstone) => tombstone.scriptId),
  );
  return scripts.filter((script) => !deletedIDs.has(script.id));
}

export function acknowledgeFolderWrite(
  state: WebSyncState,
  folder: ScriptFolder,
): WebSyncState {
  return {
    ...state,
    folderBaselines: [
      folderBaseline(folder),
      ...state.folderBaselines.filter(
        (baseline) => baseline.folderId !== folder.id,
      ),
    ],
    folderTombstones: state.folderTombstones.filter(
      (tombstone) => tombstone.folderId !== folder.id,
    ),
  };
}

export function acknowledgeFolderDeletion(
  state: WebSyncState,
  folderId: string,
): WebSyncState {
  return {
    ...state,
    folderBaselines: state.folderBaselines.filter(
      (baseline) => baseline.folderId !== folderId,
    ),
    folderTombstones: state.folderTombstones.filter(
      (tombstone) => tombstone.folderId !== folderId,
    ),
  };
}

export function unfileScriptsFromMissingFolders(
  scripts: readonly ScriptDocument[],
  folders: readonly ScriptFolder[],
): ScriptDocument[] {
  const existingFolderIDs = new Set(folders.map((folder) => folder.id));
  return scripts.map((script) =>
    script.folderId && !existingFolderIDs.has(script.folderId)
      ? { ...script, folderId: null }
      : script,
  );
}
