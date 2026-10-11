#!/usr/bin/env bash
# Bring SoniCloud up on Floci (local AWS emulator) on this machine.
#
# Safe to run any number of times, and it is the ONLY way things are brought up:
# first install, after a reboot, after stop.sh, after pulling new code. It looks
# at what exists, repairs what a restart broke, and creates only what is missing.
#
#   bash local-deploy/deploy.sh
#
# Prerequisites: bash local-deploy/install-prereqs.sh
# Machine-specific settings: ~/.sonicloud/env   (see local-deploy/README.md)
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

START=$(date +%s)
k3s_up() { docker exec "$EKS_CONTAINER" kubectl get --raw /readyz >/dev/null 2>&1; }

# ---------------------------------------------------------------- 0. preflight
step "0/10  preflight"
for c in docker terraform aws curl jq; do
  have "$c" || die "$c not found -- run: bash local-deploy/install-prereqs.sh"
done
docker info >/dev/null 2>&1 || die "cannot reach the docker daemon"
HOST_IP="$(detect_host_ip)"
c_ok "docker, terraform, aws cli present"
c_ok "this host: $HOST_IP"
c_ok "state folder: $SONICLOUD_HOME"
avail_gb=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [ "${avail_gb:-0}" -lt 12 ]; then
  c_warn "only ${avail_gb}G free on / -- the worker image alone is ~4.3GB."
  c_warn "if the disk fills, kubelet taints the node and evicts pods. 15G+ recommended."
fi
# From here on the intent is "up": a reboot brings it back (see start.sh --boot).
date > "$RUN_MARKER"; rm -f "$SONICLOUD_HOME/stopped"

# ------------------------------------------------------------------- 1. models
step "1/10  spleeter model cache"
# Older versions kept the models inside the clone. Move them out once.
if [ ! -d "$CACHE_DIR/models" ] && [ -d "$LOCAL_DIR/.cache/models" ]; then
  mv "$LOCAL_DIR/.cache/models" "$CACHE_DIR/models" && rmdir "$LOCAL_DIR/.cache" 2>/dev/null || true
  c_info "moved the model cache out of the clone to $CACHE_DIR/models"
fi
if [ -f "$CACHE_DIR/models/2stems/model.index" ]; then
  c_ok "models cached ($(du -sh "$CACHE_DIR/models" | cut -f1))"
else
  bash "$LOCAL_DIR/fetch-models.sh"
fi

