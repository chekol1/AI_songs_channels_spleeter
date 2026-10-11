#!/usr/bin/env bash
# Stop SoniCloud to free RAM and CPU. NOTHING is deleted: the database, the
# buckets, the users, the cluster and the images all stay on disk.
#
#   bash local-deploy/stop.sh      # stop
#   bash local-deploy/start.sh     # bring it back exactly as it was
#
# A reboot puts things back the way they were: stopped stays stopped, until
# you run start.sh yourself.
#   --keep-autostart   stop now, but let it start again at the next boot
#                      (this is what the system uses at shutdown)
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

step "stopping SoniCloud (data is kept)"
for c in "$INGRESS_CONTAINER" sonicloud-registry-lan; do
  docker stop "$c" >/dev/null 2>&1 && c_ok "stopped $c" || true
done
# The cluster and the database first, Floci last: Floci is their manager.
for c in $(floci_spawned); do
  docker stop -t 30 "$c" >/dev/null 2>&1 && c_ok "stopped $c" || c_warn "could not stop $c"
done
FLOCI_CONTAINER="${FLOCI_CONTAINER:-$(docker ps --filter "label=com.docker.compose.project=$COMPOSE_PROJECT" \
                    --filter "label=com.docker.compose.service=floci" --format '{{.Names}}' | head -n1)}"
if [ -n "$FLOCI_CONTAINER" ]; then
  docker stop -t 30 "$FLOCI_CONTAINER" >/dev/null 2>&1 && c_ok "stopped $FLOCI_CONTAINER" || c_warn "could not stop $FLOCI_CONTAINER"
else
  c_info "floci was not running"
fi

if [ "${1:-}" = "--keep-autostart" ]; then
  c_info "it will start again at the next boot"
else
  rm -f "$RUN_MARKER"
  c_info "it stays stopped, also after a reboot, until: bash local-deploy/start.sh"
fi
step "done"
