# S3 -> SQS on upload.
#
# NOTE: one queue{} block per suffix. S3 filter rules do not accept a list of
# suffixes, and api/app.py accepts BOTH .mp3 and .wav -- with only the .mp3
# rule, a .wav upload succeeded but never emitted an event, so the job sat in
# "processing" forever with nothing to pick it up.
resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.music_storage.id

  queue {
    id            = "mp3-uploads"
    queue_arn     = aws_sqs_queue.music_jobs_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".mp3"
  }

  queue {
    id            = "wav-uploads"
    queue_arn     = aws_sqs_queue.music_jobs_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".wav"
  }

  depends_on = [aws_sqs_queue_policy.allow_s3_logging]
}
