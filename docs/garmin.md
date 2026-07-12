# Garmin Connect (sleep, weight, readiness)

Give Tim your Garmin-native recovery data — sleep, Index scale weigh-ins, Body
Battery / HRV, training readiness — via the
[go-garmin](https://github.com/llehouerou/go-garmin) CLI’s built-in MCP server
(`garmin mcp`). A static Go binary is baked into the image (like `gws` /
`strava-mcp`); ZeroClaw launches it over stdio.

**Keep Strava** for the activity feed if you want; Garmin fills the gaps Strava
never had. Climbing typed-splits (per-route grades / attempts) are a follow-up
PR against go-garmin — not required for sleep/weight.

Upstream: [go-garmin](https://github.com/llehouerou/go-garmin) · compare with
[docs/strava.md](strava.md).

```mermaid
flowchart LR
  ZC[zeroclaw daemon] -->|MCP stdio| GM["garmin mcp"]
  GM -->|session HTTPS| GC[Garmin Connect]
  GM --- TOK[("secrets/garmin/session.json")]
```

Auth is lighter than Strava: **no API app, no client id/secret.** Login once
interactively (email / password / MFA); the CLI writes `session.json`. Runtime
only needs that file + `HOME` so `os.UserConfigDir()` resolves to the mount.

Session path (go-garmin `session.go`):

```text
$XDG_CONFIG_HOME/garmin/session.json
# with HOME=/zeroclaw-data in compose →
/zeroclaw-data/.config/garmin/session.json
```

> Upstream README mentions `garmin login -email=… -password=…`, but current
> `login.go` is **interactive prompts only** (TTY). Use `make garmin-auth`.

---

## What Tim can do

Curated tools are auto-approved in `config/config.toml.example` (prefixed
`garmin__…`):

| Ask | Tool |
|---|---|
| "How did I sleep last night?" | `get_sleep` |
| "What's my weight trend?" | `get_weight` |
| "Am I recovered enough to train?" | `get_body_battery`, `get_hrv`, `get_training_readiness` |
| "What did I do this week?" | `list_activities`, `get_activity` |

---

## 1. Optional `.env` pin

**No Garmin email/password in `.env`.** Optional build pin only (already in
`.env.example`):

```env
# GARMIN_MCP_REF=cbf5895e08bf32ea5510aabfd392c892055de2ab
```

Leaving it unset uses the Dockerfile default commit.

---

## 2. Authorize once (`make garmin-auth`)

```bash
make garmin-auth
```

That builds the image if needed, then:

```bash
docker compose run --rm --build -it --entrypoint garmin zeroclaw login
```

1. Enter Garmin Connect **email**, **password**, and **MFA** if prompted.
2. On success: `Login successful.` and `secrets/garmin/session.json` on the host
   (mounted at `/zeroclaw-data/.config/garmin`).

No published ports (unlike Strava’s OAuth callback). Re-run after
`garmin logout` or if the session expires.

---

## 3. Deploy / restart

```bash
make sync-config     # if you refreshed from config.toml.example
make build           # bakes garmin into the image
make up              # or make remote-deploy
```

`make remote-deploy` copies `secrets/garmin/session.json` when present (listed
in `scripts/deploy-manifest.txt`).

---

## Config wiring

`config/config.toml.example` already has:

```toml
mcp_bundles = ["strava", "garmin"]

[[mcp.servers]]
name = "garmin"
transport = "stdio"
command = "garmin"
args = ["mcp"]

[mcp_bundles.garmin]
servers = ["garmin"]
```

Plus `garmin__get_sleep`, `garmin__get_weight`, … in
`risk_profiles.default.auto_approve`. Keep `[mcp] deferred_loading = false`
(same Flash lesson as Strava).

If you already have a live `config/config.toml`, merge those blocks in (or
re-copy from the example carefully) — `make sync-config` only patches model /
Telegram peers, not MCP.

Compose mounts:

```yaml
- ./secrets/garmin:/zeroclaw-data/.config/garmin
```

`HOME=/zeroclaw-data` is already set, so the CLI finds the session with no
extra env vars.

---

## Smoke tests

```bash
make build
docker compose run --rm --entrypoint garmin zeroclaw --help

# After garmin-auth:
docker compose run --rm --entrypoint garmin zeroclaw sleep
docker compose run --rm --entrypoint garmin zeroclaw weight daily
```

Then ask Tim over Telegram: “How did I sleep last night?” / “What’s my latest
scale weight?”

---

## Troubleshooting

| Symptom | Likely fix |
|---|---|
| Tim doesn’t see Garmin tools | Grant bundle: `mcp_bundles = ["strava", "garmin"]` + `[mcp_bundles.garmin]`; rebuild so `garmin` is in the image |
| `garmin: not found` | `make build` / `make remote-deploy` |
| `not logged in` | `make garmin-auth`; confirm `secrets/garmin/session.json` exists and was synced |
| Every call asks for approval | Add exact `garmin__<tool>` names to `auto_approve` |
| Auth / 401 after weeks | Session expired — re-run `make garmin-auth` |
| Rate limited (429) | Unofficial Connect API — ask for summaries, don’t poll |

### `OAuth2 exchange failed: 401` on `make garmin-auth`

**Your password is fine.** If you saw `Email:` / `Password:` / `MFA Code:` and then:

```text
Error: failed to exchange for OAuth2 token: OAuth2 exchange failed: 401 Unauthorized
```

that means SSO + MFA succeeded; go-garmin died on the **next** step
(`POST …/oauth-service/oauth/exchange/user/2.0`). Browser login to
connect.garmin.com working is expected and does **not** contradict this.

**Cause:** Garmin tightened Connect SSO around **March 2026** (headers,
Cloudflare / TLS fingerprinting, mobile `audience` on the OAuth2 exchange).
[go-garmin](https://github.com/llehouerou/go-garmin) last shipped auth in
**Feb 2026** and still uses the older exchange path — so many accounts get
401/403 here even with correct credentials. The Python stack hit the same
wall; `garminconnect` ≥ 0.3 rewrote auth (and even that is flaky for some).

**Do this:**

1. **Stop retrying login** for a bit — failed SSO attempts can trigger
   account+client **429** blocks that last hours.
2. Keep Strava wired for workouts in the meantime.
3. Next engineering step (pick one):
   - Patch / fork go-garmin to the current **mobile DI OAuth** flow (audience,
     headers, embed cookie) — preferred long-term for this distroless image, or
   - Spike `garminconnect` ≥ 0.3 once (Python) only to prove *your* account
     still logs in with a modern client, then decide whether to port that flow
     into Go.

This is an upstream Garmin/auth-client mismatch, not a Tim compose misconfig.

---

## Auth flow (vs Strava)

| | Strava | Garmin (go-garmin) |
|---|---|---|
| App registration | Strava API app + client id/secret in `.env` | None |
| Secrets in `.env` | `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET` | **None** (optional `GARMIN_MCP_REF`) |
| One-shot auth | Browser OAuth + port `19876` | Interactive `garmin login` (TTY) |
| Persisted artifact | `secrets/strava/tokens.json` | `secrets/garmin/session.json` |
| Make target | `make strava-auth` | `make garmin-auth` |
| Runtime env | client id/secret + `STRAVA_TOKEN_PATH` | mount + `HOME` only |

---

## Follow-ups

- [ ] Climbing typed-splits PR on go-garmin (per-route grades / attempts)
- [ ] Decide whether to drop Strava once Garmin activity coverage feels enough
- [ ] Expand `auto_approve` if you want workouts / biometric tools

---

## Risks

Unofficial Connect API (can break), MFA/session expiry, young upstream (we pin
`GARMIN_MCP_REF`). Accept those or stay Strava-only for activities.
