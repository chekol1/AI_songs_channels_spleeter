resource "aws_ecr_repository" "worker_app" {
  name                 = "sonicloud-worker"
  image_tag_mutability = "MUTABLE"

  # CRITICAL: This allows 'terraform destroy' to remove the repo even if it has images
  force_delete = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

# Lifecycle Policy: Keep only the 5 most recent images to save money
resource "aws_ecr_lifecycle_policy" "cleanup" {
  repository = aws_ecr_repository.worker_app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = {
        type = "expire"
      }
    }]
  })
}

output "repository_url" {
  value = aws_ecr_repository.worker_app.repository_url
}
