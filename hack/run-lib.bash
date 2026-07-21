# Shared helper functions for hack/run.bash.
#
# Adapted (trimmed and lightly renamed) from platform-mesh/resource-broker's
# hack/lib.bash - if a function here behaves oddly, comparing with that
# original is a good first debugging step. Named run-lib.bash (not lib.bash)
# to avoid colliding with the sibling hack/lib.bash, which is a separate,
# much larger copy of the same original used by setup.bash's resource-broker
# onboarding flow - the two are unrelated despite the shared ancestry.

timeout="10m"

log() { echo ">>> $*"; }
die() { echo "!!! $*" >&2; exit 1; }

# --- kind -------------------------------------------------------------------

# Create the kind cluster (or reuse it) and write its kubeconfig.
kind::cluster() {
    local name="$1"
    local kubeconfig="$2"
    rm -f "$kubeconfig"
    if ! kind get clusters | grep -q "^$name$"; then
        kind create cluster --name "$name" --kubeconfig "$kubeconfig" \
            || die "Failed to create cluster $name"
    else
        kind export kubeconfig --name "$name" --kubeconfig "$kubeconfig" \
            || die "Failed to export kubeconfig for cluster $name"
    fi
}

# --- kubectl ----------------------------------------------------------------

# Apply with retries - right after cluster/CRD creation the API server often
# needs a few seconds before applies succeed.
kubectl::apply() {
    local kubeconfig="$1"
    local resource="$2"
    local try=0
    while [[ "$try" -lt 30 ]]; do
        if kubectl --kubeconfig "$kubeconfig" apply -f "$resource"; then
            return
        fi
        try=$((try + 1))
        log "kubectl apply $resource failed, retrying ($try/30)..."
        sleep 2
    done
    die "Failed to apply $resource with kubeconfig $kubeconfig"
}

kubectl::kustomize() {
    local kubeconfig="$1"
    local dir="$2"
    local try=0
    while [[ "$try" -lt 30 ]]; do
        if kubectl --kubeconfig "$kubeconfig" kustomize "$dir" \
                | kubectl --kubeconfig "$kubeconfig" apply -f-; then
            return
        fi
        try=$((try + 1))
        log "kustomize apply $dir failed, retrying ($try/30)..."
        sleep 2
    done
    die "Failed to kustomize apply $dir with kubeconfig $kubeconfig"
}

kubectl::wait() {
    local kubeconfig="$1"
    local resource="$2"
    local namespace="$3"
    local for="$4"
    kubectl --kubeconfig "$kubeconfig" wait --for="$for" "$resource" \
        --timeout="$timeout" --namespace="$namespace" \
        || die "Timed out waiting for $for on $resource (kubeconfig $kubeconfig)"
}

# Wait until a jsonpath on a resource contains a given substring.
kubectl::wait::contains() {
    local kubeconfig="$1"
    local resource="$2"
    local namespace="$3"
    local jsonpath="$4"
    local want="$5"
    local try=0
    local value=""
    while [[ "$try" -lt 300 ]]; do
        value="$(kubectl --kubeconfig "$kubeconfig" get "$resource" -n "$namespace" -o "jsonpath={$jsonpath}" 2>/dev/null || true)"
        if [[ "$value" == *"$want"* ]]; then
            log "$resource $jsonpath now contains '$want'"
            return
        fi
        try=$((try + 1))
        [[ $((try % 15)) -eq 0 ]] && log "still waiting for '$want' in $jsonpath of $resource (currently: '$value')"
        sleep 2
    done
    die "Timed out waiting for '$want' in $jsonpath of $resource"
}

# Run a Job to completion: delete a previous instance (Jobs are immutable),
# apply, wait, print logs.
kubectl::job() {
    local kubeconfig="$1"
    local manifest="$2"
    local name="$3"
    local namespace="$4"
    kubectl --kubeconfig "$kubeconfig" delete job "$name" -n "$namespace" --ignore-not-found --wait=true
    kubectl::apply "$kubeconfig" "$manifest"
    if ! kubectl --kubeconfig "$kubeconfig" wait --for=condition=Complete "job/$name" -n "$namespace" --timeout="$timeout"; then
        kubectl --kubeconfig "$kubeconfig" logs "job/$name" -n "$namespace" || true
        die "Job $name did not complete"
    fi
    kubectl --kubeconfig "$kubeconfig" logs "job/$name" -n "$namespace"
}

# --- helm -------------------------------------------------------------------

helm::repo() {
    helm repo add "$1" "$2" || die "Failed to add helm repo $1"
    helm repo update "$1" || die "Failed to update helm repo $1"
}

helm::install() {
    local kubeconfig="$1"
    local release="$2"
    local chart="$3"
    shift 3
    KUBECONFIG="$kubeconfig" helm upgrade --install --create-namespace \
        "$release" "$chart" "$@" \
        || die "Failed to install helm chart $chart as $release"
}

