#!/usr/bin/env bash

set -eu

cd "$(dirname "$0")"
source ./hack/lib.bash

KIND_CLUSTER="${KIND_CLUSTER:-platform-mesh}"
# Platform Mesh local-setup specifics (the kcp-operator install).
PM_NAMESPACE="${PM_NAMESPACE:-platform-mesh-system}"
PM_ADMIN_SECRET="${PM_ADMIN_SECRET:-kubeconfig-kcp-admin}"
# In-cluster front-proxy service the broker pod talks to.
PM_KCP_INCLUSTER="${PM_KCP_INCLUSTER:-frontproxy-front-proxy.platform-mesh-system:8443}"

kubeconfigs="$PWD/kubeconfigs"
mkdir -p "$kubeconfigs/workspaces"

kind_platform="$PWD/kind.kubeconfig"
kcp_admin="$kubeconfigs/kcp-admin.kubeconfig"

ws="$kubeconfigs/workspaces"
ws_rb="$ws/resource-broker.kubeconfig"          # root:resource-broker (holds the Provider CR)
ws_provider="$ws/provider.kubeconfig"           # provisioned root:providers:resource-broker-* (host-reachable)
ws_consumer="$ws/consumer.kubeconfig"

_kubeconfig() {
    if ! kind get clusters | grep -q "^$KIND_CLUSTER$"; then
        die "No kind cluster '$KIND_CLUSTER' found — start the Platform Mesh local-setup first"
    fi
    kind export kubeconfig --name "$KIND_CLUSTER" --kubeconfig "$kind_platform"
}

_kcp() {
    log "Extracting kcp admin kubeconfig from the local-setup"
    # The Platform Mesh local-setup exposes kcp directly at its external
    # hostname (kcp.api.portal.localhost:8443), reachable from the host — no
    # port-forward needed, unlike the standalone broker-postgres example.
    kubectl --kubeconfig "$kind_platform" -n "$PM_NAMESPACE" \
        get secret "$PM_ADMIN_SECRET" -o jsonpath='{.data.kubeconfig}' \
        | base64 -d > "$kcp_admin" \
        || die "Failed to read $PM_ADMIN_SECRET from $PM_NAMESPACE"
    KUBECONFIG="$kcp_admin" kubectl ws . >/dev/null \
        || die "Cannot reach kcp with the admin kubeconfig"
}

# workspace::create <parent-kubeconfig> <target-kubeconfig> <name>
# Creates <name> under the parent workspace and writes a kubeconfig entered into
# it. Uses the kcp kubectl plugins against the directly-reachable external URL.
workspace::create() {
    local parent="$1" target="$2" name="$3"
    cp "$parent" "$target"
    KUBECONFIG="$target" kubectl create-workspace "$name" --enter --ignore-existing \
        || die "Failed to create workspace $name"
    KUBECONFIG="$target" kubectl wait --for=jsonpath='{.status.phase}=Ready' \
        workspace "$name" --timeout="$timeout" 2>/dev/null || true
}

