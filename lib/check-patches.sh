#!/usr/bin/env bash
# check-patches.sh <brain> - verify the two WhatsApp gateway noise patches are
# still present in a running brain's /opt/hermes/gateway/run.py.
#
# WHY: the patches live under /opt/hermes, which is reset from the image on any
# container recreate or rebuild (docker compose up --force-recreate, a new
# image, or re-scaffolding). When that happens WhatsApp silently goes noisy
# again with no error - nothing tells you the edits are gone. This is the
# detector that closes that gap: run it on demand, from whatsapp-link.sh, or as
# the seeded daily cron self-heal.
#
# Exit codes:
#   0 - both patches present (or --heal succeeded in re-applying them)
#   1 - a patch is missing (and --heal was not passed / could not fix it)
#   2 - usage / container not running / source file missing
#
# Flags:
#   --heal   if a patch is missing, run patch-gateway.sh to re-apply, then exit
#            0 on success. Without it, a missing patch just exits 1 (report-only).
set -euo pipefail

NAME=""
HEAL=0
for arg in "$@"; do
  case "$arg" in
    --heal) HEAL=1 ;;
    -*) echo "unknown flag: $arg" >&2; exit 2 ;;
    *) NAME="$arg" ;;
  esac
done
[[ -z "$NAME" ]] && { echo "usage: ./lib/check-patches.sh <brain-name> [--heal]" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNPY="/opt/hermes/gateway/run.py"

if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "error: container '$NAME' is not running." >&2
  exit 2
fi

if ! docker exec "$NAME" test -f "$RUNPY"; then
  echo "error: [$NAME] $RUNPY not found (gateway source moved?)." >&2
  exit 2
fi

# The two done-markers written by patch-gateway.sh.
P1_DONE='if _gateway_platform_value(platform) not in ("telegram", "whatsapp"):'
P2_DONE='if _gateway_platform_value(event.source.platform) == "whatsapp":'

missing=0
docker exec "$NAME" grep -qF "$P1_DONE" "$RUNPY" || { echo "[$NAME] MISSING: patch1 (whatsapp noise filter)" >&2; missing=1; }
docker exec "$NAME" grep -qF "$P2_DONE" "$RUNPY" || { echo "[$NAME] MISSING: patch2 (busy-ack suppress)" >&2; missing=1; }

if [[ "$missing" -eq 0 ]]; then
  echo "[$NAME] gateway patches present (both)."
  exit 0
fi

if [[ "$HEAL" -eq 1 ]]; then
  echo "[$NAME] patches missing - re-applying via patch-gateway.sh" >&2
  if "$SCRIPT_DIR/patch-gateway.sh" "$NAME"; then
    echo "[$NAME] patches re-applied." >&2
    exit 0
  fi
  echo "[$NAME] re-apply FAILED; run ./lib/patch-gateway.sh $NAME by hand." >&2
  exit 1
fi

echo "[$NAME] patches missing - run: ./lib/patch-gateway.sh $NAME" >&2
exit 1
