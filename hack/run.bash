#!/usr/bin/env bash
#
# Entry point for every workflow in this PoC. Each subcommand is one
# self-contained step; Taskfile.yml and the Makefile are thin wrappers
# around this script. Run without arguments for usage.
#
# The flow (see examples/simple-bucket/README.md):
#   generic Bucket (kcp workspace) --api-syncagent--> kind cluster
#     --kro RGD--> S3Bucket --S3 operator--> floci-aws (emulated S3)
set -euo pipefail

# cd into the repository root so all paths below are stable.
cd "$(dirname "$(realpath "$0")")/.."
# hack/lib.bash is the resource-broker-derived helper set used by
# setup.bash/platform's flow; this script has its own, differently-shaped
# helpers (trimmed for a single-workspace PoC), kept separate to avoid a
# naming collision - see hack/run-lib.bash.
source ./hack/run-lib.bash

cluster="api-extraction"
kubeconfigs="$PWD/kubeconfigs"
mkdir -p "$kubeconfigs/workspaces"

kind_kubeconfig="$kubeconfigs/kind.kubeconfig"
kcp_admin="$kubeconfigs/kcp-admin.kubeconfig"
kcp_host="$kubeconfigs/kcp-from-host.kubeconfig"
ws_storage="$kubeconfigs/workspaces/storage.kubeconfig"

# ---------------------------------------------------------------------------
_setup() {
    log "1/7 kind cluster '$cluster'"
    kind::cluster "$cluster" "$kind_kubeconfig"

    log "2/7 cluster components: cert-manager, etcd-druid, kcp-operator, kro"
    helm::install::certmanager "$kind_kubeconfig"
    helm::install::etcddruid "$kind_kubeconfig"
    helm::install::kcp_operator "$kind_kubeconfig"
    helm::install::kro "$kind_kubeconfig"

    log "3/7 kcp control plane (RootShard + FrontProxy)"
    kubectl::kustomize "$kind_kubeconfig" ./kcp/manifests
    kcp::setup::kubeconfigs "$kind_kubeconfig" "$kcp_admin" "$kcp_host"

    log "4/7 kcp workspace 'storage' (the single workspace of this PoC)"
    kcp::create_workspace "$kcp_host" "$ws_storage" "storage"

    log "5/7 translation layer: kro RGD (generic Bucket -> S3Bucket)"
    kubectl::apply "$kind_kubeconfig" ./config/crd/s3.opendefense.internal_s3buckets.yaml
    kubectl::apply "$kind_kubeconfig" ./providers/floci-aws/manifests/rgd-bucket.yaml
    # kro instantiates the consumer-facing CRD from the RGD schema:
    KUBECONFIG="$kind_kubeconfig" kubectl wait --for=create \
        crd/buckets.storage.opendefense.cloud --timeout="$timeout"

    log "6/7 storage backend: floci-aws (emulated S3, https://floci.io)"
    kubectl::apply "$kind_kubeconfig" ./kind/manifests/floci-aws.yaml
    kubectl::wait "$kind_kubeconfig" deployment/floci-aws floci-aws condition=Available

    log "7/7 api-syncagent: publish the Bucket API into the workspace and bind it"
    # The agent does NOT create the APIExport itself - it expects an empty
    # APIExport to exist in the workspace and then manages its schemas
    # (same as the kcp-certs example in resource-broker).
    KUBECONFIG="$ws_storage" kubectl apply -f- <<'EOF'
apiVersion: apis.kcp.io/v1alpha1
kind: APIExport
metadata:
  name: buckets
EOF
    # The agent needs a kubeconfig for the workspace, delivered as a secret.
    # Inside the cluster kcp is reachable via the root shard NodePort.
    local token agent_kubeconfig="$kubeconfigs/api-syncagent.kubeconfig"
    token="$(kcp::serviceaccount::admin "$ws_storage" api-syncagent)"
    kubeconfig::create::token "$agent_kubeconfig" "$(kubeconfig::server_url "$ws_storage")" "$token"
    kubeconfig::to_secret "$kind_kubeconfig" "$agent_kubeconfig" kubeconfig-storage \
        "$cluster-control-plane:32111"
    helm::install::api_syncagent "$kind_kubeconfig" kubeconfig-storage
    kubectl::apply "$kind_kubeconfig" ./providers/floci-aws/manifests/publishedresource-buckets.yaml
    # Wait until the agent has processed the PublishedResource and filled
    # the APIExport with the Bucket schema, then bind it.
    local try=0
    until KUBECONFIG="$ws_storage" kubectl get apiexport buckets -o yaml 2>/dev/null \
            | grep -q "buckets.storage.opendefense.cloud"; do
        try=$((try + 1))
        [[ "$try" -gt 150 ]] && die "api-syncagent did not publish the Bucket schema - check: kubectl logs deploy/api-syncagent-storage"
        [[ $((try % 15)) -eq 0 ]] && log "still waiting for the Bucket schema in the APIExport..."
        sleep 2
    done
    kcp::apibinding "$ws_storage" "root:storage" buckets

    _forward
    log "Setup done. Next: 'task provider' (terminal 2), then 'task example'."
}

