"use client";

import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react";
import type { Session, User } from "@supabase/supabase-js";
import { getCloudConfig } from "@/lib/app/auth/config";
import {
  authCallbackUrl,
  getSupabaseBrowserClient,
  passwordRecoveryCallbackUrl,
} from "@/lib/app/auth/client";
import { AUTH_COPY } from "@/lib/app/auth/copy";
import {
  createFolder,
  createScript,
  createWelcomeScript,
  emptyLibrary,
  isUntouchedWelcomeScript,
  normalizeTitle,
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
  clearLibrary,
  clearGuestLibraryAfterSuccessfulImport,
  clearReaderSettings,
  loadGuestLibrary,
  loadLibrary,
  loadLibraryResult,
  loadReaderSettings,
  saveLibrary,
  saveReaderSettings,
} from "@/lib/app/persistence/local-store";
import {
  libraryStorageKey,
  principalFromUserId,
  userPrincipal,
} from "@/lib/app/persistence/keys";
import {
  mergeRemoteLibrary,
  scriptHasUnacknowledgedLocalEdit,
} from "@/lib/app/sync/remote-map";
import {
  deleteRemoteScript,
  fetchRemoteFolders,
  pullRemoteLibrary,
  upsertRemoteFolder,
  upsertRemoteScript,
  verifyRemoteScriptAbsences,
} from "@/lib/app/sync/repository";
import {
  librarySnapshotsEqual,
  mergeConcurrentLocalLibraries,
  PrincipalGenerationGuard,
  reconcileUploadAcknowledgements,
  SerializedSyncLane,
  type PrincipalGenerationToken,
  type ScriptUploadAcknowledgement,
} from "@/lib/app/sync/session-guard";
import { buildSyncStatus, type SyncStatus } from "@/lib/app/sync/status";

type AuthView = "idle" | "email" | "recovery";

export type BrowserPersistenceIssue = {
  message: string;
  recoveryRaw?: string;
};

type CrossTabLibraryMessage =
  | { kind: "delete-script"; userId: string | null; scriptId: string }
  | {
      kind: "clear-principal";
      userId: string | null;
      replacementLibrary: LibrarySnapshot;
      replacementSettings: ReaderSettings;
    }
  | {
      kind: "restore-script";
      userId: string | null;
      script: ScriptDocument;
    };

export type AppContextValue = {
  ready: boolean;
  cloudConfigured: boolean;
  user: User | null;
  session: Session | null;
  library: LibrarySnapshot;
  readerSettings: ReaderSettings;
  syncStatus: SyncStatus;
  authError: string | null;
  authNotice: string | null;
  persistenceIssue: BrowserPersistenceIssue | null;
  authView: AuthView;
  guestImportPending: LibrarySnapshot | null;
  setAuthView: (view: AuthView) => void;
  clearAuthError: () => void;
  signInWithApple: () => Promise<void>;
  signInWithEmail: (email: string, password: string) => Promise<void>;
  sendPasswordReset: (email: string) => Promise<void>;
  completePasswordRecovery: (password: string) => Promise<void>;
  signOut: () => Promise<void>;
  clearThisBrowser: () => Promise<void>;
  createNewScript: () => ScriptDocument;
  updateScript: (
    id: string,
    patch: Partial<Pick<ScriptDocument, "title" | "body" | "tags" | "folderId">>,
  ) => void;
  deleteScript: (id: string) => void;
  duplicateScript: (id: string) => ScriptDocument | null;
  getScript: (id: string) => ScriptDocument | undefined;
  touchOpened: (id: string) => void;
  createNewFolder: (name: string) => ScriptFolder;
  updateReaderSettings: (patch: Partial<ReaderSettings>) => void;
  syncNow: () => Promise<void>;
  importGuestLibrary: () => Promise<void>;
  skipGuestImport: () => void;
};

const AppContext = createContext<AppContextValue | null>(null);

function sortLibrary(library: LibrarySnapshot): LibrarySnapshot {
  return {
    scripts: [...library.scripts].sort((a, b) =>
      b.updatedAt.localeCompare(a.updatedAt),
    ),
    folders: [...library.folders].sort((a, b) => a.name.localeCompare(b.name)),
  };
}

function guestLibraryForImport(
  library: LibrarySnapshot,
): LibrarySnapshot | null {
  const scripts = library.scripts.filter(
    (script) => !isUntouchedWelcomeScript(script),
  );
  return scripts.length > 0 ? { scripts, folders: library.folders } : null;
}

