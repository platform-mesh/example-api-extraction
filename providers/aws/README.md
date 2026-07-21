# AWS provider — handover

The AWS provider is implemented separately from the rest of this example. This
document is the interface: what already exists, what you need to build, and the
traps we already ran into so you don't have to.

**The GCP provider is the verified blueprint.** Everything described here has
been executed end to end for GCP on a live Platform Mesh local-setup — the
`_gcp_provider` function in [`setup.bash`](../../setup.bash) is the exact,
working sequence. Mirror it with `aws` substituted.

## What already exists

- **Manifests in this directory** — migrated to `storage.example.io/ObjectStorage`
  and bug-fixed (see the traps below), but **not yet wired**:
  - `manifests/rgd-objectstorage.yaml` — kro realization: Job → `aws s3api
    create-bucket` against floci-aws
  - `manifests/publishedresource-objectstorages.yaml` — syncagent publication,
    landing namespace `aws-orders`
  - `manifests/acceptapi.yaml` — registers you with the broker for `region: us`
- **floci-aws** is already deployed by `setup.bash` (`kind/manifests/`):
  image `floci/floci:latest`, S3 on `:4566`, verified — `s3api create-bucket`
  works without a Docker socket, and an unauthenticated path-style
  `PUT /<bucket>` works too if you want to avoid the aws-cli image entirely.
- **The broker side is up**: AcceptAPI APIExport, coordination CRDs, marketplace
  registration and a running broker in `resource-broker-system`.

## What you need to build

Mirror `_gcp_provider` in `setup.bash` (each step is one block there):

1. **kcp workspace `root:aws`** with an **empty APIExport `objectstorages`**
   (the api-syncagent manages the resource schemas).
2. **Bind the `acceptapis` export** from the provisioned broker workspace
   (`root:providers:resource-broker-<suffix>` — derive it with the
   `provider::path` helper; the provisioned kubeconfig's server URL carries the
   logical-cluster ID, not the path).
3. **Realization** — one decision to make first, see below.
4. **api-syncagent** on the compute cluster: admin SA token in `root:aws`,
   kubeconfig against the in-cluster front-proxy
   (`https://frontproxy-front-proxy.platform-mesh-system:8443/clusters/root:aws`),
   secret `kubeconfig-aws`, helm release `api-syncagent-aws`
   (`apiExportName=objectstorages`, `agentName=aws`, **hostAliases — see traps**),
   then `manifests/publishedresource-objectstorages.yaml` + a ClusterRole/Binding
   for `objectstorages(+/status)` bound to the `api-syncagent-aws` SA.
5. **AcceptAPI** (`manifests/acceptapi.yaml`, `region: us`) in `root:aws` and
   wait for `Ready` — that is the broker handshake (it binds your export in a
   verification workspace).

## The realization decision (read before step 3)

**kro allows exactly one RGD per GVK per cluster.** The shared local-setup
cluster already runs the GCP RGD for `objectstorages.storage.example.io` —
applying `manifests/rgd-objectstorage.yaml` there would silently **replace** it
and break the GCP provider (we watched this happen: a stale RGD realized an eu
order against floci-aws). Two clean options:

- **Own compute cluster** (matches the upstream resource-broker layout): a
  second kind cluster with kro + floci-aws + your RGD, and your syncagent runs
  there. Fully independent from the GCP side; needs its own hostAliases story to
  reach kcp (the kind-node-name resolution trick from the upstream
  broker-postgres example).
- **Shared cluster with the dispatch RGD**
  ([`providers/single-cluster/`](../single-cluster/)): replace the GCP RGD with
  the dispatch RGD, which realizes both clouds from one Job branching on
  `spec.region`. You then only build steps 1–2 and 4–5 (workspace, binding,
  syncagent, AcceptAPI) — no own RGD. Coordinate the swap with us, since it
  touches the GCP realization.

For the hackathon (one laptop, one cluster) we recommend the **dispatch RGD**
route.

## Traps we already hit (so you don't)

1. **hostAliases are mandatory** for every pod that talks to kcp virtual
   workspaces (your syncagent!): kcp advertises VW URLs under its external
   hostnames (`root.kcp.localhost`, …), which resolve to `127.0.0.1` inside
   pods. Map them to the pinned traefik ClusterIP `10.96.188.4` — see the helm
   `--set hostAliases...` flags in `_gcp_provider`.
2. **Scoped tokens don't cross workspaces.** SA tokens minted in a workspace are
   scoped to its logical cluster. Fine for the syncagent (it only talks to
   `root:aws`), but don't try to reuse the provisioned provider SA for anything
   that enters child workspaces.
3. **kro YAML/CEL traps** (already fixed in the checked-in RGD — don't
   reintroduce them when editing): quote CEL ternaries (`': '` breaks YAML);
   status expressions are dry-run at RGD build time, so use
   `.?annotations[...].orValue("")` and concatenate string prefixes in CEL
   (literal `s3://${...}` prefixes are dropped); `$BUCKET` not `${BUCKET}` in
   Job shell scripts (CEL delimiter collision).
4. **Workspaces stuck Initializing are painful to delete.** If a workspace ever
   hangs in `Initializing`, fix the cause first; force-deleting leaves ghosts.
   (Removing the finalizers worked for us, but only because the broker
   immediately recreated it with a working identity.)
5. **create-only realization**: the Jobs only create buckets. On migration
   cutover the broker removes the *resource* from the losing provider, but the
   bucket stays in the emulator — fine for the demo, floci is ephemeral.

## Acceptance test

```bash
# via the consumer workspace (setup.bash created it):
KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl apply -f - <<EOF
apiVersion: storage.example.io/v1alpha1
kind: ObjectStorage
metadata:
  name: bucket-us
spec:
  region: us
EOF
KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl wait \
  objectstorage/bucket-us --for=jsonpath='{.status.status}'=Available --timeout=5m
# expect: status.url = s3://bucket-us
```

**The grand finale** (needs both providers Ready): patch the existing eu order
to `region: us` — the broker creates a `Migration`, stages at your provider,
cuts over, and tears down the GCP copy:

```bash
KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl patch \
  objectstorage bucket-from-consumer --type merge -p '{"spec":{"region":"us"}}'
```

## Debugging pointers

- AcceptAPI not Ready → `kubectl get acceptapi ... -o yaml` (conditions carry
  the broker's error) and the broker logs:
  `kubectl -n resource-broker-system logs deploy/resource-broker`
- Orders not arriving on compute → syncagent logs:
  `kubectl -n default logs deploy/api-syncagent-aws`
- Realization stuck → `kubectl -n aws-orders get objectstorages,jobs` and the
  Job pod logs.
