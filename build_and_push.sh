#!/bin/bash
# Build & push the web + api images to ECR.
# Run from the repo root after 'terraform apply'.
set -e

REGION="us-east-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REGISTRY

echo "--- Building api ---"
docker build -t ${REGISTRY}/sonicloud-api:latest ./api
docker push ${REGISTRY}/sonicloud-api:latest

echo "--- Building web ---"
docker build -t ${REGISTRY}/sonicloud-web:latest ./web
docker push ${REGISTRY}/sonicloud-web:latest

echo "--- Building worker (heavy - TensorFlow, takes a while) ---"
docker build -t ${REGISTRY}/sonicloud-worker:latest ./app
docker push ${REGISTRY}/sonicloud-worker:latest

echo "Done. Images pushed to ${REGISTRY}"
