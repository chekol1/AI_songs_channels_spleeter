# ---------------------------------------------------------------------------
# floci_override.tf  --  LOCAL-ONLY. Not part of the upstream repo.
#
# Terraform "_override.tf" files merge into and replace matching blocks from
# the other .tf files, so the repo's own provider block in main.tf is left
# untouched and the repo stays deployable to real AWS.
#
# Every service the repo's resources actually call needs an endpoint entry.
# ---------------------------------------------------------------------------

provider "aws" {
  region     = "us-east-1"
  access_key = "test"
  secret_key = "test"

  # Floci has no real IAM/STS/IMDS behind it.
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  skip_region_validation      = true
  s3_use_path_style           = true

  endpoints {
    s3  = "http://localhost:4566"  # music_storage + results buckets, CORS, notifications
    sqs = "http://localhost:4566"  # music-jobs-queue + DLQ + queue policy
    sts = "http://localhost:4566"  # data.aws_caller_identity
    iam = "http://localhost:4566"  # task/eks/node/github roles + OIDC provider
    ec2 = "http://localhost:4566"  # VPC, subnets, IGW, route tables, SGs, launch template
    ecr = "http://localhost:4566"  # 3 repos + lifecycle policies
    eks = "http://localhost:4566"  # cluster + node group
    rds = "http://localhost:4566"  # db subnet group + postgres instance
    efs = "http://localhost:4566"  # file system + mount target
  }
}

# ---------------------------------------------------------------------------
# LOCAL DEVIATION: Floci's EKS returns resourcesVpcConfig.clusterSecurityGroupId
# as null (verified: `aws eks describe-cluster` -> "sg": null). The repo's
# rds.tf feeds that value into the RDS security group's ingress rule, which
# would fail here. Replace the ingress with a VPC-CIDR rule so the config can
# apply locally.
#
# NOTE: this makes the RDS SG WEAKER than the repo's real intent. Floci does
# not enforce security groups at all, so neither version is actually enforced
# locally -- this exists purely to get a valid API call.
# ---------------------------------------------------------------------------
resource "aws_security_group" "rds_sg" {
  name        = "sonicloud-rds-sg"
  description = "LOCAL: Postgres from within VPC (Floci has no cluster SG)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "Postgres from inside the VPC (local stand-in for EKS cluster SG)"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
