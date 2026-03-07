
import boto3

import json

import os

import subprocess

sqs = boto3.client('sqs', region_name='us-east-1')

s3 = boto3.client('s3', region_name='us-east-1')



QUEUE_URL = "https://sqs.us-east-1.amazonaws.com/010686621615/music-jobs-queue"

RESULT_BUCKET = "sonic-cloud-music-results-010686621615"


def process_song(input_bucket, key):
    # 1. Setup paths
    song_name = os.path.splitext(key)[0]
    download_path = f"/tmp/{key}"
    output_base = "/tmp/output"
    zip_path = f"/tmp/{song_name}_stems" # shutil adds .zip automatically

    try:
        # 2. Download
        print(f"Downloading {key}...")
        s3.download_file(input_bucket, key, download_path)

        # 3. AI Processing
        print(f"AI splitting {key}...")
        subprocess.run(["spleeter", "separate", "-p", "spleeter:2stems", "-o", output_base, download_path], check=True)

        # 4. ZIP the results
        # This zips the folder /tmp/output/[song_name] into /tmp/[song_name]_stems.zip
        stem_folder = os.path.join(output_base, song_name)
        print(f"Zipping stems...")
        shutil.make_archive(zip_path, 'zip', stem_folder)

        # 5. UPLOAD to Results Bucket
        final_zip = f"{zip_path}.zip"
        print(f"Uploading to S3 Results: {RESULT_BUCKET}...")
        s3.upload_file(final_zip, RESULT_BUCKET, f"finished/{song_name}.zip")

    except Exception as e:
        print(f"Error during processing: {e}")
    
    finally:
        # 6. CLEANUP (The "Janitor" Phase)
        print("Cleaning up /tmp...")
        if os.path.exists(download_path): os.remove(download_path)
        if os.path.exists(f"{zip_path}.zip"): os.remove(f"{zip_path}.zip")
        if os.path.exists(output_base): shutil.rmtree(output_base)
        print("Done.")    



def listen():

    while True:

        response = sqs.receive_message(QueueUrl=QUEUE_URL, WaitTimeSeconds=20)

        if 'Messages' in response:

            for msg in response['Messages']:

                body = json.loads(msg['Body'])

                for record in body['Records']:

                    process_song(record['s3']['bucket']['name'], record['s3']['object']['key'])

                sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg['ReceiptHandle'])

if name == "main":

    listen()


