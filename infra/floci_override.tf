# ---------------------------------------------------------------------------
# floci_override.tf  --  LOCAL-ONLY. Not part of the upstream repo.
#
# Terraform "_override.tf" files merge into and replace matching blocks from
# the other .tf files, so the repo's own provider block in main.tf is left
# untouched and the repo stays deployable to real AWS.
#
# Every service the repo's resources actually call needs an endpoint entry.
# ---------------------------------------------------------------------------

# Terraform's state lives in a bucket INSIDE Floci, the same way it lives in an
# S3 bucket on real AWS. Floci keeps the bucket on its volume, so the state
# survives a reboot and a deleted clone. deploy.sh creates the bucket.
terraform {
  backend "s3" {
    bucket = "sonicloud-tfstate"
    key    = "local/terraform.tfstate"
    region = "us-east-1"

    endpoints  = { s3 = "http://localhost:4566" }
    access_key = "test"
    secret_key = "test"

    use_path_style              = true
    use_lockfile                = true # lock file in the bucket; no DynamoDB table needed
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    skip_region_validation      = true
  }
}

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
    cognitoidp = "http://localhost:4566"  # user pool + client (tenant identity)
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

# ---------------------------------------------------------------------------
# LOCAL DEVIATION: Floci cannot change a repository's scan setting after it
# exists (PutImageScanningConfiguration is unsupported), and it has no image
# scanning anyway. This matters when deploy.sh adopts repositories that
# outlived Floci's data: they come back with scanning off, and Terraform would
# fail trying to switch it on. Ignore that one attribute locally.
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "worker_app" {
  lifecycle {
    ignore_changes = [image_scanning_configuration]
  }
}

resource "aws_ecr_repository" "app_tiers" {
  lifecycle {
    ignore_changes = [image_scanning_configuration]
  }
}
