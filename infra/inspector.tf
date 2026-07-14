# ---------------------------------------------------------------
# AWS Inspector v2 - continuous vulnerability scanning
#   EC2 -> scans the EKS worker nodes
#   ECR -> scans the container images (web, api, worker)
# Uses data.aws_caller_identity.current defined in s3.tf
# ---------------------------------------------------------------

resource "aws_inspector2_enabler" "main" {
  account_ids    = [data.aws_caller_identity.current.account_id]
  resource_types = ["EC2", "ECR"]
}
