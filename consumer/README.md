# ObjectStorageUI — browsable web UI for an existing bucket

`ObjectStorageUI` is a krop blueprint installed directly in the consumer's own
workspace (`root:consumer`), not in a provider workspace. You order one by
naming an existing, `Available` `ObjectStorage` instance; it stands up a
Deployment on the host cluster running rclone's web GUI (`rcd --rc-web-gui`),
pre-configured against that bucket, so you can browse/upload/download files
through a real browser instead of just trusting `status.url`.

```yaml
apiVersion: storage.example.io/v1alpha1
kind: ObjectStorageUI
metadata:
  name: uidemo
spec:
  objectStorageName: bucket1 # must already exist and be Available
```

## Install

```bash
./setup.bash consumer-ui
```

This installs a krop-controller scoped to `root:consumer` (see `_consumer_ui`
in `setup.bash`) and publishes the blueprint
(`consumer/manifests/blueprint-objectstorageui.yaml`).

## Use

```bash
KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl apply -f consumer/order-objectstorageui.yaml
KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl get objectstorageui uidemo -w   # wait for status.uiReady

# find the actual (krop-mangled) Deployment name and port-forward it
DEPLOY=$(kubectl -n consumer-ui get deployment -o name | grep uidemo-ui)
kubectl -n consumer-ui port-forward "$DEPLOY" 5573:5572
```

Open http://localhost:5573/ (blank login — the page always shows a form, but
the pod runs with `--rc-no-auth`). `hostPort: 5572` is used instead of a
Service/NodePort (see "Why no Service" below), and it isn't in this kind
cluster's pre-mapped port list, so port-forward is the way to reach it from a
browser — same as the standalone `hack/rclone-ui.yaml` viewer.

## Known limitations

- **Only one instance at a time on a single-node kind cluster.** `hostPort`
  binds to the *node*, not the pod — a second `ObjectStorageUI` order fails
  to schedule (`didn't have free ports for the requested pod ports`) while
  another one's pod is already bound to `5572`. Delete the first before
  ordering a second, or give each order a distinct `hostPort` if you need
  more than one concurrently (would require templating the port from
  `schema.metadata.name` instead of hardcoding `5572`).
- **Credentials are fetched once, at pod start — not continuously reconciled.**
  If the underlying bucket migrates to a different provider while the UI pod
  is already running, it keeps using the *old* provider's connection info.
  To pick up the new one:
  ```bash
  kubectl -n consumer-ui delete pod -l app=<order-name>-ui
  ```
  A real fix would be a sidecar that polls the credentials Secret instead of
  a one-shot initContainer — not built here, this is the PoC tradeoff.

## Why the blueprint has zero `target: consumer` resources

The obvious design reads the order's `<name>-credentials` Secret through
krop's own `target: consumer` mechanism (either via
`storage.status.relatedResources.credentials`, or directly by the Secret's
predictable name). **Both are permanently broken** for a krop-controller that
isn't broker-routed like this one (no AcceptAPI, no `krop::register`, unlike
gcp/aws/azure) — confirmed with three independent tests, each ruling out one
candidate cause:

**Test 1 — is it a permissions/RBAC gap?**
Granted the krop-controller identity (`system:serviceaccount:krop-system:krop-controller`)
explicit RBAC for the target resource. `kubectl auth can-i` reports allowed;
the real controller request still fails:
```
$ kubectl auth can-i get secrets/bucket1-credentials \
    --as="system:serviceaccount:krop-system:krop-controller" -n default
yes

# but the controller's own log for the identical read:
"external get: secrets \"bucket1-credentials\" is forbidden: ... access denied"
```
Reproduced identically for both a *bound* type (`ObjectStorage`, exported via
APIBinding from the resource-broker's provisioned workspace) and a *plain
core* type (`Secret`, not bound/exported at all) — so it isn't specific to
bound-type routing either.

**Test 2 — does a genuinely more powerful identity change anything?**
Swapped krop-controller's own kcp-facing kubeconfig (the `krop-kubeconfig`
Secret it mounts) from the restricted service account to `kcp-admin` itself —
the same credential `setup.bash` uses everywhere for admin operations, still
scoped to `root:consumer` (same workspace as before, only the identity
changed). Identical failure, just with `User "kcp-admin"` in place of the
service account name. Since `kcp-admin` can do literally everything else in
this cluster, this rules out permissions as the cause entirely.

