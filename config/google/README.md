# Google OAuth credentials (template)

This folder is **documentation only**. Runtime secrets live in `data/google/` (gitignored).

## Quick steps

1. Create a **dedicated** bot Gmail — see [docs/google-workspace.md](../../docs/google-workspace.md).
2. Download Desktop OAuth JSON from Google Cloud Console.
3. Install it:

   ```bash
   make google-credentials SRC=/path/to/client_secret.json
   ```

4. Set `GOG_ACCOUNT` and `GOG_KEYRING_PASSWORD` in `.env`.
5. Run `make google-setup` then `make google-auth`.

Never commit `credentials.json` or token files.
