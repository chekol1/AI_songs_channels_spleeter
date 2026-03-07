resource "aws_sqs_queue" "music_jobs_dlq" {
name = "music-jobs-dlq"
}

resource "aws_sqs_queue" "music_jobs_queue" {
name                      = "music-jobs-queue"
delay_seconds             = 0
message_retention_seconds = 86400 # 1 day
receive_wait_time_seconds = 10    # Long polling (saves money!)

redrive_policy = jsonencode({
deadLetterTargetArn = aws_sqs_queue.music_jobs_dlq.arn
maxReceiveCount     = 3 # Try 3 times before moving to DLQ
})

tags = {
Environment = "Dev"
Project     = "SoniCloud"
}
}

output "sqs_url" {
value = aws_sqs_queue.music_jobs_queue.id
}

output "sqs_arn" {
value = aws_sqs_queue.music_jobs_queue.arn
}


resource "aws_sqs_queue_policy" "allow_s3_logging" {

queue_url = aws_sqs_queue.music_jobs_queue.id

policy = jsonencode({

Version = "2012-10-17"

Statement = [

{

Effect    = "Allow"

Principal = { Service = "s3.amazonaws.com" }

Action    = "sqs:SendMessage"

Resource  = aws_sqs_queue.music_jobs_queue.arn

Condition = {

ArnLike = { "aws:SourceArn": aws_s3_bucket.music_storage.arn }

}

}

]

})

}
