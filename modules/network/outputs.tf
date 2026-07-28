output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = [for az in local.availability_zones : aws_subnet.public[az].id]
}

output "data_subnet_ids" {
  value = [for az in local.availability_zones : aws_subnet.data[az].id]
}

output "availability_zones" {
  value = local.availability_zones
}