# -------------------------------------------------------------------- 2. floci
step "2/10  floci emulator"
# The LAN forwarder for the registry used to be started by hand. Compose owns it
# now; a hand-started one with the same name would block compose, so remove it.
# It holds no data.
if docker inspect sonicloud-registry-lan >/dev/null 2>&1 \
   && [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' sonicloud-registry-lan 2>/dev/null)" != "$COMPOSE_PROJECT" ]; then
  docker rm -f sonicloud-registry-lan >/dev/null
  c_info "replaced the old registry forwarder with the compose-managed one"
fi
# Listen for the build machine on this host's LAN address only.
export REGISTRY_LAN_BIND="${REGISTRY_LAN_BIND:-$HOST_IP}" REGISTRY_PORT FLOCI_PORT
compose up -d >/dev/null 2>"$SONICLOUD_HOME/compose.err" \
  || { cat "$SONICLOUD_HOME/compose.err" >&2; die "docker compose could not start Floci (see the message above)"; }
wait_for 120 "floci healthy on :$FLOCI_PORT" \
  bash -c "curl -sf -m 5 http://localhost:$FLOCI_PORT/_localstack/health >/dev/null"
resolve_floci_container
FLOCI_IP="$(container_any_ip "$FLOCI_CONTAINER" || true)"
[ -n "$FLOCI_IP" ] || die "could not determine the floci container IP"
c_ok "floci container \"$FLOCI_CONTAINER\" at $FLOCI_IP"

# Floci's internal image pulls time out after ~60s, which is what makes EKS and
# RDS fail on a first run. Pre-pull so they are already local.
step "3/10  pre-pulling images floci needs (avoids its 60s pull timeout)"
for img in rancher/k3s:latest postgres:16-alpine; do
  if docker image inspect "$img" >/dev/null 2>&1; then c_ok "$img cached"
  else c_info "pulling $img ..."
       docker pull -q "$img" >/dev/null 2>&1 && c_ok "$img" || c_warn "could not pull $img"
  fi
done

# ------------------------------------------------------- 4. cluster after restart
step "4/10  cluster check"
# After a reboot Floci still REPORTS the cluster as ACTIVE, but the container
# behind it may be stopped, or crash-looping because its address changed
# ("failed to find interface with specified node ip"). Floci does not notice.
# Asking Floci to describe the cluster makes it rebuild a MISSING container
# from the cluster's volume, so the cure is: start it, and if that does not
# work, remove it and ask.
CLUSTER_REBUILT=0
if ! aws_local eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  c_info "no cluster yet -- terraform creates it in the next step"
else
  case "$(docker inspect -f '{{.State.Status}}' "$EKS_CONTAINER" 2>/dev/null || echo missing)" in
    exited|created) docker start "$EKS_CONTAINER" >/dev/null 2>&1 || true ;;
  esac
  waited=0
  until k3s_up || [ "$waited" -ge 75 ]; do sleep 3; waited=$((waited+3)); done
  if k3s_up; then
    c_ok "cluster container healthy"
  else
    c_warn "cluster container is not healthy -- rebuilding it from its volume"
    docker rm -f "$EKS_CONTAINER" >/dev/null 2>&1 || true
    wait_for 180 "floci recreated the cluster container" \
      bash -c "AWS_ACCESS_KEY_ID=test AWS_SECRET_ACCESS_KEY=test AWS_DEFAULT_REGION=$AWS_REGION_LOCAL \
               aws --endpoint-url http://localhost:$FLOCI_PORT eks describe-cluster --name $CLUSTER_NAME >/dev/null 2>&1; \
               [ \"\$(docker inspect -f '{{.State.Running}}' $EKS_CONTAINER 2>/dev/null)\" = true ]" \
      || die "Floci did not recreate the cluster container (docker logs $FLOCI_CONTAINER)"
    wait_for 300 "kubernetes API responding" k3s_up \
      || die "the rebuilt cluster does not answer (docker logs $EKS_CONTAINER)"
    CLUSTER_REBUILT=1
  fi
fi

# ---------------------------------------------------------------- 5. terraform
step "5/10  terraform"
# State bucket first: Terraform cannot create the bucket its own state lives in.
if ! aws_local s3api head-bucket --bucket "$TFSTATE_BUCKET" >/dev/null 2>&1; then
  aws_local s3api create-bucket --bucket "$TFSTATE_BUCKET" >/dev/null \
    || die "could not create the state bucket $TFSTATE_BUCKET in Floci"
  c_info "created state bucket $TFSTATE_BUCKET"
fi
# Keep downloaded providers outside the clone (the AWS one is several hundred
# MB): a fresh clone then links to them instead of downloading again.
export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-$SONICLOUD_HOME/terraform-plugins}"
mkdir -p "$TF_PLUGIN_CACHE_DIR"
cd "$REPO_ROOT/infra"
if [ -f terraform.tfstate ]; then
  # From before the state moved into the bucket. It describes a Floci that no
  # longer exists; keeping it around only invites confusion.
  mv terraform.tfstate "terraform.tfstate.old-local.$(date +%s)" && rm -f terraform.tfstate.backup
  c_warn "set aside an old local state file (state now lives in s3://$TFSTATE_BUCKET)"
fi
if ! grep -q '"type": *"s3"' .terraform/terraform.tfstate 2>/dev/null; then
  [ -d .terraform/providers ] || c_info "downloading terraform providers (first time only; slow on a slow link) ..."
  terraform init -input=false -reconfigure >"$SONICLOUD_HOME/terraform-init.log" 2>&1 \
    || { tail -n 30 "$SONICLOUD_HOME/terraform-init.log" >&2; die "terraform init failed"; }