# Port-forwards from the developer machine into the cluster. Re-run anytime
# they die (laptop sleep etc.).
_forward() {
    log "Starting port-forwards (kcp :8443, floci-aws :4566, floci-gcp :4588)"
    kcp::front_proxy_forward "$kind_kubeconfig" 8443
    if kubectl --kubeconfig "$kind_kubeconfig" get ns floci-aws &>/dev/null; then
        pkill -f "port-forward -n floci-aws" 2>/dev/null || true
        kubectl --kubeconfig "$kind_kubeconfig" port-forward -n floci-aws svc/floci-aws 4566:4566 >/dev/null 2>&1 &
    fi
    if kubectl --kubeconfig "$kind_kubeconfig" get ns floci-gcp &>/dev/null; then
        pkill -f "port-forward -n floci-gcp" 2>/dev/null || true
        kubectl --kubeconfig "$kind_kubeconfig" port-forward -n floci-gcp svc/floci-gcp 4588:4588 >/dev/null 2>&1 &
    fi
    sleep 1
}

# The S3 vendor operator, running locally so logs are in your face.
_provider() {
    log "Running the S3 vendor operator (Ctrl-C to stop)"
    go run ./cmd \
        --kubeconfig "$kind_kubeconfig" \
        --providers-file ./hack/providers.yaml
}

# Background variant for the unattended `all` run: logs go to operator.log.
_provider_bg() {
    pkill -f "example-api-extraction/cmd" 2>/dev/null || true
    pkill -f "providers-file ./hack/providers.yaml" 2>/dev/null || true
    log "Starting the S3 vendor operator in the background (log: operator.log)"
    nohup go run ./cmd \
        --kubeconfig "$kind_kubeconfig" \
        --providers-file ./hack/providers.yaml \
        > operator.log 2>&1 &
    sleep 5
    grep -q "starting operator" operator.log \
        || { cat operator.log; die "operator did not start - see operator.log"; }
}

# ---------------------------------------------------------------------------
_example() {
    log "Ordering a Bucket through the generic API (workspace 'storage')"
    kubectl::apply "$ws_storage" ./examples/simple-bucket/bucket.yaml
    kubectl::wait::contains "$ws_storage" buckets/example-object-storage default \
        ".status.endpoint" "my-bucket"
    _example_status
}

_example_status() {
    log "Bucket in the consumer workspace:"
    KUBECONFIG="$ws_storage" kubectl get buckets -o wide
    KUBECONFIG="$ws_storage" kubectl get bucket example-object-storage -o yaml \
        | yq '.status'
    log "Credentials secret synced back to the consumer:"
    KUBECONFIG="$ws_storage" kubectl get secrets
}

