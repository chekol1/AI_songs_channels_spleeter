# SoniCloud — local deployment on Floci

Run the whole SoniCloud stack on one Linux VM against
[Floci](https://github.com/hecodes2much/floci), a local AWS emulator.
**No AWS account, no cloud spend.**

This branch is the local variant of `eks-showcase`. The real-AWS version lives
there; do not deploy this branch to AWS.

```bash
git clone -b floci-local-deployment https://github.com/chekol1/AI_songs_channels_spleeter.git
cd AI_songs_channels_spleeter
bash local-deploy/install-prereqs.sh     # docker, terraform, aws cli
bash local-deploy/deploy.sh              # everything else
```

`deploy.sh` prints the URL when it finishes. Open it in any browser on the LAN.

## Requirements

| | |
|---|---|
| OS | Ubuntu/Debian x86_64 (tested on Ubuntu 26.04) |
| RAM | 8 GB minimum — TensorFlow was OOM-killed at 3 GB |
| Disk | **20 GB free.** The worker image alone is ~4.3 GB |
| CPU | 4 cores recommended |
| Network | needed on first run (images, terraform provider, models) |

`install-prereqs.sh` needs sudo for apt and docker; terraform and the AWS CLI go
to `~/.local/bin` and need no root. If it adds you to the `docker` group you
must log out and back in, then re-run it.

## First run vs later runs

The first run is slow — the terraform AWS provider is ~146 MB, the worker image
builds TensorFlow (~586 MB wheel), and the Spleeter models are ~76 MB. Expect
**30–60 minutes** on a modest connection.

`deploy.sh` is **idempotent**; a re-run with nothing changed takes about **60
seconds**. Images are keyed by a hash of their build context, so changing source
rebuilds only what changed. Re-run it after every reboot: Floci keeps no state,
so everything is recreated (the models and images are cached, so it is quick).

```bash
bash local-deploy/deploy.sh                 # deploy or re-deploy
FORCE_BUILD=1 bash local-deploy/deploy.sh   # rebuild all images
SKIP_BUILD=1  bash local-deploy/deploy.sh   # never build, use the registry
bash local-deploy/teardown.sh               # stop everything, keep caches
bash local-deploy/teardown.sh --all         # also drop models and images
```

## What it stands up

VPC, 2 subnets, IGW, route tables, 3 security groups, launch template · 2 S3
buckets with CORS and event notifications · SQS queue + DLQ · 5 IAM roles and an
OIDC provider · 3 ECR repos · EFS · **a real k3s cluster** · **a real PostgreSQL
16** — 46 Terraform resources, then builds and deploys the web, api and worker
tiers onto the cluster.

```bash
alias kc='docker exec floci-eks-sonicloud-eks kubectl -n sonicloud'
kc get all
kc logs -l app=worker --tail=30
```

## What is real and what is not

Floci emulates AWS **APIs**. A green apply proves the config is API-level
correct; it proves nothing about security or whether it would work on real AWS.

**Real:** the EKS cluster is a genuine k3s container running real pods; RDS is a
genuine PostgreSQL container; ECR is a genuine registry; S3 event notifications
really fire into SQS, including `filter_suffix`; S3 CORS preflight is honoured;
Spleeter really runs and produces real audio stems.

**Not real:**

- **IAM is not enforced.** Verified: `DeleteObject` succeeds against a bucket
  whose task-role policy grants only `GetObject`. Every role and policy is
  created and evaluated by nothing.
- **The EKS node group is a mock** — `ACTIVE` immediately, invented ASG name,
  and `ec2 describe-instances` returns nothing. Every pod, including the 4.3 GB
  worker, runs on the single k3s control-plane container. The `t3.large` sizing
  and the IMDS hop-limit setting are untested.
- **VPC networking and security groups are inert.** Stored, never enforced.
- **EFS is a stub.** The model cache uses a k3s PVC instead.
- **The LoadBalancer is k3s klipper-lb**, not an ELB.
- **GitHub OIDC** is created but validates no token.
- **`aws ecr describe-images` returns `[]`** even for images that are in the
  registry and pulled successfully — its ECR API is disconnected from the
  registry contents. Query the registry directly instead.
- **AWS Inspector v2 does not exist in Floci**, so `infra/inspector.tf` is
  absent on this branch.
- **EKS access-entry APIs are not routed**, so those four resources and the
  cluster's `access_config` block are absent on this branch.

## Differences from `eks-showcase`

| Change | Why |
|---|---|
| `infra/floci_override.tf` | points 9 services at Floci; a `_override.tf` file so `main.tf` is untouched |
| `infra/inspector.tf` deleted | `inspector2` is not implemented by Floci |
| `infra/github_oidc.tf` trimmed | EKS access-entry APIs are not routed |
| `infra/eks.tf` — `access_config` removed | Floci never persists it, so every re-apply attempted `UpdateClusterConfig`, which it cannot serve. Broke re-runs. |
| `api/app.py` — `DB_PORT` | the port was not configurable; Floci proxies RDS on a non-standard port |
| `api/app.py` — lazy `init_db()` | it ran at import, so gunicorn's import crashed the container when the DB was not yet up; the retry loop could never help |
| `web/nginx.conf` → `.template` | nginx resolved its upstream once at startup and exited if DNS was not ready |
| `local-deploy/` | the installer, orchestrator and templated manifests |

The `api` and `nginx` changes are genuine bugs that affect real AWS too, but
they are only applied here — `eks-showcase` is untouched.

## Design notes

- **Nothing is hardcoded.** The host's LAN IP, the Floci/registry/k3s container
  IPs, the RDS host and port, the NodePort and the queue URL are all detected at
  deploy time. Container IPs and NodePorts change between rebuilds.
- **`AWS_ENDPOINT_URL` on the api pod is the host's LAN IP, deliberately.** The
  browser PUTs directly to the presigned URL the API signs, so that URL must
  name a host the browser can reach. A container-internal IP would break uploads
  while the page still loaded.
- **Images are pushed via `localhost:5100`, not the ECR-style hostname.** Docker
  refuses plain HTTP to a non-localhost name without `insecure-registries` in
  `/etc/docker/daemon.json`, which needs root. A k3s registry mirror makes the
  pull side resolve the ECR name, so the manifests keep a realistic image ref.
- **`rancher/k3s` and `postgres:16-alpine` are pre-pulled.** Floci's internal
  image pull times out after ~60 s, which is what makes EKS and RDS fail on a
  first run.
- **Models are cached at `local-deploy/.cache/` (gitignored)** and seeded into a
  PVC, so no pod ever re-downloads them.

## Troubleshooting

**`api` CrashLoopBackOff** — usually the DB. `kc logs -l app=api --previous`.

**`web` CrashLoopBackOff with `host not found in upstream`** — you are running an
image built before the nginx fix. `FORCE_BUILD=1 bash local-deploy/deploy.sh`.

**502 from `/api/`** — nginx cannot resolve the upstream. It must be an FQDN;
nginx's `resolver` ignores the search domains in `/etc/resolv.conf`.

**Pods `Pending` with `disk-pressure`** — the disk filled. Free space, then wait
about 5 minutes: kubelet holds the taint for `eviction-pressure-transition-period`
after space is recovered. `docker builder prune -af` recovers several GB.

**`terraform apply` fails on EKS or RDS with a read timeout** — the pre-pull did
not happen. `docker pull rancher/k3s:latest postgres:16-alpine` and re-run.

**Page loads but uploads fail** — the VM's IP changed. Re-run `deploy.sh`.

## Security

LAN-only and completely unauthenticated — anyone who can reach the VM can use
it and read every uploaded track. Do not port-forward it or expose it to the
internet.
