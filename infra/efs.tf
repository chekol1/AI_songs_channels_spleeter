# 1. The actual File System
resource "aws_efs_file_system" "ai_models" {
  creation_token = "sonicloud-ai-models"
  encrypted      = true
  tags           = { Name = "SpleeterModels" }
}

# 2. Mount Target (Connected to your public_a subnet)
resource "aws_efs_mount_target" "mount_a" {
  file_system_id  = aws_efs_file_system.ai_models.id
  subnet_id       = aws_subnet.public_a.id
  security_groups = [aws_security_group.efs_sg.id]
}

# 3. Security Group for EFS (Allows the Worker to talk to Storage)
resource "aws_security_group" "efs_sg" {
  name        = "sonicloud-efs-sg"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.fargate_worker_sg.id]
  }
}
