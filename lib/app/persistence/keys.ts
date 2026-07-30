/**
 * Namespaced localStorage keys.
 * Guest and each authenticated user id never share a library bucket.
 */

export type StoragePrincipal =
  | { kind: "guest" }
  | { kind: "user"; userId: string };

export const STORAGE_VERSION = "v1";
export const STORAGE_PREFIX = `phrasa.${STORAGE_VERSION}`;

export function principalKeySegment(principal: StoragePrincipal): string {
  if (principal.kind === "guest") return "guest";
  const id = principal.userId.trim().toLowerCase();
  if (!id) throw new Error("user principal requires a non-empty userId");
  return `user.${id}`;
}

export function libraryStorageKey(principal: StoragePrincipal): string {
  return `${STORAGE_PREFIX}.${principalKeySegment(principal)}.library`;
}

export function readerSettingsStorageKey(principal: StoragePrincipal): string {
  return `${STORAGE_PREFIX}.${principalKeySegment(principal)}.readerSettings`;
}

export function guestPrincipal(): StoragePrincipal {
  return { kind: "guest" };
}

export function userPrincipal(userId: string): StoragePrincipal {
  return { kind: "user", userId };
}

export function principalFromUserId(
  userId: string | null | undefined,
): StoragePrincipal {
  if (userId && userId.trim().length > 0) {
    return userPrincipal(userId.trim());
  }
  return guestPrincipal();
}
