# Override at build time: docker build --build-arg DATALOADER_VERSION=...
ARG DATALOADER_VERSION=0b08f65d6f7e5398a046003676ea185f0384e0a8@sha256:87dac9262b0228c8eb6320dd31a2a73d17647fb48b2348911cbc9ec8eb9ddfa3

FROM nxsdvlglb01acr.azurecr.io/ifs-pd/kairos-component-jobs/image/dataloader:${DATALOADER_VERSION}

# copy the dataloader external-entities config
COPY --chown=65532:65532 dataloader/external-entities.json /etc/dataloader/

# Ensure the container runs with a non-root user (distroless nonroot UID)
USER 65532:65532
