# TODO — resource-broker bucket example (floci-gcp + floci-aws)

## Before the hackathon (cheap now, expensive on site)

- [x] **Verify floci-aws** (done 2026-07-21, Docker, no kind): image is
      `floci/floci:latest` (NOT floci/floci-aws), port 4566, no `FLOCI_AWS_*` env
      needed. `aws s3api create-bucket --bucket X` -> `{"Location":"/X"}`,
      list-buckets confirms; works without a Docker socket (S3 is native).
      GET / returns 200. manifests/floci-aws.yaml updated accordingly.
      Source: https://github.com/floci-io/floci
- [ ] **kcp kubectl plugins** via krew, set PATH.
- [ ] **resource-broker image**: `start-broker` builds from the repo (Go needed) —
      run the build ahead of time, cache the image locally. (The upstream TODO
      "use prebuilt image" is still open.)
- [ ] **Generic `objects` APIExport**: prepare CRD→ARS→APIExport
      (CRD→ARS conversion, mechanical). See platform/README.md.

## Setup order (short form)

1. [ ] kind cluster `broker-poc` + base (cert-manager, etcd-druid, kcp, kro)
2. [ ] kcp workspaces + broker state workspaces + both platform exports
3. [ ] `start-broker`
4. [ ] deploy floci-gcp + floci-aws
5. [ ] per provider: RGD, syncagent + PublishedResource, AcceptAPI binding, AcceptAPI
6. [ ] both AcceptAPIs Ready
7. [ ] consumer: bind objects, order Object{region:eu} → floci-gcp
8. [ ] migration: patch region→us → floci-aws, GCP torn down

## Open technical points

- [ ] **Single cluster vs. run.bash**: `run.bash` is built for 3 clusters. Either
      adapt `_setup`/`_provider_setup` to a single cluster, or drive the helpers
      from `hack/lib.bash` individually against one kubeconfig. Check that the
      syncagent cleanly separates two instances (gcp/aws) on the same compute
      cluster (distinct agent-name/namespace).
- [ ] **kro CEL `.orValue(...)`**: verify the syntax against the kro version in
      use; otherwise switch to `has(...) ? … : …`.
- [ ] **status.url from a Job annotation**: the pattern (stamp an annotation from
      schema, read it in status) is confirmed by the kropg example — check the
      fallback when the annotation is empty.
- [ ] **RGD schema ↔ generic CRD**: `spec{region,versioning}` must match the
      upstream Object CRD, otherwise the broker's copy won't validate.

## Deliberate limits (PoC, not production)

- **create-only**: Jobs create buckets; delete/cutover only tears down the Job,
  not the bucket. floci is ephemeral (kind delete). Production: delete-Job +
  finalizer in the RGD.
- **No portal**: the broker needs none — saves the portal-specific pitfalls from
  the GCP spike. Ordering via kubectl.
- **Fake auth**: floci ignores credentials entirely.

## Upgrades (if time permits)

- [ ] kro target from Job → ACK (`s3…/Bucket`) + Config Connector
      (`StorageBucket`) with an endpoint override onto floci — "real" provider
      controllers.
- [ ] MigrationConfiguration with an intermediate stage (data transfer), like the
      Postgres example, instead of a direct cutover.
- [ ] A second generic type (e.g. `compute/KubernetesCluster` → Gardener) to show
      the pattern carries beyond buckets.