# Show the same bucket at every layer of the chain - THE result of the PoC:
# one generic order, visible as generic API, translated vendor API and real
# storage.
_translation() {
    log "LAYER 1 - consumer view: generic Bucket in the kcp workspace 'storage'"
    KUBECONFIG="$ws_storage" kubectl get buckets.storage.opendefense.cloud -o wide || true
    echo
    log "LAYER 2 - synced copy on the compute cluster (api-syncagent)"
    kubectl --kubeconfig "$kind_kubeconfig" get buckets.storage.opendefense.cloud -A -o wide || true
    echo
    log "LAYER 3 - TRANSLATED vendor API: S3Bucket rendered by the kro RGD"
    kubectl --kubeconfig "$kind_kubeconfig" get s3buckets -A -o yaml | yq '.items[] | {"spec": .spec, "status": .status}' || true
    echo
    log "LAYER 4 - real storage: S3 listing from the floci-aws emulator"
    kubectl --kubeconfig "$kind_kubeconfig" delete job storage-ls -n floci-aws --ignore-not-found --wait=true >/dev/null 2>&1
    kubectl --kubeconfig "$kind_kubeconfig" apply -f- >/dev/null <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: storage-ls
  namespace: floci-aws
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: ls
          image: rclone/rclone:latest
          env:
            - {name: RCLONE_CONFIG_AWS_TYPE, value: s3}
            - {name: RCLONE_CONFIG_AWS_PROVIDER, value: Other}
            - {name: RCLONE_CONFIG_AWS_ENDPOINT, value: "http://floci-aws.floci-aws.svc.cluster.local:4566"}
            - {name: RCLONE_CONFIG_AWS_ACCESS_KEY_ID, value: test}
            - {name: RCLONE_CONFIG_AWS_SECRET_ACCESS_KEY, value: test}
            - {name: RCLONE_CONFIG_AWS_FORCE_PATH_STYLE, value: "true"}
          command: ["/bin/sh", "-ec", "rclone lsd AWS: ; rclone ls AWS:my-bucket | head -12; rclone size AWS:my-bucket"]
EOF
    kubectl --kubeconfig "$kind_kubeconfig" wait --for=condition=Complete job/storage-ls -n floci-aws --timeout=2m >/dev/null 2>&1 \
        && kubectl --kubeconfig "$kind_kubeconfig" logs job/storage-ls -n floci-aws \
        || log "(no bucket yet - run 'task example')"
    echo
    log "LAYER 5 - what the consumer received: credentials Secret in the workspace"
    KUBECONFIG="$ws_storage" kubectl get secrets || true
}

# Everything from the README in one unattended run.
_all() {
    _setup
    _provider_bg
    _example
    _translation
    log "ALL DONE. Operator log: operator.log; re-print results: 'task translation'"
}

# ---------------------------------------------------------------------------
# floci-gcp emulator (https://floci.io) - shared by the Crossplane GCP path
# and the real provider-gcp path below. Idempotent.
_floci_gcp() {
    kubectl::apply "$kind_kubeconfig" ./kind/manifests/floci-gcp.yaml
    kubectl::wait "$kind_kubeconfig" deployment/floci-gcp floci-gcp condition=Available
}

# Crossplane + floci-gcp: the Crossplane-based GCP translation path
# (see providers/gcp-crossplane/manifests/rgd-bucket.yaml).
_crossplane() {
    log "Installing Crossplane"
    helm::install::crossplane "$kind_kubeconfig"
    KUBECONFIG="$kind_kubeconfig" kubectl wait --for=condition=Available=True \
        deployment/crossplane -n crossplane-system --timeout="$timeout"

    log "Deploying the floci-gcp emulator (simulated GCP)"
    _floci_gcp

    log "Installing upbound provider-gcp-storage (pointed at the emulator)"
    kubectl::apply "$kind_kubeconfig" ./providers/gcp-crossplane/manifests/provider-gcp.yaml
    KUBECONFIG="$kind_kubeconfig" kubectl wait --for=condition=Healthy=True \
        providers.pkg.crossplane.io/provider-gcp-storage --timeout="$timeout"
    # The ProviderConfig CRD only exists once the provider is healthy:
    kubectl::apply "$kind_kubeconfig" ./providers/gcp-crossplane/manifests/providerconfig.yaml
    _forward
    log "Crossplane ready. Switch the translation with 'task rgd:gcp'."
}