fi
# The image registry has its own volume, and Floci lists a repository for every
# image folder it finds there. So after Floci's data was deleted but the images
# were kept (teardown --destroy-data without --all), the repositories exist
# while the fresh state knows nothing about them, and "create" fails with
# RepositoryAlreadyExists. Adopt them into the state instead.
# Terraform "import" blocks do that as part of the normal apply; the file is
# written only when needed and removed again right after.
adopt_file="zz_adopt_existing.tf"
rm -f "$adopt_file"
trap 'rm -f "$REPO_ROOT/infra/$adopt_file"' EXIT
tf_state="$(terraform state list 2>/dev/null || true)"
while read -r addr repo; do
  grep -qxF "$addr" <<< "$tf_state" && continue
  aws_local ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 || continue
  printf 'import {\n  to = %s\n  id = "%s"\n}\n' "$addr" "$repo" >> "$adopt_file"
  c_info "adopting existing image repository $repo"
done <<'REPOS'
aws_ecr_repository.worker_app sonicloud-worker
aws_ecr_repository.app_tiers["sonicloud-web"] sonicloud-web
aws_ecr_repository.app_tiers["sonicloud-api"] sonicloud-api
REPOS
terraform apply -auto-approve -input=false >"$SONICLOUD_HOME/terraform-apply.log" 2>&1 || {
  tail -n 40 "$SONICLOUD_HOME/terraform-apply.log" >&2
  die "terraform apply failed (full output: $SONICLOUD_HOME/terraform-apply.log)"; }
rm -f "$adopt_file"
c_ok "$(terraform state list | wc -l) resources ($(grep -Eo 'Resources: .*' "$SONICLOUD_HOME/terraform-apply.log" | tail -n1 | sed 's/\x1b\[[0-9;]*m//g'))"
DB_PASSWORD="$(terraform output -raw db_password)"
COGNITO_USER_POOL_ID="$(terraform output -raw cognito_user_pool_id)"
COGNITO_CLIENT_ID="$(terraform output -raw cognito_client_id)"
QUEUE_URL="$(terraform output -raw sqs_url)"
cd "$REPO_ROOT"

DB_HOST="$(aws_local rds describe-db-instances --db-instance-identifier sonicloud-db \
            --query 'DBInstances[0].Endpoint.Address' --output text)"
DB_PORT="$(aws_local rds describe-db-instances --db-instance-identifier sonicloud-db \
            --query 'DBInstances[0].Endpoint.Port' --output text)"
c_ok "rds at $DB_HOST:$DB_PORT"
c_ok "cognito pool $COGNITO_USER_POOL_ID"
# The worker talks to floci container-to-container; the QUEUE_URL terraform
# emits points at localhost, which is meaningless inside a pod.
QUEUE_URL="${QUEUE_URL/localhost/$FLOCI_IP}"

# ------------------------------------------------------------------ 6. registry
step "6/10  container images"
# Floci creates the ECR registry container LAZILY -- on the first
# GetAuthorizationToken call, not when terraform creates the repositories.
# Ask for a token, then wait for the container.
aws_local ecr get-authorization-token >/dev/null 2>&1 || true
wait_for 60 "floci ECR registry container" \
  bash -c "[ \"\$(docker inspect -f '{{.State.Running}}' $REGISTRY_CONTAINER 2>/dev/null)\" = true ]"
REGISTRY_IP="$(container_ip "$REGISTRY_CONTAINER" bridge)"
[ -n "$REGISTRY_IP" ] || die "the floci ECR registry container is not running"
c_ok "registry at $REGISTRY_IP:5000 (published on localhost:$REGISTRY_PORT)"

