// @vitest-environment jsdom
// @vitest-environment-options {"url":"http://localhost/"}

import type {
  AuthChangeEvent,
  Session,
  SupabaseClient,
  User,
} from "@supabase/supabase-js";
import { act, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import {
  afterEach,
  beforeEach,
  describe,
  expect,
  it,
  vi,
} from "vitest";

const authHarness = vi.hoisted(() => {
  type Listener = (event: string, session: unknown | null) => void;
  const state = {
    session: null as unknown | null,
  };
  const listeners = new Set<Listener>();
  const getSession = vi.fn(async () => ({
    data: { session: state.session },
    error: null,
  }));
  const onAuthStateChange = vi.fn((listener: Listener) => {
    listeners.add(listener);
    return {
      data: {
        subscription: {
          unsubscribe: vi.fn(() => listeners.delete(listener)),
        },
      },
    };
  });
  const resetPasswordForEmail = vi.fn(async () => ({
    data: {},
    error: null,
  }));
  const updateUser = vi.fn(async () => ({
    data: { user: state.session },
    error: null,
  }));
  const signOut = vi.fn(async () => ({ error: null }));
  const signInWithPassword = vi.fn(async () => ({ error: null }));
  const signInWithOAuth = vi.fn(async () => ({ error: null }));
  const auth = {
    getSession,
    onAuthStateChange,
    resetPasswordForEmail,
    updateUser,
    signOut,
    signInWithPassword,
    signInWithOAuth,
  };

  return {
    auth,
    client: { auth },
    emit(event: string, session: unknown | null) {
      state.session = session;
      for (const listener of listeners) listener(event, session);
    },
    reset(session: unknown | null) {
      state.session = session;
      listeners.clear();
      for (const method of Object.values(auth)) method.mockClear();
    },
  };
});

const repositoryHarness = vi.hoisted(() => ({
  pullRemoteLibrary: vi.fn(),
  fetchRemoteScript: vi.fn(),
  fetchRemoteFolder: vi.fn(),
  fetchRemoteFolders: vi.fn(),
  verifyRemoteScriptAbsences: vi.fn(),
  verifyRemoteFolderAbsences: vi.fn(),
  writeRemoteFolder: vi.fn(),
  deleteRemoteFolder: vi.fn(),
  upsertRemoteFolder: vi.fn(),
  upsertRemoteScript: vi.fn(),
  deleteRemoteScript: vi.fn(),
}));

vi.mock("@/lib/app/auth/config", () => ({
  getCloudConfig: () => ({
    configured: true,
    url: "https://example.supabase.co",
    publishableKey: "sb_publishable_test",
  }),
}));

vi.mock("@/lib/app/auth/client", () => ({
  getSupabaseBrowserClient: () =>
    authHarness.client as unknown as SupabaseClient,
  authCallbackUrl: (origin: string) =>
    `${origin.replace(/\/+$/, "")}/auth/callback`,
  passwordRecoveryCallbackUrl: (origin: string) =>
    `${origin.replace(/\/+$/, "")}/auth/callback?recovery=1`,
}));

vi.mock("@/lib/app/sync/repository", async (importOriginal) => ({
  ...(await importOriginal<
    typeof import("@/lib/app/sync/repository")
  >()),
  ...repositoryHarness,
}));

import {
  AppProvider,
  type AppContextValue,
  useApp,
} from "@/components/app/app-provider";
import { createScript, type ScriptDocument } from "@/lib/app/models/script";
import {
  libraryStorageKey,
  userPrincipal,
} from "@/lib/app/persistence/keys";
import {
  loadLibrary,
  loadSyncState,
  saveLibrary,
} from "@/lib/app/persistence/local-store";
import { synchronizedContentFingerprint } from "@/lib/app/sync/remote-map";

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
};

type MountedProvider = {
  value: () => AppContextValue;
  unmount: () => Promise<void>;
};

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

function testUser(id: string): User {
  return {
    id,
    aud: "authenticated",
    role: "authenticated",
    email: `${id}@example.test`,
    app_metadata: {},
    user_metadata: {},
    identities: [],
    created_at: "2026-07-30T00:00:00.000Z",
  };
}

function testSession(id: string): Session {
  const user = testUser(id);
  return {
    access_token: `access-${id}`,
    refresh_token: `refresh-${id}`,
    expires_in: 3600,
    expires_at: 2_000_000_000,
    token_type: "bearer",
    user,
  };
}

