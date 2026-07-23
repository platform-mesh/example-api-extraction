# Demo

A consumer orders a vendor-neutral storage `Object`; the resource-broker routes
it to a provider by `spec.region` (`eu` → GCP, `us` → AWS) and the bucket is
created in the matching floci fake-cloud backend. Changing the region migrates
the object to the other provider.

## Prerequisites

A running Platform Mesh local-setup, then deploy the base setup:

```bash
./setup.bash
```

Background on what happens between order and realization — the handoff from
the generic API to the provider API — is in
[generic-to-provider-api.md](generic-to-provider-api.md).

## Play-by-play

1. Register a user in local-setup

2. Create an organisation and an account

3. Bind the generic ObjectStorage from the Marketplace

4. Create an ObjectStorage in the UI targeting REGION

5. See the resource in floci

TODO

6. Write data to it

TODO

7. Update ObjectStorage to target another REGION

Watch the migration

8. See the resource another floci instance and read the data from there

TODO
