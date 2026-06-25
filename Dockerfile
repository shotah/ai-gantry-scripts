# Extend the official OpenClaw image. Pin a version in production:
#   OPENCLAW_IMAGE=ghcr.io/openclaw/openclaw:2026.3.7
ARG OPENCLAW_BASE=ghcr.io/openclaw/openclaw:latest
FROM ${OPENCLAW_BASE}

USER root
RUN mkdir -p /home/node/.config/gogcli \
    && chown -R node:node /home/node/.config/gogcli
USER node
