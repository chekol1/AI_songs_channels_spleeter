# ---------------------------------------------------------------
# EKS cluster - public endpoint ("open to the outside") + node group
# ---------------------------------------------------------------

# --- Control plane IAM role ---
resource "aws_iam_role" "eks_cluster_role" {
  name = "sonicloud-eks-cluster-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- Cluster ---
resource "aws_eks_cluster" "main" {
  name     = "sonicloud-eks"
  role_arn = aws_iam_role.eks_cluster_role.arn

  # LOCAL-DEPLOY: access_config removed.
  # Floci does not persist authentication_mode, so terraform sees permanent
  # drift and every re-apply attempts UpdateClusterConfig -- an API Floci does
  # not route (the request falls through to its S3 handler and the provider
  # fails with: invalid character '<' looking for beginning of value).
  # That made re-running the installer impossible. The setting only matters for
  # EKS Access Entries, whose resources are also absent on this branch.
  # See the eks-showcase branch for the real-AWS version.

  vpc_config {
    subnet_ids              = [aws_subnet.public_a.id, aws_subnet.public_b.id]
    endpoint_public_access  = true # <-- the API server is reachable from the internet
    endpoint_private_access = true
  }

  depends_on = [aws_iam_role_policy_attachment.eks_cluster_policy]
}

# --- Worker node IAM role ---
resource "aws_iam_role" "eks_node_role" {
  name = "sonicloud-eks-node-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "node_ecr_policy" {
  role       = aws_iam_role.eks_node_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# S3 + SQS access for the app pods (api: presigned URLs, worker: queue + processing)
# (simple showcase approach: node role. Production: use IRSA per-pod roles.)
resource "aws_iam_role_policy" "node_s3_access" {
  name = "sonicloud-node-s3-access"
  role = aws_iam_role.eks_node_role.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject"]
        Resource = [
          "${aws_s3_bucket.music_storage.arn}/*",
          "${aws_s3_bucket.music_storage_results.arn}/*",
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [
          aws_s3_bucket.music_storage.arn,
          aws_s3_bucket.music_storage_results.arn,
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = [aws_sqs_queue.music_jobs_queue.arn]
      }
    ]
  })
}

# --- Launch template: IMDS hop limit 2 so pods can reach node credentials ---
resource "aws_launch_template" "eks_nodes" {
  name_prefix = "sonicloud-nodes-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # pod -> node -> IMDS needs 2 hops
  }
}

# --- Managed node group ---
resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "sonicloud-nodes"
  node_role_arn   = aws_iam_role.eks_node_role.arn
  subnet_ids      = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  instance_types  = ["t3.large"] # 8GB RAM - spleeter/TensorFlow OOM-killed on t3.medium (4GB)

  launch_template {
    id      = aws_launch_template.eks_nodes.id
    version = aws_launch_template.eks_nodes.latest_version
  }

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_ecr_policy,
  ]
}

output "eks_cluster_name" {
  value = aws_eks_cluster.main.name
}

output "eks_cluster_endpoint" {
  value = aws_eks_cluster.main.endpoint
}
