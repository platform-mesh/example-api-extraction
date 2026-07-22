# AWS provider (Path B / krop, region us)

The AWS provider follows **Path B**: krop-controller per provider workspace,
blueprint-resident realization, no api-syncagent. It mirrors the verified gcp
provider exactly — same chain (broker routing, order, cross-provider
migration), different realization: an idempotent S3 `PUT` against the
in-cluster floci-aws instead of the GCS `POST`.

## What is wired

- **`_provider_aws` in [`setup.bash`](../../setup.bash)**: workspace
  `root:aws`, krop-controller (release `krop-aws`, namespace `aws`), blueprint
  + `jobs.batch` schema CRDs, then `krop::register aws` (blueprint publish +
  AcceptAPI). Runs as part of `./setup.bash setup`; standalone via
  `./setup.bash aws`.
- **[`manifests/blueprint-objectstorage.yaml`](manifests/blueprint-objectstorage.yaml)**:
  host-target Job, `PUT http://floci-aws.floci-aws.svc.cluster.local:4566/<bucket>`
  (unauthenticated path-style, verified live; 200|409 = success),
  `status.url = s3://<name>`.
- **[`../krop/aws/acceptapi.yaml`](../krop/aws/acceptapi.yaml)**: registers the
  krop-published export with the broker for region `us`.
- **floci-aws** (S3, `:4566`, LocalStack-compatible): deployed in-cluster by
  `_floci` from `kind/manifests/floci-aws.yaml` (service
  `floci-aws.floci-aws.svc.cluster.local:4566`). No Docker socket needed for
  S3; `aws s3api` works too, but the blueprint only needs curl.

The `manifests/{acceptapi,publishedresource-objectstorages,rgd-objectstorage}.yaml`
files are the legacy Path A (api-syncagent) variant, kept for comparison — do
not register both paths for the same region at the same time.

## Acceptance test + migration finale

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

**The finale** (mechanics proven live across providers, 37s incl. cutover):
patch a standing order's region — the broker migrates it from the gcp provider
to aws:

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
   the leftover and floci answers 409 — the blueprint treats it as success
   (a `curl -sf` would crash-loop the Job forever).
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
