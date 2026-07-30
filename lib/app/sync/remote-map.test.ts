import { describe, expect, it } from "vitest";
import { createScript, createFolder } from "@/lib/app/models/script";
import {
  folderFromRemoteRow,
  folderToInsertPayload,
  makeLocalConflictCopy,
  mergeRemoteLibrary,
  outlineFromRemote,
  outlineToRemote,
  scriptHasUnacknowledgedLocalEdit,
  scriptFromRemoteRow,
  scriptToContentUpdatePayload,
  scriptToInsertPayload,
  synchronizedContentFingerprint,
} from "./remote-map";

describe("remote sync mapping", () => {
  it("maps remote script rows to local documents with wire updated_at", () => {
    const doc = scriptFromRemoteRow({
      id: "11111111-1111-4111-8111-111111111111",
      folder_id: null,
      title: "Keynote",
      body: "hello world",
      source_type: "manual",
      outline: [{ id: "p1", text: "Open", note: "" }],
      word_count: 2,
      est_seconds: 1,
      tags: ["stage"],
      last_opened_at: null,
      created_at: "2026-07-01T00:00:00.000000Z",
      updated_at: "2026-07-02T12:34:56.789012Z",
    });
    expect(doc.title).toBe("Keynote");
    expect(doc.body).toBe("hello world");
    expect(doc.outline[0]?.text).toBe("Open");
    expect(doc.remoteUpdatedAtWire).toBe("2026-07-02T12:34:56.789012Z");
    expect(doc.remoteContentFingerprint).toBe(
      synchronizedContentFingerprint(doc),
    );
    expect(scriptHasUnacknowledgedLocalEdit(doc)).toBe(false);
    expect(doc.tags).toEqual(["stage"]);
  });

  it("detects synced-content edits even when updatedAt equals the remote wire", () => {
    const clean = scriptFromRemoteRow({
      id: "fingerprint",
      folder_id: null,
      title: "Baseline",
      body: "same clock",
      source_type: "manual",
      outline: [],
      tags: ["one"],
      last_opened_at: null,
      created_at: "2026-07-01T00:00:00.000000Z",
      updated_at: "2026-07-02T12:34:56.789012Z",
    });

    expect(scriptHasUnacknowledgedLocalEdit(clean)).toBe(false);
    expect(
      scriptHasUnacknowledgedLocalEdit({
        ...clean,
        body: "edited at the same timestamp",
      }),
    ).toBe(true);
    expect(
      scriptHasUnacknowledgedLocalEdit({
        ...clean,
        tags: ["one", "two"],
      }),
    ).toBe(true);
  });

  it("builds insert payload with user_id and metrics columns", () => {
    const script = createScript({
      id: "22222222-2222-4222-8222-222222222222",
      title: "  ",
      body: "one two three",
    });
    const payload = scriptToInsertPayload(script, "user-1");
    expect(payload.user_id).toBe("user-1");
    expect(payload.title).toBe("Untitled script");
    expect(payload.word_count).toBe(3);
    expect(payload.source_type).toBe("manual");
    expect(payload.est_seconds).toBeGreaterThanOrEqual(0);
  });

  it("content updates omit timestamp columns", () => {
    const script = createScript({ title: "Talk", body: "words" });
    const payload = scriptToContentUpdatePayload(script);
    expect(payload).not.toHaveProperty("updated_at");
    expect(payload).not.toHaveProperty("created_at");
    expect(payload).not.toHaveProperty("user_id");
    expect(payload).not.toHaveProperty("id");
    expect(payload.title).toBe("Talk");
  });

  it("maps folders both directions", () => {
    const folder = createFolder("Shows", {
      id: "33333333-3333-4333-8333-333333333333",
      createdAt: "2026-07-01T00:00:00.000Z",
    });
    const insert = folderToInsertPayload(folder, "user-9");
    expect(insert.user_id).toBe("user-9");
    expect(insert.name).toBe("Shows");
    const back = folderFromRemoteRow({
      id: insert.id,
      name: insert.name,
      created_at: insert.created_at,
    });
    expect(back.name).toBe("Shows");
  });

  it("drops empty outline points on the wire", () => {
    expect(
      outlineToRemote([
        { id: "1", text: "Keep", note: "" },
        { id: "2", text: "  ", note: "\n" },
      ]),
    ).toEqual([{ id: "1", text: "Keep", note: "" }]);
    expect(outlineFromRemote(null)).toEqual([]);
  });

  it("preserves a Local conflict copy when remote is newer and content diverges", () => {
    const local = createScript({
      id: "same",
      title: "Local",
      body: "local body",
      folderId: "folder-local",
      updatedAt: "2026-07-02T00:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-01T00:00:00.000Z",
    });
    const remote = createScript({
      id: "same",
      title: "Remote",
      body: "remote body",
      folderId: "folder-remote",
      updatedAt: "2026-07-03T00:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-03T00:00:00.000Z",
    });
    const merged = mergeRemoteLibrary(
      { scripts: [local], folders: [] },
      { scripts: [remote], folders: [] },
    );
    const kept = merged.scripts.find((s) => s.id === "same");
    const conflict = merged.scripts.find((s) => s.id !== "same");
    expect(kept?.title).toBe("Remote");
    expect(kept?.body).toBe("remote body");
    expect(kept?.remoteUpdatedAtWire).toBe("2026-07-03T00:00:00.000Z");
    expect(conflict?.title).toBe("Local — Local conflict");
    expect(conflict?.body).toBe("local body");
    expect(conflict?.folderId).toBeNull();
    expect(conflict?.remoteUpdatedAtWire).toBeNull();
    expect(conflict?.id).toBe(makeLocalConflictCopy(local).id);
    expect(merged.notes[0]).toMatch(/Local conflict/i);
    expect(merged.scripts).toHaveLength(2);
  });

  it("takes a newer remote without a conflict copy when local content is clean", () => {
    const local = createScript({
      id: "clean-local",
      title: "Earlier remote",
      body: "earlier body",
      updatedAt: "2026-07-01T00:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-01T00:00:00.000Z",
    });
    const remote = createScript({
      id: "clean-local",
      title: "Newer remote",
      body: "newer body",
      updatedAt: "2026-07-03T00:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-03T00:00:00.000Z",
    });
    const merged = mergeRemoteLibrary(
      { scripts: [local], folders: [] },
      { scripts: [remote], folders: [] },
    );
    expect(merged.scripts).toHaveLength(1);
    expect(merged.scripts[0]).toEqual({
      ...remote,
      remoteContentFingerprint: synchronizedContentFingerprint(remote),
    });
    expect(merged.notes).toEqual([]);
  });

  it("does not create a conflict copy when remote is newer but content matches", () => {
    const local = createScript({
      id: "same-content",
      title: "Talk",
      body: "shared body",
      updatedAt: "2026-07-01T00:00:00.000Z",
      lastOpenedAt: "2026-07-01T12:00:00.000Z",
    });
    const remote = createScript({
      id: "same-content",
      title: "Talk",
      body: "shared body",
      updatedAt: "2026-07-03T00:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-03T00:00:00.000Z",
      lastOpenedAt: "2026-07-03T12:00:00.000Z",
    });
    const merged = mergeRemoteLibrary(
      { scripts: [local], folders: [] },
      { scripts: [remote], folders: [] },
    );
    expect(merged.scripts).toHaveLength(1);
    expect(merged.scripts[0]?.id).toBe("same-content");
    expect(merged.scripts[0]?.body).toBe("shared body");
    expect(merged.scripts[0]?.remoteUpdatedAtWire).toBe(
      "2026-07-03T00:00:00.000Z",
    );
    expect(merged.notes).toEqual([]);
  });

  it("preserves a clock-skewed local edit even when its timestamp is earlier", () => {
    const local = createScript({
      id: "slow-clock",
      title: "Local edit",
      body: "written on a slow clock",
      updatedAt: "2026-07-01T11:55:00.000Z",
      remoteUpdatedAtWire: "2026-07-01T12:00:00.000000Z",
    });
    const remote = createScript({
      id: "slow-clock",
      title: "Remote",
      body: "server copy",
      updatedAt: "2026-07-01T12:01:00.000000Z",
      remoteUpdatedAtWire: "2026-07-01T12:01:00.000000Z",
    });

    const merged = mergeRemoteLibrary(
      { scripts: [local], folders: [] },
      { scripts: [remote], folders: [] },
    );

    expect(merged.scripts.find((script) => script.id === local.id)?.body).toBe(
      "server copy",
    );
    expect(
      merged.scripts.find((script) => script.id !== local.id)?.body,
    ).toBe("written on a slow clock");
  });

  it("preserves tag, outline, and folder-only local edits as conflicts", () => {
    const baselineWire = "2026-07-01T12:00:00.000000Z";
    const local = createScript({
      id: "metadata-edit",
      title: "Same",
      body: "Same body",
      tags: ["local-tag"],
      folderId: "local-folder",
      outline: [{ id: "point", text: "Local point", note: "" }],
      updatedAt: "2026-07-01T12:00:01.000Z",
      remoteUpdatedAtWire: baselineWire,
    });
    const remote = createScript({
      id: "metadata-edit",
      title: "Same",
      body: "Same body",
      tags: ["remote-tag"],
      folderId: "remote-folder",
      outline: [{ id: "point", text: "Remote point", note: "" }],
      updatedAt: "2026-07-01T12:00:02.000000Z",
      remoteUpdatedAtWire: "2026-07-01T12:00:02.000000Z",
    });

    const merged = mergeRemoteLibrary(
      { scripts: [local], folders: [] },
      { scripts: [remote], folders: [] },
    );
    const conflict = merged.scripts.find(
      (script) => script.id !== "metadata-edit",
    );

    expect(conflict?.tags).toEqual(["local-tag"]);
    expect(conflict?.folderId).toBeNull();
    expect(conflict?.outline[0]?.text).toBe("Local point");
  });

  it("merges folders by id without script-style conflict copies; settings stay local", () => {
    const localFolder = createFolder("Local name", {
      id: "folder-1",
      createdAt: "2026-07-01T00:00:00.000Z",
    });
    const remoteFolder = createFolder("Remote name", {
      id: "folder-1",
      createdAt: "2026-07-01T00:00:00.000Z",
    });
    const onlyLocal = createFolder("Only local", {
      id: "folder-local",
      createdAt: "2026-07-02T00:00:00.000Z",
    });
    const onlyRemote = createFolder("Only remote", {
      id: "folder-remote",
      createdAt: "2026-07-02T00:00:00.000Z",
    });
    const merged = mergeRemoteLibrary(
      { scripts: [], folders: [localFolder, onlyLocal] },
      { scripts: [], folders: [remoteFolder, onlyRemote] },
    );
    expect(merged.folders.map((f) => f.id).sort()).toEqual(
      ["folder-1", "folder-local", "folder-remote"].sort(),
    );
    expect(merged.folders.find((f) => f.id === "folder-1")?.name).toBe(
      "Remote name",
    );
    // No synthetic folder conflict rows; reader settings are out of band.
    expect(merged.folders.every((f) => !f.name.includes("Local conflict"))).toBe(
      true,
    );
    expect(merged.notes).toEqual([]);
  });

  it("conflict merges are deterministic and idempotent on repeat", () => {
    const local = createScript({
      id: "repeat-me",
      title: "Draft",
      body: "device edit",
      folderId: "shows",
      updatedAt: "2026-07-01T00:00:00.000Z",
    });
    const remote = createScript({
      id: "repeat-me",
      title: "Cloud",
      body: "cloud edit",
      updatedAt: "2026-07-04T00:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-04T00:00:00.000Z",
    });
    const first = mergeRemoteLibrary(
      { scripts: [local], folders: [] },
      { scripts: [remote], folders: [] },
    );
    const second = mergeRemoteLibrary(
      { scripts: [local], folders: [] },
      { scripts: [remote], folders: [] },
    );
    expect(second.scripts).toEqual(first.scripts);
    expect(second.notes).toEqual(first.notes);

    const expectedConflict = makeLocalConflictCopy(local);
    expect(first.scripts.find((s) => s.id === expectedConflict.id)?.body).toBe(
      "device edit",
    );

    // Re-merge after the first result is already local: no second conflict row.
    const rematch = mergeRemoteLibrary(
      { scripts: first.scripts, folders: [] },
      { scripts: [remote], folders: [] },
    );
    const conflictRows = rematch.scripts.filter((s) =>
      s.title.includes("Local conflict"),
    );
    expect(conflictRows).toHaveLength(1);
    expect(conflictRows[0]?.id).toBe(expectedConflict.id);
    expect(rematch.scripts.find((s) => s.id === "repeat-me")?.body).toBe(
      "cloud edit",
    );
    expect(rematch.notes).toEqual([]);
  });

  it("accepts clean remote deletions without resurrecting them", () => {
    const local = createScript({
      id: "deleted-remotely",
      title: "Delete me",
      body: "already synced",
      updatedAt: "2026-07-03T00:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-03T00:00:00.000Z",
    });
    const merged = mergeRemoteLibrary(
      { scripts: [local], folders: [] },
      { scripts: [], folders: [] },
      new Set([local.id]),
    );
    expect(merged.scripts).toEqual([]);
    expect(merged.notes[0]).toMatch(/deleted remotely/i);
  });

  it("keeps a locally known row when its apparent remote absence was not point-verified", () => {
    const local = createScript({
      id: "possibly-truncated",
      title: "Keep until verified",
      body: "already synced",
      updatedAt: "2026-07-03T00:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-03T00:00:00.000Z",
    });

    const merged = mergeRemoteLibrary(
      { scripts: [local], folders: [] },
      { scripts: [], folders: [] },
    );

    expect(merged.scripts).toEqual([local]);
    expect(merged.notes[0]).toMatch(/absence was not verified/i);
  });

  it("keeps a dirty local edit when its remote row disappeared", () => {
    const local = createScript({
      id: "edited-after-delete",
      title: "Recover me",
      body: "new local edit",
      updatedAt: "2026-07-04T00:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-03T00:00:00.000Z",
    });
    const merged = mergeRemoteLibrary(
      { scripts: [local], folders: [] },
      { scripts: [], folders: [] },
      new Set([local.id]),
    );
    expect(merged.scripts).toEqual([local]);
    expect(merged.notes[0]).toMatch(/kept local edit/i);
  });

  it("does not remove Local conflict copies when they have no remote wire", () => {
    const origin = createScript({
      id: "origin",
      title: "Origin",
      body: "kept local",
      updatedAt: "2026-07-02T00:00:00.000Z",
    });
    const conflict = makeLocalConflictCopy(origin);
    expect(conflict.id).toBe(makeLocalConflictCopy(origin).id);
    const remote = createScript({
      id: "origin",
      title: "Origin remote",
      body: "remote",
      updatedAt: "2026-07-05T00:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-05T00:00:00.000Z",
    });
    const merged = mergeRemoteLibrary(
      {
        scripts: [
          {
            ...remote,
            remoteUpdatedAtWire: "2026-07-05T00:00:00.000Z",
          },
          conflict,
        ],
        folders: [],
      },
      { scripts: [remote], folders: [] },
    );
    expect(merged.scripts.find((s) => s.id === conflict.id)?.body).toBe(
      "kept local",
    );
    expect(merged.scripts).toHaveLength(2);
  });
});
