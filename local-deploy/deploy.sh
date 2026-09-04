#!/usr/bin/env bash
# Deploy SoniCloud onto Floci (local AWS emulator) on this VM.
# Idempotent and safe to re-run -- notably after a reboot, when Floci comes back
# with EMPTY state and everything must be recreated.
#
#   bash local-deploy/deploy.sh
#
# Prerequisites: bash local-deploy/install-prereqs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

SKIP_BUILD="${SKIP_BUILD:-0}"      # SKIP_BUILD=1 to reuse images already in the registry
START=$(date +%s)

# ---------------------------------------------------------------- 0. preflight
step "0/9  preflight"
for c in docker terraform aws curl jq; do
  have "$c" || die "$c not found -- run: bash local-deploy/install-prereqs.sh"
done
docker info >/dev/null 2>&1 || die "cannot reach the docker daemon"
HOST_IP="$(detect_host_ip)"
c_ok "docker, terraform, aws cli present"
c_ok "this host: $HOST_IP"
avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "${avail_gb:-0}" -lt 12 ]; then
  c_warn "only ${avail_gb}G free on / -- the worker image alone is ~4.3GB."
  c_warn "if the disk fills, kubelet taints the node and evicts pods. 15G+ recommended."
fi

# ------------------------------------------------------------------- 1. models
step "1/9  spleeter model cache"
if [ -f "$CACHE_DIR/models/2stems/model.index" ]; then
  c_ok "models cached ($(du -sh "$CACHE_DIR/models" | cut -f1))"
else
  bash "$LOCAL_DIR/fetch-models.sh"
fi

# -------------------------------------------------------------------- 2. floci
step "2/9  floci emulator"
(cd "$LOCAL_DIR" && docker compose -f floci-compose.yml up -d >/dev/null)
wait_for 120 "floci healthy on :$FLOCI_PORT" \
  bash -c "curl -sf -m 5 http://localhost:$FLOCI_PORT/_localstack/health >/dev/null"
FLOCI_IP="$(container_any_ip "$FLOCI_CONTAINER")"
[ -n "$FLOCI_IP" ] || die "could not determine the floci container IP"
c_ok "floci container at $FLOCI_IP"

# Floci keeps no service state across restarts, so any existing tfstate is stale.
if [ -f "$REPO_ROOT/infra/terraform.tfstate" ] \
   && [ "$(aws_local s3api list-buckets --query 'length(Buckets)' 2>/dev/null || echo 0)" = "0" ]; then
  c_warn "floci is empty but terraform state exists -- state is stale, resetting"
  rm -f "$REPO_ROOT/infra/terraform.tfstate" "$REPO_ROOT/infra/terraform.tfstate.backup"
fi

# Floci's internal image pulls time out after ~60s, which is what makes EKS and
# RDS fail on a first run. Pre-pull so they are already local.
step "3/9  pre-pulling images floci needs (avoids its 60s pull timeout)"
for img in rancher/k3s:latest postgres:16-alpine; do
  if docker image inspect "$img" >/dev/null 2>&1; then c_ok "$img cached"
  else c_info "pulling $img ..."
       docker pull -q "$img" >/dev/null 2>&1 && c_ok "$img" || c_warn "could not pull $img"
  fi
done

# ---------------------------------------------------------------- 4. terraform
step "4/9  terraform"
cd "$REPO_ROOT/infra"
[ -d .terraform ] || terraform init -input=false >/dev/null
terraform apply -auto-approve -input=false >/dev/null 2>&1 || {
  c_err "terraform apply failed; rerunning to show the error"; terraform apply -auto-approve -input=false; exit 1; }
c_ok "$(terraform state list | wc -l) resources"
DB_PASSWORD="$(terraform output -raw db_password)"
QUEUE_URL="$(terraform output -raw sqs_url)"
cd "$REPO_ROOT"

DB_HOST="$(aws_local rds describe-db-instances --db-instance-identifier sonicloud-db \
            --query 'DBInstances[0].Endpoint.Address' --output text)"
DB_PORT="$(aws_local rds describe-db-instances --db-instance-identifier sonicloud-db \
            --query 'DBInstances[0].Endpoint.Port' --output text)"
c_ok "rds at $DB_HOST:$DB_PORT"
# The worker talks to floci container-to-container; the QUEUE_URL terraform
# emits points at localhost, which is meaningless inside a pod.
QUEUE_URL="${QUEUE_URL/localhost/$FLOCI_IP}"

