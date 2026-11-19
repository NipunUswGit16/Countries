# Ubuntu test image for the kairos-component-update skill test suite.
#
# Built and run by `tests/run-tests.sh --ubuntu`. Its purpose is to prove the
# skill's shell scripts behave identically on the platform they actually ship
# to — Ubuntu, including WSL2 — rather than only on a maintainer's macOS box
# (BSD userland, ancient bash 3.2). Ubuntu contributes the divergent half of
# every portability question the suite could hit: GNU coreutils/sed/grep,
# bash 5, and mawk (NOT gawk, NOT BSD awk) as the default `awk`.
#
# The tool set mirrors what a real Kairos developer machine carries, because
# the scripts under test invoke them for real (not just `command -v`):
#   go    — collect-common.sh / codev-check.sh run `go mod edit -json`
#   yq    — mikefarah/yq: yaml-gate.sh (`yq e`), in-progress.sh, collect-common.sh
#           (`yq -p=json`). The kislyuk/yq flavor is deliberately NOT installed;
#           the suite has its own tests for detecting the wrong flavor.
#   helm  — yaml-gate.sh best-effort `helm template` layer
#   perl  — pre-flight.sh / intent-check.sh run guards under a perl alarm timeout
#   python3, git — fixtures and several scripts
# The Kairos CLI is NOT installed: the suite shims it (tests/fake-kairos.sh).
#
# Versions are pinned so the image is reproducible; bump deliberately. `go mod
# edit -json` intentionally works on a go.mod that declares a newer `go`
# directive than the toolchain, so GO_VERSION need not track the template.

FROM ubuntu:24.04

ARG GO_VERSION=1.23.4
ARG YQ_VERSION=v4.53.3
ARG HELM_VERSION=v3.16.4

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH=/usr/local/go/bin:$PATH

RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      git perl python3 curl ca-certificates tar \
 && rm -rf /var/lib/apt/lists/*

# dpkg arch is "amd64" / "arm64" — the naming go, yq and helm all use.
RUN ARCH="$(dpkg --print-architecture)" \
 && curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" \
      | tar -C /usr/local -xz \
 && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${ARCH}" \
      -o /usr/local/bin/yq \
 && chmod +x /usr/local/bin/yq \
 && curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
      | tar -xz -C /tmp \
 && mv "/tmp/linux-${ARCH}/helm" /usr/local/bin/helm \
 && rm -rf "/tmp/linux-${ARCH}" \
 && go version && yq --version && helm version --short

# GOFLAGS/GOTOOLCHAIN: keep `go mod edit` fully offline and stop it from trying
# to download a newer toolchain when a fixture go.mod names one.
ENV GOTOOLCHAIN=local
ENV GOFLAGS=-mod=mod

WORKDIR /repo
