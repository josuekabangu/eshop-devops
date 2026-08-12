variable "vpc_id" {
  description = "ID du VPC où déployer l'instance"
  type        = string
}

variable "subnet_id" {
  description = "ID du subnet public où déployer l'instance"
  type        = string
}

variable "instance_type" {
  description = "Type d'instance EC2"
  type        = string
  default     = "t3.small"
}

variable "my_ip" {
  description = "Ton IP publique, pour restreindre l'accès SSH"
  type        = string
}

variable "public_key_path" {
  description = "Chemin vers la clé publique SSH"
  type        = string
  default     = "~/.ssh/eshop-aws-key.pub"
}