# Swap the active translation. WARNING: kro deletes and recreates the Bucket
# CRD when the owning RGD changes - existing Bucket instances are lost.
# In this PoC the RGD *is* the provider selection for the whole cluster.
_rgd_gcp() {
    log "Switching translation: Bucket -> Crossplane GCP (deletes existing Buckets!)"
    kubectl --kubeconfig "$kind_kubeconfig" delete -f ./providers/floci-aws/manifests/rgd-bucket.yaml --ignore-not-found
    kubectl::apply "$kind_kubeconfig" ./providers/gcp-crossplane/manifests/rgd-bucket.yaml
    KUBECONFIG="$kind_kubeconfig" kubectl wait --for=create \
        crd/buckets.storage.opendefense.cloud --timeout="$timeout"
}

_rgd_s3() {
    log "Switching translation: Bucket -> S3Bucket/floci-aws (deletes existing Buckets!)"
    kubectl --kubeconfig "$kind_kubeconfig" delete -f ./providers/gcp-crossplane/manifests/rgd-bucket.yaml --ignore-not-found
    kubectl::apply "$kind_kubeconfig" ./providers/floci-aws/manifests/rgd-bucket.yaml
    KUBECONFIG="$kind_kubeconfig" kubectl wait --for=create \
        crd/buckets.storage.opendefense.cloud --timeout="$timeout"
}

# ---------------------------------------------------------------------------
# The REAL provider-gcp controller (sibling checkout ../provider-gcp, see
# its own README "Validating against floci-gcp"), wired into THIS PoC's
# kcp consumer flow instead of a kro RGD.
#
# Architectural difference from every other provider/ in this repo: kro is
# NOT the translator here. provider-gcp is a real Go controller that reads
# the SAME storage.opendefense.cloud/Bucket CRD (regenerated from its
# vendored SDK, so the schema is byte-for-byte what the real controller
# expects - never hand-write it) and renders a GCPBucket
# (gcp.opendefense.cloud) - the internal Crossplane claim provider-gcp
# would normally hand to Crossplane + provider-terraform. Neither of those
# exists here, so this flow drives that missing leg by hand, exactly like
# ../provider-gcp/hack/validate.bash does: send the derived
# bucketName/location/storageClass to floci-gcp for real, then patch
# GCPBucket.status.bucketUrl with the result.
#
#   kcp workspace "storage"  ◄──api-syncagent──►  kind cluster
#     Bucket (consumer)                             Bucket (synced)
#                                                       │ provider-gcp (REAL, unmodified)
#                                                       ▼
#                                                    GCPBucket
#                                                       │ (this script, standing in for
#                                                       │  Crossplane + provider-terraform)
#                                                       ▼
#                                                    floci-gcp (real GCS-compatible API)
#
# WARNING: like rgd:gcp/rgd:s3, this swaps which schema owns the Bucket CRD
# kind and is destructive to existing Bucket instances.
provider_gcp_dir="../provider-gcp"

_provider_gcp_setup() {
    [[ -d "$provider_gcp_dir" ]] \
        || die "Expected the sibling repo at $provider_gcp_dir (github.com:ducke/provider-gcp) - clone it next to this repo first."

    _setup

    log "provider-gcp 1/5: switching translation to the REAL Bucket schema (deletes existing Buckets!)"
    kubectl --kubeconfig "$kind_kubeconfig" delete -f ./providers/floci-aws/manifests/rgd-bucket.yaml --ignore-not-found
    kubectl --kubeconfig "$kind_kubeconfig" delete -f ./providers/gcp-crossplane/manifests/rgd-bucket.yaml --ignore-not-found
    # Regenerate from the vendored SDK on every run so the CRD always
    # matches exactly what the provider-gcp binary being built expects.
    go run sigs.k8s.io/controller-tools/cmd/controller-gen@v0.21.0 \
        crd paths="$provider_gcp_dir/vendor/gitlab.opencode.de/bwi/orca/cloudapi/sdks/go/apis/storage/v1alpha1/..." \
        output:crd:artifacts:config=./config/crd/provider-gcp \
        || die "controller-gen failed (needs network to fetch the tool itself)"
    kubectl::apply "$kind_kubeconfig" ./config/crd/provider-gcp/storage.opendefense.cloud_buckets.yaml
    kubectl::apply "$kind_kubeconfig" ./providers/provider-gcp/manifests/gcpbucket-crd.yaml
    # Correct the credentials Secret path for the real schema (plain string,
    # not {name: string} like our own api/opendefense/v1alpha1) - see the
    # comment in providers/provider-gcp/manifests/publishedresource-buckets.yaml.
    # The agent picks this up live, no restart needed.
    kubectl::apply "$kind_kubeconfig" ./providers/provider-gcp/manifests/publishedresource-buckets.yaml

    log "provider-gcp 2/5: floci-gcp emulator (real GCS-compatible API, no account needed)"
    _floci_gcp

    log "provider-gcp 3/5: building the REAL provider-gcp image from $provider_gcp_dir"
    docker build -t provider-gcp:dev "$provider_gcp_dir" || die "docker build failed"
    kind load docker-image provider-gcp:dev --name "$cluster"

    log "provider-gcp 4/5: deploying provider-gcp"
    kubectl::apply "$kind_kubeconfig" ./providers/provider-gcp/manifests/rbac-and-deploy.yaml
    kubectl::wait "$kind_kubeconfig" deployment/provider-gcp provider-gcp condition=Available

    log "provider-gcp 5/5: port-forwards"
    _forward
}