# The manifests in local-deploy/gitops pin each component to a release tag
# (local-vX.Y.Z), and the release pipeline builds and pushes those. So normally
# every image is already in the registry and nothing is built here.
# Only a machine whose registry is new (first install, wiped data) lacks them;
# there the image is built from this checkout and published under the pinned
# tag. An existing release tag is never overwritten.
for svc in api web worker; do
  rel="$(gitops_tag "$svc")"
  [ -n "$rel" ] || die "no image tag for sonicloud-$svc found in $GITOPS_DIR/$svc.yaml"
  if curl -sf -m 5 "http://localhost:$REGISTRY_PORT/v2/sonicloud-$svc/tags/list" | grep -q "\"$rel\""; then
    c_ok "sonicloud-$svc:$rel is in the registry"
    continue
  fi
  if [ "$svc" = worker ] && [ "${PREBUILT_WORKER:-0}" = "1" ] \
     && docker image inspect sonicloud-worker:local >/dev/null 2>&1; then
    # Slow uplink: the worker image was built offline beforehand. Reuse it.
    c_info "sonicloud-worker: using the prebuilt image sonicloud-worker:local (PREBUILT_WORKER=1)"
  else
    c_info "sonicloud-$svc:$rel is not in the registry -- building it here$([ "$svc" = worker ] && echo ' (~4.3GB with TensorFlow, this takes a while)') ..."
    # -q hides the output, so on failure replay verbosely before giving up.
    if ! docker build -q -t "sonicloud-$svc:local" "$REPO_ROOT/$svc" >/dev/null 2>&1; then
      c_warn "build failed for $svc -- retrying once with full output"
      docker build --progress=plain -t "sonicloud-$svc:local" "$REPO_ROOT/$svc" \
        || die "build failed for $svc (see the output above)"
    fi
  fi
  docker tag "sonicloud-$svc:local" "localhost:$REGISTRY_PORT/sonicloud-$svc:$rel"
  docker push -q "localhost:$REGISTRY_PORT/sonicloud-$svc:$rel" >/dev/null || die "push failed for $svc:$rel"
  c_ok "sonicloud-$svc:$rel published"
done

# ----------------------------------------------------------------- 7. k3s mirror
step "7/10  cluster: registry mirror and leftovers"
wait_for 180 "eks cluster container up" docker inspect "$EKS_CONTAINER"
mirror_file="$(mktemp)"
printf 'mirrors:\n  "%s":\n    endpoint:\n      - "http://%s:5000"\n' "$ECR_HOST" "$REGISTRY_IP" > "$mirror_file"
# The mirror file is not on the cluster's volume, and the registry's address
# can change, so compare what the container has with what it should have.
if ! docker exec "$EKS_CONTAINER" cat /etc/rancher/k3s/registries.yaml 2>/dev/null | cmp -s - "$mirror_file"; then
  docker exec "$EKS_CONTAINER" mkdir -p /etc/rancher/k3s
  docker cp "$mirror_file" "$EKS_CONTAINER:/etc/rancher/k3s/registries.yaml"
  c_info "registry mirror changed -- restarting k3s to load it ..."
  docker restart "$EKS_CONTAINER" >/dev/null
fi
rm -f "$mirror_file"
wait_for 240 "kubernetes API responding" k3s_up

