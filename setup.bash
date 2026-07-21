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
ws_gcp="$ws/gcp.kubeconfig"                     # root:gcp (the GCP provider workspace)
ws_consumer="$ws/consumer.kubeconfig"

# The traefik ClusterIP the local-setup pins; every platform component maps the
# kcp external hostnames onto it via hostAliases (they resolve to 127.0.0.1
# inside pods otherwise).
PM_TRAEFIK_IP="${PM_TRAEFIK_IP:-10.96.188.4}"

# provider::path prints the provisioned provider workspace path
# (root:providers:resource-broker-<suffix>). The provisioned kubeconfig's
# server URL carries the logical-cluster ID, not the path — list the
# workspaces under root:providers as admin instead.
provider::path() {
    local tmp="$kubeconfigs/.providers-admin.kubeconfig"
    admin::ws_kubeconfig "$tmp" "root:providers"
    local name
    name="$(KUBECONFIG="$tmp" kubectl get workspaces -o name 2>/dev/null \
        | grep 'resource-broker-' | head -1)"
    name="${name##*/}"
    [[ -n "$name" ]] || die "provisioned resource-broker workspace not found under root:providers"
    echo "root:providers:$name"
}

# admin::ws_kubeconfig <target> <workspace-path> [server-host]
# Writes an admin kubeconfig entered into <workspace-path>. Defaults to the
# host-reachable external URL; pass a server host for the in-cluster variant.
admin::ws_kubeconfig() {
    local target="$1" wspath="$2" host="${3:-kcp.api.portal.localhost:8443}"
    cp "$kcp_admin" "$target"
    yq -i ".clusters[].cluster.server = \"https://$host/clusters/$wspath\"" "$target" \
        || die "Failed to rewrite $target for $wspath"
}

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

    # The provisioned workspace only binds the platform-mesh APIs. The broker
    # needs the tenancy API to create its verify-*/staging-* child workspaces —
    # bind it as admin (the scoped provider SA may not bind root exports).
    log "Binding the tenancy API into the provider workspace"
    local provider_admin="$kubeconfigs/provider-admin.kubeconfig"
    admin::ws_kubeconfig "$provider_admin" "$(provider::path)"
    cat <<'EOF' | KUBECONFIG="$provider_admin" kubectl apply -f - || die "Failed to bind tenancy API"
apiVersion: apis.kcp.io/v1alpha2
kind: APIBinding
metadata:
  name: tenancy.kcp.io
spec:
  reference:
    export:
      path: root
      name: tenancy.kcp.io
EOF
    KUBECONFIG="$provider_admin" kubectl wait --for=condition=Ready=True \
        apibinding/tenancy.kcp.io --timeout="$timeout" \
        || die "tenancy API binding not ready"
}

_platform_apis() {
    log "Installing coordination CRDs into the provider workspace"
    kubectl::apply "$ws_provider" \
        ./config/coordbroker/crd/coord.broker.platform-mesh.io_assignments.yaml \
        ./config/coordbroker/crd/coord.broker.platform-mesh.io_migrationconfigurations.yaml \
        ./config/coordbroker/crd/coord.broker.platform-mesh.io_migrations.yaml \
        ./config/coordbroker/crd/coord.broker.platform-mesh.io_stagingworkspaces.yaml
    # The broker's coordination provider dies permanently if these kinds are not
    # discoverable when it starts (greenfield race) — gate on Established.
    for crd in assignments migrationconfigurations migrations stagingworkspaces; do
        KUBECONFIG="$ws_provider" kubectl wait --for=condition=Established \
            "crd/${crd}.coord.broker.platform-mesh.io" --timeout="$timeout" \
            || die "coordination CRD $crd not established"
    done

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

    local wspath
    wspath="$(provider::path)"

    # NOT the provisioned provider kubeconfig: that SA is scoped to its own
    # logical cluster (authentication.kcp.io/scopes), so kcp's apibinder
    # initializer — which acts as the workspace creator — cannot initialize the
    # broker's verify-*/staging-* child workspaces, and the broker cannot enter
    # them. Mount an admin kubeconfig targeting the provider workspace via the
    # in-cluster front-proxy instead (same approach as the standalone
    # broker-postgres example, which uses the kcp-operator admin kubeconfig).
    local broker_kubeconfig="$kubeconfigs/broker-incluster.kubeconfig"
    admin::ws_kubeconfig "$broker_kubeconfig" "$wspath" "$PM_KCP_INCLUSTER"
    kubectl create secret generic kcp-kubeconfig --namespace=resource-broker-system --dry-run=client -o yaml \
        --from-file=kubeconfig="$broker_kubeconfig" \
        | kubectl::apply "$kind_platform" "-"

    # The broker's workspace-tree defaults (root:platform:broker:*) come from
    # the standalone example; point them at the provisioned workspace. Replacing
    # the full args array keeps this idempotent across reruns.
    kubectl --kubeconfig "$kind_platform" -n resource-broker-system patch deployment resource-broker \
        --type json -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":[
            \"-kubeconfig=/kubeconfig/kubeconfig\",
            \"-kcp-kubeconfig=/kubeconfig/kubeconfig\",
            \"-compute-kubeconfig=/compute-kubeconfig/kubeconfig\",
            \"-acceptapi=acceptapis\",
            \"-requeue-interval=1s\",
            \"-coordination-workspace=$wspath\",
            \"-verification-tree-root=$wspath\",
            \"-staging-tree-root=$wspath\"]}]" \
        || die "Failed to patch broker workspace-tree flags"

    kubectl::wait "$kind_platform" deployment/resource-broker resource-broker-system condition=Available
}

