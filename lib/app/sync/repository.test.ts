import type { SupabaseClient } from "@supabase/supabase-js";
import { describe, expect, it } from "vitest";
import type { RemoteFolderRow, RemoteScriptRow } from "./remote-map";
import { createFolder } from "@/lib/app/models/script";
import {
  deleteRemoteFolder,
  fetchRemoteScripts,
  verifyRemoteFolderAbsences,
  verifyRemoteScriptAbsences,
  writeRemoteFolder,
} from "./repository";

type FakePage = {
  data: RemoteScriptRow[];
  count: number | null;
  error?: { message: string; code?: string } | null;
};

function scriptRow(id: string, updatedAt: string): RemoteScriptRow {
  return {
    id,
    folder_id: null,
    title: `Script ${id}`,
    body: id,
    source_type: "manual",
    outline: null,
    tags: [],
    last_opened_at: null,
    created_at: "2026-07-29T00:00:00.000000Z",
    updated_at: updatedAt,
  };
}

function pagedClient(pages: FakePage[]): {
  client: SupabaseClient;
  cursors: Array<string | null>;
} {
  const cursors: Array<string | null> = [];
  let pageIndex = 0;

  class FakeQuery implements PromiseLike<FakePage> {
    private cursor: string | null = null;

    select(): this {
      return this;
    }

    eq(): this {
      return this;
    }

    order(): this {
      return this;
    }

    limit(): this {
      return this;
    }

    gt(_column: string, cursor: string): this {
      this.cursor = cursor;
      return this;
    }

    then<TResult1 = FakePage, TResult2 = never>(
      onfulfilled?:
        | ((value: FakePage) => TResult1 | PromiseLike<TResult1>)
        | null,
      onrejected?:
        | ((reason: unknown) => TResult2 | PromiseLike<TResult2>)
        | null,
    ): PromiseLike<TResult1 | TResult2> {
      cursors.push(this.cursor);
      const page = pages[pageIndex++];
      if (!page) {
        return Promise.reject(new Error("unexpected page request")).then(
          onfulfilled,
          onrejected,
        );
      }
      return Promise.resolve({
        ...page,
        error: page.error ?? null,
      }).then(onfulfilled, onrejected);
    }
  }

  const client = {
    from() {
      return new FakeQuery();
    },
  } as unknown as SupabaseClient;
  return { client, cursors };
}

describe("complete web remote pagination", () => {
  it("loads every keyset page and preserves the public updated-time ordering", async () => {
    const first = scriptRow(
      "11111111-1111-4111-8111-111111111111",
      "2026-07-29T01:00:00.000001Z",
    );
    const second = scriptRow(
      "22222222-2222-4222-8222-222222222222",
      "2026-07-29T03:00:00.000003Z",
    );
    const third = scriptRow(
      "33333333-3333-4333-8333-333333333333",
      "2026-07-29T02:00:00.000002Z",
    );
    const { client, cursors } = pagedClient([
      { data: [first, second], count: 3 },
      { data: [third], count: 1 },
    ]);

    const result = await fetchRemoteScripts(client, "account-a");

    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(result.data.map((script) => script.id)).toEqual([
        second.id,
        third.id,
        first.id,
      ]);
    }
    expect(cursors).toEqual([null, second.id]);
  });

  it("fails closed when a truncated continuation is empty despite remaining rows", async () => {
    const first = scriptRow(
      "11111111-1111-4111-8111-111111111111",
      "2026-07-29T01:00:00.000001Z",
    );
    const { client } = pagedClient([
      { data: [first], count: 2 },
      { data: [], count: 1 },
    ]);

    const result = await fetchRemoteScripts(client, "account-a");

    expect(result).toMatchObject({
      ok: false,
      code: "incomplete_remote_snapshot",
    });
    if (!result.ok) {
      expect(result.error).toMatch(/local library kept unchanged/i);
    }
  });

  it("fails closed when the exact total changes between pages", async () => {
    const first = scriptRow(
      "11111111-1111-4111-8111-111111111111",
      "2026-07-29T01:00:00.000001Z",
    );
    const second = scriptRow(
      "22222222-2222-4222-8222-222222222222",
      "2026-07-29T02:00:00.000002Z",
    );
    const { client } = pagedClient([
      { data: [first], count: 2 },
      { data: [second], count: 2 },
    ]);

    const result = await fetchRemoteScripts(client, "account-a");

    expect(result).toMatchObject({
      ok: false,
      code: "incomplete_remote_snapshot",
    });
  });
});

describe("remote absence verification", () => {
  function absenceClient(
    responses: Array<{
      data: { id: string } | null;
      error: { message: string; code?: string } | null;
    }>,
  ): SupabaseClient {
    let responseIndex = 0;
    class FakePointQuery implements PromiseLike<(typeof responses)[number]> {
      select(): this {
        return this;
      }

      eq(): this {
        return this;
      }

      maybeSingle(): this {
        return this;
      }

      then<TResult1 = (typeof responses)[number], TResult2 = never>(
        onfulfilled?:
          | ((
              value: (typeof responses)[number],
            ) => TResult1 | PromiseLike<TResult1>)
          | null,
        onrejected?:
          | ((reason: unknown) => TResult2 | PromiseLike<TResult2>)
          | null,
      ): PromiseLike<TResult1 | TResult2> {
        const response = responses[responseIndex++];
        if (!response) {
          return Promise.reject(new Error("unexpected point lookup")).then(
            onfulfilled,
            onrejected,
          );
        }
        return Promise.resolve(response).then(onfulfilled, onrejected);
      }
    }

    return {
      from() {
        return new FakePointQuery();
      },
    } as unknown as SupabaseClient;
  }

  it("fails closed when a supposedly absent row still exists remotely", async () => {
    const result = await verifyRemoteScriptAbsences(
      absenceClient([
        {
          data: { id: "omitted-row" },
          error: null,
        },
      ]),
      "account-a",
      ["omitted-row"],
    );

    expect(result).toMatchObject({
      ok: false,
      code: "incomplete_remote_snapshot",
    });
  });

  it("returns only point-verified absent ids", async () => {
    const result = await verifyRemoteScriptAbsences(
      absenceClient([
        { data: null, error: null },
        { data: null, error: null },
      ]),
      "account-a",
      ["gone-a", "gone-b"],
    );

    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(Array.from(result.data)).toEqual(["gone-a", "gone-b"]);
    }
  });

  it("applies the same point verification to missing folder baselines", async () => {
    const result = await verifyRemoteFolderAbsences(
      absenceClient([
        { data: null, error: null },
        { data: null, error: null },
      ]),
      "account-a",
      ["gone-folder-a", "gone-folder-b"],
    );

    expect(result.ok).toBe(true);
    if (result.ok) {
      expect(Array.from(result.data)).toEqual([
        "gone-folder-a",
        "gone-folder-b",
      ]);
    }
  });
});

