# TODO — docker_open_claw

OpenClaw does the heavy lifting. This repo is mostly **Docker glue**: image, volumes, `.env`, and Make targets. There is almost no application code — and that's intentional.

---

## Try it now (first-run checklist)

Do these in order. Docker Desktop must be running.

```bash
make init                    # .env + data/ dirs
# Edit .env — at minimum set GEMINI_API_KEY and WHATSAPP_ALLOW_FROM

make build                   # wraps ghcr.io/openclaw/openclaw
make onboard                 # one-time OpenClaw setup (writes data/openclaw.json)
make up                      # start gateway
make logs                    # confirm gateway is healthy

make whatsapp-login          # scan QR with your *assistant* phone (not personal WA)
# Open http://127.0.0.1:18789 — paste OPENCLAW_GATEWAY_TOKEN from .env

# Message the assistant number from a phone in WHATSAPP_ALLOW_FROM
```

### Google Workspace (Gmail, Calendar, Docs)

**Use a dedicated bot Gmail** — not your personal account. See [docs/google-workspace.md](docs/google-workspace.md) for why and how.

```bash
# 1. Create yourname-openclaw@gmail.com + Google Cloud OAuth (Desktop app)
# 2. Set GOG_ACCOUNT and GOG_KEYRING_PASSWORD in .env

make google-credentials SRC=/path/to/client_secret.json
make restart                 # pick up GOG_* env vars
make google-setup            # verify creds + install gog skill
make google-auth             # OAuth in browser (sign in as GOG_ACCOUNT)
make google-status           # confirm connected
```

Optional: share a personal calendar *into* the bot account so it sees your real schedule without OAuth on your primary inbox.

---

## What's already done

- [x] README with architecture + Mermaid communication diagrams
- [x] `Dockerfile` — thin layer on official OpenClaw image (gogcli config dir)
- [x] `docker-compose.yml` — volumes, health check, Gemini + GOG env passthrough
- [x] `.env.example`, `.gitignore`, `Makefile` with help + docker targets
- [x] VS Code / Cursor workspace settings + recommended extensions
- [x] Persistent `data/` layout for config, workspace, Google creds
- [x] **Google Workspace guide** — [docs/google-workspace.md](docs/google-workspace.md)
- [x] **Make targets** — `google-credentials`, `google-setup`, `google-auth`, `google-status`

---

## Known gaps (manual today)

These are the things that **don't auto-magic yet** — you do them once by hand or via Make targets above.

| Gap | Impact | Workaround |
|---|---|---|
| **First-run onboard** | Gateway won't have model/auth config until onboard runs | `make onboard` (once) |
| **Flight APIs** | No custom skill yet | Agent can still web-search; dedicated skill TBD |
| **SMS / Twilio** | Env vars documented, channel not wired | WhatsApp first; Twilio later |
| **Image pin** | `latest` can break on upstream regressions | Set `OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:2026.3.7` in `.env` for production |

---

## Future enhancements

### High value

- [x] **`.env` → `openclaw.json` sync** — `make sync-config` (WhatsApp allowlist, model, TZ)
- [ ] **`make onboard` idempotency** — skip or warn if already onboarded
- [ ] **Pin default image tag** in `.env.example` (avoid broken `latest` releases)
- [ ] **Document post-onboard allowlist edit** — one-liner `config set` for WhatsApp numbers

### Integrations

- [ ] Flight API skill or documented Custom Search fallback
- [ ] Optional Twilio SMS channel in compose

### Ops & quality

- [ ] `scripts/entrypoint.sh` — render config before gateway start
- [ ] GitHub Actions: validate `docker compose config`, hadolint Dockerfile
- [ ] README roadmap section — sync checkboxes with this file

### Nice to have

- [ ] `.vscode/tasks.json` — Run `make up`, `make logs` from command palette
- [ ] Chromium / browser skill extras in Dockerfile (for flight scraping)

---

## "Should it just work?"

**Mostly yes**, with one honest caveat:

1. **OpenClaw is the product** — messaging, agent loop, skills, gateway UI all ship upstream.
2. **This repo is the lunchbox** — keeps config on `./data`, reads `.env`, gives you `make` shortcuts.
3. **You still do first-run setup once** — onboard, WhatsApp QR, allowlist, Google OAuth. That's normal for self-hosted agents; it's intentional security (OAuth + pairing).

If something fails, check `make logs` first, then the [README troubleshooting](README.md#troubleshooting) table.

---

## After your first successful run

Come back and check off what worked:

- [ ] Container healthy (`make ps`)
- [ ] Control UI loads at http://127.0.0.1:18789
- [ ] WhatsApp paired
- [ ] Test message gets a Gemini reply
- [ ] Dedicated bot Gmail created (not personal)
- [ ] Google OAuth connected (`make google-status`)
- [ ] Calendar / Gmail test from WhatsApp

Note any breakage here or open an issue — that's how the TODO list shrinks.
