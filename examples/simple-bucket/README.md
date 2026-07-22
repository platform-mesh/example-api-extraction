# Example: a generic Bucket, the simplest way

Proof of concept for **API extraction**: a consumer orders object storage
through the **generic, provider-neutral `Bucket` API**
(`storage.opendefense.cloud/v1alpha1`, following the opendefense.cloud
Object Storage API reference), and the platform fulfills it on an
S3 backend - locally emulated by [floci](https://floci.io), so no cloud
account is needed.

```
                kcp workspace "storage" (consumer view)
                Bucket my-bucket   +   Secret my-bucket-credentials
                       ▲ │                        ▲
                       │ ▼  api-syncagent (sync down / status+secret up)
  ┌────────────────────┴──────────────────────────┴─────────────────┐
  │ kind cluster                                                    │
  │   Bucket (CRD instantiated by kro from the RGD)                 │
  │      │ kro RGD = the TRANSLATION                                │
  │      │   providers/floci-aws/manifests/rgd-bucket.yaml          │
  │      ▼                                                          │
  │   S3Bucket (vendor API) ── S3 operator ── floci-aws (S3, :4566) │
  └─────────────────────────────────────────────────────────────────┘
```

One kind cluster, **one kcp workspace**, one provider. The pieces:

| Piece | Where |
|---|---|
| Generic Bucket API (typed reference) | `api/opendefense/v1alpha1/` |
| Translation (defines the CRD + maps to the vendor API) | `providers/floci-aws/manifests/rgd-bucket.yaml` |
| Vendor API + S3 operator | `api/s3/v1alpha1/`, `cmd/`, `internal/` |
| Workspace publishing | `providers/floci-aws/manifests/publishedresource-buckets.yaml` |
| Emulated S3 | `kind/manifests/floci-aws.yaml` |

## Run it

Prerequisites: docker, kind, kubectl, helm, yq, go, task (or make), and the
[kcp kubectl plugins](https://docs.kcp.io/kcp/main/setup/kubectl-plugin/).

```bash
task all           # everything unattended: setup + operator + example + results
task translation   # re-print the result: the bucket at every layer
```

Or step by step:

```bash
task setup         # kind + kcp workspace + kro RGD + floci-aws + api-syncagent
task provider      # terminal 2: the S3 vendor operator (keep running)
task example       # order examples/simple-bucket/bucket.yaml, wait for Ready
```

## What to look at afterwards

```bash
# 1. Consumer view - generic API only, no vendor terms anywhere:
KUBECONFIG=kubeconfigs/workspaces/storage.kubeconfig kubectl get buckets -o yaml

# 2. The TRANSLATED vendor resource rendered by kro:
kubectl --kubeconfig kubeconfigs/kind.kubeconfig get s3buckets -A -o yaml

# 3. Use the credentials the consumer received (task forward first):
KUBECONFIG=kubeconfigs/workspaces/storage.kubeconfig \
  kubectl get secret example-object-storage-credentials -o yaml
AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
  aws --endpoint-url http://127.0.0.1:4566 s3 ls s3://my-bucket/

# 4. All layers in one shot:
task translation
```

## Swapping the provider

The provider is one RGD file. `task crossplane && task rgd:gcp` switches the
same generic API to a Crossplane-based GCP translation against the
floci-gcp emulator (`providers/gcp-crossplane/`); real AWS S3 is a
credentials/endpoint change in `hack/providers.yaml`. See
[docs/DEVELOPMENT.md](../../docs/DEVELOPMENT.md) for extending to other
providers and other object types (databases, queues, ...).

A previous iteration of this example additionally demonstrated a
checksum-verified **live migration** between two providers (initial sync,
cutover via one spec patch, delta sync, verify); that variant used two
MinIO instances and was removed to keep this example minimal. The
resource-broker integration (`examples/broker-buckets/`) is where
multi-provider routing and migration live going forward.
