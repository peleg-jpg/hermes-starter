# hermes-starter

Turn a fresh VPS into a working, finance-focused Hermes brain - the standard
Hermes runtime carrying the 55 finance skills only, with its own identity and a
clean memory. One repo, one command.

This is a **feature seed + installer**, not a clone. You get the finance skill
set plus the runtime config (vision, transcription, MCP). No personal data,
soul, or account info is baked in - the brain starts blank and becomes whatever
you name it, with fresh memory.

## What you get

| Feature                     | How it ships                                                                                                                                   |
| --------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- |
| Finance skills (55)         | `seed/skills/finance/` - DCF, LBO, comps, merger model, 3-statement, pitch deck, IC memo, KYC, returns, tax-loss-harvesting, xlsx/pptx authors |
| Image analysis              | `config: agent.image_input_mode=auto` + `auxiliary.vision`                                                                                     |
| Voice-message transcription | `config: stt` (OpenAI whisper-1)                                                                                                               |
| MCP servers                 | `config: mcp_servers` (Apify - web scraping/data via `${APIFY_TOKEN}`)                                                                         |

## The 3 layers

```
runtime    hermes-wa:local        stock NousResearch image, built from pinned source
installer  this repo's scripts    bootstrap VPS + build image + scaffold a brain
seed       seed/ + templates/     the features + config + identity skeleton
```

The runtime is generic and shared by every brain. The seed is what makes a
brain finance-capable. Identity (`SOUL.md`) is per-brain, so two brains built
from this repo are siblings, not copies.

## Install on a fresh VPS

Ubuntu 22.04/24.04, as a normal sudo user (not root):

```bash
git clone https://github.com/peleg-jpg/hermes-starter.git
cd hermes-starter
./install.sh finbrain
```

That runs three steps: bootstrap (swap + Docker + firewall), build the image
(heavy, several minutes, needs a few GB RAM), then scaffold + seed the brain.

If Docker was just installed, your shell is not in the `docker` group yet:

```bash
newgrp docker            # or log out and back in
./install.sh finbrain --skip-bootstrap
```

Then finish setup:

```bash
nano ~/homelab/finbrain/.env          # add ONE provider key (+ APIFY_TOKEN for MCP)
finbrain                              # first run = setup wizard, then chat
nano ~/homelab/finbrain/data/SOUL.md  # give the brain its real role + voice
```

`finbrain` is now a command on PATH. Run it from anywhere; with no args it
opens chat. `finbrain setup`, `finbrain gateway run`, etc. all pass through to
the in-container `hermes` CLI.

## Faster image path (skip the build)

Building `hermes-wa:local` from source is slow. If you have a box that already
has the image, copy it instead:

```bash
# on the box that HAS the image
docker save hermes-wa:local | gzip > hermes-wa.tgz
scp hermes-wa.tgz you@new-vps:~

# on the new VPS
gunzip -c hermes-wa.tgz | docker load
cd hermes-starter && ./install.sh finbrain --skip-bootstrap --skip-build
```

## More brains on the same VPS

```bash
./lib/new-brain.sh research-bot       # another isolated, seeded brain
MEM=4g CPUS=3 ./lib/new-brain.sh big  # custom resource budget
```

Each brain is fully isolated: own folder under `~/homelab/<name>/`, own
container, own `.env`, own data volume, own CLI wrapper. **Never point two
containers at the same `data/` folder** - concurrent writes corrupt the
state and memory DBs.

## Layout

```
install.sh                      orchestrator (bootstrap -> build -> new-brain)
lib/bootstrap-vps.sh            swap + docker + ufw
lib/build-image.sh             clone pinned hermes-agent source, docker build
lib/new-brain.sh               scaffold + seed + start ONE brain
templates/config.template.yaml the brain config (env-driven, no secrets)
templates/docker-compose.template.yml
templates/env.example          provider keys, APIFY_TOKEN, messaging tokens
templates/SOUL.template.md      identity skeleton
examples/SOUL.finance.md        a worked finance identity (reference, no personal data)
seed/                          finance skills + config (vision/stt/MCP), no personal data
VERSION                         pinned image SHA + capture metadata
```

## Auth and secrets

- No secrets are committed. `config.template.yaml` references keys by env var
  (`${APIFY_TOKEN}` etc.); the real values live in each brain's gitignored
  `.env`.
- The default model provider is `openai-codex` (OAuth, set up via the wizard).
  To use a plain API key instead, put it in `.env` and pick the provider in
  `<brain>` first-run wizard, or edit `data/config.yaml`.
- Transcription needs `OPENAI_API_KEY` even if your main model is something
  else (whisper-1 runs on OpenAI).

## Updating the seed

The seed is a snapshot. To refresh it from a live brain later, copy the
portable parts of that brain's `/opt/data` (skills, config, scripts, cron,
bin) over `seed/`, excluding `memories/`, `sessions/`, `state.db*`,
`kanban.db*`, `.env`, `auth.json`, and caches. Re-scan for secrets, commit.
