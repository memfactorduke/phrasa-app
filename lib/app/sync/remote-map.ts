/**
 * Map between local web models and Supabase native-sync baseline rows.
 * Wire shape matches ios-native SupabaseCloudRepository / CloudScriptRow.
 */

import {
  normalizeFolderName,
  normalizeTitle,
  type OutlinePoint,
  type ScriptDocument,
  type ScriptFolder,
  type ScriptSource,
} from "@/lib/app/models/script";
import { estimatedSecondsRounded, wordCount } from "@/lib/app/models/metrics";

export type RemoteOutlinePoint = {
  id?: string;
  text?: string;
  note?: string;
};

export type RemoteScriptRow = {
  id: string;
  folder_id: string | null;
  title: string;
  body: string;
  source_type: string;
  outline: RemoteOutlinePoint[] | null;
  word_count?: number;
  est_seconds?: number;
  tags: string[] | null;
  last_opened_at: string | null;
  created_at: string;
  updated_at: string;
};

export type RemoteFolderRow = {
  id: string;
  name: string;
  created_at: string;
};

export type ScriptInsertPayload = {
  id: string;
  user_id: string;
  folder_id: string | null;
  title: string;
  body: string;
  source_type: ScriptSource;
  outline: Array<{ id: string; text: string; note: string }> | null;
  word_count: number;
  est_seconds: number;
  tags: string[];
  last_opened_at: string | null;
  created_at: string;
  updated_at: string;
};

/** Content-only update payload (omits immutable / trigger-managed timestamps). */
export type ScriptContentUpdatePayload = {
  folder_id: string | null;
  title: string;
  body: string;
  source_type: ScriptSource;
  outline: Array<{ id: string; text: string; note: string }> | null;
  word_count: number;
  est_seconds: number;
  tags: string[];
};

export type FolderInsertPayload = {
  id: string;
  user_id: string;
  name: string;
  created_at: string;
};

export const SCRIPT_SELECT_COLUMNS =
  "id,folder_id,title,body,source_type,outline,word_count,est_seconds,tags,last_opened_at,created_at,updated_at";

export const FOLDER_SELECT_COLUMNS = "id,name,created_at";

function parseSource(value: string): ScriptSource {
  if (value === "upload" || value === "gdrive" || value === "manual") {
    return value;
  }
  return "manual";
}

export function outlineFromRemote(
  outline: RemoteOutlinePoint[] | null | undefined,
): OutlinePoint[] {
  if (!outline || !Array.isArray(outline)) return [];
  return outline
    .map((point) => {
      const text = typeof point.text === "string" ? point.text : "";
      const note = typeof point.note === "string" ? point.note : "";
      if (text.trim().length === 0 && note.trim().length === 0) return null;
      return {
        id:
          typeof point.id === "string" && point.id.length > 0
            ? point.id
            : cryptoRandomId(),
        text,
        note,
      };
    })
    .filter((p): p is OutlinePoint => p !== null);
}

export function outlineToRemote(
  outline: OutlinePoint[],
): Array<{ id: string; text: string; note: string }> | null {
  const points = outline
    .filter(
      (p) =>
        p.text.trim().length > 0 || (p.note ?? "").trim().length > 0,
    )
    .map((p) => ({
      id: p.id,
      text: p.text,
      note: p.note ?? "",
    }));
  return points.length > 0 ? points : null;
}

function cryptoRandomId(): string {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID();
  }
  return `outline-${Math.random().toString(16).slice(2)}`;
}

export function scriptFromRemoteRow(row: RemoteScriptRow): ScriptDocument {
  const script: ScriptDocument = {
    id: row.id,
    title: normalizeTitle(row.title ?? "Untitled script"),
    body: row.body ?? "",
    source: parseSource(row.source_type ?? "manual"),
    folderId: row.folder_id ?? null,
    tags: Array.isArray(row.tags) ? row.tags.filter((t) => typeof t === "string") : [],
    outline: outlineFromRemote(row.outline),
    lastOpenedAt: row.last_opened_at ?? null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    remoteUpdatedAtWire: row.updated_at,
  };
  return {
    ...script,
    remoteContentFingerprint: synchronizedContentFingerprint(script),
  };
}

