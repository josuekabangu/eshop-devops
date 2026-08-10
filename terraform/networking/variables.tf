variable "vpc_cidr" {
  type    = string
  default = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "availability_zones" {
  type    = list(string)
  default = ["eu-north-1a", "eu-north-1b"]
}

variable "private_subnet_cidrs" {
    description = "Private subnet CIDR range (for RDS)"
    type        = list(string)
    default     = ["10.0.11.0/24", "10.0.12.0/24"]
}