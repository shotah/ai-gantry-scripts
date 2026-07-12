# Strava workout data (Garmin friendly)

Give Tim your training history so he can nudge you ("bro, get to the gym"),
suggest rest, and summarize the week. This uses the
[StravaMCP](https://github.com/Stealinglight/StravaMCP) server — a single static
Go binary baked into the image (like `gws`) that ZeroClaw launches over stdio.

**Using a Garmin?** Connect the watch to Strava once (Garmin Connect → Settings →
Connected Apps → Strava). Every activity then auto-syncs to Strava and Tim reads
it here — no fragile unofficial Garmin login required.

Upstream: [StravaMCP](https://github.com/Stealinglight/StravaMCP) ·
[Strava API](https://developers.strava.com).

```mermaid
flowchart LR
  ZC[zeroclaw daemon] -->|MCP stdio| SM[strava-mcp]
  SM -->|OAuth2 HTTPS| ST[Strava API v3]
  SM --- TOK[("secrets/strava/tokens.json")]
```

---

## What Tim can do

`strava-mcp` exposes 11 tools (prefixed `strava__…`). The useful ones here:

| Ask | Tool |
|---|---|
| "Summarize my workouts this week" | `strava_get_activities` + `strava_get_athlete_stats` |
| "Should I train or rest today?" | recent `strava_get_activities` (frequency / load heuristic) |
| "How was my last ride?" | `strava_get_activity_by_id`, `strava_get_activity_zones` |

> **Rest-day reality check:** true recovery metrics (HRV, Body Battery, sleep)
> are **Garmin-only** and not exposed through Strava. "Rest today" advice is
> inferred from training frequency, load, and back-to-back hard days — solid
> coaching, but not physiological readiness.

---

## 1. Create a Strava API app (once)

1. Go to <https://www.strava.com/settings/api>.
2. Fill in the app (any name/website). Set **Authorization Callback Domain** to
   `localhost`.
3. Copy the **Client ID** and **Client Secret** into `.env`:

```env
STRAVA_CLIENT_ID=12345
STRAVA_CLIENT_SECRET=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

---

## 2. Authorize once (no local install)

You **don't** need Go, Homebrew, or WSL just for the one-time OAuth handshake —
the `strava-mcp` binary is already baked into the image (see `Dockerfile`). Run
its `auth` command in a throwaway container that reuses the compose env and
mounts `secrets/strava`, so the token lands on your host and survives.

The flow needs a browser and a `localhost` callback. A container has no browser,
so `strava-mcp` prints the authorization URL instead — you open it on your host,
approve, and the callback is forwarded back into the container.

```bash
make strava-auth
```

That wraps the throwaway container (builds the image if needed, publishes the
callback port, runs `strava-mcp auth`). The raw equivalent, if you're not using
`make`:

```bash
docker compose run --rm --build -p 19876:19876 --entrypoint strava-mcp zeroclaw auth
```

1. It prints `Open this URL in your browser: https://www.strava.com/oauth/authorize?...`
2. Open that URL in your browser, approve access.
3. Strava redirects to `http://localhost:19876/callback`; the `-p 19876:19876`
   mapping forwards it into the container, which captures the code and prints
   `Authenticated as <Your Name>!`.

That writes `secrets/strava/tokens.json` (gitignored, mounted at
`/zeroclaw-data/.config/strava`). `strava-mcp` refreshes the access token
automatically from here on.

> `--entrypoint strava-mcp` swaps the image's default `zeroclaw` entrypoint for
> the tool binary. `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET`, and
> `STRAVA_TOKEN_PATH` already come from `.env` / `docker-compose.yml`. The
> callback has a 2-minute timeout, so have the browser ready.

<details>
<summary>Alternative: run the binary directly (macOS / Linux / WSL)</summary>

Get the binary (`brew install Stealinglight/tap/strava-mcp`,
`go install github.com/Stealinglight/StravaMCP@latest`, or a
[release](https://github.com/Stealinglight/StravaMCP/releases/latest)), then from
the repo root:

```bash
export STRAVA_CLIENT_ID=12345
export STRAVA_CLIENT_SECRET=xxxxxxxx
export STRAVA_TOKEN_PATH="$PWD/secrets/strava/tokens.json"

strava-mcp auth        # opens the browser; approve access
# -> "Authenticated as <Your Name>!"
```

On **Windows** use WSL: `localhost` is shared with Windows, so the browser
callback still lands. Point `STRAVA_TOKEN_PATH` at the repo's
`secrets/strava/tokens.json`.

</details>

---

## 3. Build + deploy

```bash
make sync-config     # regenerates config/config.toml with the [mcp] block
make build           # bakes strava-mcp into the image
make up              # local
# or: make remote-deploy   # ships the token + config to the server
```

`make remote-deploy` copies `secrets/strava/tokens.json` to the server (it's in
the deploy manifest) and rebuilds so the binary is present.

---

## 4. Ask Tim

Over Telegram:

- "Give me a summary of my workouts for the past week."
- "How many miles did I run this month?"
- "I trained hard the last three days — should I rest today?"

---

## Config (already wired)

`config/config.toml.example` registers the MCP server, **grants it to the
agent** (ZeroClaw 0.8.2 is secure-by-default), and auto-approves the tools:

```toml
[agents.main]
# ...
mcp_bundles = ["strava"]        # grant the bundle to this agent

[mcp]
enabled = true
deferred_loading = false        # eager-load tool schemas (see note below)

[[mcp.servers]]
name = "strava"
transport = "stdio"
command = "strava-mcp"

[mcp_bundles.strava]
servers = ["strava"]            # bundle that grants the "strava" server

[risk_profiles.default]
auto_approve = [
  # ...
  "strava__strava_get_activities",   # prefixed <server>__<tool> names
  "strava__strava_get_athlete_stats",
  # ... (all 11 strava__* tools)
]
```

Three separate gates matter (ZeroClaw ≥ 0.8.2):

1. **Grant** — `agents.main.mcp_bundles = ["strava"]` + `[mcp_bundles.strava]`.
   Without this, the agent sees **zero** Strava tools and improvises (it'll
   search Gmail for "strava"). Registering `[[mcp.servers]]` alone is not enough.
2. **Load** — `deferred_loading = false`. With `true` (an option, not the 0.8.2
   default), the model must call the built-in `tool_search` to activate tools
   first; Gemini Flash doesn't reliably do that, so `false` loads them eagerly.
3. **Approve** — `auto_approve` needs the exact prefixed name
   (`strava__<tool>`); a bare `"strava"` does **not** match, so every call would
   prompt (and over Telegram that can't be answered).

Credentials come from the container environment (set in `.env`, passed through
`docker-compose.yml`): `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET`, and
`STRAVA_TOKEN_PATH=/zeroclaw-data/.config/strava/tokens.json` (the mounted
`./secrets/strava`).

---

## Troubleshooting

| Symptom | Likely fix |
|---|---|
| Tim doesn't see Strava tools (searches Gmail instead) | **Grant the bundle:** `agents.main.mcp_bundles = ["strava"]` + `[mcp_bundles.strava] servers = ["strava"]`. ZeroClaw 0.8.2 is secure-by-default — `[[mcp.servers]]` alone doesn't reach the agent. Also `[mcp] enabled = true`, `deferred_loading = false`, and rebuild so `strava-mcp` is in the image |
| `strava-mcp: not found` | Rebuild the image (`make build` / `make remote-deploy`) |
| Auth / 401 / token errors | Re-run `strava-mcp auth`, then redeploy so the fresh `tokens.json` ships |
| Loop detector: `tool 'shell' called N times` | Same cause as "doesn't see Strava tools" — with no Strava tools granted, the model flails calling `shell`. Grant the bundle (row above) |
| Every call asks for approval | Add the **exact** prefixed names `strava__<tool>` to `risk_profiles.default.auto_approve` — a bare `"strava"` does not match |
| No activities | Confirm the watch/app actually syncs to Strava (Garmin → Connected Apps → Strava) |
| Rate limited | Strava caps ~100 req/15 min, 1000/day — ask for summaries, not per-second polling |
| No Windows binary | Use the container flow in [step 2](#2-authorize-once-no-local-install) — no local install; only the token file needs to reach the server |
