# Example: vendor-neutral IaaS API via resource-broker (floci-gcp + floci-aws, kind)

**Status: scaffold — not yet executed/verified.** A runbook to click through at the
IPCEI hackathon (Potsdam, 2026-07-21…24, topic AE09 "Standardized IaaS APIs").

## What this shows

**One** generic type `storage.generic.platform-mesh.io/Object` (a bucket),
**two** providers (GCP → floci-gcp, AWS → floci-aws), and the
[resource-broker](https://github.com/platform-mesh/platform-mesh/tree/main/operators/resource-broker)
routes the order by `region` — including a live **migration** on region change.
This is the AE09 thesis made tangible: one order, two clouds, provider switch
without a ticket.

```
Consumer (root:consumer)
  Object{region: eu}                       ┌── AcceptAPI region=eu ──▶ GCP provider
        │  binds the generic objects API   │      kro RGD → Job → floci-gcp (gs://…)
        ▼                                  │
  resource-broker  ── routes by region ────┤
   (root:platform, Staging/Assignment)     │
                                           └── AcceptAPI region=us ──▶ AWS provider
   region eu→us  ⇒  Migration, cutover           kro RGD → Job → floci-aws (s3://…)
```

The building block underneath — Crossplane/provider-terraform against a single
floci emulator — was verified in an earlier GCP spike (one provider, wired
statically through the api-syncagent). This example adds the **routing layer** on
top (the broker) and a **second** provider; realization here goes through **kro**
(the upstream pattern), not Crossplane.

## Architecture decisions (fixed)

- **Realization: kro RGD**, not Crossplane — like the upstream examples
  (`broker-certificates`, `broker-postgres`). kro generates the provider CRD from
  the RGD itself and relays it onto a Kubernetes workload.
- **kro target: a Job with a CLI** (`curl` against floci-gcp, `aws` against
  floci-aws) — guaranteed to run locally, zero Crossplane. Analogous to the
  `kropg` provider (Postgres as a plain Deployment). ACK / Config Connector with
  an endpoint override would be the "this is what it looks like for real" upgrade.
- **Topology: a single kind cluster.** The examples use three (platform + 2
  providers); here it collapses onto one node — broker + kro + both floci +
  2× syncagent. kcp workspaces stay logically separate.

## Layout

```
manifests/floci-gcp.yaml          Emulator GCS  (:4588)
manifests/floci-aws.yaml          Emulator S3   (:4566)   floci/floci:latest (verified)
platform/README.md                the two platform APIExports (main hand-wiring)
providers/gcp/acceptapi.yaml      region=eu  ──┐
providers/gcp/rgd-object.yaml     kro → floci-gcp
providers/gcp/publishedresource-objects.yaml   syncagent → root:providers:gcp
providers/aws/…                   same, region=us → floci-aws
consumer/apibinding-objects.yaml  consumer binds the generic API
consumer/order-object.yaml        the order + migration patch (in the comment)
tasks/todo.md                     ordering, open points, risks
```

## Runbook

### 0. Prerequisites

`docker`, `kind`, `kubectl`, `helm`, `yq`, `go`, and the
[kcp kubectl plugins](https://docs.kcp.io/kcp/main/setup/kubectl-plugin/)
(via krew; `export PATH="${KREW_ROOT:-$HOME/.krew}/bin:$PATH"`).

Sparse-checkout the resource-broker repo:

```bash
git clone --depth 1 --filter=blob:none --sparse \
  https://github.com/platform-mesh/platform-mesh.git pm
cd pm && git sparse-checkout set operators/resource-broker
cd operators/resource-broker
source ./hack/lib.bash    # helm::install::* helpers
```

### 1. One kind cluster + base

The example `run.bash` builds three clusters; we take one and set up the base with
the same helpers (all against a single kubeconfig):

```bash
kind create cluster --name broker-poc
KC=~/.kube/config
helm::install::certmanager "$KC"
helm::install::etcddruid   "$KC"
helm::install::kcp         "$KC"
helm::install::kro         "$KC"
```

> If the helpers expect cluster-specific names: use `_setup()` / `_provider_setup()`
> in `examples/broker-postgres/run.bash` as a template and reduce the `kind create`
> lines to a single cluster.

### 2. kcp workspaces + platform exports

Take the structure from `broker-postgres/run.bash _setup`:

```
root:platform                      (+ AcceptAPI export, + generic objects export)
root:platform:broker               (Assignment/Migration/StagingWorkspace)
root:platform:broker:staging
root:platform:broker:verification
root:providers:gcp                 (type universal, manual APIBinding)
root:providers:aws
root:consumer
```

Provide the **generic `objects` export** → see `platform/README.md` (the only
larger piece of hand-wiring: CRD→ARS→APIExport). All workspaces of type
`universal` with a manual APIBinding — **never** create `org`/`account` directly
(a lesson from an earlier kcp spike: they otherwise hang in the
`root:security` initializer).

### 3. Start the broker

```bash
./examples/broker-postgres/run.bash start-broker   # builds & starts the broker in the cluster
```

### 4. Set up providers (GCP & AWS)

For both providers (`gcp`, `aws`) — the kubeconfig points at the same cluster
here, only the target workspace differs:

```bash
# Emulators
kubectl apply -f manifests/floci-gcp.yaml
kubectl apply -f manifests/floci-aws.yaml

# per provider: kro RGD (creates the Object CRD) + syncagent PublishedResource
kubectl apply -f providers/gcp/rgd-object.yaml
kubectl apply -f providers/aws/rgd-object.yaml
# install api-syncagent per provider (helm::install::api_syncagent … "objects" …),
# then:
kubectl apply -f providers/gcp/publishedresource-objects.yaml
kubectl apply -f providers/aws/publishedresource-objects.yaml

# per provider: bind the AcceptAPI export, then create the AcceptAPI
#   (APIBinding acceptapis in the respective provider workspace — manifest as in
#    the Postgres example, permissionClaims: secrets get/list/watch)
kubectl --context …:providers:gcp apply -f providers/gcp/acceptapi.yaml
kubectl --context …:providers:aws apply -f providers/aws/acceptapi.yaml

# both AcceptAPIs must become Ready (broker verifies bindability):
kubectl wait acceptapi/objects.storage.generic.platform-mesh.io --for=condition=Ready --timeout=5m
```

### 5. Order (consumer)

```bash
kubectl --context …:consumer apply -f consumer/apibinding-objects.yaml
kubectl --context …:consumer wait apibinding/objects --for=condition=Ready --timeout=5m
kubectl --context …:consumer apply -f consumer/order-object.yaml
```

Expectation: the broker creates an `Assignment` (→ GCP), stages the Object, the
syncagent pulls it onto the compute cluster, the kro Job creates
`gs://bucket-from-consumer` in floci-gcp, and `status.url` shows up in the
consumer workspace.

Cross-check at the emulator:

```bash
kubectl -n floci-gcp run verify --rm -i --restart=Never --image=curlimages/curl -- \
  -s 'http://floci-gcp.floci-gcp.svc.cluster.local:4588/storage/v1/b?project=test-project'
```

### 6. Migration eu → us (the highlight)

```bash
kubectl --context …:consumer patch object bucket-from-consumer \
  --type merge -p '{"spec":{"region":"us"}}'
```

The broker creates a `Migration`, stages it at the AWS provider, both serve briefly
in parallel, then cuts over: `s3://bucket-from-consumer` in floci-aws, the GCP copy
is torn down, and `status.url` now points at S3.

```bash
kubectl -n floci-aws run verify --rm -i --restart=Never --image=amazon/aws-cli:2.31.14 \
  --env AWS_ACCESS_KEY_ID=test --env AWS_SECRET_ACCESS_KEY=test -- \
  --endpoint-url http://floci-aws.floci-aws.svc.cluster.local:4566 s3api list-buckets
```

### Cleanup

```bash
kind delete cluster --name broker-poc
```

## Known limits / risks

See `tasks/todo.md`. In short: create-only Jobs (no bucket delete on cutover;
floci is ephemeral) and the generic `objects` APIExport is the only notable piece
of hand-wiring. (floci-aws is verified: image `floci/floci:latest`, port 4566.)