Also tried the fully unscoped root-level admin kubeconfig (no workspace path
at all) — this **breaks krop-controller outright**: it can't even find its
own `ResourceGraphDefinition` CRD (`no matches for kind
"ResourceGraphDefinition"`). Workspace-scoping to wherever the blueprint and
its CRDs live is required for basic operation, not an optional restriction —
so "give it broader scope" isn't a viable direction at all.

**Test 3 — is it about cross-workspace routing or the broker's plumbing?**
Built the cleanest possible test: installed the required CRDs, a dummy
Secret, a throwaway RGD, and pointed krop-controller's own scope — ALL
directly in `root`, the same single workspace, with genuine `kcp-admin`
identity. Zero cross-workspace anything, zero broker/AcceptAPI involvement at
all. **Still fails identically**:
```
"external get: secrets \"roottest-credentials\" is forbidden: ... access denied"
```

**Conclusion**: this rules out permissions (test 1 + 2), identity power
(test 2), and topology/cross-workspace routing/broker plumbing (test 3) one
at a time, with reproducible tests. `target: consumer`'s "external get"
appears to unconditionally fail in this krop-controller build
(`hackathon-2`), independent of identity or topology. This is a
krop-controller code/design issue to report upstream, not something fixable
from this repo with more RBAC or setup changes.

**Working theory** (unverified — no access to krop-controller's source): the
controller's own logs show it reaches its published type's instances through
a type-scoped virtual-workspace connection
(`https://.../services/apiexport/<cluster>/objectstorageuis.storage.example.io`).
Guess is that `target: consumer` operations reuse that same connection, which
is scoped to carry only the one exported type — so a request for anything
else (a `Secret`, another CRD) gets rejected by the API server as
out-of-scope, which surfaces as `"forbidden"` even though no real RBAC
decision was actually being evaluated. `target: host` doesn't go through this
path at all, which is why it's unaffected.

## Workaround actually used

`ObjectStorageUI`'s Deployment has an `initContainer` that fetches the
credentials Secret itself with a plain `kubectl`, using a reusable
admin-scoped `root:consumer` kubeconfig (`_consumer_ui` in `setup.bash`
stores it once as a host Secret, `consumer-kcp-kubeconfig`) — the exact same
kind of credential this whole `setup.bash` already relies on everywhere else,
just handed directly to the pod instead of routed through krop's broken
mechanism:

1. `_consumer_ui()` stores `$ws_consumer` (already scoped to just
   `root:consumer`) as a plain Kubernetes Secret on the host.
2. The blueprint's `ui` Deployment mounts it into an `initContainer`
   (`docker.io/alpine/k8s:1.31.2` — needs `kubectl` *and* a shell/`base64`,
   several minimal kubectl-only images don't have a shell at all and can't
   run this).
3. That container runs `kubectl get secret <name>-credentials -n default -o
   jsonpath=...` directly against kcp and writes the decoded fields to a
   shared `emptyDir`.
4. The main rclone container sources that file before starting.

One easy-to-hit trap: the `initContainer`'s shell script must use `$VAR`, not
`${VAR}` — the latter collides with krop's own `${...}` CEL templating syntax
and fails the blueprint build with `references unknown identifiers`.

Another: this pod needs the same `hostAliases` mapping
`providers/krop/hostaliases` applies to krop-controller's own Deployment
(`kcp.api.portal.localhost` → the local-setup's traefik ClusterIP) — that
component only patches krop-controller's Deployment, not ones a blueprint
creates at runtime, so it's inlined directly in `ui`'s pod spec instead.

## Why `hostPort` and not a Service/NodePort

Tried a `target: host` `Service` first (the more standard way to expose a
Deployment) — kcp in this workspace cannot resolve core `v1/Service`'s schema
at all, not even via a stub CRD like the ones that work for `jobs.batch` and
`deployments.apps`: CRDs are only ever served under
`/apis/<group>/<version>/...`, never the special-cased core `/api/v1/...`
path, so an empty-group CRD is accepted (kcp doesn't reject it) but inert —
kro's schema resolver still reports `cannot resolve group version kind "/v1,
Kind=Service": schema not found`. `hostPort` on the container achieves the
same "no port-forward, in principle" goal through the Deployment resource,
which does resolve fine.