export function folderFromRemoteRow(row: RemoteFolderRow): ScriptFolder {
  return {
    id: row.id,
    name: normalizeFolderName(row.name ?? "Untitled folder"),
    createdAt: row.created_at,
  };
}

export function scriptToInsertPayload(
  script: ScriptDocument,
  userId: string,
): ScriptInsertPayload {
  return {
    id: script.id,
    user_id: userId,
    folder_id: script.folderId,
    title: normalizeTitle(script.title),
    body: script.body,
    source_type: script.source,
    outline: outlineToRemote(script.outline),
    word_count: wordCount(script.body),
    est_seconds: estimatedSecondsRounded(script.body),
    tags: script.tags,
    last_opened_at: script.lastOpenedAt,
    created_at: script.createdAt,
    updated_at: script.updatedAt,
  };
}

export function scriptToContentUpdatePayload(
  script: ScriptDocument,
): ScriptContentUpdatePayload {
  return {
    folder_id: script.folderId,
    title: normalizeTitle(script.title),
    body: script.body,
    source_type: script.source,
    outline: outlineToRemote(script.outline),
    word_count: wordCount(script.body),
    est_seconds: estimatedSecondsRounded(script.body),
    tags: script.tags,
  };
}

export function folderToInsertPayload(
  folder: ScriptFolder,
  userId: string,
): FolderInsertPayload {
  return {
    id: folder.id,
    user_id: userId,
    name: normalizeFolderName(folder.name),
    created_at: folder.createdAt,
  };
}

function synchronizedContentDiverges(
  a: ScriptDocument,
  b: ScriptDocument,
): boolean {
  if (
    a.body !== b.body ||
    a.title !== b.title ||
    a.source !== b.source ||
    a.folderId !== b.folderId ||
    a.tags.length !== b.tags.length ||
    a.outline.length !== b.outline.length
  ) {
    return true;
  }
  if (a.tags.some((tag, index) => tag !== b.tags[index])) return true;
  return a.outline.some((point, index) => {
    const other = b.outline[index];
    return (
      other === undefined ||
      point.id !== other.id ||
      point.text !== other.text ||
      point.note !== other.note
    );
  });
}

/** Stable representation of every field written by the content update path. */
export function synchronizedContentFingerprint(
  script: ScriptDocument,
): string {
  return JSON.stringify({
    title: normalizeTitle(script.title),
    body: script.body,
    source: script.source,
    folderId: script.folderId,
    tags: script.tags,
    outline: script.outline.map((point) => ({
      id: point.id,
      text: point.text,
      note: point.note ?? "",
    })),
  });
}

export function scriptHasUnacknowledgedLocalEdit(
  local: ScriptDocument,
): boolean {
  if (!local.remoteUpdatedAtWire) return true;
  if (typeof local.remoteContentFingerprint === "string") {
    return (
      synchronizedContentFingerprint(local) !==
      local.remoteContentFingerprint
    );
  }
  // Compatibility for cache rows saved before content fingerprints existed.
  return local.updatedAt !== local.remoteUpdatedAtWire;
}

/**
 * Deterministic unfiled conflict copy for divergent local title/body when the
 * remote row wins by timestamp. Comparable in spirit to native
 * CloudScriptConflictCopy: same local id + title + body always yields the same
 * new id so repeated merges stay idempotent. Unfiled so the copy never depends
 * on a separately reconciled folder row. Remote acknowledgement metadata stays
 * null so ownership/import paths treat it as local-only until an explicit upload.
 */
export function makeLocalConflictCopy(local: ScriptDocument): ScriptDocument {
  const baseTitle = normalizeTitle(local.title);
  return {
    ...local,
    id: deterministicConflictScriptId(local),
    folderId: null,
    title: `${baseTitle} — Local conflict`,
    remoteUpdatedAtWire: null,
    remoteContentFingerprint: null,
  };
}

