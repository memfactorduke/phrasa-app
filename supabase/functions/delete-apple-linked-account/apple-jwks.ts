export type AppleJwk = JsonWebKey & {
  alg?: string;
  kid?: string;
  use?: string;
};

function decodeBase64Url(value: string): Uint8Array<ArrayBuffer> | null {
  try {
    const normalized = value.replace(/-/g, "+").replace(/_/g, "/");
    const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
    const decoded = atob(padded);
    const bytes = new Uint8Array(decoded.length);
    for (let index = 0; index < decoded.length; index += 1) {
      bytes[index] = decoded.charCodeAt(index);
    }
    return bytes;
  } catch {
    return null;
  }
}

/**
 * Pure cryptographic gate. `null` means the JWKS did not contain the token's
 * kid, so the caller may refresh a bounded cache once before failing closed.
 */
export async function verifyAppleIdTokenSignatureAgainstKeys(
  idToken: string | null | undefined,
  keys: AppleJwk[],
): Promise<boolean | null> {
  if (!idToken) return false;
  const parts = idToken.trim().split(".");
  if (parts.length !== 3) return false;
  const [encodedHeader, encodedPayload, encodedSignature] = parts;
  if (!encodedHeader || !encodedPayload || !encodedSignature) return false;

  const headerBytes = decodeBase64Url(encodedHeader);
  const signature = decodeBase64Url(encodedSignature);
  if (!headerBytes || !signature) return false;

  let header: { alg?: unknown; kid?: unknown };
  try {
    header = JSON.parse(new TextDecoder().decode(headerBytes)) as {
      alg?: unknown;
      kid?: unknown;
    };
  } catch {
    return false;
  }
  if (header.alg !== "RS256" || typeof header.kid !== "string") return false;

  const jwk = keys.find(
    (candidate) =>
      candidate.kid === header.kid &&
      (!candidate.alg || candidate.alg === "RS256") &&
      (!candidate.use || candidate.use === "sig"),
  );
  if (!jwk) return null;
  try {
    const key = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
      false,
      ["verify"],
    );
    return crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      key,
      signature,
      new TextEncoder().encode(`${encodedHeader}.${encodedPayload}`),
    );
  } catch {
    return false;
  }
}
