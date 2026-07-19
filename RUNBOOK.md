# SoniCloud Runbook — full lifecycle

Everything needed to run this project from zero, and to shut it down to zero.
Prereqs (one-time): AWS CLI + admin profile, Terraform ≥ 1.5, kubectl, Docker Desktop (running).

> ArgoCD is installed with kubectl (NOT Terraform) on purpose: managing in-cluster
> software from the same Terraform root that creates the cluster breaks `destroy`
> (helm provider can't resolve its config while the cluster is being destroyed).

## Remove local copy + reclone

```bash
cd /c/dev
rm -rf AI_songs_channels_spleeter
git clone -b eks-showcase https://github.com/chekol1/AI_songs_channels_spleeter.git
cd AI_songs_channels_spleeter
```

## Deploy (~25 min)

```bash
export AWS_PROFILE=sonicloud            # rerun in EVERY new terminal

# 1. Infrastructure (VPC, EKS, RDS, S3, SQS, ECR, Inspector, CI role)
cd infra
terraform init
terraform apply                         # ~15 min, type yes

# 2. Connect kubectl to the new cluster (required every cycle - new cluster, new address)
aws eks update-kubeconfig --region us-east-1 --name sonicloud-eks

# 3. Build & push the 3 images
cd .. && ./build_and_push.sh

# 4. Namespace + DB secret (must exist BEFORE the app deploys)
kubectl apply -f k8s/namespace.yaml
kubectl create secret generic sonicloud-secrets -n sonicloud \
  --from-literal=db_host="$(cd infra && terraform output -raw db_endpoint)" \
  --from-literal=db_password="$(cd infra && terraform output -raw db_password)"

# 5. Install ArgoCD (kubectl, not terraform)
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
kubectl -n argocd rollout status deployment/argocd-server --timeout=5m
kubectl patch svc argocd-server -n argocd -p '{"spec":{"type":"LoadBalancer"}}'   # public UI (~$0.6/day)

# 6. GitOps deploy - ArgoCD syncs k8s/ from GitHub
kubectl apply -f argocd/sonicloud-app.yaml
kubectl get pods -n sonicloud -w        # wait for all Running, then Ctrl+C
```

## All URLs (run after deploy)

```bash
echo "=== App ===" && \
kubectl get svc web-service -n sonicloud -o jsonpath='http://{.status.loadBalancer.ingress[0].hostname}{"\n"}' && \
echo "=== ArgoCD UI (accept the self-signed cert warning) ===" && \
kubectl get svc argocd-server -n argocd -o jsonpath='https://{.status.loadBalancer.ingress[0].hostname}{"\n"}' && \
echo "=== ArgoCD login: admin / password below ===" && \
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d && echo && \
echo "=== GitHub Actions (CI) ===" && \
echo "https://github.com/chekol1/AI_songs_channels_spleeter/actions" && \
echo "=== AWS Inspector findings ===" && \
echo "https://console.aws.amazon.com/inspector/v2/home?region=us-east-1#/findings"
```

(ELB hostnames appear ~2-3 min after creation; rerun if a URL prints empty.)

Smoke test: upload an `.mp3` (mp3 only — the S3 notification filter ignores other
extensions), watch `kubectl logs deployment/worker -n sonicloud -f`, wait for `done`
(first job is slower: Spleeter downloads its model), download the stems.

## Destroy (~10 min) — the meter is ~$11/day while running

Order matters. ArgoCD resurrects deleted resources, and ELBs created by Kubernetes
are invisible to Terraform and block VPC deletion.

```bash
export AWS_PROFILE=sonicloud            # if new terminal

# 1. Stop ArgoCD's auto-sync FIRST
kubectl delete -f argocd/sonicloud-app.yaml

# 2. Delete the app (removes the app ELB)
kubectl delete -f k8s/web.yaml -f k8s/api.yaml -f k8s/worker.yaml

# 3. Delete ArgoCD (removes its ELB)
kubectl delete namespace argocd

# 4. Tear down all infrastructure
cd infra && terraform destroy           # type yes

# 5. Verify zero
aws s3 ls | grep sonic-cloud            # expect: nothing
aws eks list-clusters                   # expect: empty list
```

Known slow spot: the Inspector enabler deactivates slowly (15m timeout configured).
If destroy ever times out on it — run `terraform destroy` again; it resumes where it stopped.

## Troubleshooting quick refs

| Symptom | Look at | Likely cause |
|---|---|---|
| Pod CrashLoopBackOff | `kubectl logs deployment/<x> -n sonicloud` | app error on startup |
| `NoCredentialsError` in pod | IMDS hop limit on nodes | must be 2 (launch template sets it) |
| Worker 404 downloading song | key encoding | S3 events URL-encode keys (`unquote_plus`) |
| Silent worker, then restart | `kubectl describe pod` → Last State | OOMKilled → raise memory / node size |
| Logs of a crashed container | `kubectl logs <pod> --previous` | dying words of the last incarnation |
| UI "Unexpected token '<'" | api pod logs | API returned HTML 500, read the traceback |
| kubectl "no such host" | kubeconfig | points at a destroyed cluster - rerun update-kubeconfig |
| Wall of errors | the FIRST error | everything after is usually cascade |

Full background and interview prep: see `STUDY_GUIDE.md`.
