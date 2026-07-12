# Google Workspace APIs (personal Gmail is fine)

This is **not** “you need Google Workspace for Business.”

A normal `@gmail.com` account works. You still create a **free Google Cloud
project** so OAuth can talk to Gmail / Docs / Calendar APIs. That project is
just an API keyring for *your* login — no company domain, no admin console,
no service account.

ZeroClaw’s `:latest` image is **distroless** (Debian glibc). This repo keeps
that base and copies in only the [`gws`](https://github.com/googleworkspace/cli)
binary. Do not commit `secrets/google/`.

---

## Host dependencies (auth machine only)

These stay on your laptop / Windows box — **not** in the Docker image.

| Tool | Why | Install |
|---|---|---|
| [Google Cloud SDK](https://cloud.google.com/sdk) (`gcloud`) | `gws auth setup` can create/select the project and enable APIs | Windows: `choco install gcloudsdk` · macOS: `brew install --cask google-cloud-sdk` · Linux: [apt/yum install](https://cloud.google.com/sdk/docs/install) |
| [`gws`](https://github.com/googleworkspace/cli) | OAuth login + `auth export` for `secrets/google/credentials.json` | [Releases](https://github.com/googleworkspace/cli/releases) or `npm install -g @googleworkspace/cli` |

After Chocolatey / brew, open a **new** shell so `gcloud` is on `PATH`, then:

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
```

Reuse whatever project you already have in Cloud Console (no need to create another).

---

## Personal Gmail vs Workspace

| You have | What to do |
|---|---|
| Normal Gmail (`you@gmail.com`) | Follow this guide (External OAuth + test user = you) |
| Google Workspace (company) | Same OAuth flow; skip domain-wide delegation |
| Want Tim isolated | Separate Gmail + share Drive/Calendar — still this OAuth path |

---

## 1. Build the thin image

```bash
make build
# or: docker compose build
```

Remote:

```bash
make remote-deploy   # syncs Dockerfile + compose + secrets, then build + up
```

---

## 2. Free Google Cloud project (once)

Reuse an existing project if you have one (e.g. already in Cloud Console).
Use the **same Google account** Tim should act as (your personal Gmail).

**Fast path (needs `gcloud` + `gws`):**

```bash
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gws auth setup       # enables APIs / wires OAuth where possible
gws auth login --services gmail,calendar,docs,drive,sheets,tasks,people
```

**Manual path (Cloud Console):**

1. Open [Google Cloud Console](https://console.cloud.google.com/) and create or select a project.
2. Enable APIs (APIs & Services → Library):
   - Gmail API
   - Google Calendar API
   - Google Docs API
   - Google Drive API
   - Google Sheets API
   - Google Tasks API
   - People API
3. **OAuth consent screen**
   - User type: **External** (required for consumer Gmail)
   - App name / support email: yours
   - Scopes: you can leave default for now; `gws auth login` will request what it needs
   - **Test users:** add your Gmail address (required while the app is in Testing)
   - Publishing status can stay **Testing** forever for personal use
4. **Credentials** → Create credentials → **OAuth client ID**
   - Application type: **Desktop app**
   - Download the JSON (or note client id/secret for `gws`)

You are not enabling “Google Workspace” as a product. You are only turning on
APIs that personal Gmail already uses.

---

## 3. Auth on a browser machine (once)

Install `gws` on Windows/macOS/Linux (not inside distroless):

```bash
# https://github.com/googleworkspace/cli/releases
# or: npm install -g @googleworkspace/cli
```

### Windows PowerShell (this repo)

`--services` / `--full` have been falling through to **profile-only** scopes on
this setup. Use explicit **`--scopes`** so the browser asks for Calendar/Gmail.

Copy-paste from the repo root:

```powershell
# 1) Login — browser must show Calendar / Gmail / Drive permissions
gws auth logout
gws auth login --scopes "https://www.googleapis.com/auth/calendar,https://www.googleapis.com/auth/calendar.events,https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/documents,https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/spreadsheets,https://www.googleapis.com/auth/tasks,https://www.googleapis.com/auth/contacts"

# 2) Confirm (must list calendar/gmail/drive — not only userinfo.*)
gws auth status

# 3) Export UTF-8 for Docker (do NOT use ">" — that writes UTF-16)
mkdir -Force secrets\google | Out-Null
$json = gws auth export --unmasked 2>$null
if (-not $json) { $json = (gws auth export --unmasked | Out-String) }
[System.IO.File]::WriteAllText(
  "$PWD\secrets\google\credentials.json",
  "$json".Trim(),
  [System.Text.UTF8Encoding]::new($false)
)

# 4) Deploy
make remote-deploy
```

In the Google consent UI, accept **Calendar**, **Gmail**, **Drive**, etc.
If those never appear: Cloud Console → APIs & Services → **OAuth consent screen**
→ add those scopes → save → login again.

### macOS / Linux / Git Bash

```bash
gws auth logout
gws auth login --scopes "https://www.googleapis.com/auth/calendar,https://www.googleapis.com/auth/calendar.events,https://www.googleapis.com/auth/gmail.modify,https://www.googleapis.com/auth/documents,https://www.googleapis.com/auth/drive,https://www.googleapis.com/auth/spreadsheets,https://www.googleapis.com/auth/tasks,https://www.googleapis.com/auth/contacts"
gws auth status

mkdir -p secrets/google
gws auth export --unmasked > secrets/google/credentials.json

make remote-deploy
```

### Smoke checks (after deploy)

```bash
make remote-ssh CMD="docker compose exec -T zeroclaw gws auth status"
make remote-ssh CMD="docker compose exec -T zeroclaw gws calendar calendarList list"
```

(Distroless has no shell; `exec` still works for a direct binary argv.)

If Google says the app isn’t verified: Advanced → Continue (normal while OAuth
consent is in Testing). Add yourself as a **Test user** on the consent screen.

---

## 4. Config already wired

```toml
[google_workspace]
enabled = true
allowed_services = ["gmail", "calendar", "docs", "drive", "sheets", "tasks", "people"]
credentials_path = "/zeroclaw-data/.config/gws/credentials.json"
# no allowed_operations → all methods for those services
```

Compose mounts `./secrets/google` → `/zeroclaw-data/.config/gws`.

Then ask Tim over Telegram, e.g. “What’s unread?” or “Summarize the doc titled …”.

---

## Troubleshooting

- **Access blocked / app not verified** — consent screen is in Testing; add your Gmail under **Test users**, then retry login.
- **insufficient authentication scopes** — (a) re-login with `--scopes` so `gws auth status` lists calendar; (b) re-export + `make remote-deploy`; (c) if status looks good but API still 403, delete stale `secrets/google/token_cache.json` on the server (deploy sync now clears it automatically).
- **`expected value at line 1 column 1` / Bad authorized user secret** — `credentials.json` is UTF-16 (PowerShell `>`). Re-export with `[System.IO.File]::WriteAllText(...)`, then `make remote-deploy`.
- **gws: not found** — rebuild (`make build` / `make remote-deploy`).
- **Auth / 401** — re-export `credentials.json` after a successful login, redeploy.
- **Permission denied on secrets/** — readable by `ZEROCLAW_UID` on the server.
- **Tool blocked** — `google_workspace` must be in `risk_profiles.default.auto_approve` (template includes it).
- **Can't delete calendar events / `Failed to create output file: Permission denied (os error 13)`** — a *delete* returns an empty `204`, which gws writes to a file **in its working directory**. The image WORKDIR (`/zeroclaw-data`) is root-owned, so the write fails. Fixed by `working_dir: /zeroclaw-data/data` (a deploy-user-owned bind mount) in `docker-compose.yml`. This is **not** a scope issue — moving/rescheduling events (incl. UTC→local timezone fixes via `events patch`) already works with the `calendar` scope. Apply with `make remote-sync` + `make remote-up` (compose change → recreate).
- **Can't delete emails** — `gmail.modify` lets Tim **trash** mail (reversible; Google auto-purges Trash after ~30 days) but **cannot** permanently delete or empty Trash. For true permanent delete, re-login adding the broad `https://mail.google.com/` scope (full mailbox access — powerful; prefer trash). If "delete" fails, it's usually Tim calling the hard-delete method instead of trash — a prompting matter, not a block.
- **Want read-only later** — add `[[google_workspace.allowed_operations]]` (e.g. Gmail `messages` list/get only).
