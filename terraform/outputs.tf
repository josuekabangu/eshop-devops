# Networking Output
output "vpc_id" {
    value = module.networking.vpc_id
}

output "public_subnet_ids" {
    value = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
    value = module.networking.private_subnet_ids
}

# EC2 Output
output "instance_public_ip" {
    value = module.ec2.public_ip
}

# RDS Output
output "db_endpoint" {
  value = module.rds.db_endpoint
}

output "db_name" {
  value = module.rds.db_name
}