# _gcp_provider wires the GCP provider: kcp workspace + APIExport, the
# realization layer on the compute cluster (floci emulators + kro RGD), an
# api-syncagent publishing the ObjectStorage API into the workspace, and the
# AcceptAPI that registers it with the broker (region eu).
# The AWS provider is intentionally NOT wired here — it is implemented
# separately; see providers/gcp as the blueprint.
_gcp_provider() {
    log "Creating the gcp provider workspace and APIExport"
    workspace::create "$kcp_admin" "$ws_gcp" "gcp"
    # Empty APIExport — the api-syncagent manages its resource schemas.
    cat <<'EOF' | KUBECONFIG="$ws_gcp" kubectl apply -f - || die "Failed to create objectstorages APIExport"
apiVersion: apis.kcp.io/v1alpha1
kind: APIExport
metadata:
  name: objectstorages
EOF

    log "Binding the AcceptAPI export into the gcp workspace"
    cat <<EOF | KUBECONFIG="$ws_gcp" kubectl apply -f - || die "Failed to bind acceptapis"
apiVersion: apis.kcp.io/v1alpha2
kind: APIBinding
metadata:
  name: acceptapis
spec:
  reference:
    export:
      path: $(provider::path)
      name: acceptapis
  permissionClaims:
    - {group: "", resource: secrets, selector: {matchAll: true}, state: Accepted, verbs: [get, list, watch]}
EOF
    KUBECONFIG="$ws_gcp" kubectl wait --for=condition=Ready=True apibinding/acceptapis --timeout="$timeout" \
        || die "acceptapis binding not ready"

    log "Deploying the realization layer (floci emulators + kro RGD)"
    kubectl --kubeconfig "$kind_platform" get ns kro-system >/dev/null 2>&1 \
        || die "kro not found — the Platform Mesh local-setup should provide it"
    kubectl::kustomize "$kind_platform" ./kind/manifests
    kubectl::apply "$kind_platform" ./providers/gcp/manifests/rgd-objectstorage.yaml
    kubectl --kubeconfig "$kind_platform" create namespace gcp-orders --dry-run=client -o yaml \
        | kubectl::apply "$kind_platform" "-"
    kubectl::wait "$kind_platform" rgd/objectstorages.storage.example.io "" jsonpath='{.status.state}'=Active

    log "Installing the api-syncagent for the gcp workspace"
    local token agent_kubeconfig="$kubeconfigs/api-syncagent-gcp.kubeconfig"
    token="$(kcp::serviceaccount::admin "$ws_gcp" api-syncagent default | tail -1)"
    [[ -n "$token" ]] || die "Failed to create api-syncagent token"
    kubeconfig::create::token "$agent_kubeconfig" \
        "https://${PM_KCP_INCLUSTER}/clusters/root:gcp" "$token" >/dev/null
    kubectl create secret generic kubeconfig-gcp --namespace=default --dry-run=client -o yaml \
        --from-file=kubeconfig="$agent_kubeconfig" \
        | kubectl::apply "$kind_platform" "-"
    helm::repo kcp https://kcp-dev.github.io/helm-charts
    # hostAliases.enabled is required — setting only .values renders nothing
    # (the agent then dies fatally on the export's virtual-workspace URL).
    helm::install "$kind_platform" api-syncagent-gcp kcp/api-syncagent \
        --version=0.4.5 \
        --namespace default \
        --set replicas=1 \
        --set apiExportName=objectstorages \
        --set agentName=gcp \
        --set kcpKubeconfig=kubeconfig-gcp \
        --set hostAliases.enabled=true \
        --set "hostAliases.values[0].ip=$PM_TRAEFIK_IP" \
        --set "hostAliases.values[0].hostnames[0]=localhost" \
        --set "hostAliases.values[0].hostnames[1]=root.kcp.localhost" \
        --set "hostAliases.values[0].hostnames[2]=kcp.api.portal.localhost"
    kubectl::apply "$kind_platform" ./providers/gcp/manifests/publishedresource-objectstorages.yaml
    cat <<'EOF' | kubectl::apply "$kind_platform" "-"
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: api-syncagent-gcp:objectstorages
rules:
  - apiGroups: ["storage.example.io"]
    resources: ["objectstorages", "objectstorages/status"]
    verbs: [get, list, watch, create, update, delete, patch]
  - apiGroups: [""]
    resources: ["events"]
    verbs: [create, patch]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: api-syncagent-gcp:objectstorages
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: api-syncagent-gcp:objectstorages
subjects:
  - kind: ServiceAccount
    name: api-syncagent-gcp
    namespace: default
EOF

    # Gate on the agent having fully populated the APIExport (resource schemas
    # AND the permissionClaims it manages, incl. core.kcp.io/logicalclusters).
    # The broker copies the export's claims into the staging APIBinding at
    # creation time and never reconciles them afterwards — an early order
    # against an incomplete export leaves the staging sync permanently broken
    # (greenfield race: "LogicalCluster not found").
    log "Waiting for the api-syncagent to populate the objectstorages APIExport"
    local tries=0
    until KUBECONFIG="$ws_gcp" kubectl get apiexport objectstorages \
            -o jsonpath='{.spec.permissionClaims[*].resource}' 2>/dev/null \
            | grep -q logicalclusters \
        && [[ -n "$(KUBECONFIG="$ws_gcp" kubectl get apiexport objectstorages -o jsonpath='{.spec.resources}' 2>/dev/null)" ]]; do
        tries=$((tries + 1))
        [[ $tries -gt 60 ]] && die "api-syncagent did not populate the APIExport (schemas/claims)"
        sleep 5
    done

    log "Registering the gcp provider with the broker (AcceptAPI, region eu)"
    kubectl::apply "$ws_gcp" ./providers/gcp/manifests/acceptapi.yaml
    KUBECONFIG="$ws_gcp" kubectl wait acceptapi/objectstorages.storage.example.io \
        --for=condition=Ready --timeout="$timeout" \
        || die "AcceptAPI did not become Ready — check the broker logs"
}

