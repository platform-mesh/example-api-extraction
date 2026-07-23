# From the generic API to the provider API

How does a consumer's vendor-neutral `ObjectStorage` order become a
provider-specific realization? Short answer: **the broker never transforms the
object — it moves it between two APIExports of the same GVK.** The actual
field mapping happens inside the provider, in the krop blueprint. This
document walks the whole conversion, with object dumps from a live run.

The non-technical version first — the same five steps this document details:

![The order flow: customer fills one generic order form, the marketplace broker
picks a provider by region, hands over the same form without translation, the
provider workshop (blueprint) turns it into a real cloud bucket, and the status
flows back](generic-to-provider-api.png)

## Two APIExports, one GVK

The whole design rests on the same GroupVersionKind
(`storage.example.io/v1alpha1, ObjectStorage`) being exported **twice**, by
different owners, with independent schemas:

| | Generic (platform) export | Provider export |
|---|---|---|
| Name | `objectstorages` | `objectstorages.storage.example.io` |
| Lives in | the provisioned broker workspace (`root:providers:resource-broker-*`) | each provider workspace (`root:gcp`, `root:aws`, `root:azure`) |
| Schema source | CRD snapshot [`config/generic/crd/storage.example.io_objectstorages.yaml`](config/generic/crd/storage.example.io_objectstorages.yaml), applied by `kcp::apiexport` in setup.bash | published by the **krop Registrar** from the blueprint's `spec.schema` (`providers/<p>/manifests/blueprint-objectstorage.yaml`) |
| Bound by | consumers (portal "Enable" / `consumer/apibinding-objectstorages.yaml`) | the broker's staging workspaces |
| Watched by | resource-broker (via the export's virtual workspace) | the provider's krop-controller (via ITS export's virtual workspace) |

The consumer only ever sees the generic export. The provider's controller only
ever sees its own export. Neither side binds the other's API — the broker is
the only component that touches both.

## The handoff, step by step

1. **Order.** The consumer creates an `ObjectStorage` in its workspace; the
   object is served through the generic export. The broker sees it in the
   generic export's virtual workspace.

2. **Match.** Every provider registered itself with an `AcceptAPI` in its own
   workspace (`providers/krop/<p>/acceptapi.yaml`): the GVR it serves, the
   name of ITS APIExport, and filters over spec fields:

   ```yaml
   spec:
     apiExportName: objectstorages.storage.example.io   # the PROVIDER export
     filters:
       - key: region
         valueIn: [eu]        # aws: [us], azure: [ap]
     gvr: {group: storage.example.io, resource: objectstorages, version: v1alpha1}
   ```

   The broker matches the order's `spec.region` against the filters and picks
   the provider.

3. **Assignment.** The broker records the decision in `root:resource-broker`
   (live dump, demo order `bucket1`):

   ```yaml
   # kubectl get assignment -o yaml (spec)
   acceptAPIName: objectstorages.storage.example.io
   consumerCluster: objectstorages#xeqc7wgqvzsa11eh   # generic export + consumer cluster
   providerCluster: 269y9wbw0yddjuzl                  # root:gcp's logical cluster
   gvr: {group: storage.example.io, resource: objectstorages, version: v1alpha1}
   name: bucket1
   namespace: default
   ```

4. **The conversion moment: the staging workspace.** The broker creates a
   staging workspace under `root:resource-broker:staging` whose APIBinding
   points at the **provider's** export — and copies the instance into it:

   ```
   # APIBindings inside staging-8c272d03108194fc (live dump)
   NAME                                PATH               EXPORT
   objectstorages.storage.example.io   269y9wbw0yddjuzl   objectstorages.storage.example.io

   # the copied instance, same GVK, now served by the provider schema
   NS        NAME      REGION   STATUS      URL
   default   bucket1   eu       Available   gs://bucket1
   ```

   This copy is **structural**: no field is renamed, dropped, or rewritten.
   "Conversion" here means the object is now served by the provider's schema
   and visible in the provider's virtual workspace — nothing more.

5. **Realization.** The provider's krop-controller sees the staging copy
   through its APIExport virtual workspace and instantiates the blueprint's
   resource graph. This is where generic fields actually become
   provider-specific ones (next section).

6. **Status flows back.** The blueprint's status expressions write
   `status.url` / `status.status` on the staging copy; the broker syncs status
   (and `status.relatedResources`) back to the consumer's object under the
   generic export. The consumer never learns which provider fulfilled the
   order — except through the URL scheme (`gs://` vs `s3://` vs `az://`).

## Where fields are actually mapped: the blueprint

The krop blueprint plays a double role — its `spec.schema` **defines the
provider's API** (what the Registrar exports), and its `spec.resources`
**consume that schema via CEL** to produce provider-native children on the
host cluster. The mapping for the gcp provider
([`providers/gcp/manifests/blueprint-objectstorage.yaml`](providers/gcp/manifests/blueprint-objectstorage.yaml)):

| Generic field | Consumed by | Becomes |
|---|---|---|
| `metadata.name` | template CEL `${schema.metadata.name}` | bucket name (GCS/S3/az container), Job name |
| `spec.region` | broker AcceptAPI filter only | provider CHOICE — the realization itself never branches on it in the krop layout (one provider = one region) |
| `spec.versioning` | (accepted, unused in the PoC) | — |
| — | template CEL `${"gs://" + schema.metadata.name}` stamped as a child annotation | `status.url` (read back via `.?annotations[...]` — status expressions cannot reference `schema`) |
| — | `readyWhen` on the child (`status.succeeded > 0`) | `status.status`: `Provisioning` → `Available` |

The provider is free to realize the child however it wants — a curl Job
against floci (gcp/aws/azure), a production adapter chain (gcp-prod:
CloudAPI Bucket CRD → provider-gcp → Crossplane/terraform), or an
ASO/Crossplane CR directly. The generic API never changes.

## The compatibility contract

Because the handoff is a schema-blind copy, generic and provider schemas must
stay compatible by convention:

- **Spec, downward:** every spec field a consumer can set must exist in the
  provider schema (currently `region`, `versioning`). An unknown field would
  be rejected/pruned when the broker applies the copy into staging.
- **Status, upward:** every status field a provider writes must exist in the
  generic schema (`status`, `url`, `conditions`, `relatedResources`) — or the
  write-back silently loses it.
- **Filters:** AcceptAPI filter keys must be spec fields of the generic
  schema; the broker evaluates them on the consumer's object.
- **Version:** both exports serve `v1alpha1`. Schema evolution means evolving
  BOTH the CRD snapshot in `config/generic/crd/` and every blueprint's
  `spec.schema` in lockstep.

## Migration is the same conversion, twice

Patching `spec.region` re-runs the match: a different AcceptAPI wins, the
broker creates a new Assignment plus staging workspace at the target provider,
runs the data-copy stage (`Migration` + `MigrationConfiguration`, see
[`platform/object-storage-migrator/`](platform/object-storage-migrator/)) with
the two `status.url`s as origin/destination, then cuts over: the consumer's
status flips (`gs://bucket1` → `s3://bucket1`) and the old staging copy is
torn down. The realization must therefore be **idempotent on create** (409 =
success) — migrating back re-creates over leftovers.

## Contrast: Path A (api-syncagent)

The syncagent-based variant (`setup.bash syncagent-gcp`) does the conversion
at a different boundary: a `PublishedResource`
([`providers/gcp/manifests/publishedresource-objectstorages.yaml`](providers/gcp/manifests/publishedresource-objectstorages.yaml))
projects workspace objects onto the compute cluster, renaming them via a
naming template and stamping the original name as the
`syncagent.kcp.io/remote-object-name` annotation; a kro RGD on the compute
cluster then consumes them. Same generic API, same broker handoff — only the
provider-side machinery differs. Path B (krop) folds that projection into the
blueprint, which is why it needs no syncagent.
