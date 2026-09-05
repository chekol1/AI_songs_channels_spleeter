# SoniCloud — מדריך פריסה: 3-Tier App על EKS + RDS + AWS Inspector

## ארכיטקטורה

```
Internet
   │
   ▼
[ELB — LoadBalancer Service]          ← נקודת כניסה ציבורית
   │
   ▼
┌─────────────── EKS (sonicloud-eks) ───────────────┐
│  Web tier (FE):  React + nginx   (Deployment x2)  │
│        │  proxy /api                               │
│        ▼                                           │
│  App tier (BE):  Flask API       (Deployment x2)  │
└────────┬───────────────────────────────┬──────────┘
         │ SQL (5432)                     │ presigned URLs
         ▼                                ▼
   RDS PostgreSQL                    S3 (upload + results)
   (sonicloud-db, פרטי)                   │
                                          ▼ S3 event → SQS
                                   Spleeter Worker (הקיים בריפו)
```

זרימת עבודה: המשתמש מעלה שיר ב-FE → ה-BE רושם job ב-RDS ומחזיר presigned URL → הדפדפן מעלה ל-S3 → S3 שולח הודעה ל-SQS → ה-worker הקיים מפצל עם Spleeter ומעלה ZIP ל-results bucket → ה-BE מזהה שהתוצאה מוכנה, מעדכן את הסטטוס ב-DB ונותן קישור הורדה.

## מבנה הקבצים החדשים

```
web/          ← Web tier: React (Vite) + nginx + Dockerfile
api/          ← App tier: Flask + Dockerfile
infra/        ← Terraform חדש: eks.tf, rds.tf, ecr_web_api.tf, inspector.tf, s3_cors.tf
infra/vpc.tf  ← ⚠️ מחליף את vpc.tf הקיים (subnet שני + תגיות ELB)
k8s/          ← מניפסטים: namespace, api, web
build_and_push.sh
```

העתיקו הכל לריפו `AI_songs_channels_spleeter` (שימו לב ש-`infra/vpc.tf` דורס את הקיים).

## דרישות מקדימות

- AWS CLI מחובר (`aws sts get-caller-identity`)
- Terraform ≥ 1.5, kubectl, docker

## שלב 1 — Terraform (EKS + RDS + ECR + Inspector)

```bash
cd infra
terraform init
terraform apply
```

⏱ יצירת EKS לוקחת ~10-15 דקות. בסיום תקבלו outputs: `eks_cluster_name`, `db_endpoint`, `web_repository_url`, `api_repository_url`.

💰 **עלות משוערת:** ‏EKS control plane ‏(~$0.10/שעה) + ‏2×t3.medium + RDS t3.micro + ELB ≈ ‏**$6-8 ליום**. הריצו `terraform destroy` בסיום ההדגמה.

## שלב 2 — חיבור kubectl לקלאסטר

```bash
aws eks update-kubeconfig --region us-east-1 --name sonicloud-eks
kubectl get nodes   # אמורים להופיע 2 nodes במצב Ready
```

## שלב 3 — בנייה ודחיפה של האימג'ים

```bash
cd ..
chmod +x build_and_push.sh
./build_and_push.sh
```

(בזכות `scan_on_push`, ‏Inspector יסרוק את האימג'ים מיד עם הדחיפה.)

## שלב 4 — Secret עם פרטי ה-DB

```bash
cd infra
DB_HOST=$(terraform output -raw db_endpoint)
DB_PASS=$(terraform output -raw db_password)
cd ..

kubectl apply -f k8s/namespace.yaml
kubectl create secret generic sonicloud-secrets \
  --namespace sonicloud \
  --from-literal=db_host="$DB_HOST" \
  --from-literal=db_password="$DB_PASS" \
  --from-literal=cognito_user_pool_id="$(terraform -chdir=infra output -raw cognito_user_pool_id)" \
  --from-literal=cognito_client_id="$(terraform -chdir=infra output -raw cognito_client_id)"
```

## שלב 5 — פריסת האפליקציה

החליפו את `<ACCOUNT_ID>` במניפסטים ופרסו:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" k8s/api.yaml k8s/web.yaml

kubectl apply -f k8s/api.yaml
kubectl apply -f k8s/web.yaml
kubectl get pods -n sonicloud -w   # להמתין ל-Running
```

## שלב 6 — כתובת ציבורית

```bash
kubectl get svc web-service -n sonicloud
# העמודה EXTERNAL-IP = כתובת ה-ELB (לוקח ~2-3 דקות)
```

פתחו בדפדפן: `http://<EXTERNAL-IP>` — העלו קובץ mp3, עקבו אחרי הסטטוס, והורידו את ה-stems כשה-job הופך ל-done.

> הערה: ודאו שה-worker הקיים (Fargate/ECS מהריפו) רץ — הוא זה שמבצע את הפיצול בפועל.

## שלב 7 — הדגמת AWS Inspector

1. קונסולת AWS → **Inspector** → Dashboard: סריקה פעילה על **EC2** (ה-nodes של EKS) ו-**ECR** (האימג'ים).
2. **Findings** → סינון לפי repository ‏(`sonicloud-web` / `sonicloud-api` / `sonicloud-worker`) — רשימת CVEs עם חומרה, קומפוננטה פגיעה וגרסת התיקון.
3. נקודות טובות להצגה:
   - Coverage: אילו resources מכוסים
   - Finding ספציפי: CVE, ‏severity score, ‏remediation
   - ECR → repository → image → "Vulnerabilities" — אותם ממצאים ברמת האימג'

## ניקוי

```bash
kubectl delete -f k8s/web.yaml -f k8s/api.yaml   # מוחק גם את ה-ELB (חשוב לפני destroy!)
cd infra && terraform destroy
```

## שיפורים אפשריים (לשיחת ראיון/הצגה)

- **IRSA** במקום הרשאות S3 על node role — הרשאות ברמת pod
- **private subnets + NAT** ל-nodes ול-RDS — כרגע הכל בפאבליק לצורך פשטות והוזלה
- **Ingress + ALB controller + TLS** במקום Service LoadBalancer
- **Secrets Manager + External Secrets** במקום kubectl create secret
- **CI/CD** (GitHub Actions) לבנייה, סריקה ופריסה אוטומטית
