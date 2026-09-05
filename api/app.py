"""SoniCloud API - multi-tenant.

Every request that touches data is scoped to the tenant identified by a
verified Cognito ID token. Tenancy is enforced in two places that must agree:
  * SQL  - every query filters on tenant_id
  * S3   - every key lives under tenants/<tenant_id>/, and presigned URLs are
           only ever minted for keys the caller's tenant owns

NOTE ON THE EMULATOR: Floci does not enforce IAM or bucket policies, so the
isolation below is application-level only. On real AWS you would additionally
constrain the task role with an IAM prefix condition, so a bug here could not
reach another tenant's objects. That defence is NOT exercised locally.
"""
import json
import os
import time

import boto3
import psycopg2
import psycopg2.extras
from flask import Flask, g, jsonify, request

from auth import AuthError, verify_token
from billing import DEFAULT_PLAN, PLANS, plan_of, stems_allowed

app = Flask(__name__)

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
UPLOAD_BUCKET = os.environ["UPLOAD_BUCKET"]
RESULTS_BUCKET = os.environ["RESULTS_BUCKET"]

DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ.get("DB_PORT", "5432"))
DB_NAME = os.environ.get("DB_NAME", "sonicloud")
DB_USER = os.environ.get("DB_USER", "appuser")
DB_PASSWORD = os.environ["DB_PASSWORD"]

COGNITO_CLIENT_ID = os.environ["COGNITO_CLIENT_ID"]
COGNITO_USER_POOL_ID = os.environ["COGNITO_USER_POOL_ID"]

s3 = boto3.client("s3", region_name=AWS_REGION)
idp = boto3.client("cognito-idp", region_name=AWS_REGION)


def get_conn():
    return psycopg2.connect(
        host=DB_HOST, port=DB_PORT, dbname=DB_NAME, user=DB_USER,
        password=DB_PASSWORD, connect_timeout=5,
    )


