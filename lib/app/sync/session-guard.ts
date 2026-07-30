import {
  isUntouchedWelcomeScript,
  type LibrarySnapshot,
  type OutlinePoint,
  type ScriptDocument,
} from "@/lib/app/models/script";
import {
  makeLocalConflictCopy,
  scriptHasUnacknowledgedLocalEdit,
  synchronizedContentFingerprint,
} from "./remote-map";

export type PrincipalGenerationToken = Readonly<{
  userId: string | null;
  generation: number;
}>;

/**
 * Invalidates every captured async operation whenever the visible principal
 * changes, including A -> guest -> A transitions where the user id repeats.
 */
export class PrincipalGenerationGuard {
  private userId: string | null;
  private generation = 0;

  constructor(initialUserId: string | null = null) {
    this.userId = initialUserId;
  }

  current(): PrincipalGenerationToken {
    return { userId: this.userId, generation: this.generation };
  }

  transitionTo(userId: string | null): PrincipalGenerationToken {
    this.userId = userId;
    this.generation += 1;
    return this.current();
  }

  isCurrent(token: PrincipalGenerationToken): boolean {
    return (
      token.generation === this.generation && token.userId === this.userId
    );
  }

  runIfCurrent<T>(
    token: PrincipalGenerationToken,
    operation: () => T,
  ): T | undefined {
    return this.isCurrent(token) ? operation() : undefined;
  }
}

/** A failure in one operation never poisons later work in the sync lane. */
export class SerializedSyncLane {
  private tail: Promise<void> = Promise.resolve();

  enqueue<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.tail.then(operation, operation);
    this.tail = result.then(
      () => undefined,
      () => undefined,
    );
    return result;
  }
}

export type ScriptUploadAcknowledgement = Readonly<{
  uploaded: ScriptDocument;
  acknowledged: ScriptDocument;
}>;

function outlineEqual(left: OutlinePoint[], right: OutlinePoint[]): boolean {
  return (
    left.length === right.length &&
    left.every((point, index) => {
      const other = right[index];
      return (
        other !== undefined &&
        point.id === other.id &&
        point.text === other.text &&
        point.note === other.note
      );
    })
  );
}

function stringsEqual(left: string[], right: string[]): boolean {
  return (
    left.length === right.length &&
    left.every((value, index) => value === right[index])
  );
}

/**
 * True only when the current row is still the exact local revision sent to the
 * server. A later edit must keep its content and receive only the new OCC wire.
 */
export function isSameUploadedRevision(
  current: ScriptDocument,
  uploaded: ScriptDocument,
): boolean {
  return (
    current.id === uploaded.id &&
    current.updatedAt === uploaded.updatedAt &&
    current.title === uploaded.title &&
    current.body === uploaded.body &&
    current.source === uploaded.source &&
    current.folderId === uploaded.folderId &&
    stringsEqual(current.tags, uploaded.tags) &&
    outlineEqual(current.outline, uploaded.outline)
  );
}

function laterTimestamp(
  left: string | null,
  right: string | null,
): string | null {
  if (!left) return right;
  if (!right) return left;
  const leftTime = Date.parse(left);
  const rightTime = Date.parse(right);
  if (!Number.isFinite(leftTime)) return right;
  if (!Number.isFinite(rightTime)) return left;
  return leftTime >= rightTime ? left : right;
}

/**
 * Applies server acknowledgements to the latest cache, never to the stale
 * snapshot that began the upload. Rows edited during upload retain all local
 * content and take only the exact new remote wire for the follow-up OCC write.
 * Rows deleted during upload are never resurrected.
 */
