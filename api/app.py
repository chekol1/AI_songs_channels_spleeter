"""SoniCloud API - App tier (BE).

Endpoints:
  GET  /api/health              - liveness/readiness
  POST /api/jobs                - register a song job, returns presigned S3 upload URL
  GET  /api/jobs                - list jobs (auto-refreshes status from results bucket)
  GET  /api/jobs/<id>/download  - presigned URL for the finished stems zip
"""
import os
import time


import boto3
import psycopg2
from flask import Flask, jsonify, request

app = Flask(__name__)

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
UPLOAD_BUCKET = os.environ["UPLOAD_BUCKET"]          # sonic-cloud-music-<account_id>
RESULTS_BUCKET = os.environ["RESULTS_BUCKET"]        # sonic-cloud-music-results-<account_id>

DB_HOST = os.environ["DB_HOST"]
DB_NAME = os.environ.get("DB_NAME", "sonicloud")
DB_USER = os.environ.get("DB_USER", "appuser")
DB_PASSWORD = os.environ["DB_PASSWORD"]

s3 = boto3.client("s3", region_name=AWS_REGION)


def get_conn():
    return psycopg2.connect(
        host=DB_HOST, dbname=DB_NAME, user=DB_USER,
        password=DB_PASSWORD, connect_timeout=5,
    )


def init_db(retries=10, delay=5):
    """Create the jobs table, retrying while RDS/networking warms up."""
    for attempt in range(retries):
        try:
            with get_conn() as conn, conn.cursor() as cur:
                cur.execute("""
                    CREATE TABLE IF NOT EXISTS jobs (
                        id SERIAL PRIMARY KEY,
                        filename TEXT NOT NULL,
                        song_name TEXT NOT NULL,
                        status TEXT NOT NULL DEFAULT 'processing',
                        created_at TIMESTAMPTZ NOT NULL DEFAULT now()
                    )
                """)
            print("DB ready")
            return
        except Exception as e:
            print(f"DB init attempt {attempt + 1}/{retries} failed: {e}")
            time.sleep(delay)
    raise RuntimeError("Could not initialize database")


@app.get("/api/health")
def health():
    return jsonify(status="ok")


@app.post("/api/jobs")
def create_job():
    data = request.get_json(force=True)
    filename = data.get("filename", "").strip()
    if not filename or not filename.lower().endswith((".mp3", ".wav")):
        return jsonify(error="filename must end with .mp3 or .wav"), 400

    song_name = os.path.splitext(filename)[0]
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute(
            "INSERT INTO jobs (filename, song_name) VALUES (%s, %s) RETURNING id",
            (filename, song_name),
        )
        job_id = cur.fetchone()[0]

    upload_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": UPLOAD_BUCKET, "Key": filename, "ContentType": "audio/mpeg"},
        ExpiresIn=900,
    )
    return jsonify(id=job_id, upload_url=upload_url), 201


def _result_ready(song_name):
    try:
        s3.head_object(Bucket=RESULTS_BUCKET, Key=f"finished/{song_name}.zip")
        return True
    except Exception:
        return False


@app.get("/api/jobs")
def list_jobs():
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("SELECT id, filename, song_name, status, created_at FROM jobs ORDER BY id DESC")
        rows = cur.fetchall()

        jobs = []
        for job_id, filename, song_name, status, created_at in rows:
            if status == "processing" and _result_ready(song_name):
                cur.execute("UPDATE jobs SET status = 'done' WHERE id = %s", (job_id,))
                status = "done"
            jobs.append({
                "id": job_id, "filename": filename, "song_name": song_name,
                "status": status, "created_at": created_at.isoformat(),
            })
    return jsonify(jobs)


@app.get("/api/jobs/<int:job_id>/download")
def download(job_id):
    with get_conn() as conn, conn.cursor() as cur:
        cur.execute("SELECT song_name, status FROM jobs WHERE id = %s", (job_id,))
        row = cur.fetchone()
    if row is None:
        return jsonify(error="job not found"), 404
    song_name, status = row
    if status != "done":
        return jsonify(error="job not finished yet"), 409

    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": RESULTS_BUCKET, "Key": f"finished/{song_name}.zip"},
        ExpiresIn=900,
    )
    return jsonify(download_url=url)


init_db()

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