function remoteScript(
  id: string,
  title: string,
  body = title,
): ScriptDocument {
  const script = createScript({
    id,
    title,
    body,
    createdAt: "2026-07-30T01:00:00.000Z",
    updatedAt: "2026-07-30T01:00:00.000Z",
  });
  return {
    ...script,
    remoteUpdatedAtWire: "2026-07-30T01:00:00.000000Z",
    remoteContentFingerprint: synchronizedContentFingerprint(script),
  };
}

function installMemoryLocalStorage(): Storage {
  const data = new Map<string, string>();
  const storage: Storage = {
    get length() {
      return data.size;
    },
    clear() {
      data.clear();
    },
    getItem(key) {
      return data.get(key) ?? null;
    },
    key(index) {
      return Array.from(data.keys())[index] ?? null;
    },
    removeItem(key) {
      data.delete(key);
    },
    setItem(key, value) {
      data.set(key, String(value));
    },
  };
  Object.defineProperty(window, "localStorage", {
    configurable: true,
    value: storage,
  });
  return storage;
}

async function waitUntil(
  predicate: () => boolean,
  message: string,
): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (predicate()) return;
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
  }
  throw new Error(`Timed out waiting for ${message}`);
}

async function mountProvider(name: string): Promise<MountedProvider> {
  const container = document.createElement("div");
  container.dataset.provider = name;
  document.body.append(container);
  const root = createRoot(container);
  let latest: AppContextValue | null = null;

  function Probe({ children }: { children?: ReactNode }) {
    latest = useApp();
    return children ?? null;
  }

  await act(async () => {
    root.render(
      <AppProvider>
        <Probe />
      </AppProvider>,
    );
  });
  await waitUntil(() => latest?.ready === true, `${name} to become ready`);

  return {
    value() {
      if (!latest) throw new Error(`${name} did not expose app context`);
      return latest;
    },
    async unmount() {
      await act(async () => {
        root.unmount();
      });
      container.remove();
    },
  };
}

