# Local Testing — run the whole app on your machine

## What runs where

| Component | Runs | Why |
|---|---|---|
| Web (React+nginx) | locally, Docker | http://localhost:8080 |
| API (Flask) | locally, Docker | |
| PostgreSQL | locally, Docker | replaces RDS for the test |
| Spleeter worker | locally, Docker | fixed version from `worker/` |
| S3 + SQS | **real AWS** | the S3→SQS event can't be simulated easily |

So the only AWS resources needed are the two buckets + queue — created by the
repo's *existing* Terraform (`s3.tf`, `sqs.tf`, `s3_notifications.tf`). No EKS/RDS needed for local testing.

## Prerequisites

1. Docker Desktop running
2. The repo's base Terraform applied (buckets + queue + notification exist)
3. AWS credentials (access key) with S3 + SQS permissions

## Run

```bash
./run_local.sh        # Git Bash or WSL
```

The script asks for AWS credentials (or reuses your `aws configure`), writes `.env`,
applies CORS to the upload bucket (needed once), builds and starts everything.

Then open **http://localhost:8080**, upload an `.mp3`, wait for `done`, download stems.

## Important notes

- **`.mp3` only** — the S3 notification filter (`filter_suffix = ".mp3"`) ignores `.wav`.
- **First job is slow** — Spleeter downloads its AI model (~100s of MB) on first run.
- **`.env` contains your AWS secret — never commit it** (add `.env` to `.gitignore`).
- The worker image build is heavy (TensorFlow); first `docker compose up` takes several minutes.
- `worker/worker.py` is the **fixed** worker — replace `app/worker.py` in the repo with it
  (original was missing `import shutil` and had a broken `__main__` line).

## Debugging

```bash
docker compose logs -f api-service   # API logs
docker compose logs -f worker        # worker logs (job processing)
docker compose ps                    # container status
curl http://localhost:5000/api/health
docker compose down -v               # stop + wipe local DB
```

## Flow being tested (same as production, minus EKS/RDS/ELB)

Browser → nginx (localhost:8080) → Flask → local Postgres
Browser → presigned PUT → real S3 → real SQS → local worker → real S3 results
Flask polls results bucket → `done` → presigned GET download
