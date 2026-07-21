# Platform workspace: the two APIExports

The resource-broker needs two APIExports in the platform workspace
(`root:platform`). Both are created programmatically by `run.bash setup` in the
upstream examples — for this bucket example you provide them once:

## 1. AcceptAPI export (for providers)

Comes ready from the resource-broker repo:
`config/broker/crd/broker.platform-mesh.io_acceptapis.yaml`.
Providers bind this export to create their `AcceptAPI`.

## 2. Generic `objects` export (for consumers)

The broker-backed API that the consumer binds and orders against.
Base CRD is upstream: `config/generic/crd/storage.generic.platform-mesh.io_objects.yaml`.

kcp doesn't want a CRD but an **APIResourceSchema** + **APIExport**. The
CRD→ARS conversion is mechanical (the examples in the resource-broker repo
generate it in `run.bash setup`; a CRD→ARS script from an earlier GCP spike was
also available). Result:

```
APIResourceSchema  v1alpha1.objects.storage.generic.platform-mesh.io
APIExport          objects   (spec.resources[].schema -> the ARS above)
```

> MAIN TODO on site: create this ARS + the `objects` APIExport. It's the only
> larger piece of hand-wiring; everything else (broker, kro, syncagent) comes from
> the repo helpers or the manifests in `providers/` and `consumer/`.

## Broker state workspaces

`root:platform:broker` (holds `Assignment`/`Migration`/`StagingWorkspace`) with
children `staging` and `verification`. Also created by `run.bash setup` — take the
structure 1:1 from the Postgres example.
