# Demo

A consumer orders a vendor-neutral storage `Object`; the resource-broker routes
it to a provider by `spec.region` (`eu` → GCP, `us` → AWS, `ap` → Azure) and
the bucket is created in the matching floci fake-cloud backend. Changing the
region migrates the object to the other provider, copying the actual bucket
contents via `rclone` (`platform/object-storage-migrator/copy-objects.sh`).

## Rebuilding the whole stack from scratch

Only needed after a teardown, or to get a known-clean environment. Destructive
— confirm before running against a cluster you care about.

```bash
# 1. Teardown (adjust names/scope to what you actually have running)
kind delete cluster --name platform-mesh
docker rm -f proxy-k8s-io proxy-ghcr proxy-quay   # optional, self-heal on next start.sh

# 2. Rebuild the base platform (separate repo)
cd ../../helm-charts     # wholeplatformmeshrepo/helm-charts, relative to this repo
task local-setup         # or: ./local-setup/scripts/start.sh

# 3. Manual, UI-driven (not scriptable): open https://portal.localhost:8443
#    - register a user
#    - create an organisation (name must be RFC 1035: lowercase, hyphens,
#      starts with a letter, e.g. "kubermatic-demo")
#    - create an account inside it

# 4. Deploy this PoC on top
cd ../example-api-extraction    # (or wherever apiextractfork/example-api-extraction lives)
./setup.bash
```

`./setup.bash` alone deploys the broker, all three providers (gcp/aws/azure)
and a first order (`bucket1`, region `eu`). If you only need to (re)apply the
provider wiring without redoing workspaces/broker/consumer, use
`./setup.bash krop-providers`.

Background on what happens between order and realization — the handoff from
the generic API to the provider API — is in
[generic-to-provider-api.md](generic-to-provider-api.md).

## Play-by-play

1. Register a user in local-setup
2. Create an organisation and an account
3. Bind the generic ObjectStorage from the Marketplace
4. Create an ObjectStorage in the UI (or via kubectl) targeting a region:

   ```bash
   KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl apply -f - <<EOF
   apiVersion: storage.example.io/v1alpha1
   kind: ObjectStorage
   metadata: {name: demo1}
   spec: {region: us}   # eu -> gcp, us -> aws, ap -> azure
   EOF
   KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl wait \
     objectstorage/demo1 --for=jsonpath='{.status.status}'=Available --timeout=5m
   ```

5. See the resource in floci — `status.url` shows the provider-specific URI
   (`s3://demo1`, `gs://demo1`, `az://demo1`).

6. Write data to it, and watch it live via the rclone web GUI:

   ```bash
   kubectl --context kind-platform-mesh apply -f hack/rclone-ui.yaml
   kubectl --context kind-platform-mesh wait pod/rclone-ui --for=condition=Ready --timeout=90s
   kubectl --context kind-platform-mesh port-forward pod/rclone-ui 5572:5572 &
   ```

   Open http://localhost:5572/ (Login with blank credentials — the page
   always shows a login form, but the pod runs with `--rc-no-auth` so any
   input works). The file explorer's remote dropdown has `aws`/`gcp`/`azure`,
   pre-configured to the matching floci backend — pick the one your order
   landed on and browse into the bucket (named after the order).

   Upload a test object either from the GUI, or from the CLI:

   ```bash
   kubectl --context kind-platform-mesh exec rclone-ui -- sh -c \
     'echo "hello" | rclone rcat aws:demo1/hello.txt'   # swap aws: for gcp:/azure: to match your order's provider
   ```

7. Update ObjectStorage to target another region and watch the migration:

   ```bash
   KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl patch \
     objectstorage demo1 --type merge -p '{"spec":{"region":"ap"}}'
   ```

   Switch the GUI to the destination remote (e.g. `azure`) and browse to the
   same bucket name *before* patching so you can watch it go from empty to
   populated — the migration Job typically finishes in 30-45s. To confirm
   from the CLI instead:

   ```bash
   KUBECONFIG=kubeconfigs/workspaces/consumer.kubeconfig kubectl get objectstorage demo1 \
     -o jsonpath='{.status.url}'   # flips e.g. s3://demo1 -> az://demo1
   ```

8. See the resource in the other floci instance and read the data from there:

   ```bash
   kubectl --context kind-platform-mesh exec rclone-ui -- rclone ls azure:demo1
   ```

   Note this is a create-only PoC: cutover doesn't delete the source bucket,
   so the object also still exists at the origin (e.g. `rclone ls aws:demo1`
   still shows it).