function deterministicConflictScriptId(local: ScriptDocument): string {
  const seed = [
    "phrasa-script-conflict-v1",
    local.id,
    normalizeTitle(local.title),
    local.body,
    local.source,
    local.folderId ?? "",
    JSON.stringify(local.tags),
    JSON.stringify(
      local.outline.map((point) => ({
        id: point.id,
        text: point.text,
        note: point.note ?? "",
      })),
    ),
  ].join("|");
  const digest = sha256Bytes(seed);
  // UUID v5-style version/variant bits (matches native conflict UUID shaping).
  digest[6] = (digest[6]! & 0x0f) | 0x50;
  digest[8] = (digest[8]! & 0x3f) | 0x80;
  const hex = Array.from(digest, (b) => b.toString(16).padStart(2, "0")).join(
    "",
  );
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

/** Sync SHA-256 (browser + Node) — first 16 bytes used for conflict UUIDs. */
function sha256Bytes(message: string): number[] {
  const K = new Uint32Array([
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1,
    0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
    0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
    0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
    0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
    0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
  ]);
  const rotr = (x: number, n: number) => (x >>> n) | (x << (32 - n));
  const bytes = new TextEncoder().encode(message);
  const bitLen = bytes.length * 8;
  const withPad = new Uint8Array(((bytes.length + 9 + 63) & ~63));
  withPad.set(bytes);
  withPad[bytes.length] = 0x80;
  const view = new DataView(withPad.buffer);
  view.setUint32(withPad.length - 4, bitLen >>> 0, false);
  // high 32 bits of length stay 0 for web companion script sizes
  let h0 = 0x6a09e667;
  let h1 = 0xbb67ae85;
  let h2 = 0x3c6ef372;
  let h3 = 0xa54ff53a;
  let h4 = 0x510e527f;
  let h5 = 0x9b05688c;
  let h6 = 0x1f83d9ab;
  let h7 = 0x5be0cd19;
  const w = new Uint32Array(64);
  for (let i = 0; i < withPad.length; i += 64) {
    for (let j = 0; j < 16; j++) {
      w[j] = view.getUint32(i + j * 4, false);
    }
    for (let j = 16; j < 64; j++) {
      const s0 =
        rotr(w[j - 15]!, 7) ^ rotr(w[j - 15]!, 18) ^ (w[j - 15]! >>> 3);
      const s1 =
        rotr(w[j - 2]!, 17) ^ rotr(w[j - 2]!, 19) ^ (w[j - 2]! >>> 10);
      w[j] = (w[j - 16]! + s0 + w[j - 7]! + s1) >>> 0;
    }
    let a = h0;
    let b = h1;
    let c = h2;
    let d = h3;
    let e = h4;
    let f = h5;
    let g = h6;
    let h = h7;
    for (let j = 0; j < 64; j++) {
      const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
      const ch = (e & f) ^ (~e & g);
      const t1 = (h + S1 + ch + K[j]! + w[j]!) >>> 0;
      const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
      const maj = (a & b) ^ (a & c) ^ (b & c);
      const t2 = (S0 + maj) >>> 0;
      h = g;
      g = f;
      f = e;
      e = (d + t1) >>> 0;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) >>> 0;
    }
    h0 = (h0 + a) >>> 0;
    h1 = (h1 + b) >>> 0;
    h2 = (h2 + c) >>> 0;
    h3 = (h3 + d) >>> 0;
    h4 = (h4 + e) >>> 0;
    h5 = (h5 + f) >>> 0;
    h6 = (h6 + g) >>> 0;
    h7 = (h7 + h) >>> 0;
  }
  const out = new Array<number>(16);
  const words = [h0, h1, h2, h3];
  for (let i = 0; i < 4; i++) {
    const word = words[i]!;
    out[i * 4] = (word >>> 24) & 0xff;
    out[i * 4 + 1] = (word >>> 16) & 0xff;
    out[i * 4 + 2] = (word >>> 8) & 0xff;
    out[i * 4 + 3] = word & 0xff;
  }
  return out;
}

function placeConflictCopy(
  scriptMap: Map<string, ScriptDocument>,
  conflictCopy: ScriptDocument,
): boolean {
  const prior = scriptMap.get(conflictCopy.id);
  if (!prior) {
    scriptMap.set(conflictCopy.id, conflictCopy);
    return true;
  }
  // Idempotent re-merge, or refuse to overwrite a different row at the same
  // deterministic id (ownership / prior local data stays intact).
  return !synchronizedContentDiverges(prior, conflictCopy);
}

