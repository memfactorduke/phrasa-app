/**
 * Honest auth / sync copy contracts for UI and tests.
 * Prefer truth about availability over pretend “always connected” messaging.
 */

import type { CloudConfig } from "./config";

export const AUTH_COPY = {
  applePrimaryCta: "Continue with Apple",
  emailSecondaryToggle: "Use email and password instead",
  emailSignIn: "Sign in with email",
  emailPasswordReset: "Send password-reset link",
  signOut: "Sign out",
  guestModeLabel: "Guest · this browser only",
  cloudUnavailableTitle: "Cloud sync unavailable",
  cloudUnavailableBody:
    "Sign-in and cross-device sync need a configured Phrasa cloud project. You can keep using guest mode with local scripts in this browser.",
  cloudUnavailableSignInHint:
    "Cloud sync is unavailable in this environment. Guest mode still works fully offline in this browser.",
  voiceFollowNativeOnly:
    "Voice Follow is native-only on iPhone and iPad. Mac and web are speed mode only today.",
  noMicControls: "This web reader does not use the microphone.",
  guestImportPrompt:
    "Import guest scripts from this browser into your account? They upload only after each save succeeds on the server. Guest copies are cleared only after a successful upload.",
  guestImportConfirm: "Import guest scripts",
  guestImportSkip: "Keep guest scripts local only",
  signOutDataSafety:
    "Signing out returns you to guest mode in this browser. Account library data stays namespaced and is not shown while signed out.",
  syncStatusIdle: "Library in sync",
  syncStatusSyncing: "Syncing…",
  syncStatusError: "Sync paused — local edits stay on this device",
  syncStatusOffline: "Working offline",
  syncStatusGuest: "Guest library · not synced",
  lastSyncedPrefix: "Last synced",
  conflictHonest:
    "Another device may have a newer edit. Local copy kept; resolve by reopening or editing again after a refresh.",
} as const;

export function signInAvailabilityMessage(config: CloudConfig): string {
  if (!config.configured) {
    return AUTH_COPY.cloudUnavailableSignInHint;
  }
  return "Sign in with Apple to sync scripts and folders across devices. Email and password are available for existing accounts, including password reset.";
}

export function accountModeLabel(input: {
  cloudConfigured: boolean;
  userId: string | null;
  email?: string | null;
}): string {
  if (!input.cloudConfigured) {
    return AUTH_COPY.guestModeLabel;
  }
  if (!input.userId) {
    return AUTH_COPY.guestModeLabel;
  }
  if (input.email) {
    return input.email;
  }
  return "Signed in";
}
