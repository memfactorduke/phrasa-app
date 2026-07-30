import { describe, expect, it } from "vitest";
import { createFolder, createScript } from "@/lib/app/models/script";
import {
  emptyWebSyncState,
  folderBaseline,
  parseWebSyncState,
  reconcileFolders,
  removeScriptsCoveredByTombstones,
  resolveScriptTombstone,
  unfileScriptsFromMissingFolders,
  upsertFolderTombstone,
  upsertScriptTombstone,
} from "./durable-state";
import { synchronizedContentFingerprint } from "./remote-map";

const CREATED_AT = "2026-07-30T12:00:00.000Z";
const DELETED_AT = "2026-07-30T13:00:00.000Z";

function folder(id: string, name: string) {
  return createFolder(name, { id, createdAt: CREATED_AT });
}

describe("durable web sync state", () => {
  it("round-trips strict tombstones and rejects duplicate or malformed entries", () => {
    const baseline = folderBaseline(folder("folder-a", "Baseline"));
    const state = upsertFolderTombstone(
      upsertScriptTombstone(emptyWebSyncState(), {
        scriptId: "script-a",
        deletedAt: DELETED_AT,
        expectedRemoteContentFingerprint: "v2:sha256:abc",
      }),
      {
        folderId: "folder-a",
        deletedAt: DELETED_AT,
        baseline,
      },
    );
    state.folderBaselines = [baseline];

    expect(parseWebSyncState(state)).toEqual({ ok: true, state });
    expect(
      parseWebSyncState({
        ...state,
        scriptTombstones: [
          state.scriptTombstones[0],
          state.scriptTombstones[0],
        ],
      }),
    ).toMatchObject({ ok: false });
    expect(
      parseWebSyncState({
        ...state,
        folderTombstones: [
          {
            folderId: "folder-a",
            deletedAt: "not-a-date",
            baseline,
          },
        ],
      }),
    ).toMatchObject({ ok: false });
  });

  it("keeps a durable script deletion hidden across stale snapshots", () => {
    const deleted = createScript({ id: "deleted", title: "Deleted" });
    const kept = createScript({ id: "kept", title: "Kept" });
    const state = upsertScriptTombstone(emptyWebSyncState(), {
      scriptId: deleted.id,
      deletedAt: DELETED_AT,
      expectedRemoteContentFingerprint: "legacy-json",
    });

    expect(
      removeScriptsCoveredByTombstones([deleted, kept], state).map(
        (script) => script.id,
      ),
    ).toEqual(["kept"]);
  });

  it("deletes only the exact cloud generation and restores a changed one", () => {
    const remote = createScript({
      id: "remote-script",
      title: "Acknowledged",
      body: "Cloud generation one",
      remoteUpdatedAtWire: "2026-07-30T12:00:00.000Z",
    });
    const tombstone = {
      scriptId: remote.id,
      deletedAt: DELETED_AT,
      expectedRemoteContentFingerprint:
        synchronizedContentFingerprint(remote),
    };

    expect(resolveScriptTombstone(tombstone, null)).toEqual({
      action: "acknowledge-absence",
    });
    expect(resolveScriptTombstone(tombstone, remote)).toEqual({
      action: "delete",
      expectedRemote: remote,
    });
    const changed = { ...remote, body: "Cloud generation two" };
    expect(resolveScriptTombstone(tombstone, changed)).toEqual({
      action: "restore",
      changedRemote: changed,
    });
  });
});

