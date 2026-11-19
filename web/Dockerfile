# syntax=docker/dockerfile:1.7-labs

# --- Stage 0: Build Go entrypoint ---
# Compiles web/entrypoint into a static binary that substitutes env vars in
# env.js (via os.Expand) and execs static-web-server. No shell needed at
# runtime, so the final stage can use the SWS scratch image.
FROM --platform=$BUILDPLATFORM ifsrapidfortcache.azurecr.io/rfcurated/golang:1.27.3-alpine3.24-rfcurated@sha256:169118cae5f8659519cceb8f5d9322645dcf771926af2c207c46c36560ce93ec AS go-build

USER root

WORKDIR /src
COPY web/entrypoint/ .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /entrypoint . \
    && mkdir -p /runtime && touch /runtime/.keep

# --- Stage 1: Build frontend ---
# Node alpine image with necessary packages
FROM node:24-alpine AS build
RUN apk add --no-cache git openssh-client

# ARG outdir = application build output directory (default = dist)
ARG outdir=dist
ARG NPM_REGISTRY=https://registry.npmjs.org

WORKDIR /app

COPY ./web/package.json ./web/pnpm-lock.yaml ./
COPY ./web/.npmrc ./.npmrc.template

RUN npm set registry $NPM_REGISTRY

# The npm auth token is provided as a BuildKit secret (id=npm_token) so it is
# never baked into an image layer or the build history. It is mounted only for
# this RUN. When a token is present we activate .npmrc (npm/pnpm expands the
# ${NPM_TOKEN} refs inside it from the exported env var); otherwise we drop the
# template and install against the public registry only.
RUN --mount=type=secret,id=npm_token \
    export NPM_TOKEN="$(cat /run/secrets/npm_token 2>/dev/null || true)"; \
    if [ -n "$NPM_TOKEN" ]; then \
      mv .npmrc.template .npmrc; \
    else \
      rm -f .npmrc.template; \
    fi; \
    corepack enable && pnpm install --frozen-lockfile

COPY ./web/ ./
RUN pnpm run build

# --- Stage 2: Serve ---
# scratch-based static-web-server: no shell, no package manager, minimal attack surface.
# The Go entrypoint handles env var substitution and execs the server binary directly.
FROM ifsrapidfortcache.azurecr.io/rfcurated/static-web-server:2.44.1-jammy-scratch-fips-rfcurated@sha256:7fd03765f4d4ac8135f8b23fd5e94df68e6c21a03160141184c30bee11e4c7db

ARG outdir=dist

COPY --from=go-build --chmod=755 --chown=101:101 /entrypoint /app/entrypoint
COPY --from=go-build --chown=101:101             /runtime/ /runtime/
COPY --from=build    --chown=101:101             /app/${outdir}/ /public/
COPY                 --chown=101:101             ./web/configs/config.toml /etc/sws/config.toml

# /runtime holds the env.js rendered by the Go entrypoint at startup. In
# Kubernetes this path is overlaid by a writable emptyDir mount (see the
# chart); the empty /runtime baked into the image keeps plain `docker run`
# working without the mount.
# uid:gid 101 matches the chart's runAsUser/runAsGroup.

USER 101

EXPOSE 8080
ENTRYPOINT ["/app/entrypoint"]
