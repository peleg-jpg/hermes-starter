#!/usr/bin/env bash
# install.sh <brain-name> — turn a fresh VPS into a working featured Hermes.
#
#   1. bootstrap the VPS (swap + docker + firewall)   [skip: --skip-bootstrap]
#   2. build the hermes-wa:local image                [skip: --skip-build]
#   3. scaffold + seed a brain called <brain-name>
#
# Run as a normal sudo user. Re-runnable. Examples:
#   ./install.sh finbrain
#   ./install.sh sidebrain --skip-bootstrap          # docker already set up
#   MEM=4g CPUS=3 ./install.sh bigbrain               # bigger budget
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=""
DO_BOOTSTRAP=1
DO_BUILD=1
for a in "$@"; do
  case "$a" in
    --skip-bootstrap) DO_BOOTSTRAP=0 ;;
    --skip-build)     DO_BUILD=0 ;;
    -*)               echo "unknown flag: $a" >&2; exit 1 ;;
    *)                NAME="$a" ;;
  esac
done
if [[ -z "$NAME" ]]; then echo "usage: ./install.sh <brain-name> [--skip-bootstrap] [--skip-build]" >&2; exit 1; fi

if [[ "$DO_BOOTSTRAP" == 1 ]]; then
  bash "$SCRIPT_DIR/lib/bootstrap-vps.sh"
  if ! docker ps >/dev/null 2>&1; then
    echo "Docker group not active in this shell yet. Run 'newgrp docker' (or re-login)," >&2
    echo "then re-run: ./install.sh $NAME --skip-bootstrap" >&2
    exit 1
  fi
fi

[[ "$DO_BUILD" == 1 ]] && bash "$SCRIPT_DIR/lib/build-image.sh"

bash "$SCRIPT_DIR/lib/new-brain.sh" "$NAME"
