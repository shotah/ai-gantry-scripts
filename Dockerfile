# Thin ZeroClaw: keep the upstream distroless image, add only the extra tool binaries.
# Upstream :latest is gcr.io/distroless/cc-debian13 (glibc). gws gnu builds need GLIBC >= 2.39,
# so the fetch stage must be Debian 13+ (trixie), not bookworm/Alpine. Tool MCPs are static
# (zero-CGO) Go binaries, so they run on distroless fine.
#
# Recent ZeroClaw fails agent init if no shell is on PATH (`runtime.shell "sh" was not
# found`). Distroless has none; upstream `:debian` is bookworm (too old for gws), so we
# drop in a static busybox as /bin/sh instead of switching the whole base image.
#
# Build:  docker compose build
# Auth:   docs/google-workspace.md · docs/strava.md · docs/garmin.md · docs/web-search.md · docs/cast.md · docs/ytmusic.md

ARG ZEROCLAW_BASE=ghcr.io/zeroclaw-labs/zeroclaw:latest
ARG GWS_VERSION=v0.22.5
ARG STRAVA_MCP_VERSION=v1.2.0
# shotah/go-garmin release (DI auth + MCP). Override via GARMIN_MCP_VERSION.
ARG GARMIN_MCP_VERSION=v0.1.0
# Gemini Grounding with Google Search MCP (override via GEMINI_SEARCH_MCP_REF).
ARG GEMINI_SEARCH_MCP_REF=1fe676adcdaa79ed0798fd32be0695ffee15c644
# Google Workspace MCP (Go; magks) — pin commit (override via GOOGLE_WORKSPACE_MCP_REF).
ARG GOOGLE_WORKSPACE_MCP_REF=e421e4cea028e93575bb4e7b5ec1b3dc4a7084b6
# Our packages: default `latest` (resolved at build). Pin e.g. v0.0.2 to freeze.
# TOOLS_CACHEBUST (from make/remote) busts Docker cache so latest re-resolves.
ARG MCP_BEAM_VERSION=latest
ARG YOUTUBE_GO_MCP_VERSION=latest
ARG TOOLS_CACHEBUST=0

# --- static /bin/sh for distroless (agent init + shell tool) -------------------
FROM debian:trixie-slim AS shell
RUN apt-get update \
 && apt-get install -y --no-install-recommends busybox-static \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /out/bin \
 && cp /bin/busybox /out/bin/busybox \
 && ln -sf busybox /out/bin/sh \
 && /out/bin/sh -c 'echo ok'

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

# --- build Google Workspace MCP (static Go; magks) ---------------------------
FROM golang:1.25-bookworm AS google-workspace-mcp
ARG GOOGLE_WORKSPACE_MCP_REF
ARG TARGETARCH

ENV CGO_ENABLED=0
WORKDIR /src
RUN git clone https://github.com/magks/google-workspace-mcp-go.git . \
 && git checkout --detach "${GOOGLE_WORKSPACE_MCP_REF}" \
 && GOOS=linux GOARCH="${TARGETARCH}" go build -trimpath -ldflags="-s -w" -o /google-workspace-mcp-go . \
 && test -x /google-workspace-mcp-go

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

