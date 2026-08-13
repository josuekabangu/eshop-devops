variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "ec2_security_group_id" {
  description = "Security group of the EC2 instance allowed to reach RDS"
  type        = string
}

variable "db_name" {
  type    = string
  default = "eshopdb"
}

variable "db_username" {
  type    = string
  default = "postgres"
}

variable "db_password" {
  description = "RDS master password"
  type        = string
  sensitive   = true
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}
