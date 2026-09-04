#!/usr/bin/env bash
# Tear the local deployment down.
#   bash local-deploy/teardown.sh          # stack down, model cache kept
#   bash local-deploy/teardown.sh --all    # also drop the model cache + images
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

step "stopping ingress"
docker rm -f "$INGRESS_CONTAINER" >/dev/null 2>&1 && c_ok "removed $INGRESS_CONTAINER" || c_info "not running"

step "terraform destroy"
if [ -f "$REPO_ROOT/infra/terraform.tfstate" ]; then
  (cd "$REPO_ROOT/infra" && terraform destroy -auto-approve -input=false >/dev/null 2>&1) \
    && c_ok "destroyed" || c_warn "destroy failed; removing containers directly"
fi

step "removing floci-spawned containers"
ids="$(docker ps -aq --filter 'name=floci-eks-' --filter 'name=floci-rds-' --filter 'name=floci-ecr-' 2>/dev/null || true)"
[ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1 && c_ok "removed" || c_info "none"

step "stopping floci"
(cd "$LOCAL_DIR" && docker compose -f floci-compose.yml down -v >/dev/null 2>&1) && c_ok "floci down" || c_info "not running"

rm -f "$REPO_ROOT/infra/terraform.tfstate" "$REPO_ROOT/infra/terraform.tfstate.backup"
c_ok "cleared terraform state (Floci keeps no state across restarts anyway)"

if [ "${1:-}" = "--all" ]; then
  step "removing cached models and built images"
  rm -rf "$CACHE_DIR/models" && c_ok "model cache removed"
  docker rmi -f sonicloud-api:local sonicloud-web:local sonicloud-worker:local >/dev/null 2>&1 || true
  docker volume rm floci-ecr-registry-data >/dev/null 2>&1 || true
  c_ok "images and registry volume removed"
fi
step "done"
