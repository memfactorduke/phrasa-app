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
  loadSyncState,
  loadSyncStateResult,
  saveLibrary,
  saveReaderSettings,
  saveSyncState,
} from "@/lib/app/persistence/local-store";
import {
  libraryStorageKey,
  principalFromUserId,
  syncStateStorageKey,
  userPrincipal,
} from "@/lib/app/persistence/keys";
import { PersistenceBlockRegistry } from "@/lib/app/persistence/block-registry";
import {
  mergeRemoteLibrary,
  scriptHasUnacknowledgedLocalEdit,
  synchronizedContentFingerprint,
} from "@/lib/app/sync/remote-map";
import {
  deleteRemoteFolder,
  deleteRemoteScript,
  fetchRemoteScript,
  fetchRemoteFolders,
  pullRemoteLibrary,
  upsertRemoteScript,
  verifyRemoteFolderAbsences,
  verifyRemoteScriptAbsences,
  writeRemoteFolder,
} from "@/lib/app/sync/repository";
import {
  acknowledgeFolderDeletion,
  acknowledgeFolderWrite,
  reconcileFolders,
  removeScriptTombstone,
  removeScriptsCoveredByTombstones,
  resolveScriptTombstone,
  unfileScriptsFromMissingFolders,
  upsertScriptTombstone,
  type WebSyncState,
} from "@/lib/app/sync/durable-state";
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

