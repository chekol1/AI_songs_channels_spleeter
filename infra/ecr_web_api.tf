# ECR repos for the web tier (FE) and app tier (BE).
# scan_on_push feeds AWS Inspector's ECR scanning.

locals {
  app_repos = ["sonicloud-web", "sonicloud-api"]
}

resource "aws_ecr_repository" "app_tiers" {
  for_each             = toset(local.app_repos)
  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_ecr_lifecycle_policy" "app_tiers_cleanup" {
  for_each   = aws_ecr_repository.app_tiers
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 5 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 5
      }
      action = { type = "expire" }
    }]
  })
}

output "web_repository_url" {
  value = aws_ecr_repository.app_tiers["sonicloud-web"].repository_url
}

output "api_repository_url" {
  value = aws_ecr_repository.app_tiers["sonicloud-api"].repository_url
}
