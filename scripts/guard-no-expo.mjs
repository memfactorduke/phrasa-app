#!/usr/bin/env node
/**
 * Fails if shipping manifests reintroduce Expo / React Native / Metro / EAS,
 * or if removed mobile assets are referenced again.
 *
 * Usage: node scripts/guard-no-expo.mjs
 */
import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const failures = [];

function fail(message) {
  failures.push(message);
}

function readJson(path) {
  return JSON.parse(readFileSync(path, "utf8"));
}

function walkFiles(dir, predicate, out = []) {
  if (!existsSync(dir)) return out;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (entry.name === "node_modules" || entry.name === ".git" || entry.name === ".next") {
      continue;
    }
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      walkFiles(full, predicate, out);
    } else if (predicate(full)) {
      out.push(full);
    }
  }
  return out;
}

// --- 1. Retired tree must not return -----------------------------------------
if (existsSync(join(root, "mobile"))) {
  fail("`mobile/` directory exists. Expo surface is retired; remove it.");
}

for (const banned of [
  "eas.json",
  "app.json",
  "app.config.js",
  "app.config.ts",
  "metro.config.js",
  "metro.config.cjs",
  ".easignore",
]) {
  const path = join(root, banned);
  if (existsSync(path)) {
    fail(`Banned Expo/EAS file present at repo root: ${banned}`);
  }
}

// --- 2. Root package.json must not depend on Expo / RN / Metro / EAS ---------
const packageJsonPath = join(root, "package.json");
if (!existsSync(packageJsonPath)) {
  fail("Missing root package.json");
} else {
  const pkg = readJson(packageJsonPath);
  const bannedName = /^(expo|react-native|metro|@expo\/|@react-native|eas-cli|expo-)/i;
  const sections = ["dependencies", "devDependencies", "optionalDependencies", "peerDependencies"];
  for (const section of sections) {
    const deps = pkg[section] ?? {};
    for (const name of Object.keys(deps)) {
      if (bannedName.test(name) || name === "react-native" || name.startsWith("react-native-")) {
        fail(`Root package.json ${section} includes banned dependency: ${name}`);
      }
    }
  }
  const scripts = pkg.scripts ?? {};
  for (const [name, command] of Object.entries(scripts)) {
    // Allow this repo's anti-regression script name/command.
    if (name === "guard:no-expo" || String(command).includes("guard-no-expo")) {
      continue;
    }
    if (/\b(npx\s+expo|expo\s+start|expo-doctor|eas\s+build|react-native|metro)\b/i.test(String(command))) {
      fail(`Root package.json script "${name}" references Expo/EAS/RN/Metro: ${command}`);
    }
  }
}

// --- 3. Native project must not point at removed mobile assets ---------------
const projectYmlPath = join(root, "ios-native", "project.yml");
if (existsSync(projectYmlPath)) {
  const yml = readFileSync(projectYmlPath, "utf8");
  if (yml.includes("mobile/") || yml.includes("../mobile")) {
    fail("ios-native/project.yml still references mobile/ paths.");
  }
  if (!yml.includes("AtkinsonHyperlegible-Regular.ttf")) {
    fail("ios-native/project.yml must bundle AtkinsonHyperlegible-Regular.ttf.");
  }
  if (!yml.includes("Phrasa/Resources/Fonts/AtkinsonHyperlegible-Regular.ttf")) {
    fail(
      "Atkinson font must live under ios-native/Phrasa/Resources/Fonts/ (canonical path)."
    );
  }
} else {
  fail("Missing ios-native/project.yml");
}

const fontPath = join(
  root,
  "ios-native",
  "Phrasa",
  "Resources",
  "Fonts",
  "AtkinsonHyperlegible-Regular.ttf"
);
if (!existsSync(fontPath)) {
  fail("Missing canonical font: ios-native/Phrasa/Resources/Fonts/AtkinsonHyperlegible-Regular.ttf");
}

// --- 4. CI must not run Expo jobs --------------------------------------------
const ciPath = join(root, ".github", "workflows", "ci.yml");
if (existsSync(ciPath)) {
  const ci = readFileSync(ciPath, "utf8");
  if (/\bexpo-doctor\b|\beas build\b|working-directory:\s*mobile\b|Mobile \(Expo\)/i.test(ci)) {
    fail(".github/workflows/ci.yml still references Expo/EAS/mobile lane.");
  }
}

// --- 5. Scan shipping-ish config for reintroduction --------------------------
const scanRoots = [
  join(root, "package.json"),
  join(root, "package-lock.json"),
  join(root, "ios-native", "project.yml"),
  join(root, ".github"),
];
const bannedPatterns = [
  { re: /"expo"\s*:/, label: 'dependency key "expo"' },
  { re: /"react-native"\s*:/, label: 'dependency key "react-native"' },
  { re: /"eas-cli"\s*:/, label: 'dependency key "eas-cli"' },
  { re: /from ['"]expo['"]/, label: "import from expo" },
  { re: /from ['"]react-native['"]/, label: "import from react-native" },
];

function shouldScan(file) {
  return /\.(json|yml|yaml|mjs|js|ts|tsx|md)$/.test(file);
}

for (const start of scanRoots) {
  if (!existsSync(start)) continue;
  const files = statSync(start).isDirectory()
    ? walkFiles(start, shouldScan)
    : [start];
  for (const file of files) {
    // Allow this guard script and intentional docs about retirement history.
    const rel = relative(root, file);
    if (rel === "scripts/guard-no-expo.mjs") continue;
    if (rel === "tests/unit/no-expo-surface.test.ts") continue;
    if (rel.endsWith("CHANGELOG.md")) continue;
    // LegacyExpoMigrator is intentional one-time upgrade code.
    if (rel.includes("LegacyExpoMigrator")) continue;
    const text = readFileSync(file, "utf8");
    // package-lock is large; only check for top-level banned packages via JSON.
    if (rel === "package-lock.json") {
      const lock = readJson(file);
      const packages = lock.packages ?? {};
      for (const key of Object.keys(packages)) {
        if (
          key === "node_modules/expo" ||
          key === "node_modules/react-native" ||
          key.startsWith("node_modules/expo/") ||
          key.startsWith("node_modules/react-native/") ||
          key === "node_modules/eas-cli" ||
          key.startsWith("node_modules/metro")
        ) {
          fail(`package-lock.json reintroduces banned package: ${key}`);
        }
      }
      continue;
    }
    for (const { re, label } of bannedPatterns) {
      if (re.test(text)) {
        fail(`${rel} matches banned pattern (${label}).`);
      }
    }
  }
}

// --- Report ------------------------------------------------------------------
if (failures.length > 0) {
  console.error("Expo retirement guard failed:\n");
  for (const message of failures) {
    console.error(`  - ${message}`);
  }
  process.exit(1);
}

console.log("Expo retirement guard passed: no Expo/RN/EAS shipping surface reintroduced.");