describe("folder compare-and-swap writes", () => {
  type Response = {
    data: RemoteFolderRow | RemoteFolderRow[] | null;
    error: { message: string; code?: string } | null;
  };

  function mutationClient(responses: Response[]) {
    const equalityChecks: Array<[string, unknown]> = [];
    const operations: string[] = [];
    let responseIndex = 0;

    class FakeFolderQuery {
      insert(): this {
        operations.push("insert");
        return this;
      }

      update(): this {
        operations.push("update");
        return this;
      }

      delete(): this {
        operations.push("delete");
        return this;
      }

      select(): this {
        operations.push("select");
        return this;
      }

      eq(column: string, value: unknown): this {
        equalityChecks.push([column, value]);
        return this;
      }

      single(): Promise<Response> {
        const response = responses[responseIndex++];
        if (!response) throw new Error("unexpected single query");
        return Promise.resolve(response);
      }

      maybeSingle(): Promise<Response> {
        const response = responses[responseIndex++];
        if (!response) throw new Error("unexpected maybeSingle query");
        return Promise.resolve(response);
      }

      then<TResult1 = Response, TResult2 = never>(
        onfulfilled?:
          | ((value: Response) => TResult1 | PromiseLike<TResult1>)
          | null,
        onrejected?:
          | ((reason: unknown) => TResult2 | PromiseLike<TResult2>)
          | null,
      ): PromiseLike<TResult1 | TResult2> {
        const response = responses[responseIndex++];
        if (!response) {
          return Promise.reject(new Error("unexpected awaited query")).then(
            onfulfilled,
            onrejected,
          );
        }
        return Promise.resolve(response).then(onfulfilled, onrejected);
      }
    }

    return {
      client: {
        from() {
          return new FakeFolderQuery();
        },
      } as unknown as SupabaseClient,
      equalityChecks,
      operations,
    };
  }

  const original = createFolder("Original", {
    id: "folder-a",
    createdAt: "2026-07-30T12:00:00.000Z",
  });
  const renamed = { ...original, name: "Renamed" };

  it("carries the exact acknowledged name and creation time on rename", async () => {
    const { client, equalityChecks, operations } = mutationClient([
      {
        data: {
          id: renamed.id,
          name: renamed.name,
          created_at: renamed.createdAt,
        },
        error: null,
      },
    ]);

    const result = await writeRemoteFolder(
      client,
      "account-a",
      renamed,
      original,
    );

    expect(result).toMatchObject({ ok: true, data: renamed });
    expect(operations).toContain("update");
    expect(equalityChecks).toEqual(
      expect.arrayContaining([
        ["id", original.id],
        ["user_id", "account-a"],
        ["name", original.name],
        ["created_at", original.createdAt],
      ]),
    );
  });

  it("fails closed when a concurrent rename misses the baseline", async () => {
    const cloudChanged = { ...original, name: "Cloud rename" };
    const { client } = mutationClient([
      { data: null, error: null },
      {
        data: {
          id: cloudChanged.id,
          name: cloudChanged.name,
          created_at: cloudChanged.createdAt,
        },
        error: null,
      },
    ]);

    const result = await writeRemoteFolder(
      client,
      "account-a",
      renamed,
      original,
    );

    expect(result).toMatchObject({
      ok: false,
      code: "folder_conflict",
    });
  });

  it("treats an identical concurrent create as idempotent, never as an upsert", async () => {
    const { client, operations } = mutationClient([
      {
        data: null,
        error: { message: "duplicate key", code: "23505" },
      },
      {
        data: {
          id: original.id,
          name: original.name,
          created_at: original.createdAt,
        },
        error: null,
      },
    ]);

    const result = await writeRemoteFolder(
      client,
      "account-a",
      original,
      null,
    );

    expect(result).toMatchObject({ ok: true, data: original });
    expect(operations).toContain("insert");
    expect(operations).not.toContain("upsert");
  });

  it("preserves a changed cloud folder when conditional delete misses", async () => {
    const cloudChanged = { ...original, name: "Cloud rename" };
    const { client, equalityChecks } = mutationClient([
      { data: [], error: null },
      {
        data: {
          id: cloudChanged.id,
          name: cloudChanged.name,
          created_at: cloudChanged.createdAt,
        },
        error: null,
      },
    ]);

    const result = await deleteRemoteFolder(
      client,
      "account-a",
      original,
    );

    expect(result).toMatchObject({
      ok: false,
      code: "folder_conflict",
    });
    expect(equalityChecks).toEqual(
      expect.arrayContaining([
        ["name", original.name],
        ["created_at", original.createdAt],
      ]),
    );
  });
});
