output "cluster_id" {
  value = aws_eks_cluster.coffee.id
}

output "node_group_id" {
  value = aws_eks_node_group.coffee.id
}

output "vpc_id" {
  value = aws_vpc.coffee_vpc.id
}

output "subnet_ids" {
  value = aws_subnet.coffee_subnet[*].id
}