def init_db(retries=10, delay=5):
    for attempt in range(retries):
        try:
            with get_conn() as conn, conn.cursor() as cur:
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS tenants (
                        id SERIAL PRIMARY KEY,
                        cognito_sub TEXT UNIQUE NOT NULL,
                        email TEXT NOT NULL,
                        plan TEXT NOT NULL DEFAULT 'free',
                        credits INTEGER NOT NULL DEFAULT 3,
                        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                    )
                """)
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS jobs (
                        id SERIAL PRIMARY KEY,
                        filename TEXT NOT NULL,
                        song_name TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'processing',
                        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                    )
                """)
                # Additive migration: the jobs table predates multi-tenancy.
                cur.execute("ALTER TABLE jobs ADD COLUMN IF NOT EXISTS tenant_id INTEGER")
                cur.execute("ALTER TABLE jobs ADD COLUMN IF NOT EXISTS stems INTEGER NOT NULL DEFAULT 2")
                cur.execute("CREATE INDEX IF NOT EXISTS jobs_tenant_idx ON jobs (tenant_id)")
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS mock_payments (
                        id SERIAL PRIMARY KEY,
                        tenant_id INTEGER NOT NULL,
                        plan TEXT NOT NULL,
                        amount_usd INTEGER NOT NULL,
                        credits_granted INTEGER NOT NULL,
                        note TEXT NOT NULL DEFAULT 'TEST MODE - simulated, no payment taken',
                        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                    )
                """)
            print("DB ready")
            return
        except Exception as e:
            print(f"DB init attempt {attempt + 1}/{retries} failed: {e}")
            time.sleep(delay)
    raise RuntimeError("Could not initialize database")


_db_ready = False


def ensure_db():
    """Initialise on first use, not at import: gunicorn imports this module, so
    a database that is not up yet would otherwise crash the container."""
    global _db_ready
    if not _db_ready:
        init_db()
        _db_ready = True


# --------------------------------------------------------------------------- auth
def current_tenant():
    """Resolve the caller to a tenant row, creating it on first sight."""
    if getattr(g, "tenant", None):
        return g.tenant
    claims = verify_token(request.headers.get("Authorization"))
    sub = claims["sub"]
    email = claims.get("email") or claims.get("cognito:username") or sub
    with get_conn() as conn, conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute("SELECT * FROM tenants WHERE cognito_sub = %s", (sub,))
        row = cur.fetchone()
        if row is None:
            cur.execute(
                "INSERT INTO tenants (cognito_sub, email, plan, credits) "
                "VALUES (%s, %s, %s, %s) RETURNING *",
                (sub, email, DEFAULT_PLAN, PLANS[DEFAULT_PLAN]["credits"]),
            )
            row = cur.fetchone()
    g.tenant = row
    return row


@app.errorhandler(AuthError)
def _auth_error(e):
    return jsonify(error=e.message), e.status


def tenant_prefix(tenant_id):
    return f"tenants/{tenant_id}"


# ------------------------------------------------------------------------- routes
@app.get("/api/health")
def health():
    return jsonify(status="ok")


@app.get("/api/config")
def config():
    """Public: what the browser needs to talk to Cognito."""
    return jsonify(
        user_pool_id=COGNITO_USER_POOL_ID,
        client_id=COGNITO_CLIENT_ID,
        plans=PLANS,
    )


@app.post("/api/auth/signup")
def signup():
    ensure_db()
    data = request.get_json(force=True)
    email, password = (data.get("email") or "").strip(), data.get("password") or ""
    if not email or not password:
        return jsonify(error="email and password are required"), 400
    try:
        idp.sign_up(ClientId=COGNITO_CLIENT_ID, Username=email, Password=password,
                    UserAttributes=[{"Name": "email", "Value": email}])
        # No email delivery in this environment, so confirm immediately.
        idp.admin_confirm_sign_up(UserPoolId=COGNITO_USER_POOL_ID, Username=email)
    except idp.exceptions.UsernameExistsException:
        return jsonify(error="that email is already registered"), 409
    except Exception as e:
        return jsonify(error=f"signup failed: {e}"), 400
    return jsonify(ok=True), 201


@app.post("/api/auth/login")
def login():
    ensure_db()
    data = request.get_json(force=True)
    email, password = (data.get("email") or "").strip(), data.get("password") or ""
    try:
        r = idp.initiate_auth(
            ClientId=COGNITO_CLIENT_ID, AuthFlow="USER_PASSWORD_AUTH",
            AuthParameters={"USERNAME": email, "PASSWORD": password},
        )
    except Exception:
        return jsonify(error="incorrect email or password"), 401
    res = r.get("AuthenticationResult", {})
    return jsonify(id_token=res.get("IdToken"), expires_in=res.get("ExpiresIn"))


@app.get("/api/me")
def me():
    ensure_db()
    t = current_tenant()
    return jsonify(
        tenant_id=t["id"], email=t["email"], plan=t["plan"], credits=t["credits"],
        plan_detail=plan_of(t["plan"]),
    )


@app.post("/api/billing/checkout")
def checkout():
    """SIMULATED purchase. No card details are accepted and no money moves."""
    ensure_db()
    t = current_tenant()
    plan_name = (request.get_json(force=True) or {}).get("plan")
    if plan_name not in PLANS:
        return jsonify(error=f"unknown plan; choose one of {list(PLANS)}"), 400
    p = PLANS[plan_name]
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "UPDATE tenants SET plan = %s, credits = credits + %s WHERE id = %s "
            "RETURNING credits",
            (plan_name, p["credits"], t["id"]),
        )
        credits = cur.fetchone()[0]
        cur.execute(
            "INSERT INTO mock_payments (tenant_id, plan, amount_usd, credits_granted) "
            "VALUES (%s, %s, %s, %s)",
            (t["id"], plan_name, p["price_usd"], p["credits"]),
        )
    return jsonify(ok=True, test_mode=True, plan=plan_name, credits=credits,
                   note="TEST MODE - simulated purchase, no payment was taken")


@app.post("/api/jobs")
def create_job():
    ensure_db()
    t = current_tenant()
    data = request.get_json(force=True)
    filename = (data.get("filename") or "").strip()
    stems = int(data.get("stems") or 2)

    if not filename or not filename.lower().endswith((".mp3", ".wav")):
        return jsonify(error="filename must end with .mp3 or .wav"), 400
    if stems not in (2, 4, 5):
        return jsonify(error="stems must be 2, 4 or 5"), 400
    if not stems_allowed(t["plan"], stems):
        return jsonify(error=f"the {t['plan']} plan does not include {stems}-stem separation",
                       upgrade_required=True), 402
    if t["credits"] <= 0:
        return jsonify(error="you have no credits left", upgrade_required=True), 402

    song_name = os.path.splitext(filename)[0]
    key = f"{tenant_prefix(t['id'])}/uploads/{stems}/{filename}"

    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO jobs (filename, song_name, tenant_id, stems) "
            "VALUES (%s, %s, %s, %s) RETURNING id",
            (filename, song_name, t["id"], stems),
        )
        job_id = cur.fetchone()[0]
        # A credit is spent on submission, so a queued job cannot be duplicated
        # for free by re-uploading before the first finishes.
        cur.execute("UPDATE tenants SET credits = credits - 1 WHERE id = %s RETURNING credits",
                    (t["id"],))
        credits = cur.fetchone()[0]

    upload_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": UPLOAD_BUCKET, "Key": key, "ContentType": "audio/mpeg"},
        ExpiresIn=900,
    )
    return jsonify(id=job_id, upload_url=upload_url, stems=stems, credits_left=credits), 201


def _read_stage(tenant_id, song_name):
    try:
        obj = s3.get_object(Bucket=RESULTS_BUCKET,
                            Key=f"{tenant_prefix(tenant_id)}/status/{song_name}.json")
        return json.loads(obj["Body"].read())
    except Exception:
        return None


def _result_key(tenant_id, song_name):
    return f"{tenant_prefix(tenant_id)}/finished/{song_name}.zip"


def _result_ready(tenant_id, song_name):
    try:
        s3.head_object(Bucket=RESULTS_BUCKET, Key=_result_key(tenant_id, song_name))
        return True
    except Exception:
        return False


@app.get("/api/jobs")
def list_jobs():
    ensure_db()
    t = current_tenant()
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "SELECT id, filename, song_name, status, created_at, stems FROM jobs "
            "WHERE tenant_id = %s ORDER BY id DESC",
            (t["id"],),
        )
        rows = cur.fetchall()

        jobs = []
        for job_id, filename, song_name, status, created_at, stems in rows:
            if status == "processing" and _result_ready(t["id"], song_name):
                cur.execute("UPDATE jobs SET status = 'done' WHERE id = %s", (job_id,))
                status = "done"

            st = _read_stage(t["id"], song_name)
            if status == "done":
                stage, label, percent = "done", "Finished", 100
                detail = st.get("detail") if st else None
                elapsed = st.get("elapsed_seconds") if st else None
            elif st:
                stage = st.get("stage", "processing")
                label = st.get("label", "Processing")
                percent = st.get("percent", 0)
                detail = st.get("detail")
                elapsed = st.get("elapsed_seconds")
            else:
                stage, label, percent, detail = "queued", "Waiting for a worker", 5, None
                elapsed = None

            jobs.append({
                "id": job_id, "filename": filename, "song_name": song_name,
                "status": status, "created_at": created_at.isoformat(), "stems": stems,
                "stage": stage, "stage_label": label,
                "percent": percent, "stage_detail": detail,
                "elapsed_seconds": elapsed,
            })
    return jsonify(jobs)


@app.get("/api/jobs/<int:job_id>/download")
def download(job_id):
    ensure_db()
    t = current_tenant()
    with get_conn() as conn, conn.cursor() as cur:
        # The tenant_id filter is the access check: another tenant's job id
        # simply does not exist as far as this caller is concerned.
        cur.execute("SELECT song_name, status FROM jobs WHERE id = %s AND tenant_id = %s",
                    (job_id, t["id"]))
        row = cur.fetchone()
    if row is None:
        return jsonify(error="job not found"), 404
    song_name, status = row
    if status != "done":
        return jsonify(error="job not finished yet"), 409

    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": RESULTS_BUCKET, "Key": _result_key(t["id"], song_name)},
        ExpiresIn=900,
    )
    return jsonify(download_url=url)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