# ------------------------------------------------------------------ 5. registry
step "5/9  container images"
REGISTRY_IP="$(container_ip "$REGISTRY_CONTAINER" bridge)"
[ -n "$REGISTRY_IP" ] || die "the floci ECR registry container is not running"
c_ok "registry at $REGISTRY_IP:5000 (published on localhost:$REGISTRY_PORT)"
# NOTE: docker refuses plain HTTP to the ECR-style hostname
# ("server gave HTTP response to HTTPS client") unless it is in
# /etc/docker/daemon.json insecure-registries, which needs root. Pushing via
# localhost:PORT hits the SAME registry and needs no privileges; the k3s mirror
# below makes the pull side resolve the ECR name.
# Images are keyed by a hash of their build context, so a source change forces
# a rebuild. Checking only for "some image exists" silently ships stale code --
# that is exactly how a pre-fix api image survived a source change once.
src_hash() { find "$1" -type f -exec sha256sum {} + | sort | sha256sum | cut -c1-12; }

if [ "$SKIP_BUILD" = "1" ]; then
  c_info "SKIP_BUILD=1, reusing whatever is in the registry"
else
  for svc in api web worker; do
    tag="src-$(src_hash "$REPO_ROOT/$svc")"
    if [ "${FORCE_BUILD:-0}" != "1" ] \
       && curl -sf -m 5 "http://localhost:$REGISTRY_PORT/v2/sonicloud-$svc/tags/list" \
          | grep -q "\"$tag\""; then
      c_ok "sonicloud-$svc up to date ($tag)"
    else
      if [ "$svc" = worker ]; then
        c_info "building sonicloud-$svc ($tag) -- ~4.3GB with TensorFlow, this takes a while ..."
      else
        c_info "building sonicloud-$svc ($tag) ..."
      fi
      # NOTE: -q hides the build output, so a failure shows only "exit code N"
      # with no cause. On failure, replay verbosely before giving up -- apt and
      # pip failures here are often transient network blips worth retrying once.
      if ! docker build -q -t "sonicloud-$svc:local" "$REPO_ROOT/$svc" >/dev/null 2>&1; then
        c_warn "build failed for $svc -- retrying once with full output"
        docker build --progress=plain -t "sonicloud-$svc:local" "$REPO_ROOT/$svc" \
          || die "build failed for $svc (see the output above)"
      fi
      c_ok "sonicloud-$svc built"
    fi
    # Always (re)publish both tags: cheap when the layers already exist, and it
    # guarantees :latest points at the current source.
    if docker image inspect "sonicloud-$svc:local" >/dev/null 2>&1; then
      for t in "$tag" latest; do
        docker tag "sonicloud-$svc:local" "localhost:$REGISTRY_PORT/sonicloud-$svc:$t"
        docker push -q "localhost:$REGISTRY_PORT/sonicloud-$svc:$t" >/dev/null || die "push failed for $svc:$t"
      done
      c_ok "sonicloud-$svc pushed ($tag, latest)"
    fi
  done
fi

# ----------------------------------------------------------------- 6. k3s mirror
step "6/9  k3s registry mirror"
wait_for 180 "eks cluster container up" docker inspect "$EKS_CONTAINER"
printf 'mirrors:\n  "%s":\n    endpoint:\n      - "http://%s:5000"\n' "$ECR_HOST" "$REGISTRY_IP" > /tmp/registries.yaml
docker exec "$EKS_CONTAINER" mkdir -p /etc/rancher/k3s /tmp/k8s
docker cp /tmp/registries.yaml "$EKS_CONTAINER:/etc/rancher/k3s/registries.yaml"
if ! docker exec "$EKS_CONTAINER" test -d "/var/lib/rancher/k3s/agent/etc/containerd/certs.d/$ECR_HOST" 2>/dev/null; then
  c_info "restarting k3s to load the mirror ..."
  docker restart "$EKS_CONTAINER" >/dev/null
fi
wait_for 180 "kubernetes API responding" docker exec "$EKS_CONTAINER" kubectl get nodes
# A rebuild can leave the previous node object behind, holding ghost pods.
for n in $(kc get nodes --no-headers 2>/dev/null | awk '$2!="Ready"{print $1}'); do
  kc delete node "$n" >/dev/null 2>&1 && c_info "removed stale node $n"
