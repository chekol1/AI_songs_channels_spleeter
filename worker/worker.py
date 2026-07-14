"""SoniCloud Spleeter worker - FIXED version of app/worker.py.

Fixes vs. the original:
  1. `import shutil` was missing (crash on zipping step)
  2. `if __name__ == "__main__"` was malformed
  3. Queue URL / bucket / region come from env vars instead of hardcoded values
  4. Guard against S3 "TestEvent" messages that have no 'Records' key
"""
import json
import os
import shutil
import subprocess
from urllib.parse import unquote_plus

import boto3

AWS_REGION = os.environ.get("AWS_REGION", "us-east-1")
QUEUE_URL = os.environ["QUEUE_URL"]
RESULT_BUCKET = os.environ["RESULT_BUCKET"]

sqs = boto3.client("sqs", region_name=AWS_REGION)
s3 = boto3.client("s3", region_name=AWS_REGION)


def process_song(input_bucket, key):
    song_name = os.path.splitext(key)[0]
    download_path = f"/tmp/{key}"
    output_base = "/tmp/output"
    zip_path = f"/tmp/{song_name}_stems"  # shutil adds .zip automatically

    try:
        print(f"Downloading {key}...")
        s3.download_file(input_bucket, key, download_path)

        print(f"AI splitting {key}...")
        subprocess.run(
            ["spleeter", "separate", "-p", "spleeter:2stems", "-o", output_base, download_path],
            check=True,
        )

        stem_folder = os.path.join(output_base, song_name)
        print("Zipping stems...")
        shutil.make_archive(zip_path, "zip", stem_folder)

        final_zip = f"{zip_path}.zip"
        print(f"Uploading to S3 Results: {RESULT_BUCKET}...")
        s3.upload_file(final_zip, RESULT_BUCKET, f"finished/{song_name}.zip")

    except Exception as e:
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
