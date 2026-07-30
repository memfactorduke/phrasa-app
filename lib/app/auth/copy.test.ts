import { describe, expect, it } from "vitest";
import {
  AUTH_COPY,
  accountModeLabel,
  signInAvailabilityMessage,
} from "./copy";
import { resolveCloudConfig } from "./config";

describe("auth copy contracts", () => {
  it("treats Apple as primary and email as secondary", () => {
    expect(AUTH_COPY.applePrimaryCta).toMatch(/Apple/i);
    expect(AUTH_COPY.emailSecondaryToggle).toMatch(/email/i);
  });

  it("states cloud unavailable clearly when env is missing", () => {
    const config = resolveCloudConfig({});
    expect(config.configured).toBe(false);
    const msg = signInAvailabilityMessage(config);
    expect(msg).toMatch(/Cloud sync is unavailable/i);
    expect(msg).toMatch(/Guest mode/i);
    expect(AUTH_COPY.cloudUnavailableTitle).toMatch(/unavailable/i);
  });

  it("describes sign-in when cloud is configured", () => {
    const config = resolveCloudConfig({
      NEXT_PUBLIC_PHRASA_SUPABASE_URL: "https://example.supabase.co",
      NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY: "publishable-key",
    });
    expect(config.configured).toBe(true);
    expect(signInAvailabilityMessage(config)).toMatch(/Sign in with Apple/i);
    expect(signInAvailabilityMessage(config)).toMatch(/Email and password/i);
  });

  it("states Voice Follow is native-only with no mic pretence", () => {
    expect(AUTH_COPY.voiceFollowNativeOnly).toMatch(/native/i);
    expect(AUTH_COPY.voiceFollowNativeOnly).toMatch(/speed mode only/i);
    expect(AUTH_COPY.noMicControls).toMatch(/does not use the microphone/i);
    expect(AUTH_COPY.noMicControls.toLowerCase()).not.toMatch(/start listening/);
  });

  it("guest import and sign-out copy encode data-safety rules", () => {
    expect(AUTH_COPY.guestImportPrompt).toMatch(/successful upload/i);
    expect(AUTH_COPY.signOutDataSafety).toMatch(/not shown while signed out/i);
  });

  it("account mode label prefers guest when signed out", () => {
    expect(
      accountModeLabel({ cloudConfigured: true, userId: null }),
    ).toMatch(/Guest/i);
    expect(
      accountModeLabel({
        cloudConfigured: true,
        userId: "u1",
        email: "a@example.com",
      }),
    ).toBe("a@example.com");
  });
});

describe("cloud config env names", () => {
  it("requires Phrasa-prefixed URL and publishable key", () => {
    expect(
      resolveCloudConfig({
        NEXT_PUBLIC_SUPABASE_URL: "https://wrong.example",
        NEXT_PUBLIC_SUPABASE_ANON_KEY: "anon",
      }).configured,
    ).toBe(false);
    expect(
      resolveCloudConfig({
        NEXT_PUBLIC_PHRASA_SUPABASE_URL: "https://ok.supabase.co",
        NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY: "pk",
      }).configured,
    ).toBe(true);
  });

  it("rejects privileged Supabase keys before browser client creation", () => {
    const url = "https://ok.supabase.co";
    const resolveKey = (key: string) =>
      resolveCloudConfig({
        NEXT_PUBLIC_PHRASA_SUPABASE_URL: url,
        NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY: key,
      });

    expect(resolveKey("sb_secret_never-public").configured).toBe(false);
    expect(resolveKey("contains-service_role-marker").configured).toBe(false);
    expect(
      resolveKey("e30.eyJyb2xlIjoic2VydmljZV9yb2xlIn0.signature").configured,
    ).toBe(false);
    expect(resolveKey("sb_publishable_safe").configured).toBe(true);
  });
});
