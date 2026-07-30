import { describe, expect, it, vi } from "vitest";
import {
  createScript,
  createWelcomeScript,
} from "@/lib/app/models/script";
import {
  librarySnapshotsEqual,
  mergeConcurrentLocalLibraries,
  PrincipalGenerationGuard,
  reconcileUploadAcknowledgements,
  SerializedSyncLane,
} from "./session-guard";
import {
  scriptHasUnacknowledgedLocalEdit,
  synchronizedContentFingerprint,
} from "./remote-map";

describe("principal generation guard", () => {
  it("rejects account A work after switching to guest", () => {
    const guard = new PrincipalGenerationGuard();
    const accountA = guard.transitionTo("account-a");
    guard.transitionTo(null);

    let visible = "guest";
    guard.runIfCurrent(accountA, () => {
      visible = "account-a";
    });

    expect(visible).toBe("guest");
  });

  it("rejects account A work after switching to account B", () => {
    const guard = new PrincipalGenerationGuard();
    const accountA = guard.transitionTo("account-a");
    const accountB = guard.transitionTo("account-b");

    expect(guard.isCurrent(accountA)).toBe(false);
    expect(guard.isCurrent(accountB)).toBe(true);
  });

  it("does not run a scheduled account A push after sign-out", () => {
    vi.useFakeTimers();
    try {
      const guard = new PrincipalGenerationGuard();
      const accountA = guard.transitionTo("account-a");
      const pushed: string[] = [];
      setTimeout(() => {
        guard.runIfCurrent(accountA, () => pushed.push("account-a"));
      }, 800);

      guard.transitionTo(null);
      vi.advanceTimersByTime(800);

      expect(pushed).toEqual([]);
    } finally {
      vi.useRealTimers();
    }
  });
});

describe("serialized sync lane", () => {
  it("runs operations in request order", async () => {
    const lane = new SerializedSyncLane();
    const events: string[] = [];
    let releaseFirst: (() => void) | undefined;
    const firstBarrier = new Promise<void>((resolve) => {
      releaseFirst = resolve;
    });

    const first = lane.enqueue(async () => {
      events.push("first-start");
      await firstBarrier;
      events.push("first-end");
    });
    const second = lane.enqueue(async () => {
      events.push("second");
    });

    await Promise.resolve();
    expect(events).toEqual(["first-start"]);
    releaseFirst?.();
    await Promise.all([first, second]);
    expect(events).toEqual(["first-start", "first-end", "second"]);
  });
});