export function AppProvider({ children }: { children: ReactNode }) {
  const cloudConfigured = useMemo(() => getCloudConfig().configured, []);
  const [ready, setReady] = useState(false);
  const [user, setUser] = useState<User | null>(null);
  const [session, setSession] = useState<Session | null>(null);
  const [library, setLibrary] = useState<LibrarySnapshot>(emptyLibrary());
  const [readerSettings, setReaderSettings] = useState<ReaderSettings>(
    DEFAULT_READER_SETTINGS,
  );
  const [syncing, setSyncing] = useState(false);
  const [syncError, setSyncError] = useState<string | null>(null);
  const [lastSyncedAt, setLastSyncedAt] = useState<string | null>(null);
  const [authError, setAuthError] = useState<string | null>(null);
  const [authNotice, setAuthNotice] = useState<string | null>(null);
  const [persistenceIssue, setPersistenceIssue] =
    useState<BrowserPersistenceIssue | null>(null);
  const [authView, setAuthView] = useState<AuthView>("idle");
  const [guestImportPending, setGuestImportPending] =
    useState<LibrarySnapshot | null>(null);
  const [online, setOnline] = useState(() =>
    typeof navigator !== "undefined" ? navigator.onLine : true,
  );
  const libraryRef = useRef(library);
  const readerSettingsRef = useRef(readerSettings);
  const userRef = useRef(user);
  const syncTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const principalGuard = useRef(new PrincipalGenerationGuard());
  const syncLane = useRef(new SerializedSyncLane());
  const cloudMutationRevision = useRef(0);
  const crossTabChannel = useRef<BroadcastChannel | null>(null);
  const crossTabDeletedScriptIDs = useRef(new Set<string>());
  const blockedPersistenceKey = useRef<string | null>(null);

  useEffect(() => {
    libraryRef.current = library;
  }, [library]);
  useEffect(() => {
    readerSettingsRef.current = readerSettings;
  }, [readerSettings]);
  useEffect(() => {
    userRef.current = user;
  }, [user]);

  const cancelScheduledPush = useCallback(() => {
    if (syncTimer.current) {
      clearTimeout(syncTimer.current);
      syncTimer.current = null;
    }
  }, []);

  /** Persist any account's cache without changing whichever principal is visible. */
  const persistLibraryCache = useCallback(
    (next: LibrarySnapshot, userId: string | null | undefined) => {
      const sorted = sortLibrary(next);
      const principal = principalFromUserId(userId);
      const key = libraryStorageKey(principal);
      if (blockedPersistenceKey.current === key) {
        setPersistenceIssue((prior) => prior ?? {
          message:
            "This library is visible for recovery but is not being overwritten. Download the recovery copy before starting fresh.",
        });
        return sorted;
      }
      const saved = saveLibrary(principal, sorted);
      if (!saved.ok && principalGuard.current.current().userId === (userId ?? null)) {
        setPersistenceIssue({
          message: `Your latest changes are visible but were not saved in this browser: ${saved.error}`,
        });
      }
      return sorted;
    },
    [],
  );

  const applyVisibleLibrary = useCallback(
    (
      next: LibrarySnapshot,
      token: PrincipalGenerationToken,
    ): boolean => {
      if (!principalGuard.current.isCurrent(token)) return false;
      libraryRef.current = next;
      setLibrary(next);
      return true;
    },
    [],
  );

  const persistVisibleLibrary = useCallback(
    (
      next: LibrarySnapshot,
      userId: string | null | undefined,
      cloudRelevant = true,
    ) => {
      const token = principalGuard.current.current();
      if ((userId ?? null) !== token.userId) {
        return persistLibraryCache(next, userId);
      }
      const sorted = persistLibraryCache(next, userId);
      applyVisibleLibrary(sorted, token);
      if (cloudRelevant && token.userId) {
        cloudMutationRevision.current += 1;
      }
      return sorted;
    },
    [applyVisibleLibrary, persistLibraryCache],
  );

  const loadPrincipalSnapshot = useCallback((userId: string | null) => {
    const principal = principalFromUserId(userId);
    const loaded = loadLibraryResult(principal);
    let snap = loaded.library;
    let issue: BrowserPersistenceIssue | null = null;
    const key = libraryStorageKey(principal);
    if (loaded.status === "corrupt") {
      blockedPersistenceKey.current = loaded.recoveryKey ? null : key;
      issue = {
        message:
          "Phrasa found damaged browser library data and did not overwrite it. Download the recovery copy before editing or clearing this browser.",
        recoveryRaw: loaded.raw,
      };
    } else if (loaded.status === "unavailable") {
      blockedPersistenceKey.current = key;
      issue = {
        message: `Browser storage is unavailable. Changes in this tab may not survive a reload: ${loaded.error}`,
      };
    } else {
      blockedPersistenceKey.current = null;
    }
    if (principal.kind === "guest" && loaded.status === "empty") {
      snap = {
        scripts: [createWelcomeScript()],
        folders: [],
      };
      const seeded = saveLibrary(principal, snap);
      if (!seeded.ok) {
        issue = {
          message: `The sample library opened, but browser storage could not save it: ${seeded.error}`,
        };
      }
    }
    return {
      library: sortLibrary(snap),
      settings: loadReaderSettings(principal),
      issue,
    };
  }, []);

  /**
   * Auth transitions synchronously invalidate old async work and refs before
   * React schedules a render. Cache selection and visible-state application are
   * intentionally separate from background sync cache writes.
   */
  const switchPrincipal = useCallback(
    (nextUser: User | null, nextSession: Session | null) => {
      cancelScheduledPush();
      const userId = nextUser?.id ?? null;
      const token = principalGuard.current.transitionTo(userId);
      const loaded = loadPrincipalSnapshot(userId);
      userRef.current = nextUser;
      libraryRef.current = loaded.library;
      readerSettingsRef.current = loaded.settings;
      cloudMutationRevision.current = 0;
      crossTabDeletedScriptIDs.current.clear();
      setUser(nextUser);
      setSession(nextSession);
      setLibrary(loaded.library);
      setReaderSettings(loaded.settings);
      setSyncing(false);
      setSyncError(null);
      setLastSyncedAt(null);
      setAuthError(null);
      setAuthNotice(null);
      setPersistenceIssue(loaded.issue);
      return token;
    },
    [cancelScheduledPush, loadPrincipalSnapshot],
  );

  const performPush = useCallback(
    async (token: PrincipalGenerationToken) => {
      const userId = token.userId;
      const client = getSupabaseBrowserClient();
      if (
        !userId ||
        !client ||
        !principalGuard.current.isCurrent(token)
      ) {
        return { needsFollowUpPush: false };
      }

      const startingRevision = cloudMutationRevision.current;
      const uploadSnapshot = loadLibrary(userPrincipal(userId));
      const acknowledgements: ScriptUploadAcknowledgement[] = [];
      let operationError: string | null = null;

      const remoteFolders = await fetchRemoteFolders(client, userId);
      if (!remoteFolders.ok) {
        operationError = remoteFolders.error;
      } else {
        const remoteFoldersByID = new Map(
          remoteFolders.data.map((folder) => [folder.id, folder]),
        );
        for (const folder of uploadSnapshot.folders) {
          if (!principalGuard.current.isCurrent(token)) break;
          const remoteFolder = remoteFoldersByID.get(folder.id);
          if (remoteFolder?.name === folder.name) continue;
          if (remoteFolder) {
            operationError =
              `Folder “${folder.name}” changed on another device. ` +
              "Sync again to use the cloud version; no folder was overwritten.";
            break;
          }
          const result = await upsertRemoteFolder(client, userId, folder);
          if (!result.ok) {
            operationError = result.error;
            break;
          }
        }
      }

      if (!operationError) {
        const dirtyScripts = uploadSnapshot.scripts.filter(
          scriptHasUnacknowledgedLocalEdit,
        );
        for (const script of dirtyScripts) {
          if (!principalGuard.current.isCurrent(token)) break;
          const result = await upsertRemoteScript(client, userId, script);
          if (!result.ok) {
            operationError = operationError ?? result.error;
            continue;
          }
          acknowledgements.push({
            uploaded: script,
            acknowledged: result.data,
          });
        }
      }

      // Always reconcile completed acknowledgements into account A's latest
      // cache. This is safe after an A -> B transition because it does not touch
      // visible state, and it prevents a successful write from losing its OCC wire.
      const latest = loadLibrary(userPrincipal(userId));
      const reconciled = reconcileUploadAcknowledgements(
        latest,
        acknowledgements,
      );
      const cached = persistLibraryCache(reconciled.library, userId);
      const stillCurrent = principalGuard.current.isCurrent(token);
      if (stillCurrent) {
        applyVisibleLibrary(cached, token);
        if (operationError) {
          setSyncError(operationError);
        } else {
          setLastSyncedAt(new Date().toISOString());
        }
      }

      return {
        needsFollowUpPush:
          stillCurrent &&
          operationError === null &&
          (reconciled.needsFollowUpPush ||
            cloudMutationRevision.current !== startingRevision),
      };
    },
    [applyVisibleLibrary, persistLibraryCache],
  );

  const enqueuePush = useCallback(
    async function requestPush(token: PrincipalGenerationToken) {
      const outcome = await syncLane.current.enqueue(async () => {
        if (!principalGuard.current.isCurrent(token)) {
          return { needsFollowUpPush: false };
        }
        if (typeof navigator !== "undefined" && !navigator.onLine) {
          // Durable local cache is already authoritative. Reconnect handling
          // will pull then push; do not manufacture a transport error offline.
          return { needsFollowUpPush: false };
        }
        setSyncing(true);
        setSyncError(null);
        try {
          return await performPush(token);
        } catch (err) {
          if (principalGuard.current.isCurrent(token)) {
            setSyncError(err instanceof Error ? err.message : "Sync failed");
          }
          return { needsFollowUpPush: false };
        } finally {
          if (principalGuard.current.isCurrent(token)) {
            setSyncing(false);
          }
        }
      });

      if (
        outcome.needsFollowUpPush &&
        principalGuard.current.isCurrent(token)
      ) {
        cancelScheduledPush();
        syncTimer.current = setTimeout(() => {
          syncTimer.current = null;
          if (principalGuard.current.isCurrent(token)) {
            void requestPush(token);
          }
        }, 800);
      }
    },
    [cancelScheduledPush, performPush],
  );

  const pullAndMerge = useCallback(
    async (token: PrincipalGenerationToken) => {
      await syncLane.current.enqueue(async () => {
        const userId = token.userId;
        if (!userId || !principalGuard.current.isCurrent(token)) return;
        const client = getSupabaseBrowserClient();
        if (!client) return;
        setSyncing(true);
        setSyncError(null);
        try {
          const remote = await pullRemoteLibrary(client, userId);
          if (!remote.ok) {
            if (principalGuard.current.isCurrent(token)) {
              setSyncError(remote.error);
            }
            return;
          }
          const local = loadLibrary(userPrincipal(userId));
          const remoteScriptIDs = new Set(
            remote.data.scripts.map((script) => script.id),
          );
          const absenceCandidates = local.scripts
            .filter(
              (script) =>
                script.remoteUpdatedAtWire &&
                !remoteScriptIDs.has(script.id),
            )
            .map((script) => script.id);
          const verifiedAbsences = await verifyRemoteScriptAbsences(
            client,
            userId,
            absenceCandidates,
          );
          if (!verifiedAbsences.ok) {
            if (principalGuard.current.isCurrent(token)) {
              setSyncError(verifiedAbsences.error);
            }
            return;
          }
          const latest = loadLibrary(userPrincipal(userId));
          const merged = mergeRemoteLibrary(
            latest,
            remote.data,
            verifiedAbsences.data,
          );
          const cached = persistLibraryCache(
            { scripts: merged.scripts, folders: merged.folders },
            userId,
          );
          if (principalGuard.current.isCurrent(token)) {
            applyVisibleLibrary(cached, token);
            setLastSyncedAt(new Date().toISOString());
            if (merged.notes.length > 0) {
              setSyncError(merged.notes[0] ?? null);
            }
          }
        } catch (err) {
          if (principalGuard.current.isCurrent(token)) {
            setSyncError(err instanceof Error ? err.message : "Sync failed");
          }
        } finally {
          if (principalGuard.current.isCurrent(token)) {
            setSyncing(false);
          }
        }
      });
    },
    [applyVisibleLibrary, persistLibraryCache],
  );

  const schedulePush = useCallback(
    (userId: string) => {
      const token = principalGuard.current.current();
      if (token.userId !== userId) return;
      cancelScheduledPush();
      syncTimer.current = setTimeout(() => {
        syncTimer.current = null;
        if (principalGuard.current.isCurrent(token)) {
          void enqueuePush(token);
        }
      }, 800);
    },
    [cancelScheduledPush, enqueuePush],
  );

  const synchronizePrincipal = useCallback(
    async (token: PrincipalGenerationToken) => {
      if (!principalGuard.current.isCurrent(token)) return;
      await pullAndMerge(token);
      if (principalGuard.current.isCurrent(token)) {
        await enqueuePush(token);
      }
    },
    [enqueuePush, pullAndMerge],
  );

  useEffect(() => {
    const applyPeerSnapshot = (
      incoming: LibrarySnapshot,
      token: PrincipalGenerationToken,
    ) => {
      if (!principalGuard.current.isCurrent(token)) return;
      const filtered = {
        ...incoming,
        scripts: incoming.scripts.filter(
          (script) => !crossTabDeletedScriptIDs.current.has(script.id),
        ),
      };
      const current = libraryRef.current;
      const merged = mergeConcurrentLocalLibraries(current, filtered);
      if (librarySnapshotsEqual(current, merged)) return;
      const cached = persistLibraryCache(merged, token.userId);
      if (!applyVisibleLibrary(cached, token)) return;

      const hasDirtyScript = cached.scripts.some(
        scriptHasUnacknowledgedLocalEdit,
      );
      const gainedFolder = cached.folders.length > current.folders.length;
      if (token.userId && (hasDirtyScript || gainedFolder)) {
        cloudMutationRevision.current += 1;
        schedulePush(token.userId);
      }
    };

    const onStorage = (event: StorageEvent) => {
      const token = principalGuard.current.current();
      const principal = principalFromUserId(token.userId);
      if (
        event.key !== libraryStorageKey(principal)
      ) {
        return;
      }
      const loaded = loadLibraryResult(principal);
      if (loaded.status === "corrupt") {
        setPersistenceIssue({
          message:
            "Another tab wrote damaged browser library data. Phrasa left the current library visible and preserved the raw data for recovery.",
          recoveryRaw: loaded.raw,
        });
        return;
      }
      if (loaded.status === "unavailable") {
        setPersistenceIssue({
          message: `Browser storage could not be read after another-tab update: ${loaded.error}`,
        });
        return;
      }
      applyPeerSnapshot(loaded.library, token);
    };

    window.addEventListener("storage", onStorage);
    if (typeof BroadcastChannel !== "undefined") {
      const channel = new BroadcastChannel("phrasa.web.library.v1");
      crossTabChannel.current = channel;
      channel.onmessage = (event: MessageEvent<CrossTabLibraryMessage>) => {
        const message = event.data;
        const token = principalGuard.current.current();
        if (!message) return;

        if (message.kind === "clear-principal") {
          const peerLibraryResult = clearLibrary(
            principalFromUserId(message.userId),
          );
          const peerSettingsResult = clearReaderSettings(
            principalFromUserId(message.userId),
          );
          const peerClearingError = !peerLibraryResult.ok
            ? peerLibraryResult.error
            : !peerSettingsResult.ok
              ? peerSettingsResult.error
              : null;
          if (peerClearingError) {
            setPersistenceIssue({
              message: `Another tab asked to clear this browser, but this tab could not finish: ${peerClearingError}`,
            });
            return;
          }
          const replacementLibraryResult = saveLibrary(
            principalFromUserId(null),
            message.replacementLibrary,
          );
          const replacementSettingsResult = saveReaderSettings(
            principalFromUserId(null),
            message.replacementSettings,
          );
          const replacementError = !replacementLibraryResult.ok
            ? replacementLibraryResult.error
            : !replacementSettingsResult.ok
              ? replacementSettingsResult.error
              : null;
          if (replacementError) {
            setPersistenceIssue({
              message: `Another tab cleared this browser, but this tab could not install the safe replacement library: ${replacementError}`,
            });
            return;
          }
          blockedPersistenceKey.current = null;
          setPersistenceIssue(null);
          // A shared Supabase sign-out event may arrive before this channel
          // message. Clear the named cache regardless; reset visible state only
          // if this tab still shows that principal or is already guest.
          if (token.userId === message.userId || token.userId === null) {
            switchPrincipal(null, null);
            const client = getSupabaseBrowserClient();
            if (client && message.userId && token.userId === message.userId) {
              void client.auth.signOut();
            }
          }
          return;
        }

        if (message.userId !== token.userId) return;

        if (message.kind === "delete-script") {
          crossTabDeletedScriptIDs.current.add(message.scriptId);
          const next = {
            ...libraryRef.current,
            scripts: libraryRef.current.scripts.filter(
              (script) => script.id !== message.scriptId,
            ),
          };
          const cached = persistLibraryCache(next, token.userId);
          applyVisibleLibrary(cached, token);
          return;
        }

        crossTabDeletedScriptIDs.current.delete(message.script.id);
        applyPeerSnapshot(
          {
            ...libraryRef.current,
            scripts: [
              message.script,
              ...libraryRef.current.scripts.filter(
                (script) => script.id !== message.script.id,
              ),
            ],
          },
          token,
        );
      };
    }

    return () => {
      window.removeEventListener("storage", onStorage);
      crossTabChannel.current?.close();
      crossTabChannel.current = null;
    };
  }, [
    applyVisibleLibrary,
    persistLibraryCache,
    schedulePush,
    switchPrincipal,
  ]);

  useEffect(() => {
    const synchronizeIfSignedIn = () => {
      const token = principalGuard.current.current();
      if (token.userId) void synchronizePrincipal(token);
    };
    const on = () => {
      setOnline(true);
      synchronizeIfSignedIn();
    };
    const off = () => setOnline(false);
    const onVisibilityChange = () => {
      if (document.visibilityState === "visible") {
        synchronizeIfSignedIn();
      }
    };
    window.addEventListener("online", on);
    window.addEventListener("offline", off);
    document.addEventListener("visibilitychange", onVisibilityChange);
    return () => {
      window.removeEventListener("online", on);
      window.removeEventListener("offline", off);
      document.removeEventListener("visibilitychange", onVisibilityChange);
    };
  }, [synchronizePrincipal]);

  useEffect(() => {
    let cancelled = false;
    const client = getSupabaseBrowserClient();

    async function boot() {
      if (!client) {
        switchPrincipal(null, null);
        if (!cancelled) setReady(true);
        return;
      }

      const { data } = await client.auth.getSession();
      if (cancelled) return;
      const nextUser = data.session?.user ?? null;
      const token = switchPrincipal(nextUser, data.session);
      if (
        nextUser &&
        new URLSearchParams(window.location.search).get("recovery") === "1"
      ) {
        setAuthView("recovery");
      }

      if (nextUser) {
        const guest = guestLibraryForImport(loadGuestLibrary());
        if (guest) {
          setGuestImportPending(guest);
        }
        void synchronizePrincipal(token);
      }
      if (!cancelled) setReady(true);
    }

    void boot();

    if (!client) return () => {
      cancelled = true;
    };

    const { data: sub } = client.auth.onAuthStateChange((event, nextSession) => {
      const prevUserId = userRef.current?.id ?? null;
      const nextUser = nextSession?.user ?? null;

      if (event === "PASSWORD_RECOVERY") {
        setAuthView("recovery");
      }

      if (event === "SIGNED_OUT" || !nextUser) {
        // Hard switch to guest namespace — never keep prior account rows in UI state.
        setGuestImportPending(null);
        switchPrincipal(null, null);
        return;
      }

      if (nextUser.id !== prevUserId) {
        const token = switchPrincipal(nextUser, nextSession);
        const guest = guestLibraryForImport(loadGuestLibrary());
        if (guest) {
          setGuestImportPending(guest);
        }
        void synchronizePrincipal(token);
      } else {
        // Token refresh for the same principal does not invalidate safe work.
        userRef.current = nextUser;
        setUser(nextUser);
        setSession(nextSession);
      }
    });

    return () => {
      cancelled = true;
      sub.subscription.unsubscribe();
      cancelScheduledPush();
    };
  }, [cancelScheduledPush, switchPrincipal, synchronizePrincipal]);

  const signInWithApple = useCallback(async () => {
    setAuthError(null);
    setAuthNotice(null);
    const client = getSupabaseBrowserClient();
    if (!client) {
      setAuthError(AUTH_COPY.cloudUnavailableSignInHint);
      return;
    }
    const { error } = await client.auth.signInWithOAuth({
      provider: "apple",
      options: {
        redirectTo: authCallbackUrl(window.location.origin),
        skipBrowserRedirect: false,
      },
    });
    if (error) setAuthError(error.message);
  }, []);

  const signInWithEmail = useCallback(async (email: string, password: string) => {
    setAuthError(null);
    setAuthNotice(null);
    const client = getSupabaseBrowserClient();
    if (!client) {
      setAuthError(AUTH_COPY.cloudUnavailableSignInHint);
      return;
    }
    const { error } = await client.auth.signInWithPassword({ email, password });
    if (error) setAuthError(error.message);
  }, []);

  const sendPasswordReset = useCallback(async (email: string) => {
    setAuthError(null);
    setAuthNotice(null);
    const client = getSupabaseBrowserClient();
    if (!client) {
      setAuthError(AUTH_COPY.cloudUnavailableSignInHint);
      return;
    }
    const { error } = await client.auth.resetPasswordForEmail(email, {
      redirectTo: passwordRecoveryCallbackUrl(window.location.origin),
    });
    if (error) {
      setAuthError(error.message);
    } else {
      setAuthNotice(
        "Password-reset instructions are on their way. Open the link in this browser.",
      );
    }
  }, []);

  const completePasswordRecovery = useCallback(async (password: string) => {
    setAuthError(null);
    setAuthNotice(null);
    if (password.length < 8) {
      setAuthError("Use at least 8 characters for the new password.");
      return;
    }
    const client = getSupabaseBrowserClient();
    if (!client) {
      setAuthError(AUTH_COPY.cloudUnavailableSignInHint);
      return;
    }
    const { error } = await client.auth.updateUser({ password });
    if (error) {
      setAuthError(error.message);
      return;
    }
    setAuthView("idle");
    window.history.replaceState({}, "", "/app");
    setAuthNotice("Password updated.");
  }, []);

  const signOut = useCallback(async () => {
    setAuthError(null);
    setAuthNotice(null);
    const client = getSupabaseBrowserClient();
    setGuestImportPending(null);
    // Invalidate account work and synchronously switch refs before sign-out I/O.
    const guestToken = switchPrincipal(null, null);
    if (client) {
      const { error } = await client.auth.signOut();
      if (error && principalGuard.current.isCurrent(guestToken)) {
        setAuthError(error.message);
      }
    }
  }, [switchPrincipal]);

  const clearThisBrowser = useCallback(async () => {
    const currentUserId = userRef.current?.id ?? null;
    const principal = principalFromUserId(currentUserId);
    const libraryResult = clearLibrary(principal);
    const settingsResult = clearReaderSettings(principal);
    const clearingError = !libraryResult.ok
      ? libraryResult.error
      : !settingsResult.ok
        ? settingsResult.error
        : null;
    if (clearingError) {
      setPersistenceIssue({
        message: clearingError,
      });
      return;
    }
    blockedPersistenceKey.current = null;
    setPersistenceIssue(null);
    setGuestImportPending(null);
    const client = getSupabaseBrowserClient();
    switchPrincipal(null, null);
    crossTabChannel.current?.postMessage({
      kind: "clear-principal",
      userId: currentUserId,
      replacementLibrary: libraryRef.current,
      replacementSettings: readerSettingsRef.current,
    } satisfies CrossTabLibraryMessage);
    if (client && currentUserId) {
      const { error } = await client.auth.signOut();
      if (error) setAuthError(error.message);
    }
  }, [switchPrincipal]);

  const createNewScript = useCallback(() => {
    const script = createScript({ title: "Untitled script", body: "" });
    const next = {
      ...libraryRef.current,
      scripts: [script, ...libraryRef.current.scripts],
    };
    const userId = userRef.current?.id ?? null;
    persistVisibleLibrary(next, userId);
    if (userId) schedulePush(userId);
    return script;
  }, [persistVisibleLibrary, schedulePush]);

  const updateScript = useCallback(
    (
      id: string,
      patch: Partial<
        Pick<ScriptDocument, "title" | "body" | "tags" | "folderId">
      >,
    ) => {
      const now = new Date().toISOString();
      const nextScripts = libraryRef.current.scripts.map((s) => {
        if (s.id !== id) return s;
        return {
          ...s,
          title: patch.title !== undefined ? normalizeTitle(patch.title) : s.title,
          body: patch.body !== undefined ? patch.body : s.body,
          tags: patch.tags !== undefined ? patch.tags : s.tags,
          folderId: patch.folderId !== undefined ? patch.folderId : s.folderId,
          updatedAt: now,
        };
      });
      const userId = userRef.current?.id ?? null;
      persistVisibleLibrary(
        { scripts: nextScripts, folders: libraryRef.current.folders },
        userId,
      );
      if (userId) schedulePush(userId);
    },
    [persistVisibleLibrary, schedulePush],
  );

  const deleteScript = useCallback(
    (id: string) => {
      const existing = libraryRef.current.scripts.find((s) => s.id === id);
      const nextScripts = libraryRef.current.scripts.filter((s) => s.id !== id);
      const userId = userRef.current?.id ?? null;
      const token = principalGuard.current.current();
      crossTabDeletedScriptIDs.current.add(id);
      persistVisibleLibrary(
        { scripts: nextScripts, folders: libraryRef.current.folders },
        userId,
      );
      crossTabChannel.current?.postMessage({
        kind: "delete-script",
        userId,
        scriptId: id,
      } satisfies CrossTabLibraryMessage);
      if (userId && existing) {
        const client = getSupabaseBrowserClient();
        if (client) {
          void deleteRemoteScript(client, userId, existing).then((result) => {
            if (result.ok) return;
            // Restore account A's cache even if the visible principal changed.
            // Only applying to the screen remains generation-guarded.
            const latest = loadLibrary(userPrincipal(userId));
            const restored = latest.scripts.some(
              (script) => script.id === existing.id,
            )
              ? latest
              : {
                  scripts: [existing, ...latest.scripts],
                  folders: latest.folders,
            };
            const cached = persistLibraryCache(restored, userId);
            crossTabChannel.current?.postMessage({
              kind: "restore-script",
              userId,
              script: existing,
            } satisfies CrossTabLibraryMessage);
            if (principalGuard.current.isCurrent(token)) {
              crossTabDeletedScriptIDs.current.delete(existing.id);
              setSyncError(result.error);
              applyVisibleLibrary(cached, token);
            }
          });
        }
      }
    },
    [applyVisibleLibrary, persistLibraryCache, persistVisibleLibrary],
  );

  const duplicateScript = useCallback(
    (id: string) => {
      const source = libraryRef.current.scripts.find((s) => s.id === id);
      if (!source) return null;
      const copy = createScript({
        title: `${source.title} copy`,
        body: source.body,
        tags: [...source.tags],
        outline: source.outline.map((p) => ({ ...p, id: crypto.randomUUID() })),
        folderId: source.folderId,
        source: source.source,
      });
      const userId = userRef.current?.id ?? null;
      persistVisibleLibrary(
        {
          scripts: [copy, ...libraryRef.current.scripts],
          folders: libraryRef.current.folders,
        },
        userId,
      );
      if (userId) schedulePush(userId);
      return copy;
    },
    [persistVisibleLibrary, schedulePush],
  );

  const getScript = useCallback((id: string) => {
    return libraryRef.current.scripts.find((s) => s.id === id);
  }, []);

  const touchOpened = useCallback(
    (id: string) => {
      const now = new Date().toISOString();
      const nextScripts = libraryRef.current.scripts.map((s) =>
        s.id === id ? { ...s, lastOpenedAt: now } : s,
      );
      const userId = userRef.current?.id ?? null;
      // last_opened_at-only should not force content sync conflict; still persist local.
      persistVisibleLibrary(
        { scripts: nextScripts, folders: libraryRef.current.folders },
        userId,
        false,
      );
    },
    [persistVisibleLibrary],
  );

  const createNewFolder = useCallback(
    (name: string) => {
      const folder = createFolder(name);
      const userId = userRef.current?.id ?? null;
      persistVisibleLibrary(
        {
          scripts: libraryRef.current.scripts,
          folders: [...libraryRef.current.folders, folder],
        },
        userId,
      );
      if (userId) schedulePush(userId);
      return folder;
    },
    [persistVisibleLibrary, schedulePush],
  );

  const updateReaderSettings = useCallback((patch: Partial<ReaderSettings>) => {
    const next = normalizeReaderSettings({
      ...readerSettingsRef.current,
      ...patch,
    });
    readerSettingsRef.current = next;
    setReaderSettings(next);
    const saved = saveReaderSettings(
      principalFromUserId(userRef.current?.id),
      next,
    );
    if (!saved.ok) {
      setPersistenceIssue({
        message: `Reader settings changed for this tab but were not saved: ${saved.error}`,
      });
    }
  }, []);

  const syncNow = useCallback(async () => {
    const token = principalGuard.current.current();
    if (!token.userId) return;
    cancelScheduledPush();
    await synchronizePrincipal(token);
  }, [cancelScheduledPush, synchronizePrincipal]);

  const importGuestLibrary = useCallback(async () => {
    const token = principalGuard.current.current();
    const userId = token.userId;
    const pending = guestImportPending;
    if (!userId || !pending) return;
    const client = getSupabaseBrowserClient();
    if (!client) {
      setAuthError(AUTH_COPY.cloudUnavailableSignInHint);
      return;
    }

    await syncLane.current.enqueue(async () => {
      if (!principalGuard.current.isCurrent(token)) return;
      setSyncing(true);
      setSyncError(null);
      const succeeded: string[] = [];
      try {
        // Folders first for FK safety.
        for (const folder of pending.folders) {
          if (!principalGuard.current.isCurrent(token)) return;
          const result = await upsertRemoteFolder(client, userId, folder);
          if (!result.ok) {
            if (principalGuard.current.isCurrent(token)) {
              setSyncError(result.error);
            }
            return;
          }
        }
        for (const script of pending.scripts) {
          if (!principalGuard.current.isCurrent(token)) return;
          const result = await upsertRemoteScript(client, userId, {
            ...script,
            remoteUpdatedAtWire: null,
            remoteContentFingerprint: null,
          });
          if (!result.ok) {
            if (principalGuard.current.isCurrent(token)) {
              setSyncError(result.error);
            }
            break;
          }
          succeeded.push(script.id);
          // Merge each acknowledgement into this account's latest cache. Never
          // use the visible ref because auth may change while the request awaits.
          const current = loadLibrary(userPrincipal(userId));
          const without = current.scripts.filter(
            (candidate) => candidate.id !== result.data.id,
          );
          const cached = persistLibraryCache(
            {
              scripts: [result.data, ...without],
              folders: mergeRemoteLibrary(current, {
                scripts: [],
                folders: pending.folders,
              }).folders,
            },
            userId,
          );
          applyVisibleLibrary(cached, token);
        }

        if (!principalGuard.current.isCurrent(token)) return;
        const expectedIds = pending.scripts.map((script) => script.id);
        const clearResult = clearGuestLibraryAfterSuccessfulImport(
          succeeded,
          expectedIds,
        );
        if (clearResult.cleared) {
          setGuestImportPending(null);
        } else if (succeeded.length > 0) {
          setSyncError(
            clearResult.reason ??
              "Guest library kept because not every script uploaded successfully.",
          );
          // Keep only remaining guest scripts for retry.
          const remaining = pending.scripts.filter(
            (script) => !succeeded.includes(script.id),
          );
          setGuestImportPending({
            scripts: remaining,
            folders: pending.folders,
          });
        }
        setLastSyncedAt(new Date().toISOString());
      } catch (err) {
        if (principalGuard.current.isCurrent(token)) {
          setSyncError(err instanceof Error ? err.message : "Import failed");
        }
      } finally {
        if (principalGuard.current.isCurrent(token)) {
          setSyncing(false);
        }
      }
    });
  }, [applyVisibleLibrary, guestImportPending, persistLibraryCache]);

  const skipGuestImport = useCallback(() => {
    setGuestImportPending(null);
  }, []);

  const syncStatus = useMemo(
    () =>
      buildSyncStatus({
        cloudConfigured,
        userId: user?.id ?? null,
        syncing,
        error: syncError,
        lastSyncedAt,
        navigatorOnline: online,
      }),
    [cloudConfigured, user?.id, syncing, syncError, lastSyncedAt, online],
  );

  const value = useMemo<AppContextValue>(
    () => ({
      ready,
      cloudConfigured,
      user,
      session,
      library,
      readerSettings,
      syncStatus,
      authError,
      authNotice,
      persistenceIssue,
      authView,
      guestImportPending,
      setAuthView,
      clearAuthError: () => {
        setAuthError(null);
        setAuthNotice(null);
      },
      signInWithApple,
      signInWithEmail,
      sendPasswordReset,
      completePasswordRecovery,
      signOut,
      clearThisBrowser,
      createNewScript,
      updateScript,
      deleteScript,
      duplicateScript,
      getScript,
      touchOpened,
      createNewFolder,
      updateReaderSettings,
      syncNow,
      importGuestLibrary,
      skipGuestImport,
    }),
    [
      ready,
      cloudConfigured,
      user,
      session,
      library,
      readerSettings,
      syncStatus,
      authError,
      authNotice,
      persistenceIssue,
      authView,
      guestImportPending,
      signInWithApple,
      signInWithEmail,
      sendPasswordReset,
      completePasswordRecovery,
      signOut,
      clearThisBrowser,
      createNewScript,
      updateScript,
      deleteScript,
      duplicateScript,
      getScript,
      touchOpened,
      createNewFolder,
      updateReaderSettings,
      syncNow,
      importGuestLibrary,
      skipGuestImport,
    ],
  );

  return <AppContext.Provider value={value}>{children}</AppContext.Provider>;
}

export function useApp(): AppContextValue {
  const ctx = useContext(AppContext);
  if (!ctx) {
    throw new Error("useApp must be used within AppProvider");
  }
  return ctx;
}