helm::install::certmanager() {
    helm::install "$1" cert-manager oci://quay.io/jetstack/charts/cert-manager \
        --version v1.18.2 \
        --namespace cert-manager \
        --set crds.enabled=true
}

helm::install::etcddruid() {
    local kubeconfig="$1"
    local version="v0.33.0"
    kubectl::apply "$kubeconfig" \
        "https://raw.githubusercontent.com/gardener/etcd-druid/refs/tags/${version}/api/core/v1alpha1/crds/druid.gardener.cloud_etcds_without_cel.yaml"
    kubectl::apply "$kubeconfig" \
        "https://raw.githubusercontent.com/gardener/etcd-druid/refs/tags/${version}/api/core/v1alpha1/crds/druid.gardener.cloud_etcdcopybackupstasks.yaml"
    helm::install "$kubeconfig" etcd-druid \
        "oci://europe-docker.pkg.dev/gardener-project/releases/charts/gardener/etcd-druid" \
        --version "$version"
}

helm::install::kcp_operator() {
    helm::repo kcp https://kcp-dev.github.io/helm-charts
    helm::install "$1" kcp-operator kcp/kcp-operator --version=0.4.0
}

helm::install::kro() {
    helm::install "$1" kro oci://registry.k8s.io/kro/charts/kro --version=0.5.1
}

helm::install::crossplane() {
    helm::repo crossplane-stable https://charts.crossplane.io/stable
    helm::install "$1" crossplane crossplane-stable/crossplane \
        --namespace crossplane-system
}

# api-syncagent, publishing the Bucket API into the kcp workspace.
# $2 is the name of the secret holding the kubeconfig for the workspace.
helm::install::api_syncagent() {
    local kubeconfig="$1"
    local kcp_kubeconfig_secret="$2"
    helm::repo kcp https://kcp-dev.github.io/helm-charts
    helm::install "$kubeconfig" api-syncagent-storage kcp/api-syncagent \
        --version=0.4.5 \
        --set replicas=1 \
        --set apiExportName=buckets \
        --set agentName=storage \
        --set kcpKubeconfig="$kcp_kubeconfig_secret"
}

# --- kubeconfig plumbing ----------------------------------------------------

kubeconfig::hostname() {
    local kubeconfig="$1"
    local hostname
    hostname="$(yq '.clusters[0].cluster.server' "$kubeconfig")"
    [[ -z "$hostname" ]] && die "Failed to get server from kubeconfig $kubeconfig"
    hostname="${hostname#http://}"
    hostname="${hostname#https://}"
    echo "${hostname%%/*}"
}

kubeconfig::hostname::set() {
    local kubeconfig="$1"
    local old="$2"
    local new="$3"
    yq -i ".clusters[].cluster.server |= sub(\"$old\"; \"$new\")" "$kubeconfig"
}

kubeconfig::server_url() {
    local kubeconfig="$1"
    local ctx
    ctx="$(kubectl --kubeconfig "$kubeconfig" config current-context)"
    kubectl --kubeconfig "$kubeconfig" config view \
        -o jsonpath="{.clusters[?(@.name==\"$ctx\")].cluster.server}"
}

kubeconfig::create::bare() {
    local kubeconfig="$1"
    echo "" > "$kubeconfig"
    KUBECONFIG="$kubeconfig" kubectl config set-context default --cluster=default --user=default
    KUBECONFIG="$kubeconfig" kubectl config use-context default
}

# Build a token-based kubeconfig (PoC: TLS verification disabled).
kubeconfig::create::token() {
    local kubeconfig="$1"
    local url="$2"
    local token="$3"
    kubeconfig::create::bare "$kubeconfig"
    KUBECONFIG="$kubeconfig" kubectl config set-cluster default \
        --insecure-skip-tls-verify=true --server="$url"
    KUBECONFIG="$kubeconfig" kubectl config set-credentials default --token="$token"
}

# Store a kubeconfig file as a secret in a cluster, optionally rewriting the
# server hostname (for in-cluster access via NodePort).
kubeconfig::to_secret() {
    local kubeconfig="$1"     # cluster to store the secret in
    local file="$2"           # kubeconfig file to store
    local name="$3"           # secret name
    local hostname="$4"       # optional new hostname for the server URL
    cp "$file" "$file.tmp"
    if [[ -n "$hostname" ]]; then
        kubeconfig::hostname::set "$file.tmp" "$(kubeconfig::hostname "$file.tmp")" "$hostname"
    fi
    kubectl --kubeconfig "$kubeconfig" create secret generic "$name" \
        --namespace=default --dry-run=client -o yaml \
        --from-file=kubeconfig="$file.tmp" \
        | kubectl --kubeconfig "$kubeconfig" apply -f-
    rm -f "$file.tmp"
}

# --- kcp --------------------------------------------------------------------

