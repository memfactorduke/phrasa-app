// @vitest-environment jsdom

import type { ReactNode } from "react";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const mocks = vi.hoisted(() => ({
  routerReplace: vi.fn(),
  router: { replace: vi.fn() },
  getCloudConfig: vi.fn(),
  getSupabaseBrowserClient: vi.fn(),
  exchangeCodeForSession: vi.fn(),
  getSession: vi.fn(),
}));

vi.mock("next/navigation", () => ({
  useRouter: () => mocks.router,
}));

vi.mock("next/link", () => ({
  default: ({
    children,
    href,
    ...props
  }: {
    children: ReactNode;
    href: string;
  }) => (
    <a href={href} {...props}>
      {children}
    </a>
  ),
}));

vi.mock("@/lib/app/auth/config", () => ({
  getCloudConfig: mocks.getCloudConfig,
}));

vi.mock("@/lib/app/auth/client", () => ({
  getSupabaseBrowserClient: mocks.getSupabaseBrowserClient,
}));

import AuthCallbackPage from "@/app/auth/callback/page";

type Deferred<T> = {
  promise: Promise<T>;
  resolve: (value: T) => void;
};

function deferred<T>(): Deferred<T> {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((done) => {
    resolve = done;
  });
  return { promise, resolve };
}

async function settle(): Promise<void> {
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

describe("mounted auth callback", () => {
  let root: Root | null = null;

  beforeEach(() => {
    (
      globalThis as typeof globalThis & {
        IS_REACT_ACT_ENVIRONMENT: boolean;
      }
    ).IS_REACT_ACT_ENVIRONMENT = true;
    document.body.innerHTML = '<div id="root"></div>';
    window.history.replaceState({}, "", "/auth/callback");
    mocks.routerReplace.mockReset();
    mocks.router.replace = mocks.routerReplace;
    mocks.getCloudConfig.mockReset();
    mocks.getSupabaseBrowserClient.mockReset();
    mocks.exchangeCodeForSession.mockReset();
    mocks.getSession.mockReset();
    mocks.getCloudConfig.mockReturnValue({
      configured: true,
      url: "https://example.supabase.co",
      publishableKey: "sb_publishable_test",
    });
    mocks.getSupabaseBrowserClient.mockReturnValue({
      auth: {
        exchangeCodeForSession: mocks.exchangeCodeForSession,
        getSession: mocks.getSession,
      },
    });
  });

  afterEach(async () => {
    if (root) {
      await act(async () => {
        root?.unmount();
      });
      root = null;
    }
    vi.restoreAllMocks();
  });

  async function renderPage(): Promise<void> {
    const container = document.getElementById("root");
    if (!container) throw new Error("missing test root");
    root = createRoot(container);
    await act(async () => {
      root?.render(<AuthCallbackPage />);
    });
  }

  it("scrubs a recovery code before the exchange completes", async () => {
    const exchange = deferred<{ error: null }>();
    mocks.exchangeCodeForSession.mockReturnValue(exchange.promise);
    window.history.replaceState(
      {},
      "",
      "/auth/callback?recovery=1&code=secret-code&state=secret-state#access_token=secret",
    );

    await renderPage();

    expect(mocks.exchangeCodeForSession).toHaveBeenCalledWith("secret-code");
    expect(window.location.pathname + window.location.search).toBe(
      "/auth/callback?recovery=1",
    );
    expect(window.location.hash).toBe("");
    expect(window.location.href).not.toContain("secret");

    exchange.resolve({ error: null });
    await settle();

    expect(mocks.routerReplace).toHaveBeenCalledWith("/app?recovery=1");
  });

  it("does not reflect a provider error and removes it from browser history", async () => {
    const attackerText = "<img src=x onerror=alert(1)>";
    window.history.replaceState(
      {},
      "",
      `/auth/callback?error=access_denied&error_description=${encodeURIComponent(attackerText)}`,
    );

    await renderPage();
    await settle();

    expect(document.body.textContent).toContain(
      "Sign-in could not be completed.",
    );
    expect(document.body.textContent).not.toContain(attackerText);
    expect(window.location.pathname + window.location.search).toBe(
      "/auth/callback",
    );
    expect(mocks.exchangeCodeForSession).not.toHaveBeenCalled();
  });

  it("scrubs callback secrets even when cloud sync is unavailable", async () => {
    mocks.getCloudConfig.mockReturnValue({
      configured: false,
      url: null,
      publishableKey: null,
    });
    window.history.replaceState(
      {},
      "",
      "/auth/callback?code=must-not-remain&state=also-secret",
    );

    await renderPage();
    await settle();

    expect(window.location.pathname + window.location.search).toBe(
      "/auth/callback",
    );
    expect(window.location.href).not.toContain("must-not-remain");
    expect(mocks.getSupabaseBrowserClient).not.toHaveBeenCalled();
  });
});
