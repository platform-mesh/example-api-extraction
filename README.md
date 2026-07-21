# example-api-extraction

Worked examples for **standardized, vendor-neutral IaaS APIs on Platform Mesh**:
a consumer orders against one generic API, and the
[resource-broker](https://github.com/platform-mesh/platform-mesh/tree/main/operators/resource-broker)
routes the order to a matching provider by capability/policy — the "API
extraction" idea made concrete.

## Structure

The example providers live in `providers/`, one cloud provider per directory.
Resources installed into the provider workspace go into `providers/<provider>/manifests/`.

The broker and platform setup happens in `platform/`.
The example resources deployed for the consumer are in `comsumer/`.

The generic API and coordination CRDs are vendored under `config/`.

The consumer's binding and order are in `consumer/`.
`kind/manifests/` holds the floci fake-cloud storage backends.

The overarching play-by-play resource changes are documented in `DEMO.md`.

## Runnable example

[`examples/simple-bucket/`](examples/simple-bucket/) is a verified
end-to-end run of the extraction chain on one kind cluster and one kcp
workspace: a generic `Bucket` order (storage.opendefense.cloud) is
translated by a kro RGD into a vendor S3 resource and fulfilled on the
floci S3 emulator - credentials Secret and status flow back to the
consumer. `task all` (or `make run-all`) drives everything; see the example
README.
