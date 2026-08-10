# Récupère automatiquement la dernière AMI Ubuntu 22.04 officielle
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical (éditeur officiel d'Ubuntu)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# Uploade ta clé publique vers AWS
resource "aws_key_pair" "main" {
  key_name   = "eshop-key"
  public_key = file(var.public_key_path)
}

# Le pare-feu virtuel de l'instance
resource "aws_security_group" "instance" {
  name        = "eshop-ec2-sg"
  description = "SSH restreint + HTTP ouvert"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH depuis mon IP uniquement"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.my_ip}/32"]
  }

  ingress {
    description = "HTTP ouvert (pour tester un futur serveur web)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Tout le trafic sortant autorise"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "eshop-ec2-sg" }
}

# L'instance elle-même
resource "aws_instance" "main" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [aws_security_group.instance.id]
  key_name               = aws_key_pair.main.key_name

  tags = {
    Name      = "eshop-ec2"
    Project   = "eshop-devops"
    ManagedBy = "terraform"
  }
}