# Extract the kcp admin kubeconfig from the kind cluster and produce a
# host-usable variant that goes through the port-forwarded front proxy.
kcp::setup::kubeconfigs() {
    local kind_kubeconfig="$1"
    local kcp_admin="$2"      # output: admin kubeconfig (in-cluster address)
    local kcp_host="$3"       # output: admin kubeconfig via 127.0.0.1:8443

    KUBECONFIG="$kind_kubeconfig" kubectl wait --for=create secret/admin-kubeconfig \
        --timeout="$timeout" || die "Timed out waiting for admin-kubeconfig secret"
    KUBECONFIG="$kind_kubeconfig" kubectl get secret admin-kubeconfig \
        -o jsonpath='{.data.kubeconfig}' | base64 -d > "$kcp_admin" \
        || die "Failed to extract kcp admin kubeconfig"

    kcp::front_proxy_forward "$kind_kubeconfig" 8443

    cp "$kcp_admin" "$kcp_host"
    local hostname
    hostname="$(kubectl --kubeconfig "$kind_kubeconfig" get rootshards.operator.kcp.io root \
        -o jsonpath='{.spec.external.hostname}')"
    kubeconfig::hostname::set "$kcp_host" "$hostname:32443" "127.0.0.1:8443"
}

# Port-forward the kcp front proxy to localhost:$2 (in the background).
kcp::front_proxy_forward() {
    local kubeconfig="$1"
    local port="$2"
    KUBECONFIG="$kubeconfig" kubectl wait --for=condition=Available=True \
        deployment/frontproxy-front-proxy --timeout="$timeout" \
        || die "kcp front proxy is not available"
    pkill -f "port-forward svc/frontproxy-front-proxy" 2>/dev/null || true
    KUBECONFIG="$kubeconfig" kubectl port-forward svc/frontproxy-front-proxy \
        "$port:6443" >/dev/null 2>&1 &
    sleep 1
}

# Create a kcp workspace and write a kubeconfig scoped to it.
kcp::create_workspace() {
    local parent_kubeconfig="$1"
    local target_kubeconfig="$2"
    local wsname="$3"

    cp "$parent_kubeconfig" "$target_kubeconfig"
    local check_kubeconfig="$target_kubeconfig.check"
    cp "$target_kubeconfig" "$check_kubeconfig"

    while ! KUBECONFIG="$target_kubeconfig" kubectl get workspacetype universal &>/dev/null; do
        log "WorkspaceType universal not found yet, retrying..."
        sleep 2
    done
    KUBECONFIG="$target_kubeconfig" kubectl wait --timeout="$timeout" \
        --for=condition=Ready=True workspacetypes universal \
        || die "Timed out waiting for workspacetype universal"

    log "Creating workspace $wsname"
    KUBECONFIG="$target_kubeconfig" kubectl create-workspace "$wsname" --enter --ignore-existing \
        || die "Failed to create workspace $wsname (is the kcp kubectl plugin installed?)"

    KUBECONFIG="$check_kubeconfig" kubectl wait \
        --for=jsonpath='{.status.phase}'="Ready" workspace "$wsname" --timeout="$timeout" \
        || die "Timed out waiting for workspace $wsname"
    rm -f "$check_kubeconfig"
}

# Bind an APIExport into a workspace (with full permission claims on
# secrets and namespaces so related resources can be synced).
kcp::apibinding() {
    local kubeconfig="$1"
    local export_path="$2"
    local export_name="$3"

    KUBECONFIG="$kubeconfig" kubectl apply -f- <<EOF
apiVersion: apis.kcp.io/v1alpha2
kind: APIBinding
metadata:
  name: $export_name
spec:
  reference:
    export:
      path: $export_path
      name: $export_name
  permissionClaims:
    - group: ""
      resource: secrets
      state: Accepted
      selector:
        matchAll: true
      verbs: ["*"]
    - group: ""
      resource: namespaces
      state: Accepted
      selector:
        matchAll: true
      verbs: ["*"]
EOF
    KUBECONFIG="$kubeconfig" kubectl wait --for=condition=Ready=True \
        "apibindings/$export_name" --timeout="$timeout" \
        || die "Timed out waiting for apibinding $export_name"
}

# Create an admin service account in a workspace and print a token for it.
# PoC shortcut: cluster-admin; a real setup would scope this with RBAC.
kcp::serviceaccount::admin() {
    local kubeconfig="$1"
    local sa_name="$2"
    KUBECONFIG="$kubeconfig" kubectl create serviceaccount "$sa_name" \
        --dry-run=client -o yaml | KUBECONFIG="$kubeconfig" kubectl apply -f- >/dev/null
    KUBECONFIG="$kubeconfig" kubectl create clusterrolebinding "$sa_name" \
        --clusterrole=cluster-admin --serviceaccount="default:$sa_name" \
        --dry-run=client -o yaml | KUBECONFIG="$kubeconfig" kubectl apply -f- >/dev/null
    KUBECONFIG="$kubeconfig" kubectl create token "$sa_name" --duration=5208h \
        || die "Failed to create token for $sa_name"
}
