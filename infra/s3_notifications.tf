resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.music_storage.id

  queue {
    queue_arn     = aws_sqs_queue.music_jobs_queue.arn
    events        = ["s3:ObjectCreated:*"]
    filter_suffix = ".mp3"
  }
  depends_on = [aws_sqs_queue_policy.allow_s3_logging]
}
