# Thin ZeroClaw: keep the upstream distroless image, add only the extra tool binaries.
# Upstream :latest is gcr.io/distroless/cc-debian13 (glibc). gws gnu builds need GLIBC >= 2.39,
# so the fetch stage must be Debian 13+ (trixie), not bookworm/Alpine. strava-mcp is a static
# (zero-CGO) Go binary, so it runs on distroless with no glibc concerns.
#
# Build:  docker compose build
# Auth:   docs/google-workspace.md (gws) · docs/strava.md (strava-mcp)

ARG ZEROCLAW_BASE=ghcr.io/zeroclaw-labs/zeroclaw:latest
ARG GWS_VERSION=v0.22.5
ARG STRAVA_MCP_VERSION=v1.2.0

# --- fetch gws (trixie/glibc 2.41 — matches distroless/cc-debian13) ------------
FROM debian:trixie-slim AS gws
ARG GWS_VERSION
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && case "${TARGETARCH}" in \
      amd64) GWS_ARCH=x86_64-unknown-linux-gnu ;; \
      arm64) GWS_ARCH=aarch64-unknown-linux-gnu ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL \
      "https://github.com/googleworkspace/cli/releases/download/${GWS_VERSION}/google-workspace-cli-${GWS_ARCH}.tar.gz" \
      -o /tmp/gws.tar.gz \
 && tar -xzf /tmp/gws.tar.gz -C /tmp \
 && install -m 0755 /tmp/gws /gws \
 && /gws --version

# --- fetch strava-mcp (static Go binary; MCP server for Strava) ---------------
FROM debian:trixie-slim AS strava
ARG STRAVA_MCP_VERSION
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && case "${TARGETARCH}" in \
      amd64|arm64) STRAVA_ARCH="linux_${TARGETARCH}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && V="${STRAVA_MCP_VERSION#v}" \
 && curl -fsSL \
      "https://github.com/Stealinglight/StravaMCP/releases/download/${STRAVA_MCP_VERSION}/StravaMCP_${V}_${STRAVA_ARCH}.tar.gz" \
      -o /tmp/strava.tar.gz \
 && tar -xzf /tmp/strava.tar.gz -C /tmp \
 && install -m 0755 /tmp/strava-mcp /strava-mcp \
 && /strava-mcp --version

# --- runtime: upstream distroless + tool binaries -----------------------------
FROM ${ZEROCLAW_BASE}
COPY --from=gws /gws /usr/local/bin/gws
COPY --from=strava /strava-mcp /usr/local/bin/strava-mcp
