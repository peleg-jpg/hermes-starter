#!/usr/bin/env bash
# patch-gateway.sh <brain> - apply the two WhatsApp noise patches to a brain's
# gateway code (/opt/hermes/gateway/run.py), then restart the gateway cleanly.
#
# WHY: the stock gateway only silences its English play-by-play on Telegram. On
# WhatsApp the same heartbeats, the tool-progress lines, and the "Interrupting
# current task" busy-ack still get pushed straight to the chat. The config quiet
# block (display.platforms.whatsapp) handles most of it; these two CODE patches
# close the last gaps:
#   Patch 1 - extend the noise filter that was telegram-only to whatsapp too.
#   Patch 2 - suppress the direct busy-ack send on whatsapp (no "Interrupting
#             current task" pings while a turn is running).
#
# Both patches are IDEMPOTENT (re-running is safe; already-applied = skip) and
# pattern-matched, never line-number based. Each runs inside the container via
# `docker exec -u 0 <brain> python3 -`, does a precise string replace, asserts
# the anchor appears EXACTLY once, then ast.parse()s the file to prove the edit
# left valid Python. Finally we restart the gateway the clean way.
#
# IMPORTANT: these patches live under /opt/hermes. They SURVIVE `docker restart`
# but NOT a container recreate or image rebuild (those reset /opt/hermes from the
# image). Re-run this script after any `docker compose up --force-recreate`, a
# new image, or `new-brain.sh` rebuild.
set -euo pipefail

NAME="${1:-}"
[[ -z "$NAME" ]] && { echo "usage: ./lib/patch-gateway.sh <brain-name>" >&2; exit 1; }

if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  echo "error: container '$NAME' is not running." >&2
  echo "       start it:  cd ~/homelab/$NAME && docker compose up -d" >&2
  exit 1
fi

RUNPY="/opt/hermes/gateway/run.py"

echo "==> [$NAME] patching $RUNPY (WhatsApp noise filters)"

# The heredoc below runs INSIDE the container. RUNPY is interpolated by the host
# shell (it is a fixed constant), everything else is literal Python.
docker exec -u 0 -i "$NAME" python3 - "$RUNPY" <<'PYEOF'
import ast
import sys

path = sys.argv[1]
with open(path, "r", encoding="utf-8") as fh:
    src = original = fh.read()

changed = []
skipped = []


def already(needle):
    return needle in src


def apply(name, anchor, replacement):
    """Replace `anchor` with `replacement`, requiring exactly one occurrence."""
    global src
    count = src.count(anchor)
    assert count == 1, (
        f"{name}: expected the anchor exactly once, found {count}. "
        "Gateway source may have changed; patch aborted, file untouched."
    )
    src = src.replace(anchor, replacement, 1)
    changed.append(name)


# ── Patch 1: extend the noise filter from telegram-only to telegram+whatsapp ──
P1_ANCHOR = 'if _gateway_platform_value(platform) != "telegram":'
P1_DONE = 'if _gateway_platform_value(platform) not in ("telegram", "whatsapp"):'
if already(P1_DONE):
    skipped.append("patch1-noise-filter (already applied)")
else:
    apply("patch1-noise-filter", P1_ANCHOR, P1_DONE)

# ── Patch 2: suppress the busy-ack direct send on whatsapp ────────────────────
# Insert an early-return guard immediately before the reply_anchor assignment
# that precedes the busy-ack _send_with_retry(..., content=message, ...) call.
P2_ANCHOR = "        reply_anchor = self._reply_anchor_for_event(event)"
P2_GUARD = (
    '        if _gateway_platform_value(event.source.platform) == "whatsapp":\n'
    "            return True\n"
)
P2_DONE_MARKER = 'if _gateway_platform_value(event.source.platform) == "whatsapp":\n            return True'
if already(P2_DONE_MARKER):
    skipped.append("patch2-busy-ack-suppress (already applied)")
else:
    # Anchor must be unique so we hit the busy-ack sender, not some other spot.
    apply("patch2-busy-ack-suppress", P2_ANCHOR, P2_GUARD + P2_ANCHOR)

if src != original:
    # Prove the result still parses before we ever write it back.
    ast.parse(src)
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(src)

if changed:
    print("applied: " + ", ".join(changed))
if skipped:
    print("skipped: " + ", ".join(skipped))
if not changed and not skipped:
    print("nothing to do")
PYEOF

echo "==> [$NAME] restarting gateway (clean reload)"
# Clean reload - NOT 'docker restart'. docker restart mid-task can leave the
# gateway hung (no whatsapp-bridge, dead port 3000, frozen log).
docker exec "$NAME" hermes gateway restart || {
  echo "warn: 'hermes gateway restart' returned non-zero; check '$NAME gateway run' logs." >&2
}

cat <<EOF

[$NAME] gateway patches done.
  NOTE: these edits are under /opt/hermes. They survive 'docker restart' but NOT
  a container recreate or image rebuild. Re-run this after:
    - docker compose up --force-recreate
    - a new/rebuilt image
    - lib/new-brain.sh re-scaffolding
EOF