done
c_ok "cluster ready ($(kc get nodes --no-headers | wc -l) node)"

# -------------------------------------------------------------------- 7. deploy
step "7/9  deploying workloads"
export ECR_HOST AWS_REGION_LOCAL HOST_IP FLOCI_PORT FLOCI_IP \
       UPLOAD_BUCKET RESULTS_BUCKET QUEUE_URL NAMESPACE
render_dir="$(mktemp -d)"
cp "$LOCAL_DIR/k8s/namespace.yaml" "$LOCAL_DIR/k8s/models-pvc.yaml" "$render_dir/"
for t in api web worker; do
  envsubst < "$LOCAL_DIR/k8s/$t.yaml.tmpl" > "$render_dir/$t.yaml"
done
docker cp "$render_dir/." "$EKS_CONTAINER:/tmp/k8s/" >/dev/null
rm -rf "$render_dir"

kc apply -f /tmp/k8s/namespace.yaml >/dev/null
# random_password regenerates on every apply, so the Secret must be refreshed.
kcn delete secret sonicloud-secrets --ignore-not-found >/dev/null 2>&1
kcn create secret generic sonicloud-secrets \
  --from-literal=db_host="$DB_HOST" \
  --from-literal=db_port="$DB_PORT" \
  --from-literal=db_password="$DB_PASSWORD" >/dev/null
c_ok "secret sonicloud-secrets"
for f in models-pvc api web worker; do kc apply -f "/tmp/k8s/$f.yaml" >/dev/null; done
c_ok "manifests applied"
kcn rollout restart deploy/api deploy/web deploy/worker >/dev/null 2>&1 || true
for d in api web worker; do
  kcn rollout status "deploy/$d" --timeout=300s >/dev/null 2>&1 \
    && c_ok "$d ready" || c_warn "$d not ready yet (kubectl -n $NAMESPACE describe deploy/$d)"
done

# --------------------------------------------------------------- 8. seed models
step "8/9  seeding the model cache into the cluster"
WPOD="$(kcn get pods -l app=worker --field-selector status.phase=Running \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$WPOD" ]; then
  c_warn "no running worker pod; skipping seed (rerun deploy.sh once it is up)"
elif docker exec "$EKS_CONTAINER" kubectl -n "$NAMESPACE" exec "$WPOD" -- test -f /models/2stems/model.index 2>/dev/null; then
  c_ok "models already present in the cluster"
else
  tar cf - -C "$CACHE_DIR/models" . \
    | docker exec -i "$EKS_CONTAINER" kubectl -n "$NAMESPACE" exec -i "$WPOD" -- tar xf - -C /models
  c_ok "seeded $(docker exec "$EKS_CONTAINER" kubectl -n "$NAMESPACE" exec "$WPOD" -- du -sh /models | cut -f1) into /models"
fi

# ------------------------------------------------------------------ 9. ingress
step "9/9  publishing the site on the LAN"
K3S_IP="$(container_ip "$EKS_CONTAINER" bridge)"
docker rm -f "$INGRESS_CONTAINER" >/dev/null 2>&1 || true
# klipper-lb serves the web Service on port 80 of the k3s container, which is
# only reachable inside this VM. Republish it on the host's LAN address.
docker run -d --restart unless-stopped --name "$INGRESS_CONTAINER" \
  -p "${INGRESS_PORT}:80" alpine/socat \
  "tcp-listen:80,fork,reuseaddr" "tcp-connect:${K3S_IP}:80" >/dev/null
wait_for 60 "site answering on http://$HOST_IP:$INGRESS_PORT/" \
  bash -c "curl -sf -m 5 -o /dev/null http://$HOST_IP:$INGRESS_PORT/"

printf '\n\033[1;32m==> SoniCloud is up\033[0m\n\n'
printf '   Open:  \033[1mhttp://%s%s/\033[0m\n' "$HOST_IP" \
  "$([ "$INGRESS_PORT" = 80 ] && echo "" || echo ":$INGRESS_PORT")"
printf '   API :  http://%s/api/jobs\n' "$HOST_IP"
printf '\n   took %ss\n\n' "$(( $(date +%s) - START ))"
printf '   kubectl:  docker exec %s kubectl -n %s get all\n' "$EKS_CONTAINER" "$NAMESPACE"
printf '   teardown: bash local-deploy/teardown.sh\n\n'