describe("upload acknowledgement reconciliation", () => {
  it("replaces an unchanged uploaded revision with the server acknowledgement", () => {
    const uploaded = createScript({
      id: "script-clean",
      body: "same content",
      updatedAt: "2026-07-29T10:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-29T09:00:00.000000Z",
      lastOpenedAt: "2026-07-29T10:05:00.000Z",
    });
    const acknowledged = {
      ...uploaded,
      updatedAt: "2026-07-29T10:00:02.000000Z",
      remoteUpdatedAtWire: "2026-07-29T10:00:02.000000Z",
      lastOpenedAt: "2026-07-29T10:01:00.000Z",
    };

    const result = reconcileUploadAcknowledgements(
      { scripts: [uploaded], folders: [] },
      [{ uploaded, acknowledged }],
    );

    expect(result.library.scripts[0]).toMatchObject({
      body: "same content",
      updatedAt: "2026-07-29T10:00:02.000000Z",
      remoteUpdatedAtWire: "2026-07-29T10:00:02.000000Z",
      lastOpenedAt: "2026-07-29T10:05:00.000Z",
    });
    expect(result.needsFollowUpPush).toBe(false);
  });

  it("retains edit B when upload A returns and requests a follow-up push", () => {
    const uploadedA = createScript({
      id: "script-1",
      title: "Draft",
      body: "A",
      updatedAt: "2026-07-29T10:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-29T09:00:00.000000Z",
    });
    const editedB = {
      ...uploadedA,
      body: "B",
      updatedAt: "2026-07-29T10:00:01.000Z",
    };
    const acknowledgedA = {
      ...uploadedA,
      updatedAt: "2026-07-29T10:00:02.000Z",
      remoteUpdatedAtWire: "2026-07-29T10:00:02.123456Z",
    };

    const result = reconcileUploadAcknowledgements(
      { scripts: [editedB], folders: [] },
      [{ uploaded: uploadedA, acknowledged: acknowledgedA }],
    );

    expect(result.library.scripts[0]?.body).toBe("B");
    expect(result.library.scripts[0]?.updatedAt).toBe(
      "2026-07-29T10:00:01.000Z",
    );
    expect(result.library.scripts[0]?.remoteUpdatedAtWire).toBe(
      "2026-07-29T10:00:02.123456Z",
    );
    expect(result.needsFollowUpPush).toBe(true);
  });

  it("retains and marks a later edit dirty when its timestamp collides with the acknowledgement", () => {
    const uploadedA = createScript({
      id: "same-clock",
      body: "A",
      updatedAt: "2026-07-29T10:00:00.000Z",
      remoteUpdatedAtWire: "2026-07-29T09:00:00.000Z",
    });
    const acknowledgedA = {
      ...uploadedA,
      updatedAt: "2026-07-29T10:00:02.000Z",
      remoteUpdatedAtWire: "2026-07-29T10:00:02.000Z",
    };
    const editedB = {
      ...uploadedA,
      body: "B",
      // Deliberate collision: a timestamp-only check would call this clean.
      updatedAt: acknowledgedA.remoteUpdatedAtWire,
    };

    const result = reconcileUploadAcknowledgements(
      { scripts: [editedB], folders: [] },
      [{ uploaded: uploadedA, acknowledged: acknowledgedA }],
    );
    const reconciled = result.library.scripts[0]!;

    expect(reconciled.body).toBe("B");
    expect(reconciled.remoteContentFingerprint).toBe(
      synchronizedContentFingerprint(acknowledgedA),
    );
    expect(scriptHasUnacknowledgedLocalEdit(reconciled)).toBe(true);
    expect(result.needsFollowUpPush).toBe(true);
  });

  it("never resurrects a row deleted while its upload was in flight", () => {
    const uploaded = createScript({ id: "gone", body: "uploading" });
    const acknowledged = {
      ...uploaded,
      remoteUpdatedAtWire: "2026-07-29T10:00:02.123456Z",
    };

    const result = reconcileUploadAcknowledgements(
      { scripts: [], folders: [] },
      [{ uploaded, acknowledged }],
    );

    expect(result.library.scripts).toEqual([]);
    expect(result.needsFollowUpPush).toBe(false);
  });
});

describe("cross-tab library merge", () => {
  it("deduplicates simultaneous untouched Welcome samples", () => {
    const first = createWelcomeScript();
    const second = createWelcomeScript();

    const merged = mergeConcurrentLocalLibraries(
      { scripts: [first], folders: [] },
      { scripts: [second], folders: [] },
    );

    expect(merged.scripts).toHaveLength(1);
    expect(merged.scripts[0]?.title).toBe("Welcome to Phrasa");
  });

  it("repairs stale whole-library overwrites without dropping either tab's script", () => {
    const tabA = createScript({
      id: "tab-a",
      body: "A",
      updatedAt: "2026-07-29T10:00:01.000Z",
    });
    const tabB = createScript({
      id: "tab-b",
      body: "B",
      updatedAt: "2026-07-29T10:00:02.000Z",
    });

    const merged = mergeConcurrentLocalLibraries(
      { scripts: [tabA], folders: [] },
      { scripts: [tabB], folders: [] },
    );

    expect(merged.scripts.map((script) => script.id).sort()).toEqual([
      "tab-a",
      "tab-b",
    ]);
    expect(librarySnapshotsEqual(merged, merged)).toBe(true);
  });
});
