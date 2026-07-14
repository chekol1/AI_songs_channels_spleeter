# SoniCloud — AI Song Splitter on AWS EKS

A 3-tier web application that splits songs into vocal + accompaniment stems using
[Spleeter](https://github.com/deezer/spleeter) (Deezer's AI source-separation model),
deployed on AWS EKS with the entire environment defined as code (Terraform), and
continuously scanned by AWS Inspector.

Upload an `.mp3` → the AI splits it in the background → download the stems as a ZIP.

## Architecture

```
Internet
   │
   ▼
[ELB - LoadBalancer Service]            ← single public entry point
   │
   ▼
┌───────────── EKS (sonicloud-eks) ─────────────┐
│  Web tier:  React + nginx        (2 replicas) │
│      │ reverse-proxies /api/                  │
│      ▼                                        │
│  App tier:  Flask REST API       (2 replicas) │
│  Worker:    Spleeter processor   (1 replica)  │
└──────┬─────────────────────────┬──────────────┘
       │ SQL :5432               │ presigned URLs / SQS polling
       ▼                         ▼
  RDS PostgreSQL         S3 upload bucket ──event──► SQS ──► worker ──► S3 results
  (private, jobs table)                                (retry x3 → DLQ)
```

**Flow:** the browser registers a job (`POST /api/jobs`) → Flask stores it in RDS and
returns a presigned S3 URL → the browser uploads the file directly to S3 → an S3 event
lands in SQS → the worker downloads the song, runs Spleeter, uploads a ZIP of stems to
the results bucket → the API detects the result and flips the job to `done` → the user
downloads via a presigned URL. Files never pass through the application servers.

## Highlights

- **3-tier architecture** with a clear security boundary per tier: only the web tier is
  internet-facing; the API has no public address; the database accepts connections only
  from the cluster's security group (identity-based rule, `publicly_accessible = false`).
- **100% Infrastructure as Code** — VPC, EKS (public endpoint + managed node group with
  a custom launch template), RDS, S3, SQS + DLQ, ECR, IAM, and AWS Inspector are all
  Terraform. The full environment is reproducible from `git clone` in ~20 minutes and
  tears down to zero with `terraform destroy`.
- **Event-driven async processing** — minutes-long AI jobs never block an HTTP request:
  S3 events → SQS (long polling, visibility timeout sized to the job, dead-letter queue
  after 3 failed attempts).
- **AWS Inspector v2** enabled for EC2 (cluster nodes) and ECR (`scan_on_push` on all
  three images) — continuous CVE scanning of both machines and container layers.
- **Kubernetes-native operations** — rolling updates, readiness/liveness probes,
  resource requests/limits, secrets injected from Terraform outputs.

## Repository layout

| Path | What it is |
|---|---|
| `web/` | Web tier — React (Vite) built and served by nginx (multi-stage Dockerfile) |
| `api/` | App tier — Flask API (presigned URLs, job tracking in PostgreSQL) |
| `app/` | Spleeter worker (SQS consumer) + Dockerfile |
| `infra/` | All Terraform: VPC, EKS, RDS, S3, SQS, ECR, IAM, Inspector |
| `k8s/` | Kubernetes manifests: deployments, services, namespace |
| `build_and_push.sh` | Builds and pushes the three images to ECR |
| `RUNBOOK.md` | Full lifecycle: clone → deploy → smoke test → destroy + troubleshooting table |
| `DEPLOY_GUIDE.md` | Step-by-step first deployment walkthrough |
| `LOCAL_TESTING.md` | Run the whole stack locally with docker-compose |
| `STUDY_GUIDE.md` | Architecture deep-dive + production debugging log |

## Quick start

Prereqs: AWS CLI (admin profile), Terraform ≥ 1.5, kubectl, Docker Desktop.

```bash
git clone -b eks-showcase https://github.com/chekol1/AI_songs_channels_spleeter.git
cd AI_songs_channels_spleeter
# then follow RUNBOOK.md (deploy ≈ 20 min, destroy ≈ 10 min)
```

Cost while running: ≈ $10/day (EKS control plane, 2× t3.large, RDS t3.micro, ELB) —
always `terraform destroy` after a demo.

## Battle-tested

This deployment was debugged live against real production failure modes, documented in
`STUDY_GUIDE.md`: IMDS hop-limit credential failures (fixed via launch template),
URL-encoded S3 event keys, a poison message exercising the DLQ, and an OOMKilled
TensorFlow workload resolved with a node-size upgrade — zero-downtime, via IaC.

## Production roadmap

HTTPS via Ingress + ALB controller, user authentication, IRSA (pod-level IAM roles),
private subnets + NAT, Secrets Manager, CI/CD (GitHub Actions → ECR → rolling deploy),
monitoring and alerting.
