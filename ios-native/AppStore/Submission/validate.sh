#!/usr/bin/env bash
# Phrasa App Store submission packet validator.
# Uses macOS/repo-standard tooling only (bash + python3; optional sips/PIL).
#
# Modes (three-phase, non-circular):
#   packet            — static packet completeness before any App Store work
#   release-ready     — before archive/export/upload (voice, owner, signing)
#   submission-ready  — after Connect saves / build selection, before submit
#   final             — legacy alias for submission-ready
#
# Usage:
#   ./validate.sh                         # same as --mode packet
#   ./validate.sh --mode packet
#   ./validate.sh --mode release-ready
#   ./validate.sh --mode submission-ready
#   ./validate.sh packet|release-ready|submission-ready|final

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODE="packet"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="${2:-}"
      shift 2
      ;;
    packet|release-ready|submission-ready|final)
      MODE="$1"
      shift
      ;;
    -h|--help)
      sed -n '2,18p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      echo "Usage: $0 [--mode packet|release-ready|submission-ready|final]" >&2
      exit 2
      ;;
  esac
done

case "$MODE" in
  packet|release-ready|submission-ready|final) ;;
  *)
    echo "Invalid mode: $MODE (expected packet, release-ready, submission-ready, or final)" >&2
    exit 2
    ;;
esac

exec python3 "$SCRIPT_DIR/validate_packet.py" --mode "$MODE" --root "$SCRIPT_DIR"