describe("mounted authenticated AppProvider regressions", () => {
  const mounted: MountedProvider[] = [];
  let online = true;

  beforeEach(() => {
    (
      globalThis as typeof globalThis & {
        IS_REACT_ACT_ENVIRONMENT: boolean;
      }
    ).IS_REACT_ACT_ENVIRONMENT = true;
    document.body.innerHTML = "";
    installMemoryLocalStorage();
    window.history.replaceState({}, "", "/app");
    online = true;
    Object.defineProperty(window.navigator, "onLine", {
      configurable: true,
      get: () => online,
    });
    authHarness.reset(null);
    for (const method of Object.values(repositoryHarness)) method.mockReset();
    repositoryHarness.pullRemoteLibrary.mockResolvedValue({
      ok: true,
      data: { scripts: [], folders: [] },
    });
    repositoryHarness.fetchRemoteFolders.mockResolvedValue({
      ok: true,
      data: [],
    });
    repositoryHarness.fetchRemoteScript.mockResolvedValue({
      ok: true,
      data: null,
    });
    repositoryHarness.fetchRemoteFolder.mockResolvedValue({
      ok: true,
      data: null,
    });
    repositoryHarness.verifyRemoteScriptAbsences.mockResolvedValue({
      ok: true,
      data: new Set<string>(),
    });
    repositoryHarness.verifyRemoteFolderAbsences.mockResolvedValue({
      ok: true,
      data: new Set<string>(),
    });
    repositoryHarness.writeRemoteFolder.mockImplementation(
      async (_client, _userId, folder) => ({
        ok: true,
        data: folder,
      }),
    );
    repositoryHarness.deleteRemoteFolder.mockResolvedValue({ ok: true });
    repositoryHarness.upsertRemoteFolder.mockImplementation(
      async (_client, _userId, folder) => ({
        ok: true,
        data: folder,
      }),
    );
    repositoryHarness.upsertRemoteScript.mockImplementation(
      async (_client, _userId, script: ScriptDocument) => ({
        ok: true,
        data: {
          ...script,
          remoteUpdatedAtWire: script.updatedAt,
          remoteContentFingerprint: synchronizedContentFingerprint(script),
        },
      }),
    );
    repositoryHarness.deleteRemoteScript.mockResolvedValue({ ok: true });
  });

  afterEach(async () => {
    while (mounted.length > 0) {
      await mounted.pop()?.unmount();
    }
    vi.clearAllMocks();
  });

  async function mount(name: string): Promise<MountedProvider> {
    const provider = await mountProvider(name);
    mounted.push(provider);
    return provider;
  }

  async function unmount(provider: MountedProvider): Promise<void> {
    const index = mounted.indexOf(provider);
    if (index >= 0) mounted.splice(index, 1);
    await provider.unmount();
  }

  it("never paints account A's delayed pull after switching to account B", async () => {
    const sessionA = testSession("account-a");
    const sessionB = testSession("account-b");
    const cachedA = remoteScript("cached-a", "A cached");
    const cachedB = remoteScript("cached-b", "B cached");
    const remoteA = remoteScript("remote-a", "A delayed remote");
    const remoteB = remoteScript("remote-b", "B current remote");
    saveLibrary(userPrincipal("account-a"), {
      scripts: [cachedA],
      folders: [],
    });
    saveLibrary(userPrincipal("account-b"), {
      scripts: [cachedB],
      folders: [],
    });
    const accountAPull = deferred<{
      ok: true;
      data: { scripts: ScriptDocument[]; folders: [] };
    }>();
    repositoryHarness.pullRemoteLibrary.mockImplementation(
      async (_client, userId: string) =>
        userId === "account-a"
          ? accountAPull.promise
          : { ok: true, data: { scripts: [remoteB], folders: [] } },
    );
    authHarness.reset(sessionA);

    const provider = await mount("account-switch");
    await waitUntil(
      () =>
        repositoryHarness.pullRemoteLibrary.mock.calls.some(
          (call) => call[1] === "account-a",
        ),
      "account A pull to start",
    );

    await act(async () => {
      authHarness.emit("SIGNED_IN" satisfies AuthChangeEvent, sessionB);
    });

    expect(provider.value().user?.id).toBe("account-b");
    expect(provider.value().library.scripts.map((script) => script.title)).toEqual([
      "B cached",
    ]);

    accountAPull.resolve({
      ok: true,
      data: { scripts: [remoteA], folders: [] },
    });
    await waitUntil(
      () =>
        repositoryHarness.pullRemoteLibrary.mock.calls.some(
          (call) => call[1] === "account-b",
        ) &&
        provider
          .value()
          .library.scripts.some((script) => script.id === remoteB.id),
      "account B synchronization",
    );

    expect(provider.value().user?.id).toBe("account-b");
    expect(
      provider.value().library.scripts.some((script) => script.id === remoteA.id),
    ).toBe(false);
    expect(
      provider.value().library.scripts.map((script) => script.id).sort(),
    ).toEqual([cachedB.id, remoteB.id].sort());
  });

  it("reconciles account A's delayed upload only into A's cache after switching to B", async () => {
    const sessionA = testSession("upload-account-a");
    const sessionB = testSession("upload-account-b");
    const dirtyA = createScript({
      id: "dirty-account-a",
      title: "A upload in flight",
      body: "private A content",
      createdAt: "2026-07-30T02:00:00.000Z",
      updatedAt: "2026-07-30T02:00:00.000Z",
    });
    const cachedB = remoteScript("safe-account-b", "B private cache");
    saveLibrary(userPrincipal("upload-account-a"), {
      scripts: [dirtyA],
      folders: [],
    });
    saveLibrary(userPrincipal("upload-account-b"), {
      scripts: [cachedB],
      folders: [],
    });
    const uploadA = deferred<{
      ok: true;
      data: ScriptDocument;
    }>();
    repositoryHarness.upsertRemoteScript.mockImplementation(
      async (_client, userId: string, script: ScriptDocument) =>
        userId === "upload-account-a"
          ? uploadA.promise
          : {
              ok: true,
              data: {
                ...script,
                remoteUpdatedAtWire: script.updatedAt,
                remoteContentFingerprint:
                  synchronizedContentFingerprint(script),
              },
            },
    );
    authHarness.reset(sessionA);
    const provider = await mount("upload-account-switch");
    await waitUntil(
      () =>
        repositoryHarness.upsertRemoteScript.mock.calls.some(
          (call) =>
            call[1] === "upload-account-a" &&
            (call[2] as ScriptDocument).id === dirtyA.id,
        ),
      "account A upload to start",
    );

    await act(async () => {
      authHarness.emit("SIGNED_IN" satisfies AuthChangeEvent, sessionB);
    });
    expect(provider.value().user?.id).toBe("upload-account-b");
    expect(provider.value().library.scripts.map((script) => script.id)).toEqual([
      cachedB.id,
    ]);

    const acknowledgedA = {
      ...dirtyA,
      updatedAt: "2026-07-30T02:00:01.000000Z",
      remoteUpdatedAtWire: "2026-07-30T02:00:01.000000Z",
      remoteContentFingerprint: synchronizedContentFingerprint(dirtyA),
    };
    uploadA.resolve({ ok: true, data: acknowledgedA });
    await waitUntil(
      () =>
        loadLibrary(userPrincipal("upload-account-a")).scripts[0]
          ?.remoteUpdatedAtWire === acknowledgedA.remoteUpdatedAtWire,
      "account A acknowledgement to reach only A's cache",
    );

    expect(provider.value().user?.id).toBe("upload-account-b");
    expect(
      provider
        .value()
        .library.scripts.some((script) => script.id === dirtyA.id),
    ).toBe(false);
    expect(
      loadLibrary(userPrincipal("upload-account-a")).scripts[0]?.id,
    ).toBe(dirtyA.id);
  });

  it("drives password recovery without exposing the callback code again", async () => {
    const session = testSession("recovery-user");
    authHarness.reset(session);
    const provider = await mount("password-recovery");

    await act(async () => {
      await provider.value().sendPasswordReset("person@example.test");
    });
    expect(authHarness.auth.resetPasswordForEmail).toHaveBeenCalledWith(
      "person@example.test",
      {
        redirectTo:
          "http://localhost/auth/callback?recovery=1",
      },
    );

    await act(async () => {
      authHarness.emit(
        "PASSWORD_RECOVERY" satisfies AuthChangeEvent,
        session,
      );
    });
    expect(provider.value().authView).toBe("recovery");

    await act(async () => {
      await provider.value().completePasswordRecovery("short");
    });
    expect(authHarness.auth.updateUser).not.toHaveBeenCalled();
    expect(provider.value().authError).toMatch(/at least 8 characters/i);

    window.history.replaceState({}, "", "/app?recovery=1");
    await act(async () => {
      await provider.value().completePasswordRecovery("long-enough-password");
    });

    expect(authHarness.auth.updateUser).toHaveBeenCalledWith({
      password: "long-enough-password",
    });
    expect(provider.value().authView).toBe("idle");
    expect(provider.value().authNotice).toBe("Password updated.");
    expect(window.location.pathname + window.location.search).toBe("/app");
  });

  it("merges simultaneous stale-tab writes without dropping either script", async () => {
    const session = testSession("shared-account");
    authHarness.reset(session);
    const tabA = await mount("tab-a");
    const tabB = await mount("tab-b");
    let scriptA!: ScriptDocument;
    let scriptB!: ScriptDocument;

    await act(async () => {
      scriptA = tabA.value().createNewScript();
      scriptB = tabB.value().createNewScript();
    });

    // Both providers began from the same empty snapshot. The second local write
    // therefore temporarily replaced the first in shared storage. A real
    // browser delivers this event to the other tab, which must merge both.
    await act(async () => {
      window.dispatchEvent(
        new StorageEvent("storage", {
          key: libraryStorageKey(userPrincipal("shared-account")),
        }),
      );
    });
    await waitUntil(
      () =>
        [tabA, tabB].every((tab) => {
          const ids = new Set(
            tab.value().library.scripts.map((script) => script.id),
          );
          return ids.has(scriptA.id) && ids.has(scriptB.id);
        }),
      "both concurrent scripts to appear in both tabs",
    );

    for (const tab of [tabA, tabB]) {
      expect(
        tab
          .value()
          .library.scripts.filter((script) =>
            [scriptA.id, scriptB.id].includes(script.id),
          ),
      ).toHaveLength(2);
    }
  });

  it("keeps an authenticated offline delete through reload and completes it on reconnect", async () => {
    online = false;
    const session = testSession("offline-delete-account");
    const deleted = remoteScript(
      "offline-delete-script",
      "Delete me while offline",
    );
    saveLibrary(userPrincipal("offline-delete-account"), {
      scripts: [deleted],
      folders: [],
    });
    repositoryHarness.pullRemoteLibrary.mockResolvedValue({
      ok: true,
      data: { scripts: [deleted], folders: [] },
    });
    repositoryHarness.fetchRemoteScript.mockResolvedValue({
      ok: true,
      data: deleted,
    });
    authHarness.reset(session);

    const beforeReload = await mount("offline-delete-before-reload");
    expect(
      beforeReload.value().library.scripts.some((script) => script.id === deleted.id),
    ).toBe(true);

    await act(async () => {
      beforeReload.value().deleteScript(deleted.id);
    });
    expect(
      beforeReload.value().library.scripts.some((script) => script.id === deleted.id),
    ).toBe(false);
    expect(
      loadSyncState(userPrincipal("offline-delete-account")).scriptTombstones,
    ).toMatchObject([{ scriptId: deleted.id }]);
    expect(repositoryHarness.deleteRemoteScript).not.toHaveBeenCalled();

    await unmount(beforeReload);
    const afterReload = await mount("offline-delete-after-reload");
    await waitUntil(
      () => repositoryHarness.pullRemoteLibrary.mock.calls.length >= 2,
      "the reloaded provider to pull while offline",
    );
    expect(
      afterReload.value().library.scripts.some((script) => script.id === deleted.id),
    ).toBe(false);
    expect(
      loadSyncState(userPrincipal("offline-delete-account")).scriptTombstones,
    ).toMatchObject([{ scriptId: deleted.id }]);

    online = true;
    await act(async () => {
      window.dispatchEvent(new Event("online"));
    });
    await waitUntil(
      () =>
        repositoryHarness.deleteRemoteScript.mock.calls.some(
          (call) =>
            call[1] === "offline-delete-account" &&
            (call[2] as ScriptDocument).id === deleted.id,
        ) &&
        loadSyncState(userPrincipal("offline-delete-account"))
          .scriptTombstones.length === 0,
      "the durable deletion to finish after reconnect",
    );

    expect(
      afterReload.value().library.scripts.some((script) => script.id === deleted.id),
    ).toBe(false);
    expect(
      loadLibrary(userPrincipal("offline-delete-account")).scripts.some(
        (script) => script.id === deleted.id,
      ),
    ).toBe(false);
  });

  it("restores a cloud script changed after an offline delete instead of erasing it", async () => {
    online = false;
    const session = testSession("delete-conflict-account");
    const original = remoteScript(
      "delete-conflict-script",
      "Original cloud generation",
      "original body",
    );
    const changedBase = createScript({
      ...original,
      title: "Changed on another device",
      body: "newer remote body must survive",
      updatedAt: "2026-07-30T03:00:00.000Z",
    });
    const changedRemote: ScriptDocument = {
      ...changedBase,
      remoteUpdatedAtWire: "2026-07-30T03:00:00.000000Z",
      remoteContentFingerprint: synchronizedContentFingerprint(changedBase),
    };
    saveLibrary(userPrincipal("delete-conflict-account"), {
      scripts: [original],
      folders: [],
    });
    repositoryHarness.pullRemoteLibrary.mockResolvedValue({
      ok: true,
      data: { scripts: [original], folders: [] },
    });
    repositoryHarness.fetchRemoteScript.mockResolvedValue({
      ok: true,
      data: changedRemote,
    });
    authHarness.reset(session);
    const provider = await mount("delete-conflict");

    await act(async () => {
      provider.value().deleteScript(original.id);
    });
    expect(
      provider.value().library.scripts.some((script) => script.id === original.id),
    ).toBe(false);

    repositoryHarness.pullRemoteLibrary.mockResolvedValue({
      ok: true,
      data: { scripts: [changedRemote], folders: [] },
    });
    online = true;
    await act(async () => {
      window.dispatchEvent(new Event("online"));
    });
    await waitUntil(
      () =>
        provider
          .value()
          .library.scripts.some(
            (script) =>
              script.id === changedRemote.id &&
              script.body === changedRemote.body,
          ) &&
        loadSyncState(userPrincipal("delete-conflict-account"))
          .scriptTombstones.length === 0,
      "the changed cloud generation to be restored",
    );

    expect(repositoryHarness.deleteRemoteScript).not.toHaveBeenCalled();
    expect(provider.value().syncStatus.detail).toMatch(
      /changed in the cloud.*restored/i,
    );
  });
});
