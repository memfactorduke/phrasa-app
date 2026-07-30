import { describe, expect, it } from "vitest";
import { buildSyncStatus } from "./status";

describe("sync status", () => {
  it("reports cloud unavailable without pretend sync", () => {
    const s = buildSyncStatus({
      cloudConfigured: false,
      userId: null,
      syncing: false,
    });
    expect(s.phase).toBe("cloud_unavailable");
    expect(s.message).toMatch(/unavailable/i);
  });

  it("reports guest when configured but signed out", () => {
    const s = buildSyncStatus({
      cloudConfigured: true,
      userId: null,
      syncing: false,
    });
    expect(s.phase).toBe("guest");
  });

  it("prefers honest error over idle when sync fails", () => {
    const s = buildSyncStatus({
      cloudConfigured: true,
      userId: "u",
      syncing: false,
      error: "network",
      lastSyncedAt: "2026-07-01T00:00:00.000Z",
    });
    expect(s.phase).toBe("error");
    expect(s.detail).toBe("network");
    expect(s.message).toMatch(/local edits stay/i);
  });
});
