#!/usr/bin/env bash
# DELETE the local deployment, including its data.
#
# To only free RAM, you do not want this. Use:   bash local-deploy/stop.sh
#
#   bash local-deploy/teardown.sh --destroy-data         # database, buckets, users,
#                                                        # cluster, Terraform state
#   bash local-deploy/teardown.sh --destroy-data --all   # also models, images, registry
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

DESTROY=0; ALL=0
for a in "$@"; do
  case "$a" in
    --destroy-data) DESTROY=1 ;;
    --all)          ALL=1 ;;
    *) die "unknown option: $a" ;;
  esac
done
if [ "$DESTROY" != 1 ]; then
  cat >&2 <<MSG

  teardown.sh deletes data: the database, the buckets, the users, the cluster.
  Nothing was done.

    Only free RAM, keep everything:   bash local-deploy/stop.sh
    Really delete the deployment:     bash local-deploy/teardown.sh --destroy-data

MSG
  exit 1
fi

step "removing the Argo CD application"
if argocd_available; then
  # Without its finalizer Argo CD forgets the app but does not try to delete
  # workloads in a cluster that is about to disappear anyway.
  akc -n "$ARGOCD_NAMESPACE" patch application "$ARGOCD_APP_NAME" --type=merge \
      -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
  akc -n "$ARGOCD_NAMESPACE" delete application "$ARGOCD_APP_NAME" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  akc -n "$ARGOCD_NAMESPACE" delete secret "cluster-$ARGOCD_CLUSTER_NAME" --ignore-not-found >/dev/null 2>&1 || true
  c_ok "application and cluster registration removed"
else
  c_info "Argo CD not reachable; skipped"
fi

step "stopping ingress"
docker rm -f "$INGRESS_CONTAINER" >/dev/null 2>&1 && c_ok "removed $INGRESS_CONTAINER" || c_info "not running"

step "removing floci-spawned containers and their volumes"
names="$(floci_spawned -a)"
if [ -n "$names" ]; then
  docker rm -f $names >/dev/null 2>&1 || true
  for n in $names; do
    case "$n" in floci-eks-*|floci-rds-*) docker volume rm "$n" >/dev/null 2>&1 || true ;; esac
  done
  c_ok "removed: $(echo $names)"
else
  c_info "none"
fi

step "removing floci and its data"
# No "terraform destroy": the state is in a bucket inside Floci, and Floci's
# whole volume goes now, so resources and state disappear together.
compose down -v >/dev/null 2>&1 && c_ok "floci down, volume removed" || c_info "not running"
# Only the pointer to the (now deleted) state. The downloaded providers stay:
# they are large and have nothing to do with the data.
rm -f "$REPO_ROOT/infra/.terraform/terraform.tfstate" "$REPO_ROOT"/infra/terraform.tfstate*
rm -f "$RUN_MARKER"

if [ "$ALL" = 1 ]; then
  step "removing cached models and built images"
  rm -rf "$CACHE_DIR/models" && c_ok "model cache removed"
  docker rmi -f sonicloud-api:local sonicloud-web:local sonicloud-worker:local >/dev/null 2>&1 || true
  docker volume rm floci-ecr-registry-data >/dev/null 2>&1 || true
  c_ok "images and registry volume removed"
fi
step "done"
