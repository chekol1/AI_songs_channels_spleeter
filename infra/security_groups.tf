# Security Group for the Fargate Worker
resource "aws_security_group" "fargate_worker_sg" {
  name        = "sonicloud-worker-sg"
  description = "Allows worker to talk to EFS and Internet"
  vpc_id      = aws_vpc.main.id

  # Allow all outbound traffic (S3, SQS, etc.)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
