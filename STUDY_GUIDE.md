# SoniCloud — Complete Study Guide
*3-tier app on EKS + RDS + AWS Inspector. Built, deployed, debugged, and verified live on 2026-07-14.*

---

## Part 1 — The Architecture

```
Internet
   │
   ▼
[ELB - LoadBalancer Service]           ← the only public entry point
   │
   ▼
┌──────────── EKS (sonicloud-eks) ────────────┐
│  Web tier:  nginx + React static  (x2)      │
│      │ proxies /api/                        │
│      ▼                                      │
│  App tier:  Flask API             (x2)      │
│  Worker:    Spleeter (no Service) (x1)      │
└──────┬──────────────────────┬───────────────┘
       │ SQL :5432            │ presigned URLs / SQS
       ▼                      ▼
  RDS PostgreSQL         S3 upload → SQS → worker → S3 results
  (private)
```

**Full flow:** browser POSTs `/api/jobs` → Flask INSERTs row in RDS + returns presigned PUT URL →
browser uploads mp3 **directly to S3** → S3 event → SQS → worker long-polls, downloads, runs Spleeter,
zips, uploads to results bucket, deletes message → FE polls `/api/jobs` every 10s → Flask `head_object`
on results bucket → UPDATE status `done` → Download button → presigned GET straight from S3.

---

## Part 2 — The Concepts (the "bricks")

**Client/server.** Browser = client (asks), server = answers. GET = "give me", POST = "create/take this".
The server only responds — it never initiates. That's why the FE polls every 10s (**polling**).

**ELB (load balancer).** One stable public address in front of N identical copies. Routes each request
to a live, least-busy copy. Managed by AWS — *someone must keep the keeper alive, and it can't be you.*

**Stateless tiers.** No copy remembers anything between requests; all state lives in the DB. This is what
allows free routing, scaling, and killing pods without data loss. "The app tier is stateless; state lives
in the data tier."

**Reverse proxy (nginx).** Sits in front of servers, hides them. Serves static files itself; forwards
`/api/*` to Flask (`api-service` = internal Kubernetes DNS name). Same-origin = no CORS problem, and Flask
has no public address at all → smaller **attack surface**. (Forward proxy = hides the *client*; reverse =
fronts the *server*.)

**React runs in the browser, not on the server.** On the server it's just built files in a folder that
nginx hands out. The multi-stage Dockerfile throws away Node entirely.

**Presigned URLs.** Flask never moves files. It grants a scoped, temporary permission: "whoever holds this
link may PUT exactly this file, here, for 15 minutes." Browser uploads directly to S3. **Least privilege**:
smallest permission, shortest time. Bucket needs CORS because the browser PUTs cross-origin.

