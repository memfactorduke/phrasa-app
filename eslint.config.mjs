import { defineConfig, globalIgnores } from "eslint/config";
import nextVitals from "eslint-config-next/core-web-vitals";
import nextTs from "eslint-config-next/typescript";

const eslintConfig = defineConfig([
  ...nextVitals,
  ...nextTs,
  // Generated / transient dirs only — never weakens lint of app/source files.
  // Playwright creates/removes test-results while e2e runs; concurrent `npm run
  // lint` must not scandir into a disappearing tree (ENOENT race).
  globalIgnores([
    ".next/**",
    "out/**",
    "build/**",
    "next-env.d.ts",
    "ios-native/**",
    ".claude/**",
    "test-results/**",
    "playwright-report/**",
    "blob-report/**",
    "coverage/**",
  ]),
]);

export default eslintConfig;
