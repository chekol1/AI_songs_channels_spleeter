# CORS on the upload bucket - the browser PUTs the song directly
# to S3 using a presigned URL, which is a cross-origin request.

resource "aws_s3_bucket_cors_configuration" "music_storage_cors" {
  bucket = aws_s3_bucket.music_storage.id

  cors_rule {
    allowed_methods = ["PUT"]
    allowed_origins = ["*"] # showcase; restrict to the LB URL in production
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}