# --- fetch garmin CLI + MCP (static Go; shotah/go-garmin release) ------------
FROM debian:trixie-slim AS garmin
ARG GARMIN_MCP_VERSION
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && case "${TARGETARCH}" in \
      amd64|arm64) GARMIN_ARCH="linux_${TARGETARCH}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && V="${GARMIN_MCP_VERSION#v}" \
 && curl -fsSL \
      "https://github.com/shotah/go-garmin/releases/download/${GARMIN_MCP_VERSION}/garmin_${V}_${GARMIN_ARCH}.tar.gz" \
      -o /tmp/garmin.tar.gz \
 && tar -xzf /tmp/garmin.tar.gz -C /tmp \
 && install -m 0755 /tmp/garmin /garmin \
 && /garmin --version

# --- build Gemini Google Search MCP (static Go; zchee) -----------------------
FROM golang:1.26-bookworm AS gemini-search
ARG GEMINI_SEARCH_MCP_REF
ARG TARGETARCH

ENV CGO_ENABLED=0
WORKDIR /src
RUN git clone https://github.com/zchee/mcp-gemini-google-search.git . \
 && git checkout --detach "${GEMINI_SEARCH_MCP_REF}" \
 && GOOS=linux GOARCH="${TARGETARCH}" go build -trimpath -ldflags="-s -w" -o /mcp-gemini-google-search . \
 && test -x /mcp-gemini-google-search

# --- fetch mcp-beam (static Go; Chromecast + DLNA + YouTube Cast MCP) ---------
# mDNS discovery needs host networking at runtime (docs/cast.md).
FROM debian:trixie-slim AS mcp-beam
ARG MCP_BEAM_VERSION
ARG TARGETARCH
ARG TOOLS_CACHEBUST=0

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && case "${TARGETARCH}" in \
      amd64|arm64) BEAM_ARCH="linux_${TARGETARCH}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && : "TOOLS_CACHEBUST=${TOOLS_CACHEBUST}" \
 && VER="${MCP_BEAM_VERSION}" \
 && if [ "${VER}" = "latest" ]; then \
      VER=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/shotah/mcp-beam/releases/latest" \
        | sed 's|.*/||'); \
      echo "resolved mcp-beam latest -> ${VER}"; \
    fi \
 && V="${VER#v}" \
 && curl -fsSL \
      "https://github.com/shotah/mcp-beam/releases/download/${VER}/mcp-beam_${V}_${BEAM_ARCH}.tar.gz" \
      -o /tmp/mcp-beam.tar.gz \
 && tar -xzf /tmp/mcp-beam.tar.gz -C /tmp \
 && install -m 0755 /tmp/mcp-beam /mcp-beam \
 && /mcp-beam --version

# --- fetch youtube-go-mcp (static Go; YouTube Music search + library) ---------
# Browser-cookie auth at runtime via YTMUSIC_HEADERS_PATH (docs/ytmusic.md).
FROM debian:trixie-slim AS youtube-go-mcp
ARG YOUTUBE_GO_MCP_VERSION
ARG TARGETARCH
ARG TOOLS_CACHEBUST=0

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/* \
 && case "${TARGETARCH}" in \
      amd64|arm64) YTM_ARCH="linux_${TARGETARCH}" ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && : "TOOLS_CACHEBUST=${TOOLS_CACHEBUST}" \
 && VER="${YOUTUBE_GO_MCP_VERSION}" \
 && if [ "${VER}" = "latest" ]; then \
      VER=$(curl -fsSL -o /dev/null -w '%{url_effective}' \
        "https://github.com/shotah/youtube-go-mcp/releases/latest" \
        | sed 's|.*/||'); \
      echo "resolved youtube-go-mcp latest -> ${VER}"; \
    fi \
 && V="${VER#v}" \
 && curl -fsSL \
      "https://github.com/shotah/youtube-go-mcp/releases/download/${VER}/youtube-go-mcp_${V}_${YTM_ARCH}.tar.gz" \
      -o /tmp/youtube-go-mcp.tar.gz \
 && tar -xzf /tmp/youtube-go-mcp.tar.gz -C /tmp \
 && install -m 0755 /tmp/youtube-go-mcp /youtube-go-mcp \
 && /youtube-go-mcp --version

# --- runtime: upstream distroless + shell + tool binaries ---------------------
FROM ${ZEROCLAW_BASE}
# busybox-static: satisfies ZeroClaw runtime.shell without pulling in a full OS.
COPY --from=shell /out/bin/busybox /bin/busybox
COPY --from=shell /out/bin/sh /bin/sh
COPY --from=gws /gws /usr/local/bin/gws
COPY --from=google-workspace-mcp /google-workspace-mcp-go /usr/local/bin/google-workspace-mcp-go
COPY --from=strava /strava-mcp /usr/local/bin/strava-mcp
COPY --from=garmin /garmin /usr/local/bin/garmin
COPY --from=gemini-search /mcp-gemini-google-search /usr/local/bin/mcp-gemini-google-search
COPY --from=mcp-beam /mcp-beam /usr/local/bin/mcp-beam
COPY --from=youtube-go-mcp /youtube-go-mcp /usr/local/bin/youtube-go-mcp
