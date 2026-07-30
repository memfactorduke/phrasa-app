import type { SupabaseClient } from "@supabase/supabase-js";
import type { ScriptDocument, ScriptFolder } from "@/lib/app/models/script";
import {
  FOLDER_SELECT_COLUMNS,
  folderFromRemoteRow,
  folderToInsertPayload,
  SCRIPT_SELECT_COLUMNS,
  scriptFromRemoteRow,
  scriptToContentUpdatePayload,
  scriptToInsertPayload,
  type RemoteFolderRow,
  type RemoteScriptRow,
} from "./remote-map";

export type SyncResult<T> =
  | { ok: true; data: T }
  | { ok: false; error: string; code?: string };

const REMOTE_PAGE_SIZE = 250;
const INCOMPLETE_REMOTE_CODE = "incomplete_remote_snapshot";
type CompletePageResult =
  | { ok: true; expectedTotal: number; complete: boolean }
  | { ok: false; detail: string };

function incompleteRemoteResult<T>(detail: string): SyncResult<T> {
  return {
    ok: false,
    error: `Cloud returned an incomplete library snapshot (${detail}). Local library kept unchanged.`,
    code: INCOMPLETE_REMOTE_CODE,
  };
}

function appendCompletePage<Row extends { id: string }>(
  page: Row[],
  reportedCount: number | null,
  cursor: string | null,
  expectedTotal: number | null,
  accumulated: Row[],
): CompletePageResult {
  if (reportedCount === null || !Number.isSafeInteger(reportedCount)) {
    return { ok: false, detail: "missing exact count" };
  }
  if (reportedCount < 0 || page.length > reportedCount) {
    return { ok: false, detail: "invalid page count" };
  }

  const total = expectedTotal ?? reportedCount;
  if (
    expectedTotal !== null &&
    accumulated.length + reportedCount !== expectedTotal
  ) {
    return { ok: false, detail: "remote total changed during pagination" };
  }

  let previousID = cursor;
  const pageIDs = new Set<string>();
  for (const row of page) {
    const id = row.id.toLowerCase();
    if (
      pageIDs.has(id) ||
      (previousID !== null && id <= previousID.toLowerCase())
    ) {
      return { ok: false, detail: "invalid keyset order" };
    }
    pageIDs.add(id);
    previousID = id;
  }

  if (page.length === 0 && reportedCount > 0) {
    return { ok: false, detail: "empty page with rows remaining" };
  }
  accumulated.push(...page);
  if (accumulated.length > total) {
    return { ok: false, detail: "received more rows than exact count" };
  }
  return {
    ok: true,
    expectedTotal: total,
    complete: accumulated.length === total,
  };
}

export async function fetchRemoteScripts(
  client: SupabaseClient,
  userId: string,
): Promise<SyncResult<ScriptDocument[]>> {
  const rows: RemoteScriptRow[] = [];
  let cursor: string | null = null;
  let expectedTotal: number | null = null;

  while (true) {
    let query = client
      .from("scripts")
      .select(SCRIPT_SELECT_COLUMNS, { count: "exact" })
      .eq("user_id", userId)
      .order("id", { ascending: true })
      .limit(REMOTE_PAGE_SIZE);
    if (cursor) {
      query = query.gt("id", cursor);
    }
    const { data, error, count } = await query;
    if (error) {
      return { ok: false, error: error.message, code: error.code };
    }

    const page = (data ?? []) as RemoteScriptRow[];
    const appended: CompletePageResult = appendCompletePage(
      page,
      count,
      cursor,
      expectedTotal,
      rows,
    );
    if (!appended.ok) {
      return incompleteRemoteResult(appended.detail);
    }
    expectedTotal = appended.expectedTotal;
    if (appended.complete) break;
    cursor = page.at(-1)?.id ?? null;
    if (!cursor) {
      return incompleteRemoteResult("missing continuation cursor");
    }
  }

  if (new Set(rows.map((row) => row.id.toLowerCase())).size !== rows.length) {
    return incompleteRemoteResult("duplicate script ids");
  }
  return {
    ok: true,
    data: rows
      .map(scriptFromRemoteRow)
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt)),
  };
}

export async function fetchRemoteFolders(
  client: SupabaseClient,
  userId: string,
): Promise<SyncResult<ScriptFolder[]>> {
  const rows: RemoteFolderRow[] = [];
  let cursor: string | null = null;
  let expectedTotal: number | null = null;

  while (true) {
    let query = client
      .from("folders")
      .select(FOLDER_SELECT_COLUMNS, { count: "exact" })
      .eq("user_id", userId)
      .order("id", { ascending: true })
      .limit(REMOTE_PAGE_SIZE);
    if (cursor) {
      query = query.gt("id", cursor);
    }
    const { data, error, count } = await query;
    if (error) {
      return { ok: false, error: error.message, code: error.code };
    }

    const page = (data ?? []) as RemoteFolderRow[];
    const appended: CompletePageResult = appendCompletePage(
      page,
      count,
      cursor,
      expectedTotal,
      rows,
    );
    if (!appended.ok) {
      return incompleteRemoteResult(appended.detail);
    }
    expectedTotal = appended.expectedTotal;
    if (appended.complete) break;
    cursor = page.at(-1)?.id ?? null;
    if (!cursor) {
      return incompleteRemoteResult("missing continuation cursor");
    }
  }

  if (new Set(rows.map((row) => row.id.toLowerCase())).size !== rows.length) {
    return incompleteRemoteResult("duplicate folder ids");
  }
  return {
    ok: true,
    data: rows
      .map(folderFromRemoteRow)
      .sort((left, right) => left.name.localeCompare(right.name)),
  };
}

