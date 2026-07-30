import { describe, expect, it } from "vitest";
import { PersistenceBlockRegistry } from "./block-registry";

describe("principal-scoped persistence recovery blocks", () => {
  it("never unblocks account A when account B loads or clears", () => {
    const registry = new PersistenceBlockRegistry();
    const accountALibrary = "phrasa.v1.user.a.library";
    const accountASync = "phrasa.v1.user.a.syncState";
    const accountBLibrary = "phrasa.v1.user.b.library";

    registry.block(accountALibrary);
    registry.block(accountASync);
    registry.block(accountBLibrary);

    registry.resolve(accountBLibrary);

    expect(registry.isBlocked(accountALibrary)).toBe(true);
    expect(registry.isBlocked(accountASync)).toBe(true);
    expect(registry.isBlocked(accountBLibrary)).toBe(false);
  });

  it("resolves only the exact downloaded-or-cleared key", () => {
    const registry = new PersistenceBlockRegistry();
    registry.block("account-a.library");
    registry.block("account-a.sync");

    registry.resolve("account-a.library");

    expect(registry.isBlocked("account-a.library")).toBe(false);
    expect(registry.isBlocked("account-a.sync")).toBe(true);
  });
});
