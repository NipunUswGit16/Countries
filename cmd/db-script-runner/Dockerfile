# Override at build time: docker build --build-arg SQLRUNNER_VERSION=...
ARG SQLRUNNER_VERSION=0b08f65d6f7e5398a046003676ea185f0384e0a8@sha256:1c68622452bad7a443270ccea39678e0e6672c1e66620d23f256a1c783adc06b

FROM nxsdvlglb01acr.azurecr.io/ifs-pd/kairos-component-jobs/image/sqlrunner:${SQLRUNNER_VERSION}

# copy everything from /sql
COPY --chown=65532:65532 sql/ /scripts

# Ensure the container runs with a non-root user (distroless nonroot UID)
USER 65532:65532

# sqlrunner takes the script root as its argument (scripts are jailed under /scripts)
CMD ["/scripts"]
