const url = process.env.NEXT_PUBLIC_PHRASA_SUPABASE_URL?.trim() ?? "";
const key =
  process.env.NEXT_PUBLIC_PHRASA_SUPABASE_PUBLISHABLE_KEY?.trim() ?? "";

function jwtRole(value) {
  const components = value.split(".");
  if (components.length !== 3) return null;
  try {
    const payload = components[1]
      .replace(/-/g, "+")
      .replace(/_/g, "/")
      .padEnd(Math.ceil(components[1].length / 4) * 4, "=");
    const parsed = JSON.parse(Buffer.from(payload, "base64").toString("utf8"));
    return typeof parsed?.role === "string" ? parsed.role.toLowerCase() : null;
  } catch {
    return null;
  }
}

function isPrivileged(value) {
  const normalized = value.toLowerCase();
  return (
    normalized.startsWith("sb_secret_") ||
    normalized.includes("service_role") ||
    jwtRole(value) === "service_role"
  );
}

if (Boolean(url) !== Boolean(key)) {
  console.error(
    "Phrasa cloud build blocked: set both public Supabase variables or neither.",
  );
  process.exitCode = 1;
} else if (key && isPrivileged(key)) {
  console.error(
    "Phrasa cloud build blocked: a privileged Supabase key cannot be bundled into browser JavaScript.",
  );
  process.exitCode = 1;
}
