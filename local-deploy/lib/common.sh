#!/usr/bin/env bash
# Shared helpers. Everything that could differ between machines is DETECTED,
# never hardcoded -- container IPs, NodePorts and the VM's LAN address all
# change between hosts and between rebuilds.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_DIR="$REPO_ROOT/local-deploy"
CACHE_DIR="${SONICLOUD_CACHE:-$LOCAL_DIR/.cache}"

# --- config knobs (override via env) ---------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-sonicloud-eks}"
NAMESPACE="${NAMESPACE:-sonicloud}"
ACCOUNT_ID="${ACCOUNT_ID:-000000000000}"
AWS_REGION_LOCAL="${AWS_REGION_LOCAL:-us-east-1}"
FLOCI_PORT="${FLOCI_PORT:-4566}"
REGISTRY_PORT="${REGISTRY_PORT:-5100}"
INGRESS_PORT="${INGRESS_PORT:-80}"
FLOCI_CONTAINER="${FLOCI_CONTAINER:-sonicloud-floci}"
EKS_CONTAINER="floci-eks-${CLUSTER_NAME}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-floci-ecr-registry}"
INGRESS_CONTAINER="${INGRESS_CONTAINER:-sonicloud-ingress}"

UPLOAD_BUCKET="sonic-cloud-music-${ACCOUNT_ID}"
RESULTS_BUCKET="sonic-cloud-music-results-${ACCOUNT_ID}"
ECR_HOST="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION_LOCAL}.localhost:${REGISTRY_PORT}"

# --- output ----------------------------------------------------------------
c_ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
c_info() { printf '  \033[36m•\033[0m %s\n' "$*"; }
c_warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
c_err()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

# --- detection --------------------------------------------------------------
# The LAN address of this VM: what a browser on the network will connect to.
detect_host_ip() {
  local ip
  ip="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1); exit}')"
  [ -n "$ip" ] || ip="$(hostname -I | awk '{print $1}')"
  [ -n "$ip" ] || die "could not determine this host's IP address"
  echo "$ip"
}

# A container's IP on a given docker network (default: bridge).
container_ip() {
  local name="$1" net="${2:-bridge}"
  docker inspect -f "{{with index .NetworkSettings.Networks \"$net\"}}{{.IPAddress}}{{end}}" "$name" 2>/dev/null
}

# First non-empty IP on any network the container is attached to.
container_any_ip() {
  docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' "$1" 2>/dev/null | awk '{print $1}'
}

kc() { docker exec "$EKS_CONTAINER" kubectl "$@"; }
kcn() { docker exec "$EKS_CONTAINER" kubectl -n "$NAMESPACE" "$@"; }

aws_local() {
  AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test \
  AWS_DEFAULT_REGION="$AWS_REGION_LOCAL" AWS_PAGER="" \
  aws --endpoint-url "http://localhost:${FLOCI_PORT}" "$@"
}

wait_for() {   # wait_for <seconds> <description> <command...>
  local timeout="$1" what="$2"; shift 2
  local waited=0
  until "$@" >/dev/null 2>&1; do
    sleep 3; waited=$((waited+3))
    if [ "$waited" -ge "$timeout" ]; then c_err "timed out waiting for $what (${timeout}s)"; return 1; fi
  done
  c_ok "$what"
}

have() { command -v "$1" >/dev/null 2>&1; }
