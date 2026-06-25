# LESSONS - the hermes-starter reliability runbook

A long real-world deployment ("finbrain") surfaced about a dozen classes of
bugs in a fresh finance-brain deploy. This is the distilled runbook: what bit
us, why, and the exact fix. The repo already bakes most of these in (config
defaults, the gateway patch script, the SOUL rules, the helper scripts) so a
fresh brain ships clean. This doc is the human-readable backstop and the
"why did we do that" reference.

Read this end to end once before your first deploy. After that, jump to the
section that matches your symptom.

---

## 1. Linking WhatsApp (the live QR)

Link WhatsApp by running `<brain> whatsapp` in a REAL terminal (or
`./lib/whatsapp-link.sh <brain>`). That prints a LIVE, auto-refreshing QR.

The QR rotates roughly every 20 seconds. A relayed, screenshotted, or
copy-pasted QR is already expired by the time it reaches WhatsApp, which then
says "couldn't link device." So:

- Scan the QR directly in the terminal while it is live.
- Over SSH, if the terminal QR will not scan, open
  `~/homelab/<brain>/data/whatsapp/session/latest-qr.png`. The bridge rewrites
  that PNG on every refresh, so it is always the current code.
- NEVER ask the chat agent to "print the QR." By the time the model relays it,
  it has rotated. This is the single most common linking failure.

The phone you scan with becomes the AGENT (the number that receives messages
and replies).

## 2. Routing: bot vs self-chat, agent vs sender

Two numbers are involved and they get mixed up constantly:

- The number you SCAN = the AGENT. It receives incoming messages and sends the
  replies.
- `WHATSAPP_ALLOWED_USERS` = the SENDER's number(s), the people allowed to
  message the agent. It is NOT the agent's own number. Putting the agent's own
  number here silently drops every real incoming message.

`WHATSAPP_MODE` picks the shape:

- `bot` (default): a separate number other people text.
- `self-chat`: your own number; the agent only answers your "Note to Self" chat.
  Leaving this on when you meant `bot` silently drops everyone else's messages.

Set `WHATSAPP_MODE` and `WHATSAPP_ALLOWED_USERS` in the brain `.env` BEFORE
linking.

Note: Composio's Vapi toolkit is READ-ONLY (it can list, not place calls). See
section 7 for how calls actually get placed.

## 3. Silence the English noise on WhatsApp

A phone inbox should not get the CLI's English play-by-play (every shell command,
token streaming, "Interrupting current task" pings, system heartbeats). Three
layers kill it. All three ship in this repo; here is what each does so you can
tune or debug it.

(a) Per-platform quiet block - `display.platforms.whatsapp` in `config.yaml`:

```yaml
display:
  platforms:
    whatsapp:
      tool_progress: "off" # no shell-command play-by-play
      streaming: false # no token-by-token edits
      busy_ack_detail: false # no verbose busy notices
      long_running_notifications: false # no "still working" heartbeats
      interim_assistant_messages: true # DO keep the short "on it" line
```

`interim_assistant_messages: true` stays ON so the user still gets a short "on
it" acknowledgement followed by the real answer. Everything else is the noise.

(b) Global config switches:

- `compression.codex_gpt55_autoraise: false` - stops the auto-raise chatter.
- `display.credits_notices: false` and `display.turn_completion_explainer:
false` - drop the credits/turn-completion English asides.
- `display.background_process_notifications: "off"` - no background-task pings.
- `approvals.mode: off` would auto-approve all dangerous commands. This is
  OPT-IN and is NOT shipped on; the repo keeps `approvals.mode: manual`. Only
  flip it to the STRING `"off"` if you understand the security tradeoff (see
  section 11 on why it must be the quoted string).

(c) Two code patches to `/opt/hermes/gateway/run.py`, applied by
`lib/patch-gateway.sh <brain>`:

- Patch 1 extends the noise filter that was telegram-only to whatsapp too
  (`!= "telegram"` becomes `not in ("telegram", "whatsapp")`).
