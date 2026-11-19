# DataLoader entities

`external-entities.json` is baked into the `countries` dataloader image
(`cmd/dataloader/Dockerfile` copies it to `/etc/dataloader/`). List the reference
entities, grouped by `sourceComponent`, that the dataloader should pull from the
Data Lake and ingest into this component.

`chart/resources/external-entities.json` is a symlink to this file so the chart
can read it: `chart/templates/dataloader.yaml` only renders the dataloader job
when the file exists and declares at least one entity. Deleting this file while
the symlink remains breaks `helm template`, so remove both together.

`make generate` hashes this file into `$jobVersion` in
`chart/templates/dataloader.yaml`, so a change to the entity list triggers a
reload job. Do not edit `$jobVersion` by hand.

## Enabling the job

The dataloader sends ingested records to the component's integration API
(`POST {integrationApi.baseUrl}/api/core/v1/load`), so enable it only once
the component has an integration-api. Then:

1. Make sure the vendored common chart matches `chart/Chart.yaml`: the
   dependency is declared as `kairos-components-common 0.6.0-beta1106`, but
   `chart/charts/` may still hold an older tarball (beta987 ignores most
   `dataloader.datalake` settings and does not mount the Data Lake token).
   Run `helm dependency build chart` to pull the declared version.
2. Replace the placeholders in `external-entities.json` and run `make generate`.
3. Review `dataloader.enabled` plus the `datalake` and `integrationApi`
   settings in `chart/values.yaml`.
4. Keep `dataloader.auth.tokenAudience` equal to `integration-api.auth.tokenAudience`.
5. Keep the dataloader's tenant targeting a subset of `db-script-runner`'s,
   otherwise the dataloader waits forever for the missing tenants.

For a local image, run `make build-dataloader` (toolkit v1.0.47+; on older
toolkits build `cmd/dataloader/Dockerfile` manually with docker).