describe("acknowledged folder three-way reconciliation", () => {
  it("accepts a point-verified remote delete only for an unchanged baseline", () => {
    const original = folder("folder-a", "Original");
    const state = {
      ...emptyWebSyncState(),
      folderBaselines: [folderBaseline(original)],
    };

    const result = reconcileFolders(
      [original],
      [],
      state,
      new Set([original.id]),
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.folders).toEqual([]);
    expect(result.writes).toEqual([]);
    expect(result.removedFolderIDs).toEqual(new Set([original.id]));
    expect(result.state.folderBaselines).toEqual([]);
  });

  it("does not infer deletion from an unverified paginated absence", () => {
    const original = folder("folder-a", "Original");
    const state = {
      ...emptyWebSyncState(),
      folderBaselines: [folderBaseline(original)],
    };

    const result = reconcileFolders([original], [], state, new Set());

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.folders).toEqual([original]);
    expect(result.writes).toEqual([]);
    expect(result.state.folderBaselines).toEqual([
      folderBaseline(original),
    ]);
  });

  it("uploads a genuinely local-only folder without manufacturing a baseline", () => {
    const local = folder("new-folder", "New");
    const result = reconcileFolders(
      [local],
      [],
      emptyWebSyncState(),
      new Set(),
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.writes).toEqual([
      { desired: local, expectedRemote: null },
    ]);
    expect(result.state.folderBaselines).toEqual([]);
  });

  it("takes a one-sided cloud rename and records the new baseline", () => {
    const original = folder("folder-a", "Original");
    const remote = folder("folder-a", "Cloud rename");
    const state = {
      ...emptyWebSyncState(),
      folderBaselines: [folderBaseline(original)],
    };

    const result = reconcileFolders(
      [original],
      [remote],
      state,
      new Set(),
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.folders).toEqual([remote]);
    expect(result.writes).toEqual([]);
    expect(result.state.folderBaselines).toEqual([
      folderBaseline(remote),
    ]);
  });

  it("writes a one-sided local rename with the exact remote baseline", () => {
    const original = folder("folder-a", "Original");
    const local = folder("folder-a", "Local rename");
    const state = {
      ...emptyWebSyncState(),
      folderBaselines: [folderBaseline(original)],
    };

    const result = reconcileFolders(
      [local],
      [original],
      state,
      new Set(),
    );

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.writes).toEqual([
      { desired: local, expectedRemote: original },
    ]);
    expect(result.state.folderBaselines).toEqual([
      folderBaseline(original),
    ]);
  });

  it("fails closed when both devices rename the same folder", () => {
    const original = folder("folder-a", "Original");
    const state = {
      ...emptyWebSyncState(),
      folderBaselines: [folderBaseline(original)],
    };

    const result = reconcileFolders(
      [folder("folder-a", "Local rename")],
      [folder("folder-a", "Cloud rename")],
      state,
      new Set(),
    );

    expect(result).toMatchObject({ ok: false });
    if (!result.ok) expect(result.error).toMatch(/both renamed/i);
  });

  it("fails closed on a local rename versus verified cloud deletion", () => {
    const original = folder("folder-a", "Original");
    const state = {
      ...emptyWebSyncState(),
      folderBaselines: [folderBaseline(original)],
    };

    const result = reconcileFolders(
      [folder("folder-a", "Local rename")],
      [],
      state,
      new Set([original.id]),
    );

    expect(result).toMatchObject({ ok: false });
    if (!result.ok) expect(result.error).toMatch(/renamed here but deleted/i);
  });

  it("uses an explicit tombstone to delete only the unchanged cloud generation", () => {
    const original = folder("folder-a", "Original");
    const state = upsertFolderTombstone(
      {
        ...emptyWebSyncState(),
        folderBaselines: [folderBaseline(original)],
      },
      {
        folderId: original.id,
        deletedAt: DELETED_AT,
        baseline: folderBaseline(original),
      },
    );

    const result = reconcileFolders([], [original], state, new Set());

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.folders).toEqual([]);
    expect(result.remoteDeletes).toEqual([
      { tombstone: state.folderTombstones[0], expectedRemote: original },
    ]);
    expect(result.state.folderTombstones).toHaveLength(1);
  });

  it("retires a stale tombstone and restores a changed cloud folder", () => {
    const original = folder("folder-a", "Original");
    const changed = folder("folder-a", "Recreated in cloud");
    const state = upsertFolderTombstone(
      {
        ...emptyWebSyncState(),
        folderBaselines: [folderBaseline(original)],
      },
      {
        folderId: original.id,
        deletedAt: DELETED_AT,
        baseline: folderBaseline(original),
      },
    );

    const result = reconcileFolders([], [changed], state, new Set());

    expect(result.ok).toBe(true);
    if (!result.ok) return;
    expect(result.folders).toEqual([changed]);
    expect(result.remoteDeletes).toEqual([]);
    expect(result.state.folderTombstones).toEqual([]);
    expect(result.state.folderBaselines).toEqual([
      folderBaseline(changed),
    ]);
  });

  it("unfiles scripts when a safely reconciled folder is gone", () => {
    const inFolder = createScript({
      id: "script-a",
      folderId: "folder-a",
    });
    const unfiled = unfileScriptsFromMissingFolders([inFolder], []);
    expect(unfiled[0]?.folderId).toBeNull();
    expect(inFolder.folderId).toBe("folder-a");
  });
});
