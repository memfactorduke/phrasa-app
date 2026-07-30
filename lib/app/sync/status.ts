export type SyncPhase =
  | "guest"
  | "cloud_unavailable"
  | "signed_in_idle"
  | "syncing"
  | "error"
  | "offline";

export type SyncStatus = {
  phase: SyncPhase;
  message: string;
  lastSyncedAt: string | null;
  detail?: string | null;
};

export function buildSyncStatus(input: {
  cloudConfigured: boolean;
  userId: string | null;
  syncing: boolean;
  error?: string | null;
  lastSyncedAt?: string | null;
  navigatorOnline?: boolean;
}): SyncStatus {
  const online = input.navigatorOnline ?? true;
  if (!input.cloudConfigured) {
    return {
      phase: "cloud_unavailable",
      message: "Guest library · cloud sync unavailable",
      lastSyncedAt: null,
    };
  }
  if (!input.userId) {
    return {
      phase: "guest",
      message: "Guest library · not synced",
      lastSyncedAt: null,
    };
  }
  if (!online) {
    return {
      phase: "offline",
      message: "Working offline · local edits stay on this device",
      lastSyncedAt: input.lastSyncedAt ?? null,
    };
  }
  if (input.syncing) {
    return {
      phase: "syncing",
      message: "Syncing…",
      lastSyncedAt: input.lastSyncedAt ?? null,
    };
  }
  if (input.error) {
    return {
      phase: "error",
      message: "Sync paused — local edits stay on this device",
      lastSyncedAt: input.lastSyncedAt ?? null,
      detail: input.error,
    };
  }
  return {
    phase: "signed_in_idle",
    message: "Library in sync",
    lastSyncedAt: input.lastSyncedAt ?? null,
  };
}