# A rebuilt container registers as a NEW node. The old node object stays behind
# (even "Ready" for a while) and still owns the old pods.
NODE="$(docker exec "$EKS_CONTAINER" hostname)"
wait_for 120 "node $NODE registered" docker exec "$EKS_CONTAINER" kubectl get node "$NODE" || true
if kc get node "$NODE" >/dev/null 2>&1; then
  for n in $(kc get nodes -o name | sed 's|^node/||'); do
    [ "$n" = "$NODE" ] && continue
    kc delete node "$n" --wait=false >/dev/null 2>&1 && c_info "removed leftover node $n"
    # Its pods would only be cleaned up minutes later; do it now.
    kc get pods -A --field-selector "spec.nodeName=$n" \
       -o jsonpath='{range .items[*]}{.metadata.namespace} {.metadata.name}{"\n"}{end}' 2>/dev/null \
      | while read -r ns pod; do
          [ -n "$pod" ] && kc -n "$ns" delete pod "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
        done
  done
  # Volumes of the "local-path" kind are tied to the node that created them.
  # One tied to a node that no longer exists can never be mounted again, and
  # its pod would wait forever. Remove the claim; it is recreated empty by the
  # deploy step, and the model cache is copied back in by the seed step.
  kc get pv -o json 2>/dev/null | jq -r --arg n "$NODE" '
      .items[]
      | select([.spec.nodeAffinity.required.nodeSelectorTerms[]?.matchExpressions[]?
                | select(.key=="kubernetes.io/hostname") | .values[]] as $v
               | ($v|length) > 0 and ($v|index($n)|not))
      | [.metadata.name, (.spec.claimRef.namespace // ""), (.spec.claimRef.name // "")] | @tsv' \
    | while IFS=$'\t' read -r pv ns pvc; do
        if [ -n "$pvc" ]; then
          kc -n "$ns" delete pvc "$pvc" --wait=false >/dev/null 2>&1 || true
          kc -n "$ns" patch pvc "$pvc" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        fi
        kc delete pv "$pv" --wait=false >/dev/null 2>&1 || true
        kc patch pv "$pv" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
        c_info "removed volume $pv (it belonged to a node that no longer exists)"
      done
else
  c_warn "no node named like the container ($NODE); leaving nodes untouched"
fi
c_ok "cluster ready ($(kc get nodes --no-headers | wc -l) node)"

# -------------------------------------------------------------------- 8. deploy
step "8/10  deploying workloads"
# Two kinds of things go into the cluster:
#   a) values that belong to THIS machine (addresses, IDs, the DB password).
#      This script writes them into a ConfigMap and a Secret.
#   b) the application itself (local-deploy/gitops). Argo CD deploys that from
#      Git; this script only tells Argo CD where to look.
kc_apply < "$GITOPS_DIR/namespace.yaml" >/dev/null

changed=0
out="$(kcn create configmap sonicloud-env --dry-run=client -o yaml \
        --from-literal=AWS_REGION="$AWS_REGION_LOCAL" \
        --from-literal=AWS_ENDPOINT_URL="http://${FLOCI_IP}:${FLOCI_PORT}" \
        --from-literal=S3_PUBLIC_PORT="$FLOCI_PORT" \
        --from-literal=UPLOAD_BUCKET="$UPLOAD_BUCKET" \
        --from-literal=RESULTS_BUCKET="$RESULTS_BUCKET" \
        --from-literal=COGNITO_USER_POOL_ID="$COGNITO_USER_POOL_ID" \
        --from-literal=COGNITO_CLIENT_ID="$COGNITO_CLIENT_ID" \
        --from-literal=QUEUE_URL="$QUEUE_URL" | kc_apply)" || die "could not write configmap sonicloud-env"
case "$out" in *unchanged*) ;; *) changed=1 ;; esac
c_ok "configmap sonicloud-env (${out##* })"
out="$(kcn create secret generic sonicloud-secrets --dry-run=client -o yaml \
        --from-literal=db_host="$DB_HOST" \
        --from-literal=db_port="$DB_PORT" \
        --from-literal=db_password="$DB_PASSWORD" | kc_apply)" || die "could not write secret sonicloud-secrets"
case "$out" in *unchanged*) ;; *) changed=1 ;; esac
c_ok "secret sonicloud-secrets (${out##* })"

# Right after a boot Argo CD's own cluster may still be starting. Give it time
# (ARGOCD_WAIT seconds) before deciding it is not there.
if [ "$DEPLOY_MODE" != direct ] && [ "${ARGOCD_WAIT:-0}" -gt 0 ] && ! argocd_available; then
  wait_for "$ARGOCD_WAIT" "Argo CD reachable" argocd_available || true
fi
USE_ARGOCD=0
case "$DEPLOY_MODE" in
  direct) ;;
  argocd) argocd_available || die "DEPLOY_MODE=argocd, but Argo CD is not reachable (kubeconfig: $ARGOCD_KUBECONFIG, namespace: $ARGOCD_NAMESPACE)"
          USE_ARGOCD=1 ;;
  auto)   argocd_available && USE_ARGOCD=1 || true ;;
  *)      die "DEPLOY_MODE must be auto, argocd or direct (got: $DEPLOY_MODE)" ;;
esac

