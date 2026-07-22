# gcp-prod: the production adapter chain behind the standard API (region `de`)

This provider serves the same `storage.example.io/ObjectStorage` API as
gcp/azure/aws — but the realization is **ODC's unchanged production stack**
instead of a curl Job:

```
ObjectStorage {region: de}                      (consumer, standard API)
  → resource-broker → staging → krop instance   (root:gcp-prod)
  → host-target: Bucket (storage.opendefense.cloud)   ← the blueprint IS the adapter
  → provider-gcp (UNCHANGED, https://gitlab.opendefense.cloud/odc/cat/cloudapi/provider-gcp)
  → GCPBucket (Crossplane claim) → provider-terraform → floci-gcp
  → Bucket.status.endpoint → blueprint status → ObjectStorage.status.url
```

The point for the RFC: an existing production adapter adopts the proposed
standard API **without any code change** — the krop blueprint maps the standard
type onto the production type declaratively. Migration away is fully
declarative too (OwnerRef GC → terraform destroy), no create-only 409 handling.

## Run

```bash
./setup.bash gcp-prod
```

Not part of the default `setup` chain (Crossplane adds ~2 min to greenfield) —
opt in with the command above. The adapter image is a public multi-arch build
(`ghcr.io/ducke/provider-gcp:hackathon-1`, amd64+arm64), so **no ODC access is
needed to run this**. If an ODC-internal source checkout is present
(`PROVIDER_GCP_SRC`, default
`~/dev/gitlab.opendefense.cloud/odc/cat/cloudapi/provider-gcp`), the image is
built locally and sideloaded instead. The Harbor CI image remains the
production reference (amd64-only, auth-gated).

Then order with `region: de` (or migrate an existing order):

```bash
kubectl patch objectstorage bucket1 --type merge -p '{"spec":{"region":"de"}}'
```

The resulting URL carries a uniqueness suffix (`gs://<order>-<hash6>`) — the
production adapter's naming policy (global GCS names).

## Pieces

| Path | What |
|---|---|
| `manifests/blueprint-objectstorage.yaml` | krop blueprint: host-target CloudAPI Bucket |
| `host/` | Crossplane stack (verified in ODC spikes), Bucket CRD, XRD/Composition, adapter Deployment+RBAC |
| `../krop/gcp-prod/` | krop-controller kustomization + AcceptAPI (region `de`) |

Region carve-out: the job-based gcp provider keeps `eu`; `de` routes here.
