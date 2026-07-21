# example-api-extraction

Worked examples for **standardized, vendor-neutral IaaS APIs on Platform Mesh**:
a consumer orders against one generic API, and the
[resource-broker](https://github.com/platform-mesh/platform-mesh/tree/main/operators/resource-broker)
routes the order to a matching provider by capability/policy — the "API
extraction" idea made concrete.

## Structure

The example providers live in `providers/`, one cloud provider per directory.
Resource installed into the provider workspace go into `providers/<provider>/manifests/`.

The broker and platform setup happens in `platform/`.
The example resources deployed for the consumer are in `comsumer/`.

Each provider documents its own setup.
The overarching play-by-play resource changes are documented in `DEMO.md`.
