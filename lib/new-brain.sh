#!/usr/bin/env bash
# new-brain.sh <name>  - scaffold ONE isolated, fully-featured Hermes brain.
#
# Reuses the hermes-wa:local image (build-image.sh makes it), then layers on:
#   - the seed/ feature bundle (skills, bin tools, scripts, cron, fonts, assets)
#   - config.template.yaml (image-analysis, whisper transcription, MCP, etc.)
#   - a fresh SOUL.md identity for THIS brain (never a copy of another)
#
# Isolation: own folder, own data volume, own container, own .env, own CLI
# wrapper. Each brain gets fresh memory/sessions; only the FEATURES are shared.
set -euo pipefail

NAME="${1:-}"
if [[ -z "$NAME" ]]; then echo "usage: new-brain.sh <name>" >&2; exit 1; fi
if [[ ! "$NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; then
  echo "error: name must be lowercase [a-z0-9-], start with a letter, 2-31 chars. got: '$NAME'" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
HOMELAB="${HOMELAB:-$HOME/homelab}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
DIR="$HOMELAB/$NAME"
WRAPPER="$BIN_DIR/$NAME"
IMAGE="${IMAGE:-hermes-wa:local}"
MEM="${MEM:-2g}"
CPUS="${CPUS:-2.0}"

[[ -e "$DIR" ]]      && { echo "error: $DIR already exists." >&2; exit 1; }
[[ -e "$WRAPPER" ]]  && { echo "error: $WRAPPER already exists (name taken on PATH)." >&2; exit 1; }
docker ps -a --format '{{.Names}}' | grep -qx "$NAME" && { echo "error: container '$NAME' exists. docker rm -f $NAME" >&2; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || { echo "error: image $IMAGE missing. Run lib/build-image.sh first." >&2; exit 1; }

echo "==> [$NAME] creating $DIR/data and seeding features"
mkdir -p "$DIR/data" "$BIN_DIR"
cp -a "$REPO_ROOT/seed/." "$DIR/data/"
cp "$REPO_ROOT/templates/config.template.yaml" "$DIR/data/config.yaml"
sed "s/{{BRAIN_NAME}}/$NAME/g" "$REPO_ROOT/templates/SOUL.template.md" > "$DIR/data/SOUL.md"

echo "==> [$NAME] writing compose + env"
sed -e "s/__NAME__/$NAME/g" -e "s/__MEM__/$MEM/g" -e "s/__CPUS__/$CPUS/g" \
  "$REPO_ROOT/templates/docker-compose.template.yml" > "$DIR/docker-compose.yml"
cp "$REPO_ROOT/templates/env.example" "$DIR/.env"
chmod 600 "$DIR/.env"

echo "==> [$NAME] writing CLI wrapper -> $WRAPPER"
cat > "$WRAPPER" <<EOF
#!/usr/bin/env bash
# CLI for the dockerized Hermes brain "$NAME". Auto-starts the container,
# runs the one-time setup wizard on first launch, then routes the hermes CLI.
set -euo pipefail
CONTAINER=$NAME
COMPOSE_DIR=$DIR
# -it when attached to a real terminal, -i when piped (cron, ssh -T, etc.).
if [ -t 0 ] && [ -t 1 ]; then TTY_FLAGS=-it; else TTY_FLAGS=-i; fi
if ! docker ps --format '{{.Names}}' | grep -qx "\$CONTAINER"; then
  (cd "\$COMPOSE_DIR" && docker compose up -d) >&2
fi
if ! docker exec "\$CONTAINER" test -f /opt/data/.configured; then
  echo "[$NAME] first run: launching 'hermes setup' (provider + key + model)..." >&2
  # Only mark configured if the wizard actually succeeded. A failed/ctrl-C'd
  # wizard must re-prompt next launch, not get silently stamped as done. The
  # 'if' captures the exit code without tripping 'set -e'.
  if docker exec \$TTY_FLAGS "\$CONTAINER" hermes setup; then
    docker exec "\$CONTAINER" touch /opt/data/.configured
  else
    echo "[$NAME] setup did not complete; will re-run the wizard next launch." >&2
    echo "[$NAME] (to force a redo later: rm $DIR/data/.configured)" >&2
  fi
fi
[ \$# -eq 0 ] && set -- chat
exec docker exec \$TTY_FLAGS "\$CONTAINER" hermes "\$@"
EOF
chmod +x "$WRAPPER"

echo "==> [$NAME] starting container"
( cd "$DIR" && docker compose up -d >/dev/null )

# Bind-mounted seed files land owned by the host user; the in-container hermes
# account is uid/gid 1001 (matches HERMES_UID/HERMES_GID in the compose file).
# Without this chown the brain cannot write its own state dir (sessions, memory,
# logs). Classic Hermes uid-mismatch gotcha.
echo "==> [$NAME] fixing /opt/data ownership to the hermes account"
docker exec -u 0 "$NAME" chown -R hermes:hermes /opt/data

# Apply the WhatsApp noise patches to the gateway so a fresh brain ships quiet.
# Non-fatal: if it fails (e.g. gateway source moved), warn and keep going - the
# brain still works, just re-run lib/patch-gateway.sh once it is up.
echo "==> [$NAME] applying WhatsApp gateway noise patches"
if ! "$SCRIPT_DIR/patch-gateway.sh" "$NAME"; then
  echo "warn: [$NAME] patch-gateway.sh failed; re-run './lib/patch-gateway.sh $NAME' later." >&2
fi

cat <<EOF

==========================================
 $NAME ready  (fully featured)
==========================================
 folder:    $DIR
 container: $NAME        ($MEM RAM, $CPUS CPU)
 CLI:       $NAME        (run from anywhere; '$NAME' alone opens chat)
 skills:    $(ls "$DIR/data/skills" | wc -l | tr -d ' ') seeded (finance, media, research, ...)

 next:
  1. edit $DIR/.env          -> add ONE provider key (and APIFY_TOKEN for MCP)
  2. run:  $NAME                  -> first run does the setup wizard, then chat
  3. edit $DIR/data/SOUL.md   -> give this brain its real role + voice
  4. WhatsApp? set WHATSAPP_MODE / WHATSAPP_ALLOWED_USERS in .env, then run
       $NAME whatsapp           -> scan the LIVE QR (see README: Linking WhatsApp)
       NOT via the chat agent - it relays an expired QR. Scan in a real terminal.

 operating notes (full runbook: docs/LESSONS.md):
  - restart with   $NAME gateway restart   (clean reload), NOT 'docker restart'
    (docker restart mid-task can leave the gateway hung).
  - presentations come out as HTML via  bin/make_deck.py  (never PPTX).
  - the gateway noise patches survive 'docker restart' but NOT a recreate/rebuild
    - re-run  ./lib/patch-gateway.sh $NAME  after those, or let the seeded daily
      cron self-heal (it re-applies and logs).

 OFF by default (turn on when you need them):
  - FALLBACK on 429: the brain ships with NO model failover. Add
    OPENROUTER_API_KEY to .env and uncomment fallback_providers in
    data/config.yaml, or the first codex 429 will stall the brain.
    (docs/LESSONS.md, section 10.)
  - PHONE CALLS: copy   data/bin/call.py.template -> data/bin/call.py ,
    fill PHONE_NUMBER_ID / DEFAULT_ASSISTANT, set VAPI_API_KEY in .env, and
    uncomment the call rule in data/SOUL.md. (docs/LESSONS.md, section 7.)
  - redo the setup wizard:  rm $DIR/data/.configured && $NAME
EOF
