# Developer Guide

This guide explains how the pieces fit together and how to extend them.
It assumes basic Kubernetes/CRD knowledge but no prior kcp, kro or
Crossplane experience. Everything here is designed to be workable without
any AI tooling: each layer is one small, readable artifact.

## 1. The idea: API extraction

Consumers should order infrastructure ("a bucket", "a database") through a
**generic API** owned by the platform, not through vendor APIs. The vendor
is an implementation detail that can be chosen - and *changed* - per
resource without the consumer's manifests changing.

This PoC implements the chain for object storage:

| Layer | Technology | Artifact |
|---|---|---|
| Consumer API surface | kcp workspace + APIExport/APIBinding | created by api-syncagent |
| Transport workspace <-> cluster | api-syncagent | `providers/floci-aws/manifests/publishedresource-buckets.yaml` |
| Generic API definition + translation | kro ResourceGraphDefinition | `providers/*/manifests/rgd-bucket.yaml` |
| Vendor provisioning | our S3 operator / Crossplane | `cmd/` + `internal/`, `providers/gcp-crossplane/` |
| Simulated clouds | floci (AWS + GCP emulators) | `kind/manifests/` |

## 2. The layers, bottom-up

### 2.1 Simulated clouds

* The floci-aws emulator provides a local S3 API (no account, no billing).
* [floci](https://floci.io) emulates the real cloud APIs locally
  (`floci-gcp` for Google Cloud Storage; floci also has AWS and Azure
  emulators). No credentials, no billing.

### 2.2 Vendor APIs and provisioning

Real clouds bring their own Kubernetes operators and CRDs (AWS ACK, GCP
Config Connector, Azure Service Operator, or Crossplane providers). Our
local emulated "cloud" needs the same thing, so this repo ships a small vendor
operator:

* CRD: `S3Bucket` (`s3.opendefense.internal`), `api/s3/v1alpha1/`.
* Operator: `internal/controller/s3bucket_controller.go` - ensures the
  bucket on the selected backend, maintains a `<name>-credentials` Secret,
  reports endpoint/conditions in status. Backends come from
  `hack/providers.yaml`.

The GCP path needs no Go at all: Crossplane's `provider-gcp-storage`
already serves `Bucket.storage.gcp.upbound.io`.

### 2.3 Translation: kro ResourceGraphDefinitions

A kro RGD does two things at once:

1. **Defines** the consumer-facing CRD from its `spec.schema` block
   (`Bucket` in `storage.opendefense.cloud`).
2. **Translates** each instance into vendor resources via CEL expressions,
   and maps vendor status back into the generic status.

Compare the `resources:` blocks of the floci-aws and gcp-crossplane `rgd-bucket.yaml` files:
same schema, different vendor mapping. That single file is the entire cost
of supporting a provider.

Constraint to know: only one RGD may own the `Bucket` kind per cluster, and
kro recreates the CRD when the owning RGD is swapped (existing instances
are deleted). Multi-provider *routing* on one cluster is done inside a
single RGD (via `spec.providerConfig.provider`);
routing across clusters/workspaces is resource-broker's job (AcceptAPI),
out of scope here.

The typed Go definition in `api/opendefense/v1alpha1/` documents the canonical schema
(and can generate clients); when you change one, change both - a schema
drift between the RGD and `api/opendefense/v1alpha1` is a bug.

### 2.4 kcp: the consumer surface

kcp gives each consumer an isolated, Kubernetes-compatible **workspace**
without running any nodes. This PoC uses exactly one workspace,
`root:storage`, which both exports and consumes the API - that is
sufficient because binding an APIExport from the same workspace is allowed.
Adding more consumer workspaces later is one `kubectl create-workspace`
plus one APIBinding each.

**api-syncagent** connects the workspace to the kind cluster: it publishes
the `Bucket` CRD as an APIExport in the workspace, syncs instances down to
the cluster, and syncs status *and* the credentials Secret (declared as a
`related` resource via `status.bucketSecret.name`) back up. See
`providers/floci-aws/manifests/publishedresource-buckets.yaml`.

### 2.5 Provider switch and migration

Changing `spec.providerConfig.provider` re-renders the vendor resource and
the operator repoints bucket, Secret and endpoint - the control-plane side
of a migration. Moving *data* (rclone sync -> cutover -> delta -> checksum
verify, as staged Jobs) was demonstrated in an earlier two-provider variant
of this PoC and lives on in the resource-broker integration
(`Migration`/`MigrationConfiguration`), where such Jobs become stage
templates with CEL success conditions.

## 3. How to extend

### 3.1 Add another provider for storage

1. Install the provider's operator (e.g. `task crossplane` variant, ACK, ...).
2. Copy `providers/gcp-crossplane/manifests/rgd-bucket.yaml`, keep the `schema:` block identical,
   rewrite the `resources:` templates to the new vendor's kinds.
3. If the provider hands out credentials, surface them as a Secret and map
   `status.bucketSecret.name`, so the syncagent `related` config keeps
   working.
4. Data migration to it = an rclone remote for the new endpoint plus a
   sync/cutover/delta/verify Job sequence (see the resource-broker
   Migration stages).

### 3.2 Add a new object type (database, queue, ...)

The pattern is type-agnostic; storage is just the example. For, say,
`Database` in `databases.opendefense.cloud`:

1. Define the generic schema: new package under `api/` (copy
   `api/opendefense/v1alpha1`), run `task generate`.
2. Write one RGD per provider with that schema (e.g. translate to a
   CloudNativePG `Cluster`, an RDS instance via Crossplane, ...).
3. Add a `PublishedResource` for the new group to
   `providers/floci-aws/manifests/publishedresource-buckets.yaml` (plus the ClusterRole rules).
4. For data migration, pick a type-appropriate mover
   (`pg_dump`/logical replication instead of rclone).

`resource-broker/api/generic/` already sketches candidate schemas for
databases, networking, messaging, AI and more.

## 4. PoC shortcuts (do not copy into production)

* The emulator credentials are handed to consumers; real
  providers must mint scoped, per-bucket credentials.
* Service accounts in kcp get `cluster-admin`; needs real RBAC.
* TLS verification is disabled in generated kubeconfigs.
* `bucketSize`, `bucketPolicy`, `permissions` are accepted but not
  enforced by the S3 translation; encryption needs a KMS-enabled
  backend and is reported (not enforced) otherwise.
* The RGD swap (`task rgd:gcp`) is destructive; per-resource provider
  *routing* across providers is the resource-broker integration, planned
  as the next step after this PoC.

## 5. Troubleshooting

* **Port-forwards died** (laptop sleep): `task forward`.
* **`kubectl create-workspace` unknown**: install the kcp krew plugins
  (see README prerequisites).
* **APIExport `buckets` never appears**: check the agent -
  `kubectl logs deployment/api-syncagent-storage`; usually the kubeconfig
  secret (step 7 of setup) can't reach kcp on
  `api-extraction-control-plane:32111`.
* **Bucket stays without status**: is `task provider` running? Its log
  says which backend it talked to; `kubectl get s3buckets -A` shows the
  vendor-side object kro rendered.
* **Crossplane MR stuck**: `kubectl describe` the MR - if the emulator
  endpoint override is not honored by your provider version, fall back to
  real GCP credentials (`providers/gcp-crossplane/manifests/providerconfig.yaml` comments).
