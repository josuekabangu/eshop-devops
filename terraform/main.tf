terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

module "networking" {
    source = "./networking"
    
    vpc_cidr            = var.vpc_cidr
    public_subnet_cidrs = var.public_subnet_cidrs
    availability_zones  = var.availability_zones
}

module "ec2" {
    source = "./ec2"
    
    vpc_id        = module.networking.vpc_id
    subnet_id     = module.networking.public_subnet_ids[0]
    my_ip         = var.my_ip
    instance_type = var.instance_type        
}