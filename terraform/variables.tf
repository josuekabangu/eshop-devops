# Networking Variables 
variable "aws_region" {
  description = "Région AWS cible"
  type        = string
  default     = "eu-north-1"
}

variable "vpc_cidr" {
  description = "Plage d'adresses IP du VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Plages IP des subnets publics"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "availability_zones" {
  description = "Zones de disponibilité utilisées"
  type        = list(string)
  default     = ["eu-north-1a", "eu-north-1b"]
}

# EC2 Variables
variable "my_ip" {
  description = "Mon IP publique pour restreindre SSH"
  type        = string
}

variable "instance_type" {
  description = "Type d'instance EC2"
  type        = string
  default     = "t3.small"
}

variable "private_subnet_cidrs" {
  type = list(string)
  default = ["10.0.11.0/24", "10.0.12.0/24"]
}