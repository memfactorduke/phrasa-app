import { describe, expect, it } from "vitest";
import { createScript, createFolder } from "@/lib/app/models/script";
import {
  guestPrincipal,
  libraryStorageKey,
  principalFromUserId,
  syncStateStorageKey,
  userPrincipal,
} from "./keys";
import {
  emptyWebSyncState,
  upsertScriptTombstone,
} from "@/lib/app/sync/durable-state";
import {
  clearGuestLibraryAfterSuccessfulImport,
  clearLibrary,
  loadActiveLibrary,
  loadLibrary,
  loadLibraryResult,
  loadReaderSettings,
  loadSyncStateResult,
  memoryStorage,
  saveLibrary,
  saveReaderSettings,
  saveSyncState,
} from "./local-store";

describe("namespaced local persistence", () => {
  it("isolates guest and user library keys", () => {
    expect(libraryStorageKey(guestPrincipal())).toContain(".guest.library");
    expect(libraryStorageKey(userPrincipal("ABC-123"))).toContain(
      ".user.abc-123.library",
    );
    expect(libraryStorageKey(guestPrincipal())).not.toBe(
      libraryStorageKey(userPrincipal("u1")),
    );
  });

  it("never loads another user's library when principal is guest", () => {
    const storage = memoryStorage();
    const userScript = createScript({ title: "Secret", body: "account only" });
    saveLibrary(userPrincipal("user-a"), { scripts: [userScript], folders: [] }, storage);

    const guest = loadActiveLibrary(null, storage);
    expect(guest.scripts).toHaveLength(0);
    expect(guest.scripts.find((s) => s.title === "Secret")).toBeUndefined();
  });

  it("sign-out principal switch does not reveal previous account cache", () => {
    const storage = memoryStorage();
    saveLibrary(
      userPrincipal("user-a"),
      { scripts: [createScript({ title: "A private" })], folders: [] },
      storage,
    );
    saveLibrary(
      guestPrincipal(),
      { scripts: [createScript({ title: "Guest note" })], folders: [] },
      storage,
    );

    // Simulate signed-in view
    expect(loadActiveLibrary("user-a", storage).scripts[0]?.title).toBe(
      "A private",
    );
    // Sign out → guest only
    const afterSignOut = loadActiveLibrary(null, storage);
    expect(afterSignOut.scripts.map((s) => s.title)).toEqual(["Guest note"]);
    expect(afterSignOut.scripts.some((s) => s.title === "A private")).toBe(
      false,
    );
  });

  it("persists reader settings per principal", () => {
    const storage = memoryStorage();
    saveReaderSettings(
      userPrincipal("u1"),
      {
        font: "serif",
        fontSize: 48,
        lineHeight: 1.5,
        horizontalMargin: 0.1,
        focusPosition: 0.3,
        speedWPM: 160,
        speedCountdown: 15,
        mirrorHorizontal: true,
        mirrorVertical: false,
      },
      storage,
    );
    const guestSettings = loadReaderSettings(guestPrincipal(), storage);
    expect(guestSettings.speedCountdown).toBe(5);
    const userSettings = loadReaderSettings(userPrincipal("u1"), storage);
    expect(userSettings.speedCountdown).toBe(15);
    expect(userSettings.speedWPM).toBe(160);
  });

  it("clears guest library only after full successful remote upsert set", () => {
    const storage = memoryStorage();
    const a = createScript({ title: "A" });
    const b = createScript({ title: "B" });
    saveLibrary(guestPrincipal(), { scripts: [a, b], folders: [] }, storage);

    const partial = clearGuestLibraryAfterSuccessfulImport(
      [a.id],
      [a.id, b.id],
      storage,
    );
    expect(partial.cleared).toBe(false);
    expect(loadLibrary(guestPrincipal(), storage).scripts).toHaveLength(2);

    const full = clearGuestLibraryAfterSuccessfulImport(
      [a.id, b.id],
      [a.id, b.id],
      storage,
    );
    expect(full.cleared).toBe(true);
    expect(loadLibrary(guestPrincipal(), storage).scripts).toHaveLength(0);
  });

  it("clearLibrary removes only the target principal", () => {
    const storage = memoryStorage();
    saveLibrary(
      guestPrincipal(),
      { scripts: [createScript({ title: "G" })], folders: [] },
      storage,
    );
    saveLibrary(
      userPrincipal("u"),
      {
        scripts: [createScript({ title: "U" })],
        folders: [createFolder("Talks")],
      },
      storage,
    );
    clearLibrary(guestPrincipal(), storage);
    expect(loadLibrary(guestPrincipal(), storage).scripts).toHaveLength(0);
    expect(loadLibrary(userPrincipal("u"), storage).scripts).toHaveLength(1);
  });

  it("principalFromUserId treats empty as guest", () => {
    expect(principalFromUserId(undefined).kind).toBe("guest");
    expect(principalFromUserId("").kind).toBe("guest");
    expect(principalFromUserId("x").kind).toBe("user");
  });

  it("preserves malformed raw library data under a recovery key", () => {
    const principal = guestPrincipal();
    const key = libraryStorageKey(principal);
    const storage = memoryStorage({ [key]: "{not-json" });

    const result = loadLibraryResult(principal, storage);
    expect(result.status).toBe("corrupt");
    if (result.status !== "corrupt") return;
    expect(result.raw).toBe("{not-json");
    expect(result.recoveryKey).toBe(`${key}.recovery`);
    expect(storage.data[`${key}.recovery`]).toBe("{not-json");
    expect(storage.data[key]).toBe("{not-json");
  });

  it("clearLibrary removes its preserved recovery copy too", () => {
    const principal = guestPrincipal();
    const key = libraryStorageKey(principal);
    const storage = memoryStorage({
      [key]: JSON.stringify({ scripts: [], folders: [] }),
      [`${key}.recovery`]: "{not-json",
    });

    expect(clearLibrary(principal, storage)).toEqual({ ok: true });
    expect(storage.data[key]).toBeUndefined();
    expect(storage.data[`${key}.recovery`]).toBeUndefined();
  });

  it("does not silently discard one invalid row from a partial library", () => {
    const principal = guestPrincipal();
    const key = libraryStorageKey(principal);
    const storage = memoryStorage({
      [key]: JSON.stringify({
        scripts: [{ id: "missing-required-fields" }],
        folders: [],
      }),
    });

    expect(loadLibraryResult(principal, storage).status).toBe("corrupt");
    expect(storage.data[key]).toContain("missing-required-fields");
  });

  it("rejects malformed nested outline points, duplicate point ids, and loose dates", () => {
    const principal = guestPrincipal();
    const key = libraryStorageKey(principal);
    const valid = createScript({
      id: "strict-script",
      outline: [{ id: "point-a", text: "Open", note: "" }],
    });
    const cases = [
      { ...valid, outline: [{ id: "point-a", text: null }] },
      {
        ...valid,
        outline: [
          { id: "duplicate", text: "One", note: "" },
          { id: "duplicate", text: "Two", note: "" },
        ],
      },
      { ...valid, updatedAt: "tomorrow" },
      { ...valid, remoteContentFingerprint: "" },
    ];

    for (const script of cases) {
      const storage = memoryStorage({
        [key]: JSON.stringify({ scripts: [script], folders: [] }),
      });
      expect(loadLibraryResult(principal, storage).status).toBe("corrupt");
    }
  });

  it("keeps a recovery block visible after the primary library is repaired", () => {
    const principal = guestPrincipal();
    const key = libraryStorageKey(principal);
    const storage = memoryStorage({
      [key]: JSON.stringify({ scripts: [], folders: [] }),
      [`${key}.recovery`]: "{original-corrupt-json",
    });

    const result = loadLibraryResult(principal, storage);
    expect(result.status).toBe("recovery");
    if (result.status !== "recovery") return;
    expect(result.raw).toBe("{original-corrupt-json");
    expect(storage.data[`${key}.recovery`]).toBe("{original-corrupt-json");
  });

  it("round-trips durable sync state and preserves malformed metadata", () => {
    const principal = userPrincipal("account-a");
    const key = syncStateStorageKey(principal);
    const storage = memoryStorage();
    const state = upsertScriptTombstone(emptyWebSyncState(), {
      scriptId: "script-a",
      deletedAt: "2026-07-30T13:00:00.000Z",
      expectedRemoteContentFingerprint: "v2:sha256:abc",
    });

    expect(saveSyncState(principal, state, storage)).toEqual({ ok: true });
    expect(loadSyncStateResult(principal, storage)).toEqual({
      status: "ok",
      state,
    });

    storage.data[key] = JSON.stringify({
      ...state,
      scriptTombstones: [
        {
          ...state.scriptTombstones[0],
          deletedAt: "not-an-iso-date",
        },
      ],
    });
    const corrupt = loadSyncStateResult(principal, storage);
    expect(corrupt.status).toBe("corrupt");
    if (corrupt.status !== "corrupt") return;
    expect(corrupt.recoveryKey).toBe(`${key}.recovery`);
    expect(storage.data[`${key}.recovery`]).toBe(storage.data[key]);
  });

  it("clearLibrary removes only the target principal's sync metadata and recovery", () => {
    const accountA = userPrincipal("account-a");
    const accountB = userPrincipal("account-b");
    const accountAKey = syncStateStorageKey(accountA);
    const accountBKey = syncStateStorageKey(accountB);
    const storage = memoryStorage({
      [accountAKey]: JSON.stringify(emptyWebSyncState()),
      [`${accountAKey}.recovery`]: "damaged-a",
      [accountBKey]: JSON.stringify(emptyWebSyncState()),
    });

    expect(clearLibrary(accountA, storage)).toEqual({ ok: true });
    expect(storage.data[accountAKey]).toBeUndefined();
    expect(storage.data[`${accountAKey}.recovery`]).toBeUndefined();
    expect(storage.data[accountBKey]).toBeDefined();
  });

  it("reports storage read and quota failures without throwing", () => {
    const throwingRead = {
      getItem() {
        throw new DOMException("blocked", "SecurityError");
      },
      setItem() {},
      removeItem() {},
    };
    expect(loadLibraryResult(guestPrincipal(), throwingRead).status).toBe(
      "unavailable",
    );

    const quotaStorage = {
      getItem() {
        return null;
      },
      setItem() {
        throw new DOMException("full", "QuotaExceededError");
      },
      removeItem() {},
    };
    const save = saveLibrary(
      guestPrincipal(),
      { scripts: [createScript({ title: "Unsaved" })], folders: [] },
      quotaStorage,
    );
    expect(save.ok).toBe(false);
  });
});
