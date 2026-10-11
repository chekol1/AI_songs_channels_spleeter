#!/bin/bash
# Fill a NEW, empty ECR with the images the manifests ask for.
# Run from the repo root after 'terraform apply'.
#
# Day to day, images are built by the Release workflow (.github/workflows/
# release.yml), not by this script. But the showcase environment is destroyed
# and recreated, and a recreated ECR is empty, while k8s/*.yaml still pin the
# last released version. This script builds the current checkout and publishes
# it under exactly those pinned tags, so the pods can start.
#
# Tags are immutable: one that already exists is left alone.
set -euo pipefail

REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$REGISTRY"

for c in api web worker; do
  tag=$(sed -n "s|^ *image: .*/sonicloud-$c:\([^ ]*\) *$|\1|p" "k8s/$c.yaml" | head -n1)
  [ -n "$tag" ] || { echo "No image tag for sonicloud-$c found in k8s/$c.yaml" >&2; exit 1; }
  if aws ecr describe-images --repository-name "sonicloud-$c" --image-ids imageTag="$tag" >/dev/null 2>&1; then
    echo "--- sonicloud-$c:$tag is already in ECR, skipping ---"
    continue
  fi
  echo "--- Building sonicloud-$c:$tag $([ "$c" = worker ] && echo '(heavy - TensorFlow, takes a while) ')---"
  docker build -t "${REGISTRY}/sonicloud-$c:$tag" "./$c"
  docker push "${REGISTRY}/sonicloud-$c:$tag"
done

echo "Done. Images are in ${REGISTRY}"