function loadGuestLibraryForImport(): LibrarySnapshot {
  const principal = principalFromUserId(null);
  const library = loadGuestLibrary();
  return {
    ...library,
    scripts: removeScriptsCoveredByTombstones(
      library.scripts,
      loadSyncState(principal),
    ),
  };
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
  const persistenceBlocks = useRef(new PersistenceBlockRegistry());
  const syncStateRef = useRef<WebSyncState | null>(null);

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
  const durablyPersistLibraryCache = useCallback(
    (next: LibrarySnapshot, userId: string | null | undefined) => {
      const sorted = sortLibrary(next);
      const principal = principalFromUserId(userId);
      const key = libraryStorageKey(principal);
      if (persistenceBlocks.current.isBlocked(key)) {
        setPersistenceIssue((prior) => prior ?? {
          message:
            "This library is visible for recovery but is not being overwritten. Download the recovery copy before starting fresh.",
        });
        return null;
      }
      const saved = saveLibrary(principal, sorted);
      if (!saved.ok && principalGuard.current.current().userId === (userId ?? null)) {
        setPersistenceIssue({
          message: `Your latest changes are visible but were not saved in this browser: ${saved.error}`,
        });
      }
      return saved.ok ? sorted : null;
    },
    [],
  );

  const persistLibraryCache = useCallback(
    (next: LibrarySnapshot, userId: string | null | undefined) =>
      durablyPersistLibraryCache(next, userId) ?? sortLibrary(next),
    [durablyPersistLibraryCache],
  );

  const persistSyncStateCache = useCallback(
    (state: WebSyncState, userId: string | null | undefined): boolean => {
      const principal = principalFromUserId(userId);
      const key = syncStateStorageKey(principal);
      if (persistenceBlocks.current.isBlocked(key)) {
        if (principalGuard.current.current().userId === (userId ?? null)) {
          setPersistenceIssue((prior) => prior ?? {
            message:
              "Cloud recovery metadata is protected from being overwritten. Clear this browser only after downloading the recovery copy.",
          });
        }
        return false;
      }
      const saved = saveSyncState(principal, state);
      if (!saved.ok) {
        persistenceBlocks.current.block(key);
        if (principalGuard.current.current().userId === (userId ?? null)) {
          setPersistenceIssue({
            message:
              `Cloud recovery metadata could not be saved. Destructive sync is paused: ${saved.error}`,
          });
        }
        return false;
      }
      if (principalGuard.current.current().userId === (userId ?? null)) {
        syncStateRef.current = state;
      }
      return true;
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
    const loadedSyncState = loadSyncStateResult(principal);
    let snap = loaded.library;
    let issue: BrowserPersistenceIssue | null = null;
    const key = libraryStorageKey(principal);
    const syncKey = syncStateStorageKey(principal);
    if (loaded.status === "corrupt" || loaded.status === "recovery") {
      persistenceBlocks.current.block(key);
      issue = {
        message:
          "Phrasa found damaged browser library data and did not overwrite it. Download the recovery copy before editing or clearing this browser.",
        recoveryRaw: loaded.raw,
      };
    } else if (loaded.status === "unavailable") {
      persistenceBlocks.current.block(key);
      issue = {
        message: `Browser storage is unavailable. Changes in this tab may not survive a reload: ${loaded.error}`,
      };
    } else {
      persistenceBlocks.current.resolve(key);
    }
    if (
      loadedSyncState.status === "corrupt" ||
      loadedSyncState.status === "recovery"
    ) {
      persistenceBlocks.current.block(syncKey);
      issue ??= {
        message:
          "Phrasa found damaged cloud recovery metadata and paused cloud sync so deleted work cannot reappear or erase a newer copy.",
        recoveryRaw: loadedSyncState.raw,
      };
    } else if (loadedSyncState.status === "unavailable") {
      persistenceBlocks.current.block(syncKey);
      issue ??= {
        message:
          `Cloud recovery metadata is unavailable. Destructive sync is paused: ${loadedSyncState.error}`,
      };
    } else {
      persistenceBlocks.current.resolve(syncKey);
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
      library: sortLibrary({
        ...snap,
        scripts: removeScriptsCoveredByTombstones(
          snap.scripts,
          loadedSyncState.state,
        ),
      }),
      settings: loadReaderSettings(principal),
      syncState: loadedSyncState.state,
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
      syncStateRef.current = loaded.syncState;
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

      const principal = userPrincipal(userId);
      if (
        persistenceBlocks.current.isBlocked(libraryStorageKey(principal)) ||
        persistenceBlocks.current.isBlocked(syncStateStorageKey(principal))
      ) {
        setSyncError(
          "Cloud sync is paused until this browser's protected recovery data is downloaded or cleared.",
        );
        return { needsFollowUpPush: false };
      }

      const startingRevision = cloudMutationRevision.current;
      const acknowledgements: ScriptUploadAcknowledgement[] = [];
      let operationError: string | null = null;
      let syncState = loadSyncState(principal);

      // Destructive intent is consumed only inside this serialized lane. A
      // reload, offline period, or transient failure leaves the tombstone for
      // the next launch/reconnect instead of resurrecting the row.
      for (const tombstone of [...syncState.scriptTombstones]) {
        if (!principalGuard.current.isCurrent(token)) break;
        const remoteScript = await fetchRemoteScript(
          client,
          userId,
          tombstone.scriptId,
        );
        if (!remoteScript.ok) {
          operationError = remoteScript.error;
          break;
        }
        const resolution = resolveScriptTombstone(
          tombstone,
          remoteScript.data,
        );
        if (resolution.action === "acknowledge-absence") {
          const latest = loadLibrary(principal);
          const cached = durablyPersistLibraryCache(
            {
              ...latest,
              scripts: latest.scripts.filter(
                (script) => script.id !== tombstone.scriptId,
              ),
            },
            userId,
          );
          if (!cached) {
            operationError =
              "The cloud deletion is complete, but the browser copy could not be removed safely. Its deletion marker was kept for retry.";
            break;
          }
          const nextState = removeScriptTombstone(
            syncState,
            tombstone.scriptId,
          );
          if (!persistSyncStateCache(nextState, userId)) {
            operationError =
              "A completed script deletion could not be acknowledged locally. Destructive sync is paused.";
            break;
          }
          syncState = nextState;
          crossTabDeletedScriptIDs.current.delete(tombstone.scriptId);
          applyVisibleLibrary(cached, token);
          continue;
        }
        if (resolution.action === "restore") {
          const changedRemote = resolution.changedRemote;
          const latest = loadLibrary(principal);
          const restored = {
            ...latest,
            scripts: [
              changedRemote,
              ...latest.scripts.filter(
                (script) => script.id !== changedRemote.id,
              ),
            ],
          };
          const cached = durablyPersistLibraryCache(restored, userId);
          if (!cached) {
            operationError =
              "The cloud script changed and was preserved, but its restored browser copy could not be saved. The deletion marker was kept for retry.";
            break;
          }
          const nextState = removeScriptTombstone(
            syncState,
            tombstone.scriptId,
          );
          if (!persistSyncStateCache(nextState, userId)) {
            operationError =
              "The cloud script changed, but its stale deletion marker could not be retired. The cloud copy was preserved.";
            break;
          }
          syncState = nextState;
          crossTabDeletedScriptIDs.current.delete(tombstone.scriptId);
          crossTabChannel.current?.postMessage({
            kind: "restore-script",
            userId,
            script: changedRemote,
          } satisfies CrossTabLibraryMessage);
          applyVisibleLibrary(cached, token);
          operationError =
            `“${changedRemote.title}” changed in the cloud after it was deleted here. ` +
            "The newer cloud copy was restored instead of being erased.";
          continue;
        }
        const deleted = await deleteRemoteScript(
          client,
          userId,
          resolution.expectedRemote,
        );
        if (!deleted.ok) {
          operationError = deleted.error;
          break;
        }
        const latest = loadLibrary(principal);
        const cached = durablyPersistLibraryCache(
          {
            ...latest,
            scripts: latest.scripts.filter(
              (script) => script.id !== tombstone.scriptId,
            ),
          },
          userId,
        );
        if (!cached) {
          operationError =
            "The cloud script was deleted, but the browser copy could not be removed safely. Its deletion marker was kept for retry.";
          break;
        }
        const nextState = removeScriptTombstone(
          syncState,
          tombstone.scriptId,
        );
        if (!persistSyncStateCache(nextState, userId)) {
          operationError =
            "The cloud script was deleted, but its local deletion marker could not be acknowledged. Sync is paused.";
          break;
        }
        syncState = nextState;
        crossTabDeletedScriptIDs.current.delete(tombstone.scriptId);
        applyVisibleLibrary(cached, token);
      }

      if (!operationError) {
        const folderSnapshot = loadLibrary(principal);
        const remoteFolders = await fetchRemoteFolders(client, userId);
        if (!remoteFolders.ok) {
          operationError = remoteFolders.error;
        } else {
          const remoteFolderIDs = new Set(
            remoteFolders.data.map((folder) => folder.id),
          );
          const folderAbsenceCandidates = new Set<string>();
          for (const baseline of syncState.folderBaselines) {
            if (!remoteFolderIDs.has(baseline.folderId)) {
              folderAbsenceCandidates.add(baseline.folderId);
            }
          }
          for (const tombstone of syncState.folderTombstones) {
            if (!remoteFolderIDs.has(tombstone.folderId)) {
              folderAbsenceCandidates.add(tombstone.folderId);
            }
          }
          const verifiedFolderAbsences = await verifyRemoteFolderAbsences(
            client,
            userId,
            Array.from(folderAbsenceCandidates),
          );
          if (!verifiedFolderAbsences.ok) {
            operationError = verifiedFolderAbsences.error;
          } else {
            const folderResult = reconcileFolders(
              folderSnapshot.folders,
              remoteFolders.data,
              syncState,
              verifiedFolderAbsences.data,
            );
            if (!folderResult.ok) {
              operationError = folderResult.error;
            } else {
              syncState = folderResult.state;
              const reconciledFolders = new Map(
                folderResult.folders.map((folder) => [folder.id, folder]),
              );
              const completedFolderDeletionIDs: string[] = [];

              for (const deletion of folderResult.remoteDeletes) {
                const result = await deleteRemoteFolder(
                  client,
                  userId,
                  deletion.expectedRemote,
                );
                if (!result.ok) {
                  operationError = result.error;
                  break;
                }
                reconciledFolders.delete(deletion.tombstone.folderId);
                completedFolderDeletionIDs.push(
                  deletion.tombstone.folderId,
                );
              }

              if (!operationError) {
                for (const write of folderResult.writes) {
                  const result = await writeRemoteFolder(
                    client,
                    userId,
                    write.desired,
                    write.expectedRemote,
                  );
                  if (!result.ok) {
                    operationError = result.error;
                    break;
                  }
                  syncState = acknowledgeFolderWrite(syncState, result.data);
                  reconciledFolders.set(result.data.id, result.data);
                  if (!persistSyncStateCache(syncState, userId)) {
                    operationError =
                      "A completed folder write could not be acknowledged locally. Sync is paused.";
                    break;
                  }
                }
              }

              // Keep folders created by this tab while cloud I/O was in
              // flight. They will be handled by the scheduled follow-up pass.
              const latest = loadLibrary(principal);
              const startedFolderIDs = new Set(
                folderSnapshot.folders.map((folder) => folder.id),
              );
              for (const folder of latest.folders) {
                if (!startedFolderIDs.has(folder.id)) {
                  reconciledFolders.set(folder.id, folder);
                }
              }
              const folders = Array.from(reconciledFolders.values());
              const folderCached = durablyPersistLibraryCache(
                {
                  scripts: unfileScriptsFromMissingFolders(
                    removeScriptsCoveredByTombstones(
                      latest.scripts,
                      syncState,
                    ),
                    folders,
                  ),
                  folders,
                },
                userId,
              );
              if (!folderCached) {
                operationError ??=
                  "Folder reconciliation reached the cloud, but the browser library could not be saved. Deletion markers were kept for retry.";
              } else {
                applyVisibleLibrary(folderCached, token);
                for (const folderId of completedFolderDeletionIDs) {
                  syncState = acknowledgeFolderDeletion(syncState, folderId);
                }
              }
              if (
                folderCached &&
                !persistSyncStateCache(syncState, userId)
              ) {
                operationError ??=
                  "Folder reconciliation could not be saved safely. Sync is paused.";
              }
            }
          }
        }
      }

      if (!operationError) {
        const uploadSnapshot = loadLibrary(principal);
        const dirtyScripts = removeScriptsCoveredByTombstones(
          uploadSnapshot.scripts,
          syncState,
        ).filter(
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
      const latest = loadLibrary(principal);
      const reconciled = reconcileUploadAcknowledgements(
        {
          ...latest,
          scripts: removeScriptsCoveredByTombstones(
            latest.scripts,
            syncState,
          ),
        },
        acknowledgements,
      );
      const durableAcknowledgementCache = durablyPersistLibraryCache(
        reconciled.library,
        userId,
      );
      if (!durableAcknowledgementCache && acknowledgements.length > 0) {
        persistenceBlocks.current.block(libraryStorageKey(principal));
        operationError ??=
          "Cloud writes completed, but their safe browser acknowledgements could not be saved. Cloud sync is paused to prevent a duplicate retry.";
      }
      const cached =
        durableAcknowledgementCache ?? sortLibrary(reconciled.library);
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
    [
      applyVisibleLibrary,
      durablyPersistLibraryCache,
      persistSyncStateCache,
    ],
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
        const principal = userPrincipal(userId);
        if (
          persistenceBlocks.current.isBlocked(libraryStorageKey(principal)) ||
          persistenceBlocks.current.isBlocked(syncStateStorageKey(principal))
        ) {
          setSyncError(
            "Cloud sync is paused until this browser's protected recovery data is downloaded or cleared.",
          );
          return;
        }
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
          const syncState = loadSyncState(principal);
          const remoteScripts = removeScriptsCoveredByTombstones(
            remote.data.scripts,
            syncState,
          );
          const loadedLocal = loadLibrary(principal);
          const local = {
            ...loadedLocal,
            scripts: removeScriptsCoveredByTombstones(
              loadedLocal.scripts,
              syncState,
            ),
          };
          const remoteScriptIDs = new Set(
            remoteScripts.map((script) => script.id),
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
          const remoteFolderIDs = new Set(
            remote.data.folders.map((folder) => folder.id),
          );
          const folderAbsenceCandidates = new Set<string>();
          for (const baseline of syncState.folderBaselines) {
            if (!remoteFolderIDs.has(baseline.folderId)) {
              folderAbsenceCandidates.add(baseline.folderId);
            }
          }
          for (const tombstone of syncState.folderTombstones) {
            if (!remoteFolderIDs.has(tombstone.folderId)) {
              folderAbsenceCandidates.add(tombstone.folderId);
            }
          }
          const verifiedFolderAbsences = await verifyRemoteFolderAbsences(
            client,
            userId,
            Array.from(folderAbsenceCandidates),
          );
          if (!verifiedFolderAbsences.ok) {
            if (principalGuard.current.isCurrent(token)) {
              setSyncError(verifiedFolderAbsences.error);
            }
            return;
          }
          const loadedLatest = loadLibrary(principal);
          const latest = {
            ...loadedLatest,
            scripts: removeScriptsCoveredByTombstones(
              loadedLatest.scripts,
              syncState,
            ),
          };
          const folderResult = reconcileFolders(
            latest.folders,
            remote.data.folders,
            syncState,
            verifiedFolderAbsences.data,
          );
          if (!folderResult.ok) {
            if (principalGuard.current.isCurrent(token)) {
              setSyncError(folderResult.error);
            }
            return;
          }
          const merged = mergeRemoteLibrary(
            latest,
            { scripts: remoteScripts, folders: [] },
            verifiedAbsences.data,
          );
          const cached = durablyPersistLibraryCache(
            {
              scripts: unfileScriptsFromMissingFolders(
                merged.scripts,
                folderResult.folders,
              ),
              folders: folderResult.folders,
            },
            userId,
          );
          if (!cached) {
            if (principalGuard.current.isCurrent(token)) {
              setSyncError(
                "The cloud library was read, but the browser copy could not be saved. Existing recovery baselines were kept.",
              );
            }
            return;
          }
          if (!persistSyncStateCache(folderResult.state, userId)) {
            if (principalGuard.current.isCurrent(token)) {
              setSyncError(
                "The cloud library was read, but its recovery baseline could not be saved. Further sync is paused.",
              );
            }
            return;
          }
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
    [
      applyVisibleLibrary,
      durablyPersistLibraryCache,
      persistSyncStateCache,
    ],
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
      const durableState =
        syncStateRef.current ??
        loadSyncState(principalFromUserId(token.userId));
      const filtered = {
        ...incoming,
        scripts: removeScriptsCoveredByTombstones(
          incoming.scripts,
          durableState,
        ).filter(
          (script) =>
            !crossTabDeletedScriptIDs.current.has(script.id),
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
      const libraryKey = libraryStorageKey(principal);
      const syncKey = syncStateStorageKey(principal);
      if (event.key !== libraryKey && event.key !== syncKey) {
        return;
      }
      if (event.key === syncKey) {
        const loadedState = loadSyncStateResult(principal);
        if (
          loadedState.status === "corrupt" ||
          loadedState.status === "recovery"
        ) {
          persistenceBlocks.current.block(syncKey);
          setPersistenceIssue({
            message:
              "Another tab wrote damaged cloud recovery metadata. Cloud sync is paused and the raw data was preserved.",
            recoveryRaw: loadedState.raw,
          });
          return;
        }
        if (loadedState.status === "unavailable") {
          persistenceBlocks.current.block(syncKey);
          setPersistenceIssue({
            message:
              `Cloud recovery metadata could not be read after another-tab update: ${loadedState.error}`,
          });
          return;
        }
        persistenceBlocks.current.resolve(syncKey);
        syncStateRef.current = loadedState.state;
        const filtered = {
          ...libraryRef.current,
          scripts: removeScriptsCoveredByTombstones(
            libraryRef.current.scripts,
            loadedState.state,
          ),
        };
        applyVisibleLibrary(filtered, token);
        return;
      }
      const loaded = loadLibraryResult(principal);
      if (loaded.status === "corrupt" || loaded.status === "recovery") {
        persistenceBlocks.current.block(libraryKey);
        setPersistenceIssue({
          message:
            "Another tab wrote damaged browser library data. Phrasa left the current library visible and preserved the raw data for recovery.",
          recoveryRaw: loaded.raw,
        });
        return;
      }
      if (loaded.status === "unavailable") {
        persistenceBlocks.current.block(libraryKey);
        setPersistenceIssue({
          message: `Browser storage could not be read after another-tab update: ${loaded.error}`,
        });
        return;
      }
      persistenceBlocks.current.resolve(libraryKey);
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
          const clearedPrincipal = principalFromUserId(message.userId);
          persistenceBlocks.current.resolve(
            libraryStorageKey(clearedPrincipal),
          );
          persistenceBlocks.current.resolve(
            syncStateStorageKey(clearedPrincipal),
          );
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
        const guest = guestLibraryForImport(loadGuestLibraryForImport());
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
        const guest = guestLibraryForImport(loadGuestLibraryForImport());
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
    persistenceBlocks.current.resolve(libraryStorageKey(principal));
    persistenceBlocks.current.resolve(syncStateStorageKey(principal));
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
      if (!existing) return;
      const nextScripts = libraryRef.current.scripts.filter((s) => s.id !== id);
      const userId = userRef.current?.id ?? null;
      const principal = principalFromUserId(userId);
      const nextSyncState = upsertScriptTombstone(
        loadSyncState(principal),
        {
          scriptId: id,
          deletedAt: new Date().toISOString(),
          expectedRemoteContentFingerprint:
            existing.remoteContentFingerprint ??
            synchronizedContentFingerprint(existing),
        },
      );
      // Save destructive intent before hiding the row. If the browser cannot
      // durably record it, leave the script visible instead of risking a
      // reload resurrection or unsafe cloud delete.
      if (!persistSyncStateCache(nextSyncState, userId)) return;
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
      if (userId) schedulePush(userId);
    },
    [
      persistSyncStateCache,
      persistVisibleLibrary,
      schedulePush,
    ],
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
        const accountPrincipal = userPrincipal(userId);
        if (
          persistenceBlocks.current.isBlocked(
            libraryStorageKey(accountPrincipal),
          ) ||
          persistenceBlocks.current.isBlocked(
            syncStateStorageKey(accountPrincipal),
          )
        ) {
          setSyncError(
            "Guest import is paused until this account's protected recovery data is downloaded or cleared.",
          );
          return;
        }
        let accountSyncState = loadSyncState(accountPrincipal);
        // Folders first for FK safety.
        for (const folder of pending.folders) {
          if (!principalGuard.current.isCurrent(token)) return;
          const result = await writeRemoteFolder(
            client,
            userId,
            folder,
            null,
          );
          if (!result.ok) {
            if (principalGuard.current.isCurrent(token)) {
              setSyncError(result.error);
            }
            return;
          }
          accountSyncState = acknowledgeFolderWrite(
            accountSyncState,
            result.data,
          );
          if (!persistSyncStateCache(accountSyncState, userId)) {
            setSyncError(
              "The folder imported, but its safe cloud baseline could not be saved. Import is paused.",
            );
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
  }, [
    applyVisibleLibrary,
    guestImportPending,
    persistLibraryCache,
    persistSyncStateCache,
  ]);

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