_consumer() {
    log "Creating the consumer workspace and binding the ObjectStorage API"
    workspace::create "$kcp_admin" "$ws_consumer" "consumer"
    # The binding manifest carries a placeholder export path — substitute the
    # actual provisioned provider workspace path.
    sed "s|path: root:providers:resource-broker .*|path: $(provider::path)|" \
        ./consumer/apibinding-objectstorages.yaml \
        | kubectl::apply "$ws_consumer" "-"
    kubectl::wait "$ws_consumer" apibinding/objectstorages "" condition=Ready

    log "Placing an order (ObjectStorage, region eu)"
    kubectl::apply "$ws_consumer" ./consumer/order-objectstorage.yaml
    KUBECONFIG="$ws_consumer" kubectl wait objectstorage/bucket-from-consumer \
        --for=jsonpath='{.status.status}'=Available --timeout="$timeout" \
        || die "Order did not become Available — check broker/syncagent logs"
    log "Order fulfilled: $(KUBECONFIG="$ws_consumer" kubectl get objectstorage bucket-from-consumer -o jsonpath='{.status.url}')"
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

    if docker ps --all --quiet | grep -q "^${name}$"; then
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
    _gcp_provider
    _consumer
    # The AWS provider is implemented separately (see providers/aws/README.md,
    # with providers/gcp as the blueprint); once its AcceptAPI (region us) is
    # Ready, patching the order's region from eu to us triggers the broker
    # migration.
    #
    # _provider_gcp/_provider_aws/_provider_azure (kro running per provider
    # workspace, floci as docker containers on the kind network) are an
    # alternative realization in progress — run them via
    # `setup.bash kro-providers`. Note: _provider_gcp shares root:gcp with
    # _gcp_provider; don't run both against the same workspace.
    log "Setup complete: order routed through the broker to the gcp provider."
    log "Marketplace view:"
    log "  kubectl --kubeconfig $ws_provider get apiexports,contentconfigurations,providermetadatas"
}

case "${1:-setup}" in
    (setup) _setup ;;
    (kubeconfig) _kubeconfig; _kcp ;;
    (broker) _kubeconfig; _kcp; _broker ;;
    (gcp) _kubeconfig; _kcp; _gcp_provider ;;
    (consumer) _kubeconfig; _kcp; _consumer ;;
    (kro-providers) _kubeconfig; _kcp; _provider_gcp; _provider_aws; _provider_azure ;;
    (*) die "Unknown command: $1 (want: setup | kubeconfig | broker | gcp | consumer | kro-providers)" ;;
esac
