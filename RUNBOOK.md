# SoniCloud Runbook — full lifecycle

Everything needed to run this project from zero, and to shut it down to zero.
Prereqs (one-time): AWS CLI + profile with admin rights, Terraform ≥ 1.5, kubectl, Docker Desktop.

## Remove local copy

```bash
cd /c/dev
rm -rf AI_songs_channels_spleeter
```

## Clone

```bash
git clone -b eks-showcase https://github.com/chekol1/AI_songs_channels_spleeter.git
cd AI_songs_channels_spleeter
```

## Deploy (~20 min total)

```bash
export AWS_PROFILE=sonicloud            # rerun in every new terminal

# 1. Infrastructure: VPC, EKS, RDS, S3, SQS, ECR, Inspector
cd infra && terraform init && terraform apply          # ~15 min, type yes

# 2. Connect kubectl to the new cluster
aws eks update-kubeconfig --region us-east-1 --name sonicloud-eks

# 3. Build & push the 3 images (Docker Desktop must be running)
cd .. && ./build_and_push.sh

# 4. Namespace + DB credentials from terraform outputs
kubectl apply -f k8s/namespace.yaml
kubectl create secret generic sonicloud-secrets -n sonicloud \
  --from-literal=db_host="$(cd infra && terraform output -raw db_endpoint)" \
  --from-literal=db_password="$(cd infra && terraform output -raw db_password)"

# 5. Deploy the app - GitOps way: ArgoCD syncs k8s/ from GitHub
kubectl apply -f argocd/sonicloud-app.yaml
kubectl get pods -n sonicloud -w        # wait for all Running, Ctrl+C
#    (manual alternative: kubectl apply -f k8s/api.yaml -f k8s/web.yaml -f k8s/worker.yaml)

# 6. Public URL (appears after ~3 min)
kubectl get svc web-service -n sonicloud    # EXTERNAL-IP → open http://<it>

# 7. ArgoCD UI - URL is in the terraform outputs (self-signed cert: accept the browser warning)
cd infra && terraform output argocd_url
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
# login: admin / <that password>
```

Smoke test: upload an `.mp3` (mp3 only — the S3 notification filter ignores other
extensions), watch `kubectl logs deployment/worker -n sonicloud -f`, wait for the
status to flip to `done` (first job is slower: Spleeter downloads its model), download stems.

## Destroy (~10 min) — the meter is ~$10/day while running

```bash
# 1. Delete k8s services FIRST - removes the ELB that terraform doesn't know about
kubectl delete -f k8s/web.yaml -f k8s/api.yaml -f k8s/worker.yaml

# 2. Tear down everything else
cd infra && terraform destroy           # type yes

# 3. Verify zero
aws s3 ls | grep sonic-cloud            # expect: nothing
aws eks list-clusters                   # expect: empty list
```

Known slow spot: the Inspector enabler deactivates slowly; a 15m delete timeout is
configured, but if destroy ever times out on it — just run `terraform destroy` again.

## Troubleshooting quick refs

| Symptom | Look at | Likely cause |
|---|---|---|
| Pod CrashLoopBackOff | `kubectl logs deployment/<x> -n sonicloud` | app error on startup |
| `NoCredentialsError` in pod | IMDS hop limit on nodes | must be 2 (launch template sets it) |
| Worker 404 downloading song | key encoding | fixed via `unquote_plus` in worker.py |
| Silent worker, then restart | `kubectl describe pod` → Last State | OOMKilled → raise memory / node size |
| Logs of a crashed container | `kubectl logs <pod> --previous` | dying words of the last incarnation |
| UI "Unexpected token '<'" | api pod logs | API returned HTML 500, read the traceback |

Full background and interview prep: see `STUDY_GUIDE.md`.