/**
 * Merge remote snapshot over local user library.
 * Same id: prefer newer updatedAt; keep remoteUpdatedAtWire from remote when remote wins.
 * Divergent synchronized content when remote wins: keep remote at the shared id and preserve
 * the local edit as a deterministic unfiled “Local conflict” copy (native-comparable).
 * Folders: remote name wins by id (no conflict copies). Reader settings are not synced.
 * Honest policy: never silently discard divergent local synchronized content.
 */
export function mergeRemoteLibrary(
  local: { scripts: ScriptDocument[]; folders: ScriptFolder[] },
  remote: { scripts: ScriptDocument[]; folders: ScriptFolder[] },
  verifiedRemoteAbsenceIDs: ReadonlySet<string> = new Set(),
): { scripts: ScriptDocument[]; folders: ScriptFolder[]; notes: string[] } {
  const notes: string[] = [];
  const scriptMap = new Map<string, ScriptDocument>();
  for (const s of local.scripts) scriptMap.set(s.id, s);
  for (const remoteScript of remote.scripts) {
    const existing = scriptMap.get(remoteScript.id);
    if (!existing) {
      scriptMap.set(remoteScript.id, remoteScript);
      continue;
    }
    const localTime = Date.parse(existing.updatedAt);
    const remoteTime = Date.parse(remoteScript.updatedAt);
    if (Number.isFinite(remoteTime) && remoteTime >= (Number.isFinite(localTime) ? localTime : 0)) {
      if (
        synchronizedContentDiverges(existing, remoteScript) &&
        scriptHasUnacknowledgedLocalEdit(existing)
      ) {
        const conflictCopy = makeLocalConflictCopy(existing);
        const placed = placeConflictCopy(scriptMap, conflictCopy);
        if (placed) {
          notes.push(
            `Kept newer remote “${remoteScript.title}” and saved the local edit as “${conflictCopy.title}”.`,
          );
        } else {
          notes.push(
            `Remote version of “${remoteScript.title}” is newer; could not place a Local conflict copy without overwriting an existing row.`,
          );
        }
      }
      scriptMap.set(remoteScript.id, {
        ...remoteScript,
        remoteUpdatedAtWire: remoteScript.remoteUpdatedAtWire ?? remoteScript.updatedAt,
        remoteContentFingerprint:
          remoteScript.remoteContentFingerprint ??
          synchronizedContentFingerprint(remoteScript),
      });
    } else {
      notes.push(
        `Kept local edit of “${existing.title}”; remote may differ until upload succeeds.`,
      );
    }
  }

  // Respect a confirmed remote deletion only when the local row has not been
  // edited since its last acknowledged remote version. Dirty local edits stay
  // recoverable and can be uploaded deliberately; clean stale cache rows do
  // not silently resurrect a deletion made on another device.
  // Conflict copies use remoteUpdatedAtWire: null so they are never treated as
  // confirmed remote rows and are not removed by remote absence.
  const remoteScriptIds = new Set(remote.scripts.map((script) => script.id));
  for (const localScript of local.scripts) {
    if (!localScript.remoteUpdatedAtWire || remoteScriptIds.has(localScript.id)) {
      continue;
    }
    if (!verifiedRemoteAbsenceIDs.has(localScript.id)) {
      notes.push(
        `Kept “${localScript.title}” because its remote absence was not verified.`,
      );
      continue;
    }
    if (scriptHasUnacknowledgedLocalEdit(localScript)) {
      notes.push(
        `Kept local edit of “${localScript.title}” after its remote copy was deleted.`,
      );
      continue;
    }
    scriptMap.delete(localScript.id);
    notes.push(`Removed “${localScript.title}” because it was deleted remotely.`);
  }

  const folderMap = new Map<string, ScriptFolder>();
  for (const f of local.folders) folderMap.set(f.id, f);
  for (const remoteFolder of remote.folders) {
    folderMap.set(remoteFolder.id, remoteFolder);
  }

  return {
    scripts: Array.from(scriptMap.values()).sort((a, b) =>
      b.updatedAt.localeCompare(a.updatedAt),
    ),
    folders: Array.from(folderMap.values()).sort((a, b) =>
      a.name.localeCompare(b.name),
    ),
    notes,
  };
}