# _provider_workspace onboards resource-broker as a Platform Mesh Provider:
# create root:resource-broker, bind the providers API, create the Provider CR,
# and let the providers-operator provision the marketplace-visible provider
# workspace (root:providers:resource-broker-*) plus a scoped kubeconfig.
_provider_workspace() {
    log "Creating root:resource-broker and binding the providers API"
    workspace::create "$kcp_admin" "$ws_rb" "resource-broker"
    # The permissionClaims mirror root:providers:system — the operator needs to
    # create the namespace/SA/secret/RBAC in the provisioned provider workspace.
    cat <<'EOF' | KUBECONFIG="$ws_rb" kubectl apply -f - || die "Failed to bind providers API"
apiVersion: apis.kcp.io/v1alpha2
kind: APIBinding
metadata:
  name: providers.platform-mesh.io
spec:
  reference:
    export:
      path: root:platform-mesh-system
      name: providers.platform-mesh.io
  permissionClaims:
    - {group: "", resource: namespaces, selector: {matchAll: true}, state: Accepted, verbs: [get, list, watch, create, update, patch, delete]}
    - {group: "", resource: serviceaccounts, selector: {matchAll: true}, state: Accepted, verbs: [get, list, watch, create, update, patch, delete]}
    - {group: "", resource: secrets, selector: {matchAll: true}, state: Accepted, verbs: [get, list, watch, create, update, patch, delete]}
    - {group: rbac.authorization.k8s.io, resource: roles, selector: {matchAll: true}, state: Accepted, verbs: [get, list, watch, create, update, patch, delete]}
    - {group: rbac.authorization.k8s.io, resource: rolebindings, selector: {matchAll: true}, state: Accepted, verbs: [get, list, watch, create, update, patch, delete]}
EOF
    KUBECONFIG="$ws_rb" kubectl wait --for=condition=Ready \
        apibinding/providers.platform-mesh.io --timeout="$timeout" \
        || die "providers API binding not ready"

    log "Creating the resource-broker Provider"
    cat <<'EOF' | KUBECONFIG="$ws_rb" kubectl apply -f - || die "Failed to create Provider"
apiVersion: providers.platform-mesh.io/v1alpha1
kind: Provider
metadata:
  name: resource-broker
spec: {}
EOF
    KUBECONFIG="$ws_rb" kubectl wait --for=jsonpath='{.status.phase}=Ready' \
        provider/resource-broker --timeout="$timeout" \
        || die "Provider resource-broker did not become Ready"

    log "Extracting the provisioned provider kubeconfig"
    # In-cluster form (broker pod mounts this verbatim — it targets the provider
    # workspace via the in-cluster front-proxy).
    KUBECONFIG="$ws_rb" kubectl get secret resource-broker-provider-kubeconfig \
        -o jsonpath='{.data.kubeconfig}' | base64 -d > "$kubeconfigs/provider-incluster.kubeconfig" \
        || die "Failed to read provisioned provider kubeconfig"
    # Host-reachable form for bootstrapping resources from this script.
    cp "$kubeconfigs/provider-incluster.kubeconfig" "$ws_provider"
    yq -i ".clusters[].cluster.server |= sub(\"${PM_KCP_INCLUSTER}\"; \"kcp.api.portal.localhost:8443\")" \
        "$ws_provider" || die "Failed to rewrite provider kubeconfig host"
}

_platform_apis() {
    log "Creating staging and verification workspaces under root:resource-broker"
    workspace::create "$ws_rb" "$ws/staging.kubeconfig" "staging"
    workspace::create "$ws_rb" "$ws/verification.kubeconfig" "verification"

    log "Installing coordination CRDs into root:resource-broker"
    kubectl::apply "$ws_rb" \
        ./config/coordbroker/crd/coord.broker.platform-mesh.io_assignments.yaml \
        ./config/coordbroker/crd/coord.broker.platform-mesh.io_migrationconfigurations.yaml \
        ./config/coordbroker/crd/coord.broker.platform-mesh.io_migrations.yaml \
        ./config/coordbroker/crd/coord.broker.platform-mesh.io_stagingworkspaces.yaml

    log "Creating AcceptAPI APIExport for providers"
    # Becomes the `acceptapis` APIExportEndpointSlice the broker watches via
    # -acceptapi=acceptapis; every other slice in the workspace is brokered.
    kcp::apiexport "$ws_provider" ./config/broker/crd/broker.platform-mesh.io_acceptapis.yaml \
        secrets get,list,watch

    log "Creating ObjectStorage APIExport for consumers"
    kcp::apiexport "$ws_provider" ./config/generic/crd/storage.example.io_objectstorages.yaml \
        secrets '*' \
        events '*' \
        namespaces '*'
    # The marketplace + portal join APIExport <-> ProviderMetadata/ContentConfiguration
    # on this label; value = APIExport name (also the ProviderMetadata name).
    kubectl --kubeconfig "$ws_provider" label apiexport objectstorages \
        ui.platform-mesh.io/content-for=objectstorages --overwrite \
        || die "Failed to label objectstorages APIExport"
    # Allow account users to bind the objectstorages APIExport (the marketplace
    # Enable action). Without this the bind is denied and Enable does nothing.
    kubectl --kubeconfig "$ws_provider" apply -f ./platform/manifests/apiexport-bind-rbac.yaml \
        || die "Failed to apply APIExport bind RBAC"

    log "Registering the provider in the Platform Mesh marketplace"
    # ProviderMetadata surfaces the provider tile; ContentConfiguration adds the
    # account-scoped nav + generic list/detail/create views for the Object API.
    # Both join the APIExport via the content-for label (== ProviderMetadata name).
    kubectl --kubeconfig "$ws_provider" apply -f ./platform/manifests/provider-metadata.yaml \
        || die "Failed to apply ProviderMetadata"
    kubectl --kubeconfig "$ws_provider" apply -f ./platform/manifests/content-configuration.yaml \
        || die "Failed to apply ContentConfiguration"
}

