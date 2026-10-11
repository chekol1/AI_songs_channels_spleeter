#!/usr/bin/env bash
# Start SoniCloud again after stop.sh or after a reboot. Same as deploy.sh --
# there is one code path for bringing things up -- plus a log file.
#
#   bash local-deploy/start.sh
#   bash local-deploy/start.sh --boot    # how the system calls it at boot:
#                                        # does nothing if you stopped it on purpose
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

if [ "${1:-}" = "--boot" ]; then
  if [ -f "$STOP_MARKER" ]; then
    echo "SoniCloud was stopped on purpose ($(cat "$STOP_MARKER")). Not starting. Run: bash local-deploy/start.sh"
    exit 0
  fi
  # Argo CD lives in another cluster on this machine that is booting too.
  export ARGOCD_WAIT="${ARGOCD_WAIT:-300}"
fi

mkdir -p "$SONICLOUD_HOME/logs"
log="$SONICLOUD_HOME/logs/start-$(date +%Y%m%d-%H%M%S).log"
# Keep the 20 newest logs.
{ ls -1t "$SONICLOUD_HOME/logs"/start-*.log 2>/dev/null || true; } | tail -n +20 | xargs -r rm -f
echo "log: $log"
set +e
bash "$LOCAL_DIR/deploy.sh" 2>&1 | tee "$log"
exit "${PIPESTATUS[0]}"
