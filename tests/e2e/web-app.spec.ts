import { test, expect, type Page } from "@playwright/test";

async function openApp(page: Page) {
  await page.goto("/app");
  await expect(page.getByRole("heading", { name: "Library" })).toBeVisible();
  await expect(page.getByTestId("new-script")).toBeVisible();
}

test.describe("web companion guest flows", () => {
  test.use({
    viewport: { width: 1280, height: 800 },
  });

  test("guest create, edit, present with countdown and settings", async ({
    page,
  }) => {
    await openApp(page);

    // Cloud should be unavailable in e2e (env cleared).
    await expect(
      page.getByText(/Cloud sync unavailable|Guest · this browser only|cloud sync unavailable/i).first(),
    ).toBeVisible();

    await page.getByTestId("new-script").click();
    await expect(page.getByTestId("script-title")).toBeVisible();

    await page.getByTestId("script-title").fill("E2E Keynote");
    await page
      .getByTestId("script-body")
      .fill(
        [
          "Welcome to the web companion.",
          "",
          "This script exercises create, edit, and the speed reader.",
          "Space plays and pauses. Countdown defaults to five seconds.",
          "Voice Follow stays native-only — no microphone controls here.",
        ].join("\n"),
      );

    await page.getByTestId("open-reader").click();
    await expect(page.getByTestId("reader-root")).toBeVisible();
    await expect(page.getByTestId("reader-text")).toContainText(
      "Welcome to the web companion",
    );

    // No fake mic controls
    await expect(page.getByText(/start listening|microphone on/i)).toHaveCount(
      0,
    );

    await page.getByTestId("reader-settings-toggle").click();
    await expect(page.getByTestId("reader-settings")).toBeVisible();
    await expect(page.getByTestId("countdown-select")).toHaveValue("5");

    await page.getByTestId("countdown-select").selectOption("5");
    await page.getByTestId("wpm-range").fill("120");
    await page.getByTestId("font-size-range").fill("36");

    // A vertical mirror must flip the reading guide as well as the words.
    await page.getByTestId("focus-range").fill("30");
    await expect(page.getByTestId("reader-focus-line")).toHaveCSS("top", "240px");
    await page.getByTestId("mirror-v").check();
    await expect(page.getByTestId("reader-focus-line")).toHaveCSS("top", "560px");

    await expect(
      page.getByText(/does not use the microphone/i).first(),
    ).toBeVisible();
    await expect(page.getByText(/native-only/i).first()).toBeVisible();

    // Close settings chrome noise, start with countdown
    await page.getByTestId("reader-settings-toggle").click();
    await page.getByTestId("reader-play").click();
    await expect(page.getByTestId("countdown-overlay")).toBeVisible();
    await expect(page.getByTestId("countdown-overlay")).toContainText(/[1-5]/);

    // Cancel countdown and verify pause path
    await page.getByTestId("reader-play").click();
    await expect(page.getByTestId("countdown-overlay")).toHaveCount(0);

    // Countdown off then play without overlay
    await page.getByTestId("reader-settings-toggle").click();
    await page.getByTestId("countdown-select").selectOption("0");
    await page.getByTestId("reader-settings-toggle").click();
    await page.getByTestId("reader-play").click();
    await expect(page.getByTestId("countdown-overlay")).toHaveCount(0);
    await expect(page.getByTestId("reader-play")).toHaveText(/Pause/i);

    // Library still has the script after navigation
    await page.getByRole("link", { name: "Library" }).first().click();
    await expect(page.getByText("E2E Keynote")).toBeVisible();
  });

  test("responsive layout works at mobile width", async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await openApp(page);
    await expect(page.getByTestId("new-script")).toBeVisible();
    await page.getByTestId("new-script").click();
    await expect(page.getByTestId("script-body")).toBeVisible();
    await page.getByTestId("script-body").fill("Mobile width body text for reader.");
    await page.waitForTimeout(400);
    await page.getByTestId("open-reader").click();
    await expect(page.getByTestId("reader-root")).toBeVisible();
    await expect(page.getByTestId("reader-text")).toContainText("Mobile width");
    // Controls remain usable (min touch targets via min-h-11)
    const play = page.getByTestId("reader-play");
    const box = await play.boundingBox();
    expect(box).toBeTruthy();
    expect((box?.height ?? 0) >= 44).toBeTruthy();
  });

  test("immediate navigation keeps the final editor keystrokes", async ({
    page,
  }) => {
    await openApp(page);
    await page.getByTestId("new-script").click();
    await page.getByTestId("script-title").fill("No debounce escape");
    await page
      .getByTestId("script-body")
      .fill("The final sentence survives immediate navigation. UNIQUE-TAIL-9381");

    // Deliberately do not wait: this is the regression.
    await page.getByTestId("open-reader").click();
    await expect(page.getByTestId("reader-text")).toContainText(
      "UNIQUE-TAIL-9381",
    );
    await page.getByRole("link", { name: "Edit" }).click();
    await expect(page.getByTestId("script-body")).toHaveValue(
      /UNIQUE-TAIL-9381/,
    );
  });

  test("tablet width keeps library and account panel usable", async ({
    page,
  }) => {
    await page.setViewportSize({ width: 820, height: 1180 });
    await openApp(page);
    await expect(page.getByRole("heading", { name: "Account" })).toBeVisible();
    await expect(
      page.getByText(/Cloud sync unavailable|Guest/i).first(),
    ).toBeVisible();
    await page.getByTestId("library-search").fill("Welcome");
    await expect(page.getByText(/Welcome to Phrasa|Welcome/i).first()).toBeVisible();
  });

  test("clearing one tab cannot be undone by a stale second tab", async ({
    context,
    page,
  }) => {
    const peer = await context.newPage();
    await openApp(page);
    await openApp(peer);

    await page.getByTestId("new-script").click();
    await page.getByTestId("script-title").fill("Cross-tab clear sentinel");
    await expect(peer.getByText("Cross-tab clear sentinel")).toBeVisible();

    page.once("dialog", (dialog) => dialog.accept());
    await page.getByRole("button", { name: "Clear this browser" }).click();

    await expect(
      peer.getByText("Cross-tab clear sentinel"),
    ).toHaveCount(0);
    await expect(peer.getByText("Welcome to Phrasa")).toBeVisible();
  });
});
