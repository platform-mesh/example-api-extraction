#!/usr/bin/env bash
# Run the Azure kro PoC against an existing kind cluster.
#
# Usage:
#   ./providers/azure/hack/run-poc.sh
#   KIND_CLUSTER=my-cluster ./providers/azure/hack/run-poc.sh
#
# Requirements: kubectl, kind

set -euo pipefail

KIND_CLUSTER="${KIND_CLUSTER:-platform-mesh}"
CONTEXT="kind-${KIND_CLUSTER}"
NAMESPACE="${NAMESPACE:-azure-orders}"
OBJECT_NAME="${OBJECT_NAME:-my-azure-bucket}"

repo_root="$(cd "$(dirname "$0")/../../.." && pwd)"

# ── Colours (disabled when not a terminal) ───────────────────────────────────
if [[ -t 1 ]]; then
  _bold='\033[1m'; _green='\033[1;32m'; _yellow='\033[1;33m'
  _red='\033[1;31m'; _cyan='\033[1;36m'; _reset='\033[0m'
else
  _bold=''; _green=''; _yellow=''; _red=''; _cyan=''; _reset=''
fi

step() { echo -e "\n${_cyan}[$(date +%H:%M:%S)]${_reset} ${_bold}$*${_reset}"; }
ok()   { echo -e "${_green}  ✓ $*${_reset}"; }
warn() { echo -e "${_yellow}  ! $*${_reset}"; }
skip() { echo -e "${_yellow}  ~ $* — skipping${_reset}"; }
die()  { echo -e "\n${_red}  ✗ $*${_reset}" >&2; exit 1; }
info() { echo -e "    $*"; }

# retry <attempts> <sleep_seconds> <description> -- <cmd...>
# Runs <cmd> up to <attempts> times with a delay between tries.
retry() {
  local attempts="$1" delay="$2" desc="$3"
  shift 3; [[ "${1:-}" == "--" ]] && shift
  local i=0
  while [[ "$i" -lt "$attempts" ]]; do
    if "$@" 2>/dev/null; then return 0; fi
    i=$((i + 1))
    [[ "$i" -lt "$attempts" ]] || die "giving up after $attempts attempts: $desc"
    warn "$desc failed (attempt $i/$attempts), retrying in ${delay}s..."
    sleep "$delay"
  done
}

# wait_for_resource <description> <attempts> <sleep_seconds> -- <cmd...>
# Polls until <cmd> exits 0 (resource exists).
wait_for_resource() {
  local desc="$1" attempts="$2" delay="$3"
  shift 3; [[ "${1:-}" == "--" ]] && shift
  local i=0
  while [[ "$i" -lt "$attempts" ]]; do
    if "$@" >/dev/null 2>&1; then return 0; fi
    i=$((i + 1))
    [[ "$i" -lt "$attempts" ]] || die "timed out waiting for $desc"
    [[ $((i % 10)) -eq 0 ]] && warn "still waiting for $desc ($i/$attempts)..."
    sleep "$delay"
  done
}

# ── Banner ────────────────────────────────────────────────────────────────────
echo
echo -e "${_bold}Azure kro PoC — Object Storage via floci-az${_reset}"
echo -e "  cluster   : ${_cyan}${KIND_CLUSTER}${_reset}"
echo -e "  namespace : ${_cyan}${NAMESPACE}${_reset}"
echo -e "  object    : ${_cyan}${OBJECT_NAME}${_reset}"

# ── Pre-flight checks ─────────────────────────────────────────────────────────
step "pre-flight checks"

for cmd in kubectl kind; do
  command -v "$cmd" >/dev/null \
    && ok "$cmd found" \
    || die "missing required command: $cmd"
done

kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER" \
  && ok "cluster '$KIND_CLUSTER' exists" \
  || die "cluster '$KIND_CLUSTER' not found — run: kind create cluster --name $KIND_CLUSTER"

kubectl --context "$CONTEXT" get deployment kro -n kro-system >/dev/null 2>&1 \
  && ok "kro is running in kro-system" \
  || die "kro not found in kro-system — is it installed on this cluster?"

# ── 1. floci-az ───────────────────────────────────────────────────────────────
step "1/5  floci-az emulator"

if kubectl --context "$CONTEXT" get deployment/floci-azure -n floci-azure >/dev/null 2>&1; then
  skip "floci-az already deployed"
else
  info "deploying floci-az..."
  retry 5 3 "apply floci-azure.yaml" -- \
    kubectl --context "$CONTEXT" apply -f "$repo_root/kind/manifests/floci-azure.yaml"
fi

info "waiting for floci-az rollout..."
kubectl --context "$CONTEXT" rollout status deployment/floci-azure \
  --namespace floci-azure \
  --timeout=120s
ok "floci-az ready at floci-azure.floci-azure.svc.cluster.local:4577"

# ── 2. kro RGD ────────────────────────────────────────────────────────────────
step "2/5  kro ResourceGraphDefinition"

