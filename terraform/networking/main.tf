# VPC (Le réseau global)
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name      = "eshop-vpc"
    Project   = "eshop-devops"
    ManagedBy = "terraform"
  }
}

# Internet Gateway (La port d'entrée/sortie vers Internet)
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags   = { 
    Name = "eshop-igw" 
  }
}

# Subnet Privé (Deux subnets publics, dans deux AZ différentes)
resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index]

  tags = { 
    Name = "eshop-private-${count.index + 1}" 
   }
}

# Subnet Public (Deux subnets publics, dans deux AZ différentes)
resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = { 
    Name = "eshop-public-${count.index + 1}" 
  }
}

# La table de routage qui rend ces subnets "publics"
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { 
    Name = "eshop-public-rt" 
  }
}

# Associe chaque subnet public à cette table de routage
resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

