#!/usr/bin/env bash
# Installs gstack — the browser-automation + engineering-workflow skill pack this
# project uses (see the "gstack" section in CLAUDE.md). Idempotent: re-running
# updates an existing install. Requires git; installs bun if it's missing.
set -euo pipefail

SKILL_DIR="$HOME/.claude/skills/gstack"

if [ -d "$SKILL_DIR/.git" ]; then
  echo "gstack already present — updating…"
  git -C "$SKILL_DIR" pull --ff-only || true
else
  echo "Cloning gstack…"
  git clone --single-branch --depth 1 \
    https://github.com/garrytan/gstack.git "$SKILL_DIR"
fi

if ! command -v bun >/dev/null 2>&1; then
  echo "Installing bun (required by gstack)…"
  curl -fsSL https://bun.sh/install | bash
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
fi

echo "Running gstack setup…"
( cd "$SKILL_DIR" && ./setup )

echo "✓ gstack installed. Use /browse for web automation (see CLAUDE.md)."
