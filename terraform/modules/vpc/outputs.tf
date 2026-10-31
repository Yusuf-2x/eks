output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr_block" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
  # Nodes in these subnets need their NAT route from the moment they launch
  # until they've drained on destroy.
  depends_on = [aws_route.private_nat, aws_route_table_association.private]
}

output "nat_public_ips" {
  description = "Outbound IPs your nodes use to reach the internet."
  value       = aws_eip.nat[*].public_ip
}
