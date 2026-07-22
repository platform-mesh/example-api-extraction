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
    # (No tenancy binding needed here anymore: the broker's coordination and
    # verify-*/staging-* trees live under root:resource-broker, which is an
    # admin-created workspace that serves tenancy natively.)
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
    # The broker's coordination provider dies permanently if these kinds are not
    # discoverable when it starts (greenfield race) — gate on Established.
    for crd in assignments migrationconfigurations migrations stagingworkspaces; do
        KUBECONFIG="$ws_rb" kubectl wait --for=condition=Established \
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

    # Admin kubeconfig, NOT the provisioned provider kubeconfig: that SA is
    # scoped to its own logical cluster (authentication.kcp.io/scopes), so it
    # cannot enter the coordination/staging/verification workspaces, and kcp's
    # apibinder initializer — acting as the workspace creator — could not
    # initialize the broker-created child workspaces.
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

# _gcp_provider wires the GCP provider: kcp workspace + APIExport, the
# realization layer on the compute cluster (floci emulators + kro RGD), an
# api-syncagent publishing the ObjectStorage API into the workspace, and the
# AcceptAPI that registers it with the broker (region eu).
# This is the legacy Path A wiring (gcp only); the AWS provider exists only
# under Path B (_provider_aws).
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
    KUBECONFIG="$ws_consumer" kubectl wait objectstorage/bucket1 \
        --for=jsonpath='{.status.status}'=Available --timeout="$timeout" \
        || die "Order did not become Available — check broker/syncagent logs"
    log "Order fulfilled: $(KUBECONFIG="$ws_consumer" kubectl get objectstorage bucket1 -o jsonpath='{.status.url}')"
}

_krop() {
    local provider="$1"
    local ws_path="$2"
    local ws_admin="$3"
    local kind_namespace="$4"

    local krop_kubeconfig="$kubeconfigs/workspaces/gcp.krop.kubeconfig"

    # setup RBAC in kcp, we are reusing the same service account for all providers
    kubectl --kubeconfig "$kcp_admin" apply -f ./providers/krop/kcp-root-rbac.yaml
    kubectl --kubeconfig "$ws_admin" apply -f ./providers/krop/kcp-provider-rbac.yaml

    # create a kubectl and store it as a secret for krop-controller to use
    kubectl --kubeconfig "$kind_platform" apply \
        -f ./providers/krop/kind-kubectl.yaml
    # Greenfield race: the kcp-operator needs a moment to mint the secret from
    # the Kubeconfig CR. Without this wait the pipeline below silently produces
    # an EMPTY kubeconfig (kubectl fails, but base64|sed exit 0), the chart
    # mounts an empty file and the controller falls back to in-cluster config.
    kubectl --kubeconfig "$kind_platform" -n platform-mesh-system \
        wait --for=create secret/krop-controller-kubeconfig --timeout="$timeout" \
        || die "krop-controller-kubeconfig secret was not minted"

    # export the host and rewrite the target host at the same time
    # rewrite at the same time because mac defaults to non-gnu sed and
    # tahts annoying
    kubectl --kubeconfig "$kind_platform" \
        -n platform-mesh-system \
        get secrets krop-controller-kubeconfig \
        -o jsonpath='{.data.kubeconfig}' \
        | base64 -d \
        | sed -e "s#root.kcp.localhost#frontproxy-front-proxy.platform-mesh-system.svc.cluster.local#g" \
        | sed -e "s#/clusters/root#/clusters/root:$provider#g" \
        > "$krop_kubeconfig"
    [[ -s "$krop_kubeconfig" ]] || die "extracted krop kubeconfig is empty"

    kubectl create namespace "$kind_namespace" \
        --dry-run=client -o yaml \
        | kubectl --kubeconfig "$kind_platform" apply -f-

    kubectl -n "$kind_namespace" create secret generic krop-kubeconfig \
        --from-file=kubeconfig="$krop_kubeconfig" \
        --dry-run=client -o yaml \
        | kubectl --kubeconfig "$kind_platform" apply -f-

    kustomize build --enable-helm "./providers/krop/$provider" \
        | kubectl --kubeconfig "$kind_platform" apply -f- \
        || die "Failed to deploy krop-controller for $provider"

    kubectl --kubeconfig "$ws_admin" apply -f ./providers/krop/kcp-provider-crd.yaml
    # As noted in https://github.com/platform-mesh/example-api-extraction/pull/10#issuecomment-5043180426
    # The krop-controller engages the clients with all control planes so
    # deploying a job resource fails unless the kcp workspace has the
    # Job API resource.
    # To prevent this we install the job CRD even though it isn't used.
    # TODO(ntnn): Report upstream.
    kubectl --kubeconfig "$ws_admin" apply -f ./providers/krop/kcp-provider-crd-jobs.yaml

    # then create an RGD like described here:
    # https://github.com/opendefensecloud/krop-controller/blob/main/docs/getting-started.md#3a-install-the-blueprint-crd-into-the-provider-workspace
}

_floci() {
    # The blueprint's host Job targets the in-cluster floci service (stable svc
    # DNS, verified) — deploy it alongside the docker-network variant above.
    kubectl::kustomize "$kind_platform" ./kind/manifests
}

