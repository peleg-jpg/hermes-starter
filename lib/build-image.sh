#!/usr/bin/env bash
# Build the hermes-wa:local base image from pinned NousResearch source.
# This is the runtime layer. Skills/config/identity are layered on later
# by new-brain.sh, so this image is generic and shared by every brain.
#
# Heavy: ~3.7 GB image, compiles web + ui-tui, runs uv sync. Give it a few
# GB of RAM and several minutes. The messaging/whatsapp/anthropic/bedrock
# extras are baked by the upstream Dockerfile (no build args needed).
#
# Fast path instead of building: on a box that already has the image, run
#   docker save hermes-wa:local | gzip > hermes-wa.tgz
# copy it over, then `gunzip -c hermes-wa.tgz | docker load`, and skip this.
set -euo pipefail

HERMES_SHA="${HERMES_SHA:-4e6d05c6a51e4461af0d0d51e79e3c6afe3f7b9a}"
HERMES_REPO="${HERMES_REPO:-https://github.com/NousResearch/hermes-agent.git}"
SRC="${HERMES_SRC:-$HOME/.hermes/hermes-agent}"
IMAGE="${IMAGE:-hermes-wa:local}"

if docker image inspect "$IMAGE" >/dev/null 2>&1 && [ "${FORCE_BUILD:-0}" != "1" ]; then
  echo "==> $IMAGE already present; skipping build (FORCE_BUILD=1 to rebuild)."
  exit 0
fi

echo "==> fetching hermes-agent source @ ${HERMES_SHA:0:9}"
if [ ! -d "$SRC/.git" ]; then
  git clone --filter=blob:none "$HERMES_REPO" "$SRC"
fi
git -C "$SRC" fetch --depth 1 origin "$HERMES_SHA" 2>/dev/null || git -C "$SRC" fetch origin
git -C "$SRC" checkout -q "$HERMES_SHA"

echo "==> docker build -t $IMAGE  (this takes a while)"
docker build -t "$IMAGE" "$SRC"

echo "==> built: $(docker image inspect "$IMAGE" --format '{{.RepoTags}} {{.Size}} bytes')"