if kubectl --context "$CONTEXT" \
    get resourcegraphdefinition/objects.storage.generic.platform-mesh.io >/dev/null 2>&1; then
  skip "RGD already exists"
else
  info "applying RGD..."
  retry 5 3 "apply rgd-object.yaml" -- \
    kubectl --context "$CONTEXT" apply -f "$repo_root/providers/azure/manifests/rgd-object.yaml"
fi

info "waiting for RGD to become Ready..."
wait_for_resource "RGD" 30 2 -- \
  kubectl --context "$CONTEXT" \
    get resourcegraphdefinition/objects.storage.generic.platform-mesh.io
kubectl --context "$CONTEXT" \
  wait resourcegraphdefinition/objects.storage.generic.platform-mesh.io \
  --for=condition=Ready \
  --timeout=120s
ok "RGD objects.storage.generic.platform-mesh.io is Ready"

# ── 3. Sample Object ──────────────────────────────────────────────────────────
step "3/5  sample Object '$OBJECT_NAME'"

kubectl --context "$CONTEXT" create namespace "$NAMESPACE" \
  --dry-run=client --output=yaml \
  | kubectl --context "$CONTEXT" apply -f - >/dev/null

if kubectl --context "$CONTEXT" \
    get object/"$OBJECT_NAME" -n "$NAMESPACE" >/dev/null 2>&1; then
  skip "Object '$OBJECT_NAME' already exists"
else
  info "creating Object..."
  retry 5 3 "apply sample Object" -- \
    kubectl --context "$CONTEXT" apply -f - <<EOF
apiVersion: storage.generic.platform-mesh.io/v1alpha1
kind: Object
metadata:
  name: $OBJECT_NAME
  namespace: $NAMESPACE
spec:
  region: ap
  versioning: false
EOF
  ok "Object '$OBJECT_NAME' submitted to namespace '$NAMESPACE'"
fi

# ── 4. Wait for kro to create the Job ────────────────────────────────────────
step "4/5  waiting for kro to create Job"

if kubectl --context "$CONTEXT" \
    get job/"${OBJECT_NAME}-create" -n "$NAMESPACE" >/dev/null 2>&1; then
  skip "Job ${OBJECT_NAME}-create already exists"
else
  info "kro reconciles asynchronously — polling for Job ${OBJECT_NAME}-create..."
  wait_for_resource "Job ${OBJECT_NAME}-create" 60 2 -- \
    kubectl --context "$CONTEXT" get job/"${OBJECT_NAME}-create" --namespace "$NAMESPACE"
fi
ok "Job ${OBJECT_NAME}-create exists"

# ── 5. Wait for the Job to complete ──────────────────────────────────────────
step "5/5  waiting for Job to complete"

info "running: az storage container create → floci-az"
kubectl --context "$CONTEXT" wait job/"${OBJECT_NAME}-create" \
  --namespace "$NAMESPACE" \
  --for=condition=Complete \
  --timeout=120s

failed=$(kubectl --context "$CONTEXT" get job/"${OBJECT_NAME}-create" \
  --namespace "$NAMESPACE" \
  -o jsonpath='{.status.failed}' 2>/dev/null || echo "0")
if [[ "${failed:-0}" -gt 0 ]]; then
  warn "Job had $failed failed pod(s) — logs:"
  kubectl --context "$CONTEXT" logs \
    --namespace "$NAMESPACE" job/"${OBJECT_NAME}-create" || true
  die "Job ${OBJECT_NAME}-create failed — see logs above"
fi
ok "Job completed — container created in floci-az"

# ── Results ───────────────────────────────────────────────────────────────────
echo
echo -e "${_bold}Job output:${_reset}"
kubectl --context "$CONTEXT" logs \
  --namespace "$NAMESPACE" \
  job/"${OBJECT_NAME}-create" | sed 's/^/  /'

echo
echo -e "${_bold}Object status:${_reset}"
kubectl --context "$CONTEXT" get object "$OBJECT_NAME" \
  --namespace "$NAMESPACE" \
  -o jsonpath='{.status}' | python3 -m json.tool 2>/dev/null | sed 's/^/  /' || \
kubectl --context "$CONTEXT" get object "$OBJECT_NAME" \
  --namespace "$NAMESPACE" \
  -o yaml | grep -A20 "^status:" | sed 's/^/  /'

echo
echo -e "${_green}${_bold}PoC complete.${_reset}"
echo
echo -e "${_bold}Verify:${_reset}"
echo "  kubectl --context $CONTEXT -n floci-azure logs deployment/floci-azure"
echo "  kubectl --context $CONTEXT get object $OBJECT_NAME -n $NAMESPACE -o yaml"
echo
echo -e "${_bold}Teardown:${_reset}"
echo "  kubectl --context $CONTEXT delete object $OBJECT_NAME -n $NAMESPACE"
echo "  kubectl --context $CONTEXT delete -f $repo_root/kind/manifests/floci-azure.yaml"
echo "  kubectl --context $CONTEXT delete rgd objects.storage.generic.platform-mesh.io"
