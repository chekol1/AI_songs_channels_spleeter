# 1. The "Task Role" - This is for your Python Code
resource "aws_iam_role" "ecs_task_role" {
  name = "sonicloud-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# 2. Permissions for S3 & SQS
resource "aws_iam_role_policy" "task_policy" {
  name = "sonicloud-task-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket"]
        Resource = [
          aws_s3_bucket.music_storage.arn,
          "${aws_s3_bucket.music_storage.arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${aws_s3_bucket.music_storage_results.arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.music_jobs_queue.arn]
      }
    ]
  })
}

# 3. Permissions for EFS (The AI Model storage)
resource "aws_iam_role_policy" "efs_policy" {
  name = "sonicloud-efs-policy"
  role = aws_iam_role.ecs_task_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "elasticfilesystem:ClientMount",
          "elasticfilesystem:ClientWrite",
          "elasticfilesystem:ClientRootAccess"
        ]
        Resource = aws_efs_file_system.ai_models.arn
      }
    ]
  })
}

output "task_role_arn" {
  value = aws_iam_role.ecs_task_role.arn
}
