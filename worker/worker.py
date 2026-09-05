"""SoniCloud Spleeter worker - FIXED version of app/worker.py.

Fixes vs. the original:
  1. `import shutil` was missing (crash on zipping step)
  2. `if __name__ == "__main__"` was malformed
  3. Queue URL / bucket / region come from env vars instead of hardcoded values
  4. Guard against S3 "TestEvent" messages that have no 'Records' key
"""
import datetime
import json
import os
import shutil
import subprocess
import time
from urllib.parse import unquote_plus

import boto3

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
QUEUE_URL = os.environ["QUEUE_URL"]
RESULT_BUCKET = os.environ["RESULT_BUCKET"]

sqs = boto3.client("sqs", region_name=AWS_REGION)
s3 = boto3.client("s3", region_name=AWS_REGION)

# --------------------------------------------------------------------------
# Progress reporting.
#
# The API cannot see inside this process, so the UI could only ever show
# "processing" for the whole run -- which on a full song is minutes of silence.
# Each stage is published as a small JSON object next to the results; the API
# reads it back. S3 is used because the worker already has S3 credentials and
# needs no new dependency, database access or network path.
#
# Status writes must never break a job, so every failure here is swallowed.
# --------------------------------------------------------------------------
STAGES = {
    "downloading": (15, "Downloading your song"),
    "separating":  (40, "AI is separating the stems"),
    "packaging":   (85, "Packaging the stems"),
    "uploading":   (92, "Uploading the result"),
    "done":        (100, "Finished"),
    "failed":      (0, "Failed"),
}


def set_stage(song_name, stage, detail=None, started_at=None):
    percent, label = STAGES.get(stage, (0, stage))
    body = {
        "song_name": song_name,
        "stage": stage,
        "label": label,
        "percent": percent,
        "detail": detail,
        "updated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    }
    if started_at is not None:
        body["elapsed_seconds"] = round(time.time() - started_at, 1)
    try:
        s3.put_object(
            Bucket=RESULT_BUCKET,
            Key=f"status/{song_name}.json",
            Body=json.dumps(body).encode(),
            ContentType="application/json",
        )
    except Exception as e:  # never let reporting fail the job
        print(f"(status write failed, continuing: {e})")
    print(f"[{stage}] {label}" + (f" - {detail}" if detail else ""))


def process_song(input_bucket, key):
    song_name = os.path.splitext(key)[0]
    download_path = f"/tmp/{key}"
    output_base = "/tmp/output"
    zip_path = f"/tmp/{song_name}_stems"  # shutil adds .zip automatically

    t0 = time.time()
    try:
        set_stage(song_name, "downloading", f"{key} from {input_bucket}", t0)
        s3.download_file(input_bucket, key, download_path)

        size_mb = round(os.path.getsize(download_path) / 1048576, 1)
        set_stage(song_name, "separating", f"{size_mb} MB - this is the slow step", t0)
        subprocess.run(
            ["spleeter", "separate", "-p", "spleeter:2stems", "-o", output_base, download_path],
            check=True,
        )

        stem_folder = os.path.join(output_base, song_name)
        set_stage(song_name, "packaging", "vocals + accompaniment", t0)
        shutil.make_archive(zip_path, "zip", stem_folder)

        final_zip = f"{zip_path}.zip"
        zip_mb = round(os.path.getsize(final_zip) / 1048576, 1)
        set_stage(song_name, "uploading", f"{zip_mb} MB to {RESULT_BUCKET}", t0)
        s3.upload_file(final_zip, RESULT_BUCKET, f"finished/{song_name}.zip")

        set_stage(song_name, "done", f"took {round(time.time() - t0)}s", t0)

    except Exception as e:
        set_stage(song_name, "failed", str(e)[:200], t0)
        print(f"Error during processing: {e}")
        raise  # let SQS retry / DLQ handle it

    finally:
        print("Cleaning up /tmp...")
        if os.path.exists(download_path):
            os.remove(download_path)
        if os.path.exists(f"{zip_path}.zip"):
            os.remove(f"{zip_path}.zip")
        if os.path.exists(output_base):
            shutil.rmtree(output_base)
        print("Done.")


def listen():
    print(f"Worker listening on {QUEUE_URL}")
    while True:
        response = sqs.receive_message(QueueUrl=QUEUE_URL, WaitTimeSeconds=20)
        for msg in response.get("Messages", []):
            body = json.loads(msg["Body"])
            try:
                for record in body.get("Records", []):  # skip S3 TestEvent
                    process_song(
                        record["s3"]["bucket"]["name"],
                        # S3 events URL-encode the key ("My Song.mp3" -> "My+Song.mp3")
                        unquote_plus(record["s3"]["object"]["key"]),
                    )
                sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
            except Exception as e:
                # don't delete -> message becomes visible again -> retry, then DLQ after 3
                print(f"Job failed, leaving message for retry: {e}")


if __name__ == "__main__":
    listen()
