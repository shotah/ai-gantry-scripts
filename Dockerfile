# Extend the official OpenClaw image. Pin a version in production:
#   OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:2026.3.7
#
# Skills (gog, flights-search) are NOT installed here — ./data mounts over
# ~/.openclaw, so runtime installs via `make google-setup` / `make flights-setup`
# persist on the host volume instead of being hidden by an empty first-run mount.
ARG OPENCLAW_BASE=ghcr.io/openclaw/openclaw:latest
FROM ${OPENCLAW_BASE}

USER root
RUN mkdir -p /home/node/.config/gogcli \
    && chown -R node:node /home/node/.config/gogcli
USER node
