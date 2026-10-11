#!/usr/bin/env bash
# Make a reboot return SoniCloud to the state it was in (systemd):
# up before the reboot -> started again; stopped or not deployed -> left alone.
#
#   bash local-deploy/install-service.sh            # needs sudo once
#   bash local-deploy/install-service.sh --remove
#
# The service points at THIS clone. If you delete the clone and clone again
# somewhere else, run this again from the new one.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
UNIT=/etc/systemd/system/sonicloud.service

if [ "${1:-}" = "--remove" ]; then
  sudo systemctl disable sonicloud.service 2>/dev/null || true
  sudo rm -f "$UNIT" && sudo systemctl daemon-reload
  c_ok "service removed (the deployment itself is untouched)"
  exit 0
fi

for c in docker terraform aws kubectl jq curl; do have "$c" || c_warn "$c not found in PATH"; done
# systemd starts with a minimal PATH; give it the folders the tools are in.
tool_path="$(for c in docker terraform aws kubectl jq curl bash; do dirname "$(command -v "$c" 2>/dev/null || echo /usr/bin/x)"; done | awk '!s[$0]++' | paste -sd:)"
after="docker.service network-online.target"
systemctl list-unit-files k3s.service >/dev/null 2>&1 && after="$after k3s.service"

tmp="$(mktemp)"
cat > "$tmp" <<UNITFILE
[Unit]
Description=SoniCloud local deployment (Floci)
Documentation=file://$LOCAL_DIR/README.md
Requires=docker.service
Wants=network-online.target
After=$after

[Service]
Type=oneshot
RemainAfterExit=yes
User=$(id -un)
Group=$(id -gn)
Environment=HOME=$HOME
Environment=PATH=$tool_path:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WorkingDirectory=$REPO_ROOT
ExecStart=/usr/bin/env bash $LOCAL_DIR/start.sh --boot
ExecStop=/usr/bin/env bash $LOCAL_DIR/stop.sh --keep-autostart
TimeoutStartSec=1200
TimeoutStopSec=180

[Install]
WantedBy=multi-user.target
UNITFILE

step "installing $UNIT (sudo)"
sudo install -m 644 "$tmp" "$UNIT" && sudo systemctl daemon-reload && sudo systemctl enable sonicloud.service
rm -f "$tmp"
c_ok "installed and enabled"
c_info "at boot it runs:  start.sh --boot     (log: $SONICLOUD_HOME/logs/)"
c_info "it starts SoniCloud at boot only if it was up before the reboot"
c_info "it was NOT started now; the running deployment is untouched"