export function reconcileUploadAcknowledgements(
  latest: LibrarySnapshot,
  acknowledgements: readonly ScriptUploadAcknowledgement[],
): { library: LibrarySnapshot; needsFollowUpPush: boolean } {
  const byID = new Map(
    acknowledgements.map((entry) => [entry.uploaded.id, entry]),
  );
  let needsFollowUpPush = false;

  const scripts = latest.scripts.map((current) => {
    const entry = byID.get(current.id);
    if (!entry) return current;

    const remoteWire =
      entry.acknowledged.remoteUpdatedAtWire ??
      entry.acknowledged.updatedAt;
    const remoteContentFingerprint =
      entry.acknowledged.remoteContentFingerprint ??
      synchronizedContentFingerprint(entry.acknowledged);
    if (!isSameUploadedRevision(current, entry.uploaded)) {
      needsFollowUpPush = true;
      return {
        ...current,
        remoteUpdatedAtWire: remoteWire,
        remoteContentFingerprint,
      };
    }

    return {
      ...entry.acknowledged,
      remoteContentFingerprint,
      // Opening a script is local metadata in the web companion's content
      // update path. Do not regress a newer local open stamp with an older echo.
      lastOpenedAt: laterTimestamp(
        current.lastOpenedAt,
        entry.acknowledged.lastOpenedAt,
      ),
    };
  });

  return {
    library: { scripts, folders: latest.folders },
    needsFollowUpPush,
  };
}

function scriptContentEqual(
  left: ScriptDocument,
  right: ScriptDocument,
): boolean {
  return (
    left.title === right.title &&
    left.body === right.body &&
    left.source === right.source &&
    left.folderId === right.folderId &&
    stringsEqual(left.tags, right.tags) &&
    outlineEqual(left.outline, right.outline)
  );
}

function timestampValue(value: string): number {
  const parsed = Date.parse(value);
  return Number.isFinite(parsed) ? parsed : Number.NEGATIVE_INFINITY;
}

/**
 * Repairs whole-library localStorage writes from another tab by merging rows
 * instead of accepting a stale full-snapshot overwrite. Explicit delete
 * messages are handled by the provider because absence alone is ambiguous.
 */
export function mergeConcurrentLocalLibraries(
  current: LibrarySnapshot,
  incoming: LibrarySnapshot,
): LibrarySnapshot {
  const scripts = new Map(current.scripts.map((script) => [script.id, script]));
  for (const candidate of incoming.scripts) {
    const existing = scripts.get(candidate.id);
    if (!existing) {
      scripts.set(candidate.id, candidate);
      continue;
    }
    if (scriptContentEqual(existing, candidate)) {
      scripts.set(
        candidate.id,
        timestampValue(candidate.updatedAt) >= timestampValue(existing.updatedAt)
          ? candidate
          : existing,
      );
      continue;
    }

    const existingDirty = scriptHasUnacknowledgedLocalEdit(existing);
    const candidateDirty = scriptHasUnacknowledgedLocalEdit(candidate);
    if (!existingDirty && candidateDirty) {
      scripts.set(candidate.id, candidate);
      continue;
    }
    if (existingDirty && !candidateDirty) {
      continue;
    }

    const candidateWins =
      timestampValue(candidate.updatedAt) > timestampValue(existing.updatedAt);
    const winner = candidateWins ? candidate : existing;
    const loser = candidateWins ? existing : candidate;
    const conflict = makeLocalConflictCopy(loser);
    if (!scripts.has(conflict.id)) scripts.set(conflict.id, conflict);
    scripts.set(winner.id, winner);
  }

  const folders = new Map(current.folders.map((folder) => [folder.id, folder]));
  for (const folder of incoming.folders) {
    if (!folders.has(folder.id)) folders.set(folder.id, folder);
  }

  const sortedScripts = Array.from(scripts.values()).sort((left, right) =>
    right.updatedAt.localeCompare(left.updatedAt),
  );
  let keptWelcome = false;
  const deduplicatedScripts = sortedScripts.filter((script) => {
    if (!isUntouchedWelcomeScript(script)) return true;
    if (keptWelcome) return false;
    keptWelcome = true;
    return true;
  });

  return {
    scripts: deduplicatedScripts,
    folders: Array.from(folders.values()).sort((left, right) =>
      left.name.localeCompare(right.name),
    ),
  };
}

export function librarySnapshotsEqual(
  left: LibrarySnapshot,
  right: LibrarySnapshot,
): boolean {
  return JSON.stringify(left) === JSON.stringify(right);
}