# _provider_X creates the provider's kcp workspace, then wires krop to it.
# krop::register <provider> <ws_admin> - publishes the provider's ObjectStorage
# blueprint (providers/<provider>/manifests/blueprint-objectstorage.yaml) into its
# workspace and registers it with the broker via the provider's AcceptAPI.
# Shared by gcp/aws/azure.
krop::register() {
    local provider="$1" ws_admin="$2"

    log "Publishing the ObjectStorage blueprint ($provider)"
    # Greenfield race: _krop applied the CRDs seconds ago - gate on Established
    # and use the full resource name (the rgd shortname is not in kubectl's
    # discovery until the CRD has settled).
    local crd
    for crd in resourcegraphdefinitions.krop.opendefense.cloud jobs.batch; do
        KUBECONFIG="$ws_admin" kubectl wait --for=condition=Established \
            "crd/$crd" --timeout="$timeout" \
            || die "CRD $crd not established"
    done
    kubectl::apply "$ws_admin" "./providers/$provider/manifests/blueprint-objectstorage.yaml"
    KUBECONFIG="$ws_admin" kubectl wait resourcegraphdefinitions.krop.opendefense.cloud/objectstorage \
        --for=jsonpath="{.status.exportedAPI}"=objectstorages.storage.example.io \
        --timeout="$timeout" \
        || die "blueprint did not publish"

    log "Registering the $provider provider with the broker (AcceptAPI)"
    cat <<EOF | KUBECONFIG="$ws_admin" kubectl apply -f - || die "Failed to bind acceptapis"
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
    KUBECONFIG="$ws_admin" kubectl wait --for=condition=Ready=True apibinding/acceptapis --timeout="$timeout" \
        || die "acceptapis binding not ready"
    kubectl::apply "$ws_admin" "./providers/krop/$provider/acceptapi.yaml"
    KUBECONFIG="$ws_admin" kubectl wait acceptapi/objectstorages.storage.example.io \
        --for=condition=Ready --timeout="$timeout" \
        || die "AcceptAPI did not become Ready - check the broker logs"
}

_provider_gcp() {
    local kind_namespace="gcp"
    local ws_admin="$kubeconfigs/workspaces/gcp.admin.kubeconfig"
    kcp::create_workspace "$kcp_admin" "$ws_admin" "gcp"
    _krop gcp root:gcp "$ws_admin" "$kind_namespace"

    krop::register gcp "$ws_admin"
}

_provider_aws() {
    local kind_namespace="aws"
    local ws_admin="$kubeconfigs/workspaces/aws.admin.kubeconfig"
    kcp::create_workspace "$kcp_admin" "$ws_admin" "aws"
    _krop aws root:aws "$ws_admin" "$kind_namespace"

    krop::register aws "$ws_admin"
}

_provider_azure() {
    local kind_namespace="azure"
    local ws_admin="$kubeconfigs/workspaces/azure.admin.kubeconfig"
    kcp::create_workspace "$kcp_admin" "$ws_admin" "azure"
    _krop azure root:azure "$ws_admin" "$kind_namespace"

    krop::register azure "$ws_admin"
}

# gcp-prod (region de): the same krop pattern, but the blueprint's host-target
# resource is a CloudAPI Bucket (storage.opendefense.cloud) realized by ODC's
# UNCHANGED production adapter chain: provider-gcp -> GCPBucket (Crossplane
# claim) -> provider-terraform -> floci-gcp. See providers/gcp-prod/README.md.
# Not part of the default `setup` chain (Crossplane adds ~2 min to greenfield);
# opt in via `setup.bash gcp-prod`. The adapter image is public multi-arch on
# ghcr - no ODC access needed. With an ODC-internal source checkout present
# (PROVIDER_GCP_SRC), the image is built locally and sideloaded instead.
PROVIDER_GCP_SRC="${PROVIDER_GCP_SRC:-$HOME/dev/gitlab.opendefense.cloud/odc/cat/cloudapi/provider-gcp}"

