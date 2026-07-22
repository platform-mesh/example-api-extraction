# azure-prod: the standard API backed by Azure Service Operator (region `nl`)

This provider serves the same `storage.example.io/ObjectStorage` API as
gcp/azure/aws/gcp-prod — but the realization is [Azure Service Operator v2
(ASO)](https://github.com/Azure/azure-service-operator) driving **real Azure**,
instead of the RGD-to-curl-job pattern:

```
ObjectStorage {region: nl}                       (consumer, standard API)
  → resource-broker → staging → krop instance    (root:azure-prod)
  → host-target resources (the krop blueprint):
      ResourceGroup                          resources.azure.com/v20200601
      StorageAccount   (StorageV2, Std_LRS)  storage.azure.com/v20250601
      StorageAccountsBlobService             storage.azure.com/v20250601
      StorageAccountsBlobServicesContainer   storage.azure.com/v20250601
  → ASO controller → Azure ARM → real Azure storage
  → StorageAccount.status.primaryEndpoints.blob → blueprint status → ObjectStorage.status.url
```

The krop blueprint maps the standard type onto ASO's Azure CRDs declaratively —
no Crossplane, no XRD/Composition, no adapter (simpler than gcp-prod). Migration
away is fully declarative: deleting the staged instance triggers OwnerRef GC of
the ASO resources, which ASO deletes from Azure via the ownership chain.

## Why real Azure (not floci)

gcp-prod runs against the floci-gcp emulator because a GCS bucket-create *is* a
data-plane REST call, so terraform just repoints its endpoints. ASO always
provisions through **Azure ARM** (`management.azure.com`), and the `floci-az`
emulator is Azurite-style **data-plane only** (Blob REST on `:4577`, no ARM
surface). There is no emulator shortcut, so azure-prod targets real Azure in both
demo and CI.

## Credentials

ASO needs an Azure service principal. Create the real secret from the template
(the real file is gitignored; `setup.bash azure-prod` fails if it is missing):

```bash
az ad sp create-for-rbac -n aso-example-api --role Contributor \
  --scopes /subscriptions/<SUBSCRIPTION_ID>

cp providers/azure-prod/host/aso-controller-settings.secret.example.yaml \
   providers/azure-prod/host/aso-controller-settings.secret.yaml
# fill AZURE_SUBSCRIPTION_ID / AZURE_TENANT_ID / AZURE_CLIENT_ID / AZURE_CLIENT_SECRET
```

Same credential convention as gcp-prod's `clusterproviderconfig.yaml.example` — a
committed `.example` template documents the shape; the real values live in a file
`setup.bash` guards on. gcp-prod commits its real file (floci fake values);
azure-prod gitignores it (real values, required).

## Run

```bash
./setup.bash azure-prod
```

Not part of the default `setup` chain (installs ASO + cert-manager). Then order
with `region: nl` (or migrate an existing order):

```bash
kubectl patch objectstorage bucket1 --type merge -p '{"spec":{"region":"nl"}}'
```

The storage account name carries a uniqueness suffix (Azure account names are
globally unique, 3–24 chars, lowercase alphanumeric) — the blueprint's naming
policy.

## Pieces

| Path | What |
|---|---|
| `manifests/blueprint-objectstorage.yaml` | krop blueprint: host-target ASO resources |
| `host/aso-controller-settings.secret.example.yaml` | credential template (real file gitignored) |
| `../krop/azure-prod/` | krop-controller kustomization + AcceptAPI (region `nl`) |

ASO install (Helm chart `aso2/azure-service-operator`, `crdPattern` limited to
`resources.azure.com/*;storage.azure.com/*`) and cert-manager are installed by
`_host_azure_prod` in `setup.bash`.

Region carve-out: the job-based azure provider keeps `ap`; `nl` routes here
(Azure West Europe, Amsterdam).
