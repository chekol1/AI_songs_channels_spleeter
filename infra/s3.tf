data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "music_storage" {
  bucket = "sonic-cloud-music-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "Music Storage"
    Environment = "Dev"
  }
}

resource "aws_s3_bucket_public_access_block" "example" {
  bucket = aws_s3_bucket.music_storage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket_name" {
  value = aws_s3_bucket.music_storage.id
}

resource "aws_s3_bucket" "music_storage_results" {
  bucket = "sonic-cloud-music-results-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name        = "Music Storage Results"
    Environment = "Dev"
  }
}

resource "aws_s3_bucket_public_access_block" "example_results" {
  bucket = aws_s3_bucket.music_storage_results.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket_name_results" {
  value = aws_s3_bucket.music_storage_results.id
}