export async function upsertRemoteFolder(
  client: SupabaseClient,
  userId: string,
  folder: ScriptFolder,
): Promise<SyncResult<ScriptFolder>> {
  const payload = folderToInsertPayload(folder, userId);
  const { data, error } = await client
    .from("folders")
    .upsert(payload, { onConflict: "id" })
    .select(FOLDER_SELECT_COLUMNS)
    .single();

  if (error) {
    return { ok: false, error: error.message, code: error.code };
  }
  return { ok: true, data: folderFromRemoteRow(data as RemoteFolderRow) };
}

export async function upsertRemoteScript(
  client: SupabaseClient,
  userId: string,
  script: ScriptDocument,
): Promise<SyncResult<ScriptDocument>> {
  // Prefer insert for brand-new rows; content update for known remote rows.
  if (!script.remoteUpdatedAtWire) {
    const insertPayload = scriptToInsertPayload(script, userId);
    const { data, error } = await client
      .from("scripts")
      .upsert(insertPayload, { onConflict: "id" })
      .select(SCRIPT_SELECT_COLUMNS)
      .single();

    if (error) {
      return { ok: false, error: error.message, code: error.code };
    }
    return { ok: true, data: scriptFromRemoteRow(data as RemoteScriptRow) };
  }

  const content = scriptToContentUpdatePayload(script);
  const { data, error } = await client
    .from("scripts")
    .update(content)
    .eq("id", script.id)
    .eq("user_id", userId)
    .eq("updated_at", script.remoteUpdatedAtWire)
    .select(SCRIPT_SELECT_COLUMNS)
    .maybeSingle();

  if (error) {
    return { ok: false, error: error.message, code: error.code };
  }
  if (!data) {
    // OCC miss or missing row — honest failure, keep local.
    return {
      ok: false,
      error:
        "Could not update remote script (newer remote edit or missing row). Local copy kept.",
      code: "occ_miss",
    };
  }
  return { ok: true, data: scriptFromRemoteRow(data as RemoteScriptRow) };
}

export async function deleteRemoteScript(
  client: SupabaseClient,
  userId: string,
  script: ScriptDocument,
): Promise<SyncResult<true>> {
  let query = client
    .from("scripts")
    .delete()
    .eq("id", script.id)
    .eq("user_id", userId);

  if (script.remoteUpdatedAtWire) {
    query = query.eq("updated_at", script.remoteUpdatedAtWire);
  }

  const { error, data } = await query.select("id");
  if (error) {
    return { ok: false, error: error.message, code: error.code };
  }
  // Idempotent when already gone (empty representation).
  if ((!data || data.length === 0) && script.remoteUpdatedAtWire) {
    // Verify absence vs OCC conflict.
    const check = await client
      .from("scripts")
      .select("id")
      .eq("id", script.id)
      .eq("user_id", userId)
      .maybeSingle();
    if (check.data) {
      return {
        ok: false,
        error: "Remote script changed before delete. Local delete kept; refresh to reconcile.",
        code: "occ_miss",
      };
    }
  }
  return { ok: true, data: true };
}

/**
 * A complete page count can still race a delete+insert with the same total.
 * Point-look up every locally known row missing from the page snapshot before
 * absence is allowed to mean deletion.
 */
export async function verifyRemoteScriptAbsences(
  client: SupabaseClient,
  userId: string,
  candidateIDs: readonly string[],
): Promise<SyncResult<Set<string>>> {
  const verified = new Set<string>();
  for (const id of candidateIDs) {
    const { data, error } = await client
      .from("scripts")
      .select("id")
      .eq("id", id)
      .eq("user_id", userId)
      .maybeSingle();
    if (error) {
      return { ok: false, error: error.message, code: error.code };
    }
    if (data) {
      return incompleteRemoteResult(
        `script ${id} was omitted from the paginated snapshot`,
      );
    }
    verified.add(id);
  }
  return { ok: true, data: verified };
}

export async function pullRemoteLibrary(
  client: SupabaseClient,
  userId: string,
): Promise<
  SyncResult<{ scripts: ScriptDocument[]; folders: ScriptFolder[] }>
> {
  const [scriptsResult, foldersResult] = await Promise.all([
    fetchRemoteScripts(client, userId),
    fetchRemoteFolders(client, userId),
  ]);
  if (!scriptsResult.ok) return scriptsResult;
  if (!foldersResult.ok) return foldersResult;
  return {
    ok: true,
    data: { scripts: scriptsResult.data, folders: foldersResult.data },
  };
}
