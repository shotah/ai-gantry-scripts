# Persona & system prompt (Tim)

ZeroClaw builds Tim’s system prompt each session from markdown in:

```text
config/agents/main/workspace/
```

That directory is bind-mounted with `./config` → `/zeroclaw-data/.zeroclaw` on the server.

## Templates vs personal files

| Committed (safe) | Local / server (gitignored) |
|---|---|
| `SOUL.example.md` | `SOUL.md` |
| `USER.example.md` | `USER.md` |
| `IDENTITY.example.md` | `IDENTITY.md` |
| `AGENTS.example.md` | `AGENTS.md` |
| `TOOLS.example.md` | `TOOLS.md` |
| `MEMORY.example.md` | `MEMORY.md` |
| `HEARTBEAT.example.md` | `HEARTBEAT.md` |

```bash
make persona          # create missing *.md from *.example.md
make persona-force    # overwrite *.md from examples (wipes local edits)
```

`make init` and `make remote-sync` run `persona` so files exist before deploy.
Fill in **`USER.md`** (name, canonical Google email, city) before expecting good Google tool calls.

## What each file is for

| File | Purpose |
|---|---|
| `SOUL.md` | Personality, coach mode, anti-hallucination rules |
| `USER.md` | Who you are — **canonical email lives here** |
| `IDENTITY.md` | Name “Tim”, vibe |
| `AGENTS.md` | Operating rules / workflows |
| `TOOLS.md` | How to use Google / Strava / Garmin / Cast / YT Music / memory |
| `MEMORY.md` | Curated long-term notes (injected in main session) |
| `HEARTBEAT.md` | Optional periodic checks (empty = skip) |

These are **not** the same as hybrid SQLite memory (`brain.db`).
Persona files = doctrine you control. Hybrid memory = auto-recall (can go wrong).

## Edit & deploy

```bash
# edit config/agents/main/workspace/*.md  (gitignored)
make remote-sync          # ensures persona files exist, then scp
make remote-restart       # or remote-up if down
```

After a bad session: Telegram `/new`, and scrub bad hybrid memories if needed.

## Related

- Models / provider swap: [models.md](models.md)
- Telegram `/new` + memory notes: [telegram.md](telegram.md)