# Order a Bucket, then stand in for Crossplane + provider-terraform: send
# the exact request provider-gcp derived to floci-gcp and patch the status
# back, so the consumer sees a real, working bucket end to end.
_provider_gcp_example() {
    log "Ordering a Bucket through the generic API (workspace 'storage')"
    # Uses its own sample: the real vendored SDK validates storageClass as
    # lowercase (standard/nearline/...), unlike our own api/opendefense/v1alpha1
    # schema used by the kro-based paths (Standard/Nearline/...).
    kubectl::apply "$ws_storage" ./examples/simple-bucket/bucket-provider-gcp.yaml

    log "Waiting for provider-gcp to render the GCPBucket"
    local try=0 ns name ns_name
    until ns_name="$(kubectl --kubeconfig "$kind_kubeconfig" get gcpbucket -A \
            -o jsonpath='{.items[0].metadata.namespace} {.items[0].metadata.name}' 2>/dev/null)" \
            && [[ -n "$ns_name" ]]; do
        try=$((try + 1))
        [[ "$try" -gt 60 ]] && die "provider-gcp never created a GCPBucket - check: kubectl --kubeconfig $kind_kubeconfig -n provider-gcp logs deploy/provider-gcp"
        sleep 2
    done
    read -r ns name <<<"$ns_name"

    log "translated spec (rendered by the REAL provider-gcp, not by kro):"
    local spec bucket_name location storage_class response bucket_url
    spec="$(kubectl --kubeconfig "$kind_kubeconfig" get gcpbucket "$name" -n "$ns" -o json | jq -c .spec)"
    echo "$spec" | jq .
    bucket_name="$(jq -r .bucketName <<<"$spec")"
    location="$(jq -r .location <<<"$spec")"
    storage_class="$(jq -r .storageClass <<<"$spec")"

    log "standing in for Crossplane/provider-terraform: sending the derived request to floci-gcp"
    response="$(curl -sf -X POST 'http://127.0.0.1:4588/storage/v1/b?project=test-project' \
        -H 'Content-Type: application/json' \
        -d "{\"name\":\"$bucket_name\",\"location\":\"$location\",\"storageClass\":\"$storage_class\"}")" \
        || die "floci-gcp rejected the request derived by provider-gcp - real bug, not a script issue"
    echo "$response" | jq .
    bucket_url="$(jq -r .selfLink <<<"$response")"

    log "writing status.bucketUrl back onto the GCPBucket (what provider-terraform would do)"
    kubectl --kubeconfig "$kind_kubeconfig" patch gcpbucket "$name" -n "$ns" \
        --type merge --subresource status -p "{\"status\":{\"bucketUrl\":\"$bucket_url\"}}"

    log "waiting for the consumer workspace to see the bucket become Ready"
    kubectl::wait::contains "$ws_storage" buckets/example-object-storage default \
        ".status.endpoint" "storage/v1/b"
}

