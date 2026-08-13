# Regroupe les subnets privés où RDS peut être placé
resource "aws_db_subnet_group" "main" {
  name       = "eshop-db-subnet-group"
  subnet_ids = var.private_subnet_ids

  tags = { Name = "eshop-db-subnet-group" }
}

# Pare-feu de la base — n'autorise QUE l'EC2, jamais Internet
resource "aws_security_group" "rds" {
  name        = "eshop-rds-sg"
  description = "Allow Postgres access from EC2 instance only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Postgres from EC2 instance"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [var.ec2_security_group_id]
  }

  egress {
    description = "All outbound traffic allowed"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "eshop-rds-sg" }
}

resource "aws_db_instance" "main" {
  identifier     = "eshop-db"
  engine         = "postgres"
  engine_version = "15"
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type       = "gp2"

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true

  tags = {
    Name      = "eshop-db"
    Project   = "eshop-devops"
    ManagedBy = "terraform"
  }
}
