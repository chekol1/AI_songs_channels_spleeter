#!/bin/bash
# One-command local test runner for SoniCloud.
# Runs FE + BE + DB + worker in Docker on your machine.
# Uses the REAL AWS S3 buckets + SQS queue (must already exist via Terraform).
# Run from Git Bash / WSL:  ./run_local.sh
set -e
cd "$(dirname "$0")"

echo "=== SoniCloud local test runner ==="

# --- 0. Docker check ---
if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: Docker is not installed / not in PATH. Install Docker Desktop first."
  exit 1
fi

# --- 1. Reuse existing .env? ---
if [ -f .env ]; then
  read -r -p "Found existing .env - reuse it? [Y/n] " REUSE
  if [ "$REUSE" != "n" ] && [ "$REUSE" != "N" ]; then
    echo "Reusing .env"
    SKIP_PROMPTS=1
  fi
fi

if [ -z "$SKIP_PROMPTS" ]; then
  # --- 2. AWS credentials ---
  ACCOUNT_ID=""
  USE_CLI=""
  if command -v aws >/dev/null 2>&1 && aws sts get-caller-identity >/dev/null 2>&1; then
    ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
    echo "Detected AWS CLI already configured (account: $ACCOUNT_ID)"
    read -r -p "Use these credentials? [Y/n] " USE_CLI
  fi

  if [ -n "$ACCOUNT_ID" ] && [ "$USE_CLI" != "n" ] && [ "$USE_CLI" != "N" ]; then
    AWS_ACCESS_KEY_ID=$(aws configure get aws_access_key_id)
    AWS_SECRET_ACCESS_KEY=$(aws configure get aws_secret_access_key)
    AWS_SESSION_TOKEN=$(aws configure get aws_session_token || true)
    AWS_REGION=$(aws configure get region || echo "us-east-1")
  else
    read -r -p "AWS Access Key ID: " AWS_ACCESS_KEY_ID
    read -r -s -p "AWS Secret Access Key (hidden): " AWS_SECRET_ACCESS_KEY; echo
    read -r -p "AWS Session Token (Enter to skip): " AWS_SESSION_TOKEN
    read -r -p "AWS Region [us-east-1]: " AWS_REGION
    AWS_REGION=${AWS_REGION:-us-east-1}
    read -r -p "AWS Account ID (12 digits): " ACCOUNT_ID
  fi

  # --- 3. Resource names (defaults match the repo's Terraform) ---
  read -r -p "Upload bucket [sonic-cloud-music-${ACCOUNT_ID}]: " UPLOAD_BUCKET
  UPLOAD_BUCKET=${UPLOAD_BUCKET:-sonic-cloud-music-${ACCOUNT_ID}}
  read -r -p "Results bucket [sonic-cloud-music-results-${ACCOUNT_ID}]: " RESULTS_BUCKET
  RESULTS_BUCKET=${RESULTS_BUCKET:-sonic-cloud-music-results-${ACCOUNT_ID}}
  read -r -p "SQS queue URL [https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/music-jobs-queue]: " QUEUE_URL
  QUEUE_URL=${QUEUE_URL:-https://sqs.${AWS_REGION}.amazonaws.com/${ACCOUNT_ID}/music-jobs-queue}

  # --- 4. Write .env (never commit this file) ---
  cat > .env <<EOF
AWS_REGION=${AWS_REGION}
AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID}
AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY}
AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN}
UPLOAD_BUCKET=${UPLOAD_BUCKET}
RESULTS_BUCKET=${RESULTS_BUCKET}
QUEUE_URL=${QUEUE_URL}
DB_PASSWORD=localdev123
EOF
  echo ".env written."

  # --- 5. Bucket CORS (needed once: the browser PUTs directly to S3) ---
  if command -v aws >/dev/null 2>&1; then
    read -r -p "Apply CORS config to the upload bucket now (needed once)? [Y/n] " DO_CORS
    if [ "$DO_CORS" != "n" ] && [ "$DO_CORS" != "N" ]; then
      aws s3api put-bucket-cors --bucket "$UPLOAD_BUCKET" --cors-configuration '{
        "CORSRules": [{
          "AllowedMethods": ["PUT"],
          "AllowedOrigins": ["*"],
          "AllowedHeaders": ["*"],
          "MaxAgeSeconds": 3600
        }]
      }' && echo "CORS applied to $UPLOAD_BUCKET"
    fi
  else
    echo "NOTE: aws cli not found - make sure the upload bucket has CORS allowing PUT (see infra/s3_cors.tf)."
  fi
fi

# --- 6. Build & run ---
echo
echo "Building and starting containers (first worker build downloads Spleeter - takes a while)..."
docker compose up --build -d

echo
echo "==============================================="
echo "  Open:  http://localhost:8080"
echo "  API:   http://localhost:5000/api/health"
echo "  Logs:  docker compose logs -f"
echo "  Stop:  docker compose down"
echo "==============================================="
echo "NOTE: upload .mp3 files only - the S3->SQS notification filter ignores other extensions."
