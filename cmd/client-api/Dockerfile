# Use the official Golang image as the base image
FROM --platform=$BUILDPLATFORM ifsrapidfortcache.azurecr.io/rfcurated/golang:1.27.3-alpine3.24-rfcurated@sha256:169118cae5f8659519cceb8f5d9322645dcf771926af2c207c46c36560ce93ec AS builder

ARG GOPROXY
ENV GOPROXY=${GOPROXY}
ENV GONOSUMDB=bitbucket.org/ifs-pd/*
ARG TARGETOS
ARG TARGETARCH
ARG BUILD_TAGS

# RapidFort golang image runs as non-root (godev). /go is writable; /build is not.
RUN mkdir -p /go/src/app
WORKDIR /go/src/app

COPY --chown=64999:64999 go.mod go.sum ./
# Local replace target; go mod download reads this go.mod.
COPY --chown=64999:64999 pkg/schema/go.mod pkg/schema/go.sum ./pkg/schema/

# Download Go module dependencies
RUN --mount=type=cache,id=go-mod-godev,target=/go/pkg/mod,uid=64999,gid=64999 \
    go mod download

COPY --chown=64999:64999 internal/ internal/
COPY --chown=64999:64999 cmd/ cmd/
COPY --chown=64999:64999 pkg/ pkg/

RUN --mount=type=cache,id=go-mod-godev,target=/go/pkg/mod,uid=64999,gid=64999 \
    --mount=type=cache,id=go-build-godev,target=/go/.cache/go-build,uid=64999,gid=64999 \
    GOFIPS140=certified CGO_ENABLED=0 GOOS="${TARGETOS}" \
    GOARCH="${TARGETARCH}" \
    go build -tags="${BUILD_TAGS}" -ldflags="-s -w" -o main ./cmd/client-api

# Use the new base image from your private registry
FROM ifsrapidfortcache.azurecr.io/rfcurated/debian:13-distroless-static-nonroot-rfcurated@sha256:6e0732617567e495eacc9cd02782790058fe70620916374d9cb2f31ac695b06f

# Ensure the container runs with a non-root user
USER 65532:65532

# Copy to / — distroless WORKDIR /home/nonroot is 700 (uid 65532); chart runs as 1001.
COPY --from=builder --chmod=755 /go/src/app/main /main

EXPOSE 8080
ENTRYPOINT [ "/main" ]
