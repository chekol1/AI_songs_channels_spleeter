# ---------------------------------------------------------------
# RDS PostgreSQL - data tier (DB)
# Private (not internet-facing); only the EKS cluster can reach it.
# ---------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name       = "sonicloud-db-subnets"
  subnet_ids = [aws_subnet.public_a.id, aws_subnet.public_b.id]
  tags       = { Name = "sonicloud-db-subnets" }
}

resource "aws_security_group" "rds_sg" {
  name        = "sonicloud-rds-sg"
  description = "Allow Postgres only from EKS cluster"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from EKS nodes/pods"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_eks_cluster.main.vpc_config[0].cluster_security_group_id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "random_password" "db" {
  length  = 20
  special = false
}

resource "aws_db_instance" "main" {
  identifier        = "sonicloud-db"
  engine            = "postgres"
  engine_version    = "16"
  instance_class    = "db.t3.micro"
  allocated_storage = 20

  db_name  = "sonicloud"
  username = "appuser"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  publicly_accessible = false
  multi_az            = false
  skip_final_snapshot = true # showcase env - allows clean terraform destroy
}

output "db_endpoint" {
  value = aws_db_instance.main.address
}

output "db_password" {
  value     = random_password.db.result
  sensitive = true
}
