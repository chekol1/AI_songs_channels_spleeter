#!/bin/bash
# Get the Repo URL from Terraform
REPO_URL=$(cd ../infra && terraform output -raw repository_url)
REGION="us-east-1"

# 1. Login to ECR
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REPO_URL

# 2. Build the image
docker build -t sonicloud-worker .

# 3. Tag the image
docker tag sonicloud-worker:latest $REPO_URL:latest

# 4. Push to the cloud
docker push $REPO_URL:latest

echo "Done! Image is now in ECR: $REPO_URL"