if [ "$USE_ARGOCD" = 1 ]; then
  # --- let Argo CD into SoniCloud's cluster ---------------------------------
  # Argo CD runs in a different cluster, so it needs an address and a login:
  # a ServiceAccount here, whose token Argo CD stores as a "cluster" Secret.
  EKS_API_PORT="$(docker port "$EKS_CONTAINER" 6443/tcp 2>/dev/null | head -n1 | sed 's/.*://')"
  [ -n "$EKS_API_PORT" ] || die "the cluster container $EKS_CONTAINER does not publish its API port (6443)"
  kc_apply >/dev/null <<'YAML' || die "could not create the argocd-manager account in the cluster"
apiVersion: v1
kind: ServiceAccount
metadata: { name: argocd-manager, namespace: kube-system }
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: argocd-manager }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects:
  - { kind: ServiceAccount, name: argocd-manager, namespace: kube-system }
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: kube-system
  annotations: { kubernetes.io/service-account.name: argocd-manager }
type: kubernetes.io/service-account-token
YAML
  ARGO_TOKEN=""
  for _ in $(seq 1 20); do
    ARGO_TOKEN="$(kc -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [ -n "$ARGO_TOKEN" ] && break; sleep 1
  done
  [ -n "$ARGO_TOKEN" ] || die "the cluster did not issue a token for argocd-manager"
  # insecure: the k3s certificate is issued for the container's own addresses,
  # not for this host's LAN address. Acceptable on a private lab network.
  akc apply -f - >/dev/null <<YAML || die "could not register the cluster with Argo CD"
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$ARGOCD_CLUSTER_NAME
  namespace: $ARGOCD_NAMESPACE
  labels: { argocd.argoproj.io/secret-type: cluster }
type: Opaque
stringData:
  name: $ARGOCD_CLUSTER_NAME
  server: https://$HOST_IP:$EKS_API_PORT
  config: '$(jq -cn --arg t "$ARGO_TOKEN" '{bearerToken:$t,tlsClientConfig:{insecure:true}}')'
YAML
  c_ok "cluster registered with Argo CD as \"$ARGOCD_CLUSTER_NAME\" (https://$HOST_IP:$EKS_API_PORT)"

  # --- point Argo CD at the manifests ----------------------------------------
  if [ -n "$GITOPS_REVISION" ]; then
    sed "s|^\( *targetRevision:\).*|\1 $GITOPS_REVISION|" "$ARGOCD_APP_FILE" | akc apply -f - >/dev/null \
      || die "could not create the Argo CD application"
    c_warn "Argo CD follows branch \"$GITOPS_REVISION\" (GITOPS_REVISION is set)"
  else
    akc apply -f "$ARGOCD_APP_FILE" >/dev/null || die "could not create the Argo CD application"
  fi
  app_field() { akc -n "$ARGOCD_NAMESPACE" get application "$ARGOCD_APP_NAME" -o jsonpath="$1" 2>/dev/null; }
  akc -n "$ARGOCD_NAMESPACE" annotate application "$ARGOCD_APP_NAME" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  # Argo CD removes that annotation once it has re-read Git. Until then the
  # status still describes the PREVIOUS revision, so wait for it first.
  app_refreshed() { [ -z "$(app_field '{.metadata.annotations.argocd\.argoproj\.io/refresh}')" ]; }
  app_done()      { [ "$(app_field '{.status.sync.status}/{.status.health.status}')" = Synced/Healthy ]; }
  wait_for 120 "Argo CD re-read Git" app_refreshed || true
  if wait_for 480 "Argo CD application $ARGOCD_APP_NAME synced and healthy" app_done; then
    c_ok "deployed Git revision $(app_field '{.status.sync.revision}' | cut -c1-7)"
  else
    c_err "state: $(app_field '{.status.sync.status}/{.status.health.status}')"
    app_field '{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' >&2 || true
    die "Argo CD did not finish deploying. Look closer with: kubectl -n $ARGOCD_NAMESPACE describe application $ARGOCD_APP_NAME"
  fi
