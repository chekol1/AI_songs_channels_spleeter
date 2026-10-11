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
# The LAN forwarder for the registry used to be started by hand. Compose owns it
# now; a hand-started one with the same name would block compose, so remove it.
# It holds no data.
if docker inspect sonicloud-registry-lan >/dev/null 2>&1 \
   && [ -z "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' sonicloud-registry-lan 2>/dev/null)" ]; then
  docker rm -f sonicloud-registry-lan >/dev/null
  c_info "replaced the hand-started registry forwarder with the compose-managed one"
fi
# Listen for the build machine on this host's LAN address only.
export REGISTRY_LAN_BIND="${REGISTRY_LAN_BIND:-$HOST_IP}" REGISTRY_PORT
(cd "$LOCAL_DIR" && docker compose -f floci-compose.yml up -d >/dev/null) \
  || die "docker compose could not start Floci (run: cd local-deploy && docker compose -f floci-compose.yml up -d)"
wait_for 120 "floci healthy on :$FLOCI_PORT" \
  bash -c "curl -sf -m 5 http://localhost:$FLOCI_PORT/_localstack/health >/dev/null"
resolve_floci_container
FLOCI_IP="$(container_any_ip "$FLOCI_CONTAINER" || true)"
[ -n "$FLOCI_IP" ] || die "could not determine the floci container IP"
c_ok "floci container \"$FLOCI_CONTAINER\" at $FLOCI_IP"

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

# ------------------------------------------------------------------ 5. registry
step "5/9  container images"
# Floci creates the ECR registry container LAZILY -- on the first
# GetAuthorizationToken call, not when terraform creates the repositories. On a
# cold machine nothing has asked for a token yet, so the container does not
# exist and this step died with "the floci ECR registry container is not
# running". Earlier runs only passed because a registry was left over from a
# previous attempt. Ask for a token, then wait for the container.
aws_local ecr get-authorization-token >/dev/null 2>&1 || true
wait_for 60 "floci ECR registry container" \
  bash -c "[ \"\$(docker inspect -f '{{.State.Running}}' $REGISTRY_CONTAINER 2>/dev/null)\" = true ]"
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
    elif [ "$svc" = worker ] && [ "${PREBUILT_WORKER:-0}" = "1" ] \
         && docker image inspect sonicloud-worker:local >/dev/null 2>&1; then
      # Slow uplink: the worker image was built OFFLINE from pre-fetched debs
      # and wheels (~/sonic-work/build-worker-offline.sh). Reuse it as-is.
      c_ok "sonicloud-worker: using the prebuilt offline image (PREBUILT_WORKER=1)"
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

# The manifests in local-deploy/gitops pin each component to a release tag
# (local-vX.Y.Z). Normally the build pipeline has already pushed that tag. On a
# machine whose registry was just (re)created it is missing, and the pods would
# sit in ImagePullBackOff -- so publish the image we have under that tag.
# An existing release tag is never overwritten.
for svc in api web worker; do
  rel="$(gitops_tag "$svc")"
  [ -n "$rel" ] || die "no image tag for sonicloud-$svc found in $GITOPS_DIR/$svc.yaml"
  if curl -sf -m 5 "http://localhost:$REGISTRY_PORT/v2/sonicloud-$svc/tags/list" | grep -q "\"$rel\""; then
    c_ok "sonicloud-$svc:$rel is in the registry"
    continue
  fi
  if ! docker image inspect "sonicloud-$svc:local" >/dev/null 2>&1; then
    docker pull -q "localhost:$REGISTRY_PORT/sonicloud-$svc:latest" >/dev/null 2>&1 \
      && docker tag "localhost:$REGISTRY_PORT/sonicloud-$svc:latest" "sonicloud-$svc:local" \
      || die "sonicloud-$svc:$rel is not in the registry and there is no image to publish as it (rerun without SKIP_BUILD=1)"
  fi
  docker tag "sonicloud-$svc:local" "localhost:$REGISTRY_PORT/sonicloud-$svc:$rel"
  docker push -q "localhost:$REGISTRY_PORT/sonicloud-$svc:$rel" >/dev/null || die "push failed for $svc:$rel"
  c_warn "sonicloud-$svc:$rel was missing from the registry -- published the current build under that tag"
done

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
  kc_apply >/dev/null <<'EOF' || die "could not create the argocd-manager account in the cluster"
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
EOF
  ARGO_TOKEN=""
  for _ in $(seq 1 20); do
    ARGO_TOKEN="$(kc -n kube-system get secret argocd-manager-token -o jsonpath='{.data.token}' 2>/dev/null | base64 -d 2>/dev/null || true)"
    [ -n "$ARGO_TOKEN" ] && break; sleep 1
  done
  [ -n "$ARGO_TOKEN" ] || die "the cluster did not issue a token for argocd-manager"
  # insecure: the k3s certificate is issued for the container's own addresses,
  # not for this host's LAN address. Acceptable on a private lab network.
  akc apply -f - >/dev/null <<EOF || die "could not register the cluster with Argo CD"
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
EOF
  c_ok "cluster registered with Argo CD as \"$ARGOCD_CLUSTER_NAME\" (https://$HOST_IP:$EKS_API_PORT)"

  # --- point Argo CD at the manifests ----------------------------------------
  if [ -n "$GITOPS_REVISION" ]; then
    sed "s|^\( *targetRevision:\).*|\1 $GITOPS_REVISION|" "$ARGOCD_APP_FILE" | akc apply -f - >/dev/null \
      || die "could not create the Argo CD application"
    c_warn "Argo CD follows branch \"$GITOPS_REVISION\" (GITOPS_REVISION is set)"
  else
    akc apply -f "$ARGOCD_APP_FILE" >/dev/null || die "could not create the Argo CD application"
  fi
  akc -n "$ARGOCD_NAMESPACE" annotate application "$ARGOCD_APP_NAME" \
    argocd.argoproj.io/refresh=hard --overwrite >/dev/null
  app_state() { akc -n "$ARGOCD_NAMESPACE" get application "$ARGOCD_APP_NAME" \
                  -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null; }
  if wait_for 420 "Argo CD application $ARGOCD_APP_NAME synced and healthy" \
       bash -c "[ \"\$(kubectl --kubeconfig '$ARGOCD_KUBECONFIG' -n '$ARGOCD_NAMESPACE' get application '$ARGOCD_APP_NAME' -o jsonpath='{.status.sync.status}/{.status.health.status}')\" = Synced/Healthy ]"; then
    c_ok "deployed Git revision $(akc -n "$ARGOCD_NAMESPACE" get application "$ARGOCD_APP_NAME" -o jsonpath='{.status.sync.revision}' | cut -c1-7)"
  else
    c_err "state: $(app_state)"
    akc -n "$ARGOCD_NAMESPACE" get application "$ARGOCD_APP_NAME" \
      -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' >&2 || true
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

# --------------------------------------------------------------- 8. seed models
step "8/9  seeding the model cache into the cluster"
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
printf '   API :  http://%s%s/api/health\n' "$HOST_IP" \
  "$([ "$INGRESS_PORT" = 80 ] && echo "" || echo ":$INGRESS_PORT")"
printf '\n   took %ss\n\n' "$(( $(date +%s) - START ))"
printf '   kubectl:  docker exec %s kubectl -n %s get all\n' "$EKS_CONTAINER" "$NAMESPACE"
printf '   teardown: bash local-deploy/teardown.sh\n\n'
