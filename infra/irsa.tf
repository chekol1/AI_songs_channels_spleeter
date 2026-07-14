# ---------------------------------------------------------------
# IRSA (IAM Roles for Service Accounts)
# Lets a specific K8s service account ("image-builder" in namespace
# "sonicloud") assume an IAM role with ECR push rights - WITHOUT
# giving those rights to every pod via the node role.
# ---------------------------------------------------------------

locals {
  oidc_issuer = replace(aws_eks_cluster.main.identity[0].oidc[0].issuer, "https://", "")
}

data "tls_certificate" "eks" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Registers the cluster's OIDC identity provider with IAM,
# so IAM can trust tokens that the cluster issues to service accounts.
resource "aws_iam_openid_connect_provider" "eks" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

# Role assumable ONLY by the sonicloud/image-builder service account
resource "aws_iam_role" "image_builder" {
  name = "sonicloud-image-builder"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.eks.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "${local.oidc_issuer}:sub" = "system:serviceaccount:sonicloud:image-builder"
          "${local.oidc_issuer}:aud" = "sts.amazonaws.com"
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "image_builder_ecr_push" {
  name = "ecr-push"
  role = aws_iam_role.image_builder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # GetAuthorizationToken is account-wide by design
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
          "ecr:PutImage"
        ]
        Resource = [
          aws_ecr_repository.worker_app.arn,
          aws_ecr_repository.app_tiers["sonicloud-web"].arn,
          aws_ecr_repository.app_tiers["sonicloud-api"].arn,
        ]
      }
    ]
  })
}

output "image_builder_role_arn" {
  value = aws_iam_role.image_builder.arn
}