_provider_gcp_translation() {
    log "LAYER 1 - consumer view: generic Bucket in the kcp workspace 'storage'"
    KUBECONFIG="$ws_storage" kubectl get buckets.storage.opendefense.cloud -o wide || true
    echo
    log "LAYER 2 - synced copy on the compute cluster (api-syncagent)"
    kubectl --kubeconfig "$kind_kubeconfig" get buckets.storage.opendefense.cloud -A -o wide || true
    echo
    log "LAYER 3 - TRANSLATED vendor API: GCPBucket rendered by the REAL provider-gcp"
    kubectl --kubeconfig "$kind_kubeconfig" get gcpbuckets -A -o yaml | yq '.items[] | {"spec": .spec, "status": .status}' || true
    echo
    log "LAYER 4 - real storage: bucket listing from the floci-gcp emulator"
    curl -sf 'http://127.0.0.1:4588/storage/v1/b?project=test-project' | jq . \
        || log "(floci-gcp not reachable - run 'task forward')"
    echo
    log "LAYER 5 - what the consumer received: credentials Secret in the workspace"
    KUBECONFIG="$ws_storage" kubectl get secrets || true
}

_provider_gcp_all() {
    _provider_gcp_setup
    _provider_gcp_example
    _provider_gcp_translation
    log "PROVIDER-GCP DONE. Re-print results: 'task provider-gcp:translation'"
}

# ---------------------------------------------------------------------------
_cleanup() {
    log "Removing example resources (cluster stays up)"
    KUBECONFIG="$ws_storage" kubectl delete -f ./examples/simple-bucket/bucket.yaml --ignore-not-found
    KUBECONFIG="$ws_storage" kubectl delete -f ./examples/simple-bucket/bucket-provider-gcp.yaml --ignore-not-found
}

_destroy() {
    log "Deleting kind cluster '$cluster' and kubeconfigs"
    pkill -f "providers-file ./hack/providers.yaml" 2>/dev/null || true
    pkill -f "port-forward" 2>/dev/null || true
    kind delete cluster --name "$cluster"
    rm -rf "$kubeconfigs"
}

# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: hack/run.bash <command>

  all          EVERYTHING unattended: setup, operator (background), example
               bucket, results
  translation  show the bucket at every layer (generic -> vendor -> storage)

  setup        kind + kcp (1 workspace) + kro + floci-aws + api-syncagent
  provider     run the S3 vendor operator locally (blocks; own terminal)
  example      order a Bucket through the generic API and show the result
  status       show the consumer-side view of the Bucket

  crossplane   install crossplane + floci-gcp emulator + provider-gcp
  rgd:gcp      switch translation to GCP/Crossplane (destructive for Buckets)
  rgd:s3       switch translation back to S3/floci-aws (destructive as well)

  provider-gcp             EVERYTHING for the REAL provider-gcp controller
                            (sibling ../provider-gcp checkout): swap the Bucket
                            schema, build+deploy provider-gcp, deploy floci-gcp,
                            order a Bucket, validate against floci-gcp, show
                            results. Destructive for existing Buckets.
  provider-gcp:setup       just the swap + build + deploy steps above
  provider-gcp:example     order a Bucket and validate it against floci-gcp
  provider-gcp:translation re-print the result at every layer

  forward      restart all port-forwards
  cleanup      remove example resources
  destroy      delete the kind cluster
EOF
    exit 1
}

case "${1:-}" in
    (all) _all ;;
    (translation) _translation ;;
    (setup) _setup ;;
    (provider) _provider ;;
    (provider-bg) _provider_bg ;;
    (example) _example ;;
    (status) _example_status ;;
    (crossplane) _crossplane ;;
    (rgd:gcp) _rgd_gcp ;;
    (rgd:s3) _rgd_s3 ;;
    (provider-gcp) _provider_gcp_all ;;
    (provider-gcp:setup) _provider_gcp_setup ;;
    (provider-gcp:example) _provider_gcp_example ;;
    (provider-gcp:translation) _provider_gcp_translation ;;
    (forward) _forward ;;
    (cleanup) _cleanup ;;
    (destroy) _destroy ;;
    (*) usage ;;
esac
