# single-cluster: dispatch realization

kro allows exactly one RGD per GVK on a cluster. The per-provider RGDs in
`providers/{gcp,aws}` assume one compute cluster per provider (the upstream
resource-broker layout); on a shared kind cluster the second `kubectl apply`
silently replaces the first — orders would then all run the wrong realization.

For the single-cluster demo apply THIS RGD instead of the two per-provider ones:

```bash
kubectl apply -f providers/single-cluster/manifests/rgd-objectstorage.yaml
```

One Job realizes both clouds — the shell branches on `spec.region`
(`us` → floci-aws/S3 via unauthenticated path-style `PUT`, anything else →
floci-gcp/GCS via JSON API). One curl image, no aws-cli needed.

The kcp/broker wiring is unchanged: two provider workspaces, two syncagents
(landing namespaces `gcp-orders` / `aws-orders`), two AcceptAPIs. Only the
compute-side realization is shared.