# _host_gcp_prod installs the production realization chain on the kind cluster:
# Crossplane + provider-terraform (endpoints target the in-cluster floci-gcp
# from kind/manifests), the CloudAPI Bucket CRD, the GCPBucket XRD/Composition
# and the provider-gcp adapter (built locally for the host arch).
_host_gcp_prod() {
    log "Installing Crossplane + provider-terraform (host)"
    helm::repo crossplane-stable https://charts.crossplane.io/stable
    helm --kubeconfig "$kind_platform" upgrade --install crossplane \
        crossplane-stable/crossplane \
        -n crossplane-system --create-namespace --wait --timeout "$timeout" \
        || die "crossplane install failed"
    kubectl::apply "$kind_platform" \
        ./providers/gcp-prod/host/provider-terraform.yaml \
        ./providers/gcp-prod/host/function-patch-and-transform.yaml
    local pkg
    for pkg in provider.pkg.crossplane.io/provider-terraform \
        function.pkg.crossplane.io/function-patch-and-transform; do
        kubectl --kubeconfig "$kind_platform" wait "$pkg" \
            --for=condition=Healthy --timeout="$timeout" \
            || die "$pkg did not become Healthy"
    done
    # The ClusterProviderConfig CRD is registered by the provider package -
    # kubectl::apply retries bridge the gap.
    kubectl::apply "$kind_platform" \
        ./providers/gcp-prod/host/clusterproviderconfig.yaml \
        ./providers/gcp-prod/host/buckets.storage.opendefense.cloud.crd.yaml \
        ./providers/gcp-prod/host/xrd-gcpbucket.yaml
    kubectl --kubeconfig "$kind_platform" wait \
        xrd/gcpbuckets.gcp.opendefense.cloud \
        --for=condition=Established --timeout="$timeout" \
        || die "GCPBucket XRD not established"
    kubectl::apply "$kind_platform" ./providers/gcp-prod/host/composition-gcpbucket.yaml

    if [[ -d "$PROVIDER_GCP_SRC" ]]; then
        log "Building the provider-gcp adapter locally (source checkout found)"
        docker build -t ghcr.io/ducke/provider-gcp:hackathon-1 "$PROVIDER_GCP_SRC" \
            || die "provider-gcp image build failed"
        kind load docker-image ghcr.io/ducke/provider-gcp:hackathon-1 --name "$KIND_CLUSTER" \
            || die "Failed to load provider-gcp image into kind"
    else
        log "No provider-gcp source checkout - the public ghcr image will be pulled"
    fi
    kubectl::apply "$kind_platform" ./providers/gcp-prod/host/provider-gcp.yaml
    kubectl::wait "$kind_platform" deployment/provider-gcp gcp-system condition=Available
}

_provider_gcp_prod() {
    local kind_namespace="gcp-prod"
    local ws_admin="$kubeconfigs/workspaces/gcp-prod.admin.kubeconfig"
    kcp::create_workspace "$kcp_admin" "$ws_admin" "gcp-prod"
    _krop gcp-prod root:gcp-prod "$ws_admin" "$kind_namespace"

    # kro type-checks blueprint children against the workspace API surface -
    # the host-target Bucket needs its CRD in the workspace (same pattern as
    # the jobs.batch schema CRD in _krop).
    kubectl::apply "$ws_admin" ./providers/gcp-prod/host/buckets.storage.opendefense.cloud.crd.yaml
    KUBECONFIG="$ws_admin" kubectl wait --for=condition=Established \
        crd/buckets.storage.opendefense.cloud --timeout="$timeout" \
        || die "buckets CRD not established in root:gcp-prod"

    krop::register gcp-prod "$ws_admin"
}

_object_storage_migrator() {
    local image="localhost/object-storage-migrator:latest"
    log "Building $image"
    docker build -t "$image" ./platform/object-storage-migrator \
        || die "Failed to build $image"
    log "Loading $image into kind cluster $KIND_CLUSTER"
    kind load docker-image "$image" --name "$KIND_CLUSTER" \
        || die "Failed to load $image into kind"
    log "Install MigrationConfiguration"
    kubectl::apply "$ws_rb" ./platform/migrationconfiguration.yaml
}

_setup() {
    _kubeconfig
    _kcp
    _provider_workspace
    _platform_apis
    _broker
    _object_storage_migrator
    _floci # deploy floci instances in the kind cluster
    # Path B (the decided architecture): krop-controller per provider workspace,
    # blueprint-resident realization, no api-syncagent.
    _provider_gcp
    _provider_aws
    _provider_azure
    # gcp (eu), aws (us) and azure (ap) all carry blueprints + AcceptAPIs - the
    # broker migration demo is self-contained: patch an order's region between
    # eu, us and ap (see providers/aws/README.md for the us walkthrough).
    _consumer
    # Keep instance names short until opendefensecloud/krop-controller#8 is fixed.
    #
    # The syncagent-based Path A remains available for comparison via
    # `setup.bash syncagent-gcp` (uses the same root:gcp workspace — the
    # AcceptAPIs of both paths must not be registered for the same region at
    # the same time, or broker routing becomes ambiguous).
    log "Setup complete: order routed through the broker to the krop gcp provider."
    log "Marketplace view:"
    log "  kubectl --kubeconfig $ws_provider get apiexports,contentconfigurations,providermetadatas"
}

case "${1:-setup}" in
    (setup) _setup ;;
    (kubeconfig) _kubeconfig; _kcp ;;
    (broker) _kubeconfig; _kcp; _broker ;;
    (gcp) _kubeconfig; _kcp; _provider_gcp ;;
    (aws) _kubeconfig; _kcp; _provider_aws ;;
    (syncagent-gcp) _kubeconfig; _kcp; _gcp_provider ;;
    (consumer) _kubeconfig; _kcp; _consumer ;;
    (krop-providers) _kubeconfig; _kcp; _provider_gcp; _provider_aws; _provider_azure ;;
    (gcp-prod) _kubeconfig; _kcp; _host_gcp_prod; _provider_gcp_prod ;;
    (*) die "Unknown command: $1 (want: setup | kubeconfig | broker | gcp | aws | syncagent-gcp | consumer | krop-providers | gcp-prod)" ;;
esac