- Patch 2 suppresses the busy-ack direct send on whatsapp (no "Interrupting
  current task" message while a turn runs).

`new-brain.sh` runs the patch script automatically for a fresh brain. The
patches survive `docker restart` but NOT a container recreate or image rebuild
(section 11), so re-run `lib/patch-gateway.sh <brain>` after those.

## 4. Make the brain USE its capabilities (put commands in SOUL.md)

Hermes models do NOT reliably reach for `skills_list` on their own. If a
capability is only discoverable through a tool the model has to think to call,
the model will often just deny it has the capability ("I can't call", "I can't
make a deck").

Fix: any capability the agent MUST use goes DIRECTLY in `SOUL.md` (which loads
fresh every message) with the EXACT command to run. Example lines for a brain
that should make decks and place calls:

```
- Presentations: build them with  bin/make_deck.py --slides <json> --out <file.html>
  You CAN do this. Never say you can't make a deck.
- Phone calls: place them with  bin/call.py --to <number> --say "<line>"
  You CAN call. Never route calls to the VAPI_* Composio tools (read-only).
```

Spell out the command; do not assume the model will discover it.

## 5. Anti-leak and anti-hallucination rules

Two failure modes, both fixed by SOUL rules (the defaults ship in
`templates/SOUL.template.md`):

- Leaking machinery. The model sometimes pastes raw tool output, JSON, schemas,
  or internal blocks (like an `untrusted_tool_result` wrapper) straight into the
  chat. Rule: never paste raw tool output / JSON / internal blocks into a reply;
  summarize the outcome. Note: "don't narrate tools" means do not SHOW the user
  the commands and results - it does NOT mean "don't use the tools." Use them
  freely; just report the outcome, not the play-by-play.

- Hallucinating completion. The model claims a file/call/deck/result is done
  before it actually ran the tool that produces it. Rule: never claim something
  is done until you actually ran the tool and saw the result.

## 6. The deterministic-helper pattern

For any multi-step task the weak fallback model fumbles or fakes, do NOT make
the model free-hand it. Write a deterministic helper script that does the heavy
lifting; the agent only supplies the content/params and runs ONE command. The
script owns correctness; the model owns content.

Shipped examples:

- `bin/make_deck.py` - the agent passes a JSON list of slides; the script owns
  the HTML design and writes the file (section 8).
- `bin/call.py` (from `bin/call.py.template`) - the agent passes `--to` and
  `--say`; the script owns the Vapi REST call, number normalization, and the
  Cloudflare workaround (section 7).

When you hit a new "the model keeps faking step N" task, add a helper rather
than nagging the prompt.

## 7. Placing phone calls (Vapi, direct REST)

Composio's Vapi toolkit has only READ tools (`VAPI_LIST_*`). It cannot create a
call. So place calls via the Vapi REST API directly:

- `POST https://api.vapi.ai/call` with the Vapi PRIVATE key from `.env`
  (`VAPI_API_KEY`).
- Vapi sits behind Cloudflare, which 403s default User-Agents (Cloudflare error
  1010). Send the header `User-Agent: curl/8.5.0` to get through.

Even when the user says "use vapi to call X", route to the helper
(`bin/call.py`), NEVER to the `VAPI_*` Composio tools. Setup: copy
`bin/call.py.template` to `bin/call.py`, fill `PHONE_NUMBER_ID` and
`DEFAULT_ASSISTANT`, set `VAPI_API_KEY` in `.env`. The helper normalizes a local
`0xx` number to `+972xx` (configurable), supports `--voice provider:voiceId`,
`--prompt`, and `--dry-run`.

## 8. Presentations are HTML, never PPTX

Do not build PowerPoint / python-pptx. Build HTML decks with `bin/make_deck.py`.
The agent supplies a JSON list of slides (types: `cover`, `content`, `stat`,
`cards`, `closing`); the script owns the design (dark theme, gold accent, RTL,
scroll-snap, keyboard/scroll nav) and writes the file. It is forgiving of
field-name variations, so `points` / `items` / `bullets` all work, `stat` or
`stat1`/`stat2`, card `text` or a nested `items` list, etc. To get a PDF, open
the HTML and print to PDF (the CSS has a print stylesheet).

```
bin/make_deck.py --slides slides.json --out /opt/data/decks/q3.html --title "Q3 Review"
```

## 9. Contacts via Google Contacts (and the People API gotcha)

Look up contacts through Composio: `GOOGLECONTACTS_LIST_CONNECTIONS` with
`personFields` set to `names,phoneNumbers`.

GOTCHA: the Google People API must be ENABLED in the Google Cloud project tied
to the Composio connection. If it is not, you get a 403:
`People API has not been used in project N before or it is disabled`. Enable it
once at:

```
https://console.developers.google.com/apis/api/people.googleapis.com
```

(use the project number from the error message), then retry.

## 10. Provider and fallback chain

- The primary model is `codex` / `gpt-5.5`. It frequently 429s (usage limit).
- Use a PAID OpenRouter model as the FIRST fallback - for example
  `z-ai/glm-5.2` (tool-capable, roughly $0.95 per million tokens). Set
  `OPENROUTER_API_KEY` in `.env`.
- Free OpenRouter models cap at 50 requests/day (1000/day with $10 of credit on
  the account). When that runs out, weak free models get confused and start
  echoing their own context into the chat. Keep a paid model first in the chain.

CRITICAL GOTCHA: do NOT set OpenRouter as the PRIMARY model
(`model.provider: openrouter`). It crash-loops the long-running gateway: a
background gateway task fails on an openrouter-primary even though a single-turn
CLI call works fine, so it looks healthy in testing and then dies in service.
Keep `codex` primary with `glm-5.2` as the first fallback.

Example fallback chain (commented in `config.template.yaml`):

```yaml
fallback_providers:
  - provider: openrouter
    model: z-ai/glm-5.2 # paid, tool-capable, first fallback
  - provider: openrouter
    model: deepseek/deepseek-chat:free
  - provider: openrouter
    model: qwen/qwen-2.5-72b-instruct:free
# WARNING: never set model.provider: openrouter as the PRIMARY - it crash-loops
# the gateway. OpenRouter belongs ONLY in the fallback chain.
```

## 11. Operations (restart, edits, persistence)

- RESTART a brain with `<brain> gateway restart` (clean reload). Do NOT use
  `docker restart`. A `docker restart` mid-task can leave the gateway HUNG: s6
  thinks the service is up but it spawns no whatsapp-bridge and writes no
  gateway log. Symptom: no `bridge.js` process, port 3000 dead, and a frozen
  gateway log. Recover with `<brain> gateway restart`.
- `SOUL.md` reloads per message - no restart needed after editing it.
- Edit container files as the right user: `docker exec -u hermes <brain> ...`
  for `/opt/data`, or `-u 0` for `/opt/hermes`.
- Code patches under `/opt/hermes` (the gateway patches from section 3) survive
  `docker restart` but NOT a container recreate or image rebuild - those reset
  `/opt/hermes` from the image. Re-run `lib/patch-gateway.sh <brain>` after a
  recreate, a new image, or a re-scaffold.
- `approvals.mode` must be the STRING `"off"` to mean auto-approve. A bare `off`
  in YAML parses as the boolean `false`, which the runtime treats as unset and
  falls back to `"manual"`. So if you ever opt into auto-approve, quote it.

## 12. Multi-message UX (busy_input_mode)

`display.busy_input_mode` controls what happens when a second message arrives
while the brain is still working on the first. Options:

- `interrupt` (the old default) - KILLS the first message when a second
  arrives. Awful for texting, where people send three short messages in a row.
- `queue` - finishes the first, then handles the next.
- `steer` (shipped default here) - folds follow-up messages into the running
  turn. This is the natural behavior for multi-message texting and is what a
  fresh brain ships with.

---

## Quick symptom index

- "couldn't link device" / QR fails -> section 1 (live QR, never relay it).
- Bot ignores all incoming messages -> section 2 (mode + allowed-users mix-up).
- WhatsApp spams English commands / "Interrupting current task" -> section 3
  (quiet block + `lib/patch-gateway.sh`).
- Model says "I can't make a deck / place a call" -> section 4 (put the command
  in `SOUL.md`).
- Raw JSON / `untrusted_tool_result` shows up in chat -> section 5.
- "use vapi" but nothing dials -> section 7 (REST + `curl/8.5.0` UA, not the
  read-only Composio tool).
- Asked for a PPTX -> section 8 (HTML decks instead).
- 403 "People API has not been used in project" -> section 9.
- Frequent 429s / gateway crash-loop -> section 10 (paid fallback; never
  openrouter primary).
- Gateway hung after `docker restart` -> section 11 (`gateway restart`).
- Second message kills the first -> section 12 (`busy_input_mode: steer`).
