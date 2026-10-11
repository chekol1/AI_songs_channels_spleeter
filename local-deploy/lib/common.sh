#!/usr/bin/env bash
# Shared helpers. Everything that could differ between machines is DETECTED,
# never hardcoded -- container IPs, NodePorts and the VM's LAN address all
# change between hosts and between rebuilds.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LOCAL_DIR="$REPO_ROOT/local-deploy"

# --- where this machine keeps its state -------------------------------------
# The Git clone is disposable: delete it, clone again next month, and the
# deployment must come back exactly as it was. So nothing that matters lives in
# the clone. It lives in docker volumes with fixed names, and in this folder:
#   env      machine-specific settings (KEY=value lines), read below
#   models/  the downloaded Spleeter models
#   logs/    output of unattended starts
#   running  marker: "it was up". Only then is it started again at boot, so a
#            reboot returns the machine to the state it was in before.
SONICLOUD_HOME="${SONICLOUD_HOME:-$HOME/.sonicloud}"
mkdir -p "$SONICLOUD_HOME"
if [ -f "$SONICLOUD_HOME/env" ]; then
  set -a; . "$SONICLOUD_HOME/env"; set +a
fi
CACHE_DIR="${SONICLOUD_CACHE:-$SONICLOUD_HOME}"
# Fixed docker compose project name, so the clone's path does not matter.
COMPOSE_PROJECT="sonicloud"
TFSTATE_BUCKET="${TFSTATE_BUCKET:-sonicloud-tfstate}"
RUN_MARKER="$SONICLOUD_HOME/running"

# --- config knobs (override via env) ---------------------------------------
CLUSTER_NAME="${CLUSTER_NAME:-sonicloud-eks}"
NAMESPACE="${NAMESPACE:-sonicloud}"
ACCOUNT_ID="${ACCOUNT_ID:-000000000000}"
AWS_REGION_LOCAL="${AWS_REGION_LOCAL:-us-east-1}"
FLOCI_PORT="${FLOCI_PORT:-4566}"
REGISTRY_PORT="${REGISTRY_PORT:-5100}"
# 8088, not 80: on a shared lab server port 80 usually belongs to something
# else already (here: the lab cluster's Traefik). INGRESS_PORT=80 to override.
INGRESS_PORT="${INGRESS_PORT:-8088}"
# Name to give the Floci container when it is created. A lab server whose
# other tools expect a different name sets this in ~/.sonicloud/env.
export FLOCI_CONTAINER_NAME="${FLOCI_CONTAINER_NAME:-sonicloud-floci}"
# Empty means "find it": see resolve_floci_container below.
FLOCI_CONTAINER="${FLOCI_CONTAINER:-}"
EKS_CONTAINER="floci-eks-${CLUSTER_NAME}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-floci-ecr-registry}"
INGRESS_CONTAINER="${INGRESS_CONTAINER:-sonicloud-ingress}"

UPLOAD_BUCKET="sonic-cloud-music-${ACCOUNT_ID}"
RESULTS_BUCKET="sonic-cloud-music-results-${ACCOUNT_ID}"
ECR_HOST="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION_LOCAL}.localhost:${REGISTRY_PORT}"

# --- GitOps (Argo CD) --------------------------------------------------------
# The manifests Argo CD deploys, and the Argo CD that deploys them. Argo CD is
# NOT installed by this project: it is the one already running in the lab
# cluster (k3s) on this server, and it manages SoniCloud's cluster from outside.
GITOPS_DIR="$LOCAL_DIR/gitops"
ARGOCD_APP_FILE="$LOCAL_DIR/argocd/sonicloud-local.yaml"
ARGOCD_APP_NAME="${ARGOCD_APP_NAME:-sonicloud-local}"
ARGOCD_NAMESPACE="${ARGOCD_NAMESPACE:-argocd}"
ARGOCD_KUBECONFIG="${ARGOCD_KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"
ARGOCD_CLUSTER_NAME="${ARGOCD_CLUSTER_NAME:-sonicloud-floci}"
# Branch Argo CD follows. Empty = whatever the Application file says. Set it to
# test a feature branch:  GITOPS_REVISION=my-branch bash local-deploy/deploy.sh
GITOPS_REVISION="${GITOPS_REVISION:-}"
# auto   = use Argo CD when it is reachable, otherwise apply directly
# argocd = require Argo CD            direct = never use Argo CD
DEPLOY_MODE="${DEPLOY_MODE:-auto}"

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

# The Floci container. Its name differs between machines (this compose file
# calls it sonicloud-floci; a lab server may have renamed it), so look it up by
# the labels docker compose puts on it, and only then fall back to known names.
resolve_floci_container() {
  local name
  if [ -n "$FLOCI_CONTAINER" ]; then
    docker inspect "$FLOCI_CONTAINER" >/dev/null 2>&1 \
      || die "FLOCI_CONTAINER=$FLOCI_CONTAINER is set, but no such container exists"
    return 0
  fi
  name="$(docker ps -a \
            --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
            --filter "label=com.docker.compose.service=floci" \
            --format '{{.Names}}' | head -n1)"
  if [ -z "$name" ]; then
    for name in "$FLOCI_CONTAINER_NAME" sonicloud-floci floci ""; do
      [ -n "$name" ] && docker inspect "$name" >/dev/null 2>&1 && break
    done
  fi
  [ -n "$name" ] || die "cannot find the Floci container (is it running? docker ps). Set FLOCI_CONTAINER=<name> to point at it."
  FLOCI_CONTAINER="$name"
}

compose() { docker compose -p "$COMPOSE_PROJECT" -f "$LOCAL_DIR/floci-compose.yml" "$@"; }

# Every container Floci started for this deployment (cluster, database, registry).
floci_spawned() {   # floci_spawned [-a]
  docker ps "$@" --format '{{.Names}}' | grep -E '^floci-(eks|rds|ecr)-' || true
}

# kubectl against the LAB cluster, where Argo CD lives (not SoniCloud's cluster).
akc() { kubectl --kubeconfig "$ARGOCD_KUBECONFIG" "$@"; }

argocd_available() {
  have kubectl && [ -r "$ARGOCD_KUBECONFIG" ] \
    && akc --request-timeout=10s -n "$ARGOCD_NAMESPACE" get deploy argocd-repo-server >/dev/null 2>&1
}

# Release tag a component is pinned to in the GitOps manifests.
gitops_tag() {   # gitops_tag <api|web|worker>
  sed -n "s|^ *image: .*/sonicloud-$1:\([^ ]*\) *$|\1|p" "$GITOPS_DIR/$1.yaml" | head -n1
}

kc() { docker exec "$EKS_CONTAINER" kubectl "$@"; }
kcn() { docker exec "$EKS_CONTAINER" kubectl -n "$NAMESPACE" "$@"; }
# kubectl apply reading the manifest from stdin (the files live on the host,
# kubectl runs inside the cluster container).
kc_apply() { docker exec -i "$EKS_CONTAINER" kubectl apply -f - ; }

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
