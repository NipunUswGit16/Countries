# Docker Reviewer Rules

Apply only to `Dockerfile` and `*.dockerfile` files. Report only demonstrably real production risks.

**Each bullet below is an anti-pattern. Flag any code in the diff that matches.** The section header is the category for the finding.

## BASE_IMAGE

- `FROM image:latest` — mutable tag; builds are not reproducible and silent breaking changes are pulled in
- `FROM image` with no tag at all — equivalent to `latest`
- Base image not pinned by digest (`FROM image@sha256:...`) in a production Dockerfile — tag can be repointed
- `FROM scratch` or minimal base used for a language runtime that requires libc/SSL — runtime failures for anything that dynamically links system libraries

## SECRETS_IN_BUILD

- Secret value passed as `ARG` or `ENV` — visible in `docker history` and image metadata; anyone with image pull access can read it
- `COPY` or `ADD` of a credentials file (`.env`, `id_rsa`, `*.pem`, `credentials`, `config`) into the image — secret is baked into the layer permanently
- `RUN curl -H "Authorization: ..."` with a hardcoded token — token captured in the layer and in `docker history`
- Secret mounted with `--mount=type=secret` but the consuming `RUN` step copies it to a persistent location — secret persists beyond the build step

## ROOT_AND_PRIVILEGES

- No `USER` instruction — container runs as root by default; container escape yields host root
- `USER root` explicitly set in a final stage — same as above; often added to work around a permission issue that should be fixed instead
- `--privileged` in a `RUN` step (via `docker build --allow`) — grants full host device access during build

## LAYER_AND_CACHE

- `COPY . .` or `ADD . .` before dependency installation — any source file change invalidates the dependency cache layer; always copy dependency manifests first (`go.mod`, `package.json`, `requirements.txt`)
- `apt-get update` in a separate `RUN` layer from `apt-get install` — if only `install` is re-run, it uses a stale package index from cache
- `apt-get install` without `--no-install-recommends` — installs unnecessary packages, inflating image size
- `apt-get` / `yum` / `apk` without cleaning the package cache in the same `RUN` layer — cache is committed to the image layer and cannot be removed later
- Multiple `RUN` commands that could be chained — each `RUN` creates a new layer; chain with `&&` for related operations

## MULTI_STAGE

- Final image built from a development base image (`*-dev`, `*-sdk`, `golang`, `node`) — includes compilers, package managers, and debug tools that inflate the image and increase attack surface
- Build artefact copied from the wrong stage — `COPY --from=builder ...` references the wrong stage name or index
- Stage not given a name (`FROM image AS builder`) — COPY from unnamed stages breaks if the order changes

## FILESYSTEM_AND_NETWORKING

- `ADD` used instead of `COPY` for local files — `ADD` has implicit tar extraction and URL fetching behaviour that is almost never wanted for local copies
- `ADD` with a URL — fetches at build time with no integrity check; use `RUN curl ... | sha256sum -c` to verify
- `EXPOSE` port not documented or inconsistent with the application's actual listening port — misleads operators and breaks port-mapping conventions
- `WORKDIR` not set — all commands run from `/`; paths are ambiguous and files may land in unexpected locations
- Executable file `COPY`ed into the image without verifying it was built for the target OS/architecture — silent `exec format error` at runtime