**Queue (SQS).** Never do slow work inside an HTTP request. S3 drops an event note in the queue; the worker
pulls at its own pace (long-polling). Decoupling + buffering + retries.
- **Visibility timeout**: taking a message hides it (doesn't delete it). Crash mid-job → message reappears →
  another worker retries. Delete only AFTER success.
- **DLQ**: after 3 failed receives the message moves to the dead-letter queue (poison message quarantine).
- Set visibility timeout > job duration (we use 900s) or a second worker will double-process.

**Lazy status update.** Worker doesn't know the DB exists. On each GET /api/jobs, Flask checks whether the
result ZIP exists and flips the row to `done`. Trade-off: up to 10s staleness vs. another moving part.
"We chose 10 seconds of staleness over another component."

**Containers.** Code + runtime + libraries sealed in one box that runs identically everywhere. Image stored
in ECR. **Multi-stage build**: build stage (Node) discarded; ship stage = nginx + files only (~25MB, no
compiler for attackers).

**Kubernetes / EKS.** You declare desired state ("2 copies of api, always"); K8s reconciles reality to match
(**reconciliation loop**). EKS = AWS runs the control plane; you supply nodes (plain EC2).
- **Deployment** = desired state for pods; rolling updates.
- **Service** = stable address over ephemeral pods. ClusterIP (internal, api) / LoadBalancer (public, web).
  The worker has NO service — it serves no requests, it only polls.
- **Probes**: readiness = "don't send traffic yet" (shop sign); liveness = "kill & restart" (defibrillator).
- **requests/limits**: request = scheduling reservation; limit = hard cap (exceed memory → OOMKilled).

**VPC networking.** VPC = private fenced network. Subnet is *public* only if its route table sends 0.0.0.0/0
to the Internet Gateway. 2 subnets in 2 AZs (EKS and RDS both require 2 AZs). Tag
`kubernetes.io/role/elb=1` tells K8s where to place ELBs.

**Security groups.** Default deny. The RDS rule allows :5432 **from the EKS cluster's SG** — source is an
*identity*, not an IP (pods change IPs constantly). Plus `publicly_accessible=false` → no public address at
all. Layers: no route → SG → password = **defense in depth**.

**Terraform (IaC).** Declarative infra + state file. `plan` = diff (also **drift detection** — manual console
changes show up), `apply` = reconcile, `destroy` = full teardown. Same desired-state idea as K8s, one floor
lower. State file = Terraform's memory — guard it (team setup: S3 backend + locking).

**AWS Inspector v2.** Continuous vulnerability scanning: EC2 (node OS packages) + ECR (image layers) matched
against the CVE feed. New CVE published → existing findings appear without re-scan. `scan_on_push` on ECR.
Findings = CVE id + CVSS severity + remediation.

---

## Part 3 — The Debugging War Stories (tell these in interviews!)

### 1. IMDS hop limit — `NoCredentialsError`
**Symptom:** worker CrashLoopBackOff; log ended with `botocore NoCredentialsError`.
**Cause:** pods get AWS credentials from the node's metadata service (IMDS). Pod→node→IMDS = 2 network hops,
but the nodes' IMDS `HttpPutResponseHopLimit` was 1 → responses died en route → no credentials.
**Fix:** `aws ec2 modify-instance-metadata-options --http-put-response-hop-limit 2` (immediate), then a
**launch template** in Terraform so new nodes are born correct. Production answer: **IRSA** (pod-level IAM
roles) which skips node identity entirely.
**Bonus lesson:** the api pods had cached the failed credential lookup → needed `kubectl rollout restart`.
Fixing the environment isn't enough if the process cached the failure.

### 2. URL-encoded S3 keys — 404 on download
**Symptom:** worker looped: `Downloading Busy+Signal+-+Ichekol.mp3... 404 Not Found`.
**Cause:** S3 event notifications URL-encode object keys (space → `+`). The worker used the encoded key
verbatim → asked S3 for a file that doesn't exist.
**Fix:** `urllib.parse.unquote_plus(record["s3"]["object"]["key"])`.
**Bonus:** the poisoned message burned its 3 retries and landed in the DLQ — exactly what a DLQ is for.

### 3. OOMKilled — TensorFlow vs. memory limit
**Symptom:** log went silent mid-`AI splitting`; pod restarted quietly. `kubectl describe pod` →
`Last State: Terminated, Reason: OOMKilled, Exit Code: 137`.
**Cause:** Spleeter/TensorFlow needed more than the 3Gi limit; t3.medium node (4GB total) couldn't offer more.
**Fix:** node group → t3.large (8GB) via Terraform (node group replacement, pods migrated automatically),
worker limit → 6Gi.
**Lesson:** exit code 137 = SIGKILL = almost always OOM. Check `Last State`, not just logs.

### 4. Stale JSON error in the UI
**Symptom:** FE showed `Unexpected token '<', "<!doctype"... is not valid JSON`.
**Cause:** Flask crashed on `generate_presigned_url` (the NoCredentials issue) AFTER inserting the DB row,
returning an HTML 500 page that the FE tried to parse as JSON.
**Lesson:** "unexpected token <" in a fetch = your API returned an HTML error page, go read the server logs.

### Also worth knowing
- Original `worker.py` bugs: missing `import shutil`, malformed `__main__`.
- S3→SQS notification has `filter_suffix=".mp3"` → .wav uploads never process.
- Node group replacement is safe for stateless pods; think twice mid-long-job.
- `kubectl logs deployment/x` may pick the OLD pod during a rollout ("Found 2 pods") — log the pod by name.
- Rebuilding an image does nothing until you `docker push` AND the pod restarts and re-pulls.

---

## Part 4 — Interview Q&A (one-liners)

- **Why is the DB not internet-exposed; how do pods reach it?** No public address + SG allowing :5432 only
  from the cluster SG (identity-based, not IP-based). Admin access via bastion/SSM.
- **Api pod dies — what happens?** Readiness pulls it from Service rotation first; Deployment replaces it.
- **Why SQS over synchronous?** Minutes-long jobs, decoupling, buffering, retry + DLQ.
- **Service vs Ingress?** LB Service = one L4 ELB per service; Ingress = one L7 ALB, path/host routing + TLS.
- **Probes: readiness vs liveness?** Traffic gate vs restart trigger. Different diseases, different medicine.
- **Pod scaling vs node scaling?** HPA adds pods; Cluster Autoscaler adds machines when pods don't fit.
- **Harden this system?** IRSA, private subnets + NAT, HTTPS/Ingress, Secrets Manager, CORS restricted to
  the ELB origin, NetworkPolicies, non-root containers.
- **What separates this demo from production?** No TLS, no auth, public subnets, node-role IAM instead of
  IRSA, no monitoring/alerts, single-AZ DB with no backups, no CI/CD.
- **Trust vs permission policy (IAM)?** Trust = who may assume the role; permission = what it may do.
- **Why multi-stage build?** Small image, fast pulls, no build tools in the attack surface.
- **What is drift?** Reality diverging from IaC; `terraform plan` exposes it, `apply` reverts it.

**Self-test:** narrate the full upload→download flow from memory (Part 1). If you can, you're ready.

---

## Part 5 — Redeploy Quickstart (after destroy)

```bash
source: export AWS_PROFILE=sonicloud
cd infra && terraform init && terraform apply                # ~15 min
aws eks update-kubeconfig --region us-east-1 --name sonicloud-eks
cd .. && ./build_and_push.sh                                  # 3 images (worker is heavy)
kubectl apply -f k8s/namespace.yaml
cd infra
kubectl create secret generic sonicloud-secrets -n sonicloud \
  --from-literal=db_host="$(terraform output -raw db_endpoint)" \
  --from-literal=db_password="$(terraform output -raw db_password)"
cd ..
# (manifests already have the account id baked in)
kubectl apply -f k8s/api.yaml -f k8s/web.yaml -f k8s/worker.yaml
kubectl get svc web-service -n sonicloud                      # EXTERNAL-IP after ~3 min
```

**Teardown (the meter is ~$10/day):**
```bash
kubectl delete -f k8s/web.yaml -f k8s/api.yaml -f k8s/worker.yaml   # deletes the ELB first!
cd infra && terraform destroy
```
(Deleting the k8s LoadBalancer BEFORE destroy matters: Terraform doesn't know about the ELB that
Kubernetes created, and a leftover ELB blocks VPC deletion.)
