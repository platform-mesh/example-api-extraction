# AWS provider — handover (Path B / krop)

The AWS provider is implemented separately. The team has decided on **Path B**:
krop-controller per provider workspace, blueprint-resident realization, no
api-syncagent. This documents the interface: what exists, what to build, and
the traps already found. **The gcp provider is the verified blueprint** — the
whole chain (broker routing, order, cross-provider migration) has been executed
live against it; `_provider_gcp` in [`setup.bash`](../../setup.bash) is the
exact working sequence.

## What already exists

- **`_provider_aws` in setup.bash** deploys the infrastructure: workspace
  `root:aws`, krop-controller (release `krop-aws`, namespace `aws`), blueprint +
  `jobs.batch` schema CRDs, floci as a docker container on the kind network.
  Run it via `./setup.bash krop-providers` (or call the function alone).
- **floci-aws** (S3, `:4566`, LocalStack-compatible): verified — an
  unauthenticated path-style `PUT /<bucket>` creates a bucket; `aws s3api`
  works too, no Docker socket needed for S3. If you prefer the in-cluster
  variant with a stable service DNS name, `kind/manifests/floci-aws.yaml` is
  already applied by the gcp setup (service
  `floci-aws.floci-aws.svc.cluster.local:4566`).
- **The broker side is up** and treats krop-published exports like any other
  (verified): AcceptAPI verification, routing, staging, migration all work.
- **A verified AWS blueprint variant already exists** (used live in the
  cross-architecture migration test): the gcp blueprint with the S3 `PUT`
  instead of the GCS `POST` — see the `s3://` twin in
  [PR #10's blueprint comment](https://github.com/platform-mesh/example-api-extraction/pull/10#issuecomment-5043180426).

## What you need to build

Mirror the gcp additions (three small files + the `_provider_gcp` tail):

1. **`providers/krop/aws/blueprint-objectstorage.yaml`** — copy
   [`providers/krop/gcp/blueprint-objectstorage.yaml`](../krop/gcp/blueprint-objectstorage.yaml)
   and change: the Job namespace to `aws` (must match the krop-controller
   namespace), the URL prefix to `s3://`, and the create call to the idempotent
   S3 PUT:
   ```sh
   code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
     "http://floci-aws.floci-aws.svc.cluster.local:4566/$BUCKET")
   case "$code" in 200|409) echo "ok ($code)";; *) echo "unexpected HTTP $code"; exit 1;; esac
   ```
2. **`providers/krop/aws/acceptapi.yaml`** — copy the gcp one, filter
   `region: valueIn: [us]`.
3. **Wire it in `_provider_aws`** like the `_provider_gcp` tail: apply the
   blueprint into `root:aws` (wait for `status.exportedAPI`), bind `acceptapis`
   from the provisioned broker workspace (`provider::path` helper), apply the
   AcceptAPI, wait `Ready`.

## Acceptance test + the Friday finale

```bash
# fresh us order through the broker:
KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl apply -f - <<EOF
apiVersion: storage.example.io/v1alpha1
kind: ObjectStorage
metadata: {name: us1}
spec: {region: us}
EOF
KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl wait \
  objectstorage/us1 --for=jsonpath='{.status.status}'=Available --timeout=5m
# expect: status.url = s3://us1
```

**The finale** (mechanics already proven live across providers, 37s incl.
cutover): patch the standing order's region — the broker migrates it from the
gcp provider to yours:

```bash
KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl patch \
  objectstorage bucket1 --type merge -p '{"spec":{"region":"us"}}'
# status.url flips gs://bucket1 -> s3://bucket1, the gcp copy is torn down
```

## Traps already found (all live-verified)

1. **Keep instance names short** until
   [opendefensecloud/krop-controller#8](https://github.com/opendefensecloud/krop-controller/issues/8)
   is fixed: krop stamps the mangled host name (`<cluster>-<name>-<name>-…`) as
   a pod-template **label**, capped at 63 bytes — instance names ≥ ~17 chars
   fail to materialize silently, and a migration then hangs before cutover.
2. **Idempotent creates are mandatory** for migration round-trips: cutover
   never deletes buckets (create-only PoC), so migrating BACK re-creates over
   the leftover and floci answers 409 — treat it as success (see the snippet
   above; a `curl -sf` crash-loops the Job forever).
3. **kro type-checks blueprint children against the workspace API surface** —
   kcp serves neither `batch/v1` nor Pods. `_krop` already applies the minimal
   `jobs.batch` schema CRD; don't remove it.
4. **hostAliases are load-bearing** for every pod talking to kcp VW URLs — the
   `providers/krop/hostaliases` kustomize component handles it (kind-only
   target selector, applies to any Deployment). The `/clusters/root ->
   /clusters/root:<provider>` sed in `_krop` sets the controller's workspace —
   also load-bearing.
5. **Consumer-target resources land in the staging workspace** in the broker
   flow (the instance copy lives there), not at the real consumer —
   `status.url` is the consumer contract; don't rely on consumer-target
   projection for broker-routed orders.

## Debugging pointers

- AcceptAPI not Ready → `kubectl get acceptapi ... -o yaml` (conditions) and
  broker logs: `kubectl -n resource-broker-system logs deploy/resource-broker`
- Blueprint not Published → `kubectl get rgd.krop.opendefense.cloud -o yaml`
  (`BuildFailed` message names the missing schema)
- Order stuck Provisioning → krop logs
  (`kubectl -n aws logs deploy/krop-aws-krop-controller`) and the host Job in
  ns `aws` (watch for the #8 label error).