_broker() {
    log "Deploying resource-broker (targets its provisioned provider workspace)"
    kubectl::kustomize "$kind_platform" ./platform/manifests

    # temporary workaround - build an admin kubeconfig
    KUBECONFIG="$kcp_admin" kubectl ws use :root:providers \
        || die "Failed to enter root:providers"
    local provider_ws_name="$(KUBECONFIG="$kcp_admin" kubectl get workspaces -o name | grep -o 'resource-broker-[a-z0-9]*' | head -1)"
    KUBECONFIG="$kcp_admin" kubectl ws use :root
    [[ -n "$provider_ws_name" ]] || die "Failed to find provisioned provider workspace under root:providers"
    local provider_ws_path="root:providers:$provider_ws_name"

    kcp::kubeconfig::workspace "$kcp_admin" \
        "$kubeconfigs/broker-incluster.kubeconfig" \
        "$provider_ws_path" "$PM_KCP_INCLUSTER"

    kubectl create secret generic kcp-kubeconfig --namespace=resource-broker-system --dry-run=client -o yaml \
        --from-file=kubeconfig="$kubeconfigs/broker-incluster.kubeconfig" \
        | kubectl::apply "$kind_platform" "-"

    kubectl::wait "$kind_platform" deployment/resource-broker resource-broker-system condition=Available
}

_consumer() {
    log "Binding the generic Object API and placing an order in the consumer workspace"
    kubectl::apply "$ws_consumer" \
        ./consumer/apibinding-objects.yaml
    kubectl::wait "$ws_consumer" apibinding/objectstorages "" condition=Ready
    kubectl::apply "$ws_consumer" \
        ./consumer/order-object.yaml
}

_kro() {
    local provider="$1"
    local ws_path="$2"
    local ws_admin="$3"
    shift 3

    log "Installing the kro CRDs into $ws_path"
    kubectl apply --kubeconfig "$ws_admin" \
        -f "https://raw.githubusercontent.com/kubernetes-sigs/kro/main/helm/crds/kro.run_resourcegraphdefinitions.yaml"

    log "Create in-cluster kubeconfig for kro targeting the workspace"
    local ws_incluster="$kubeconfigs/workspaces/${provider}.kubeconfig"
    kcp::kubeconfig::workspace "$kcp_admin" "$ws_incluster" "$ws_path" "$PM_KCP_INCLUSTER"

    log "Installing kro for the $provider provider workspace"
    helm::install::kro::workspace "$kind_platform" \
        "kro-${provider}" \
        "$ws_incluster" \
        "kro-${provider}-system" \
        "kro-kubeconfig"

    kubectl::wait "$kind_platform" \
        deployment/kro-${provider} \
        "kro-${provider}-system" \
        condition=Available
}

_floci() {
    local name="$1"
    shift

    if docker ps --all --format '{{.Names}}' | grep -q "^${name}$"; then
        # exists, do nothing
        return
    fi
    docker run --network kind -d --name "$name" "$@"
}

# _provider_X creates the provider's kcp workspace, then wires kro to it.
_provider_gcp() {
    local ws_admin="$kubeconfigs/workspaces/gcp.admin.kubeconfig"
    kcp::create_workspace "$kcp_admin" "$ws_admin" "gcp"
    _kro gcp root:gcp "$ws_admin"

    log "Deploy floci gcp"
    _floci floci-gcp -p 4588:4588 \
      floci/floci-gcp:latest
}

_provider_aws() {
    local ws_admin="$kubeconfigs/workspaces/aws.admin.kubeconfig"
    kcp::create_workspace "$kcp_admin" "$ws_admin" "aws"
    _kro aws root:aws "$ws_admin"

    log "Deploy floci aws"
    # All 68 services on :4566
    _floci floci -p 4566:4566 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      floci/floci:latest
}

_provider_azure() {
    local ws_admin="$kubeconfigs/workspaces/azure.admin.kubeconfig"
    kcp::create_workspace "$kcp_admin" "$ws_admin" "azure"
    _kro azure root:azure "$ws_admin"

    log "Deploy floci azure"
    # REST :4577 · Event Hubs AMQP :5672 · Service Bus AMQP :5673
    _floci floci-az -p 4577:4577 \
      -p 5672:5672 \
      -p 5673:5673 \
      floci/floci-az:latest
}

_setup() {
    _kubeconfig
    _kcp
    _provider_workspace
    _platform_apis
    _broker
    _provider_gcp
    _provider_aws
    _provider_azure
    log "Setup complete. The resource-broker provider and its Object API are"
    log "registered. Check the marketplace, or:"
    log "  kubectl --kubeconfig $ws_provider get apiexports,contentconfigurations,providermetadatas"
}

case "${1:-setup}" in
    (setup) _setup ;;
    (kubeconfig) _kubeconfig; _kcp ;;
    (broker) _kubeconfig; _kcp; _broker ;;
    (*) die "Unknown command: $1 (want: setup | kubeconfig | broker)" ;;
esac
