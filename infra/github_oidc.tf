# ---------------------------------------------------------------
# GitHub Actions OIDC federation - CI/CD with NO stored AWS keys.
# AWS trusts identity tokens that GitHub issues to workflow runs
# of this specific repo/branch. Least privilege: ECR push + EKS deploy.
# ---------------------------------------------------------------

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

resource "aws_iam_role" "github_actions" {
  name = "sonicloud-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # only workflows from THIS repo may assume the role
          "token.actions.githubusercontent.com:sub" = "repo:chekol1/AI_songs_channels_spleeter:*"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_permissions" {
  name = "ci-cd"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:DescribeRepositories"
        ]
        Resource = [
          aws_ecr_repository.worker_app.arn,
          aws_ecr_repository.app_tiers["sonicloud-web"].arn,
          aws_ecr_repository.app_tiers["sonicloud-api"].arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = aws_eks_cluster.main.arn
      }
    ]
  })
}

# Kubernetes-side access: let the CI role run kubectl (rollout restart)


# Cluster admin access for the human operator (the terraform/CLI user)


output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}

# ---------------------------------------------------------------------------
# REMOVED FOR THE LOCAL DEPLOYMENT
# aws_eks_access_entry x2 and aws_eks_access_policy_association x2 lived here.
# Floci does not route the EKS access-entry APIs at all -- CreateAccessEntry and
# AssociateAccessPolicy fall through to its S3 handler and return:
#   InvalidArgument: POST requires either ?uploads, ?uploadId, ?restore or
#   ?select parameter
# They are only meaningful against a real EKS control plane, so they are absent
# on this branch. See the eks-showcase branch for the real-AWS version.
# ---------------------------------------------------------------------------
