import { test, expect } from "@playwright/test";

test.describe("public Phrasa site", () => {
  test("home tells the product story with store CTA and web companion", async ({
    page,
  }) => {
    await page.goto("/");
    await expect(
      page.getByRole("heading", {
        level: 1,
        name: /Read like you.re not reading/i,
      }),
    ).toBeVisible();
    await expect(page.getByText(/iPhone/i).first()).toBeVisible();
    await expect(page.getByText(/iPad/i).first()).toBeVisible();
    await expect(page.getByText(/Mac/i).first()).toBeVisible();
    await expect(page.getByText("Coming soon on the App Store")).toBeVisible();
    await expect(
      page.getByRole("link", { name: /Open web companion/i }),
    ).toBeVisible();
    await expect(page.getByText(/web companion/i).first()).toBeVisible();
    await expect(
      page.getByText(
        /Recognition stays on device when Apple Speech supports it/i,
      ),
    ).toBeVisible();
    await expect(
      page.getByText(/Apple services may process the audio/i),
    ).toBeVisible();
    await expect(
      page.getByText(
        /Phrasa’s developer-operated servers never receive microphone audio or speech recognition text/i,
      ),
    ).toBeVisible();
    await expect(
      page.getByText(/Voice Follow is native-only/i).first(),
    ).toBeVisible();
    await expect(
      page.getByRole("heading", { name: /Trust the tool you read from/i }),
    ).toBeVisible();
    await expect(
      page.getByRole("link", { name: /Explore Phrasa on GitHub/i }),
    ).toHaveAttribute(
      "href",
      "https://github.com/memfactorduke/phrasa-app",
    );
  });

  test("privacy page loads with local storage, optional sync, and speech truth", async ({
    page,
  }) => {
    await page.goto("/privacy");
    await expect(
      page.getByRole("heading", { level: 1, name: "Privacy Policy" }),
    ).toBeVisible();
    await expect(page.getByText(/microphone/i).first()).toBeVisible();
    await expect(
      page.getByText(/reader settings, resume state, and rehearsal recaps stay on the device/i).first(),
    ).toBeVisible();
    await expect(
      page.getByText(/Scripts, folders, tags, and outlines linked to your account/i).first(),
    ).toBeVisible();
    await expect(
      page.getByText(/Reader settings remain local on each device/i).first(),
    ).toBeVisible();
    await expect(
      page.getByText(/automatically synchronizes scripts, folders, tags, and outlines/i).first(),
    ).toBeVisible();
    await expect(page.getByText(/Sync now/i).first()).toBeVisible();
    await expect(
      page.getByText(/Unsaved drafts are not uploaded/i).first(),
    ).toBeVisible();
    await expect(page.getByText(/user-initiated, not automatic/i)).toHaveCount(0);
    await expect(
      page.getByRole("heading", {
        level: 2,
        name: "Optional account and cross-device sync",
      }),
    ).toBeVisible();
    await expect(page.getByText(/Sign in with Apple/i).first()).toBeVisible();
    await expect(page.getByText(/App Functionality/i).first()).toBeVisible();
    await expect(
      page
        .getByText(/Recognition stays on device when Apple Speech supports it/i)
        .first(),
    ).toBeVisible();
    await expect(
      page
        .getByText(
          /Phrasa’s developer-operated servers and Supabase never receive microphone audio or speech recognition text/i,
        )
        .first(),
    ).toBeVisible();
    await expect(page.getByText(/local-only/i)).toHaveCount(0);
    await expect(page.getByText(/\bcandidate\b/i)).toHaveCount(0);
    await expect(page.locator('a[href^="mailto:"]')).toHaveCount(0);
    await expect(page.getByText(/@/)).toHaveCount(0);
    await expect(
      page.getByRole("link", { name: "Support" }).first(),
    ).toBeVisible();
  });

  test("terms page loads", async ({ page }) => {
    await page.goto("/terms");
    await expect(
      page.getByRole("heading", { level: 1, name: "Terms of Service" }),
    ).toBeVisible();
  });

  test("support page loads with recovery topics", async ({ page }) => {
    await page.goto("/support");
    await expect(
      page.getByRole("heading", { level: 1, name: "Support" }),
    ).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: "Create and import documents" }),
    ).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: "Web companion" }),
    ).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: "Speed mode" }),
    ).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: "Voice following" }),
    ).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: "Optional account and sync" }),
    ).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: "Backup and restore" }),
    ).toBeVisible();
    await expect(
      page.getByRole("heading", { level: 2, name: "Offline use" }),
    ).toBeVisible();
    await expect(
      page.getByText(
        /Library, editing, speed mode, import, export, and backup work offline/i,
      ),
    ).toBeVisible();
    await expect(
      page.getByText(/Sign in with Apple is primary/i).first(),
    ).toBeVisible();
    await expect(
      page.getByText(
        /Voice following works offline only when Apple Speech provides on-device recognition/i,
      ),
    ).toBeVisible();
    await expect(
      page.getByText(/may need an internet connection/i),
    ).toBeVisible();
    await expect(
      page.getByText(/Voice following is available in the native/i),
    ).toBeVisible();
    await expect(
      page.getByRole("heading", {
        level: 2,
        name: "Feedback for beta testers",
      }),
    ).toBeVisible();
    await expect(
      page.getByText(/If you are a TestFlight beta tester/i),
    ).toBeVisible();
    await expect(
      page.getByText(
        /Public App Store users are not expected to use TestFlight/i,
      ),
    ).toBeVisible();
    await expect(page.getByText(/local-only/i)).toHaveCount(0);
    await expect(page.getByText(/\bcandidate\b/i)).toHaveCount(0);
    await expect(
      page.locator('a[href="mailto:support@phrasa.app"]').first(),
    ).toBeVisible();
  });

  test("retired library route is not a product page", async ({ page }) => {
    const res = await page.goto("/library");
    expect(res?.status()).toBe(404);
    await expect(page.getByRole("heading", { name: /not found/i })).toBeVisible();
  });

  test("skip link and footer legal nav exist on home", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("link", { name: /Skip to content/i })).toBeAttached();
    await expect(page.getByRole("navigation", { name: "Primary" })).toBeVisible();
    await expect(page.getByRole("navigation", { name: "Footer" })).toBeVisible();
    await expect(page.getByRole("link", { name: "Privacy" }).first()).toBeVisible();
    await expect(page.getByRole("link", { name: "Terms" }).first()).toBeVisible();
    await expect(page.getByRole("link", { name: "Support" }).first()).toBeVisible();
    await expect(page.getByRole("link", { name: "Web app" }).first()).toBeVisible();
  });
});
