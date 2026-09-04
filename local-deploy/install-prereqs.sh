#!/usr/bin/env bash
# Install what the local deployment needs on a fresh Ubuntu/Debian VM.
# Idempotent: everything is checked before it is installed.
#
#   bash local-deploy/install-prereqs.sh
#
# Needs sudo for apt + docker. Terraform and the AWS CLI go to ~/.local/bin,
# which needs no root at all.
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

TF_VERSION="${TF_VERSION:-1.9.8}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"

need_sudo() {
  if [ "$(id -u)" -eq 0 ]; then SUDO=""; return; fi
  have sudo || die "sudo is required to install system packages"
  SUDO="sudo"
  if ! sudo -n true 2>/dev/null; then
    c_warn "sudo will prompt for your password"
  fi
}

step "1/6  base packages"
if have curl && have unzip && have jq && have git && have tmux && have envsubst; then
  c_ok "curl, unzip, jq, git, tmux, envsubst already present"
else
  need_sudo
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq curl unzip jq git tmux ca-certificates gettext-base
  c_ok "installed base packages"
fi

step "2/6  docker engine + compose plugin"
if have docker && docker compose version >/dev/null 2>&1; then
  c_ok "docker $(docker --version | awk '{print $3}' | tr -d ,) with compose plugin"
else
  need_sudo
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO tee /etc/apt/keyrings/docker.asc >/dev/null
  $SUDO chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" \
    | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  c_ok "installed docker"
fi

step "3/6  docker group membership"
if id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
  c_ok "$USER is in the docker group"
else
  need_sudo
  $SUDO usermod -aG docker "$USER"
  c_warn "added $USER to the docker group -- LOG OUT AND BACK IN, then re-run this script"
  exit 1
fi
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is it running? 'sudo systemctl start docker')"

step "4/6  terraform ${TF_VERSION}"
if have terraform; then
  c_ok "terraform $(terraform version -json 2>/dev/null | jq -r .terraform_version 2>/dev/null || echo present)"
else
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/tf.zip" \
    "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip"
  unzip -q -o "$tmp/tf.zip" -d "$BIN_DIR"; rm -rf "$tmp"
  c_ok "terraform -> $BIN_DIR/terraform"
fi

step "5/6  aws cli v2"
if have aws; then
  c_ok "$(aws --version 2>&1 | awk '{print $1}')"
else
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"
  unzip -q "$tmp/awscli.zip" -d "$tmp"
  "$tmp/aws/install" --install-dir "$HOME/.local/aws-cli" --bin-dir "$BIN_DIR" >/dev/null
  rm -rf "$tmp"
  c_ok "aws cli -> $BIN_DIR/aws"
fi

step "6/6  PATH"
if echo ":$PATH:" | grep -q ":$BIN_DIR:"; then
  c_ok "$BIN_DIR is on PATH"
else
  if ! grep -qs "$BIN_DIR" "$HOME/.bashrc"; then
    echo "export PATH=\"$BIN_DIR:\$PATH\"" >> "$HOME/.bashrc"
  fi
  c_warn "added $BIN_DIR to ~/.bashrc -- run: export PATH=\"$BIN_DIR:\$PATH\""
fi

step "done"
c_info "next:  bash local-deploy/deploy.sh"
