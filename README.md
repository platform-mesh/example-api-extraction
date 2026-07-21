# example-api-extraction

Worked examples for **standardized, vendor-neutral IaaS APIs on Platform Mesh**:
a consumer orders against one generic API, and the
[resource-broker](https://github.com/platform-mesh/platform-mesh/tree/main/operators/resource-broker)
routes the order to a matching provider by capability/policy — the "API
extraction" idea made concrete.

## Examples

### [`examples/broker-buckets`](examples/broker-buckets)

One generic type `storage.generic.platform-mesh.io/Object` (a bucket), two
providers realized entirely locally against
[floci](https://floci.io/) emulators — **GCP → floci-gcp** (GCS) and
**AWS → floci-aws** (S3) — on a single `kind` cluster. The broker routes by
`region` (`eu` → GCP, `us` → AWS) and performs a live **migration** on region
change. Provider realization uses **kro** `ResourceGraphDefinition`s (no
Crossplane), mirroring the upstream `broker-postgres` / `broker-certificates`
examples.

Status: scaffold / runbook — see the example README for the step-by-step and the
open verification points before running.

## Context

Prepared for the IPCEI-CIS / Apeiro hackathon (Potsdam, 2026-07), topic
"Standardized IaaS APIs". The Go module skeleton (`./`, `./api`) is reserved for
shared types / e2e tooling as the examples grow.
