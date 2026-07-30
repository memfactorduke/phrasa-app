import { describe, expect, it } from "vitest";
import {
  appRoutes,
  appStoreUrl,
  platforms,
  publicRoutes,
  resolveSiteUrl,
  retiredRoutes,
  sourceCodeUrl,
  siteDescription,
  siteName,
} from "./site";

describe("site config", () => {
  it("names the product and describes platforms honestly", () => {
    expect(siteName).toBe("Phrasa");
    expect(siteDescription.toLowerCase()).toMatch(/iphone/);
    expect(siteDescription.toLowerCase()).toMatch(/ipad/);
    expect(siteDescription.toLowerCase()).toMatch(/mac/);
    expect(siteDescription.toLowerCase()).toMatch(/voice follow is native-only|native-only/);
    expect(siteDescription.toLowerCase()).toMatch(/open-source/);
    expect([...platforms]).toEqual([
      "iPhone",
      "iPad",
      "Web",
      "Mac prerelease",
    ]);
  });

  it("publishes the canonical open-source repository", () => {
    expect(sourceCodeUrl).toBe(
      "https://github.com/memfactorduke/phrasa-app",
    );
  });

  it("exposes marketing public routes for the sitemap", () => {
    expect([...publicRoutes]).toEqual([
      "/",
      "/privacy",
      "/terms",
      "/support",
    ]);
  });

  it("declares web companion app routes", () => {
    expect(appRoutes).toContain("/app");
    expect(appRoutes).toContain("/auth/callback");
  });

  it("lists retired browser-product routes for invariant tests", () => {
    expect(retiredRoutes).toContain("/library");
    expect(retiredRoutes).toContain("/login");
    expect(retiredRoutes).toContain("/pricing");
    expect(retiredRoutes).toContain("/api/billing");
    expect(retiredRoutes).not.toContain("/auth/callback");
  });

  it("has no public App Store URL until one is committed", () => {
    expect(appStoreUrl).toBeNull();
  });

  it("resolves a site URL without product secrets", () => {
    const url = resolveSiteUrl();
    expect(url).toMatch(/^https?:\/\//);
    expect(url).not.toMatch(/undefined/);
  });
});