else
  c_warn "Argo CD not used (DEPLOY_MODE=$DEPLOY_MODE) -- applying local-deploy/gitops directly"
  for f in models-pvc api web worker; do
    kc_apply < "$GITOPS_DIR/$f.yaml" >/dev/null || die "could not apply $f.yaml"
  done
  c_ok "manifests applied"
fi

# Pods read the ConfigMap and Secret only when they start, so new values need
# a restart. Nothing changed -> nothing restarts.
if [ "$changed" = 1 ]; then
  kcn rollout restart deploy/api deploy/worker >/dev/null 2>&1 || true
  c_info "settings changed -- restarted api and worker"
fi
for d in api web worker; do
  kcn rollout status "deploy/$d" --timeout=300s >/dev/null 2>&1 \
    && c_ok "$d ready" || c_warn "$d not ready yet (kubectl -n $NAMESPACE describe deploy/$d)"
done

# --------------------------------------------------------------- 9. seed models
step "9/10  seeding the model cache into the cluster"
# Newest pod, not items[0]: right after a rollout the OLD pod is still listed
# as Running while it terminates, and exec into it fails with "container not found".
WPOD="$(kcn get pods -l app=worker --field-selector status.phase=Running \
        --sort-by=.metadata.creationTimestamp \
        -o jsonpath='{.items[-1:].metadata.name}' 2>/dev/null || true)"
if [ -z "$WPOD" ]; then
  c_warn "no running worker pod; skipping seed (rerun deploy.sh once it is up)"
elif docker exec "$EKS_CONTAINER" kubectl -n "$NAMESPACE" exec "$WPOD" -- test -f /models/2stems/model.index 2>/dev/null; then
  c_ok "models already present in the cluster"
else
  tar cf - -C "$CACHE_DIR/models" . \
    | docker exec -i "$EKS_CONTAINER" kubectl -n "$NAMESPACE" exec -i "$WPOD" -- tar xf - -C /models
  c_ok "seeded $(docker exec "$EKS_CONTAINER" kubectl -n "$NAMESPACE" exec "$WPOD" -- du -sh /models | cut -f1) into /models"
fi

# ----------------------------------------------------------------- 10. ingress
step "10/10  publishing the site on the LAN"
K3S_IP="$(container_ip "$EKS_CONTAINER" bridge)"
docker rm -f "$INGRESS_CONTAINER" >/dev/null 2>&1 || true
# klipper-lb serves the web Service on port 80 of the k3s container, which is
# only reachable inside this machine. Republish it on the host's LAN address.
docker run -d --restart unless-stopped --name "$INGRESS_CONTAINER" \
  -p "${INGRESS_PORT}:80" alpine/socat \
  "tcp-listen:80,fork,reuseaddr" "tcp-connect:${K3S_IP}:80" >/dev/null \
  || die "could not publish the site on port $INGRESS_PORT (is another program using it? set INGRESS_PORT in $SONICLOUD_HOME/env)"
wait_for 90 "site answering on http://$HOST_IP:$INGRESS_PORT/" \
  bash -c "curl -sf -m 5 -o /dev/null http://$HOST_IP:$INGRESS_PORT/"

port_suffix="$([ "$INGRESS_PORT" = 80 ] && echo "" || echo ":$INGRESS_PORT")"
printf '\n\033[1;32m==> SoniCloud is up\033[0m\n\n'
printf '   Open:  \033[1mhttp://%s%s/\033[0m\n' "$HOST_IP" "$port_suffix"
printf '   API :  http://%s%s/api/health\n' "$HOST_IP" "$port_suffix"
printf '\n   took %ss%s\n\n' "$(( $(date +%s) - START ))" "$([ "$CLUSTER_REBUILT" = 1 ] && echo '  (cluster container was rebuilt)')"
printf '   stop  (free RAM, keep data):  bash local-deploy/stop.sh\n'
printf '   start (after stop or reboot): bash local-deploy/start.sh\n'
printf '   kubectl:  docker exec %s kubectl -n %s get all\n\n' "$EKS_CONTAINER" "$NAMESPACE"
