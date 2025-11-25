terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
}

provider "aws" {
  region = "ap-south-1"
}

# ---------------------
# Variables (simple)
# ---------------------
variable "ssh_public_key_path" {
  description = "Path to your public SSH key to create key pair"
  type        = string
  default     = "~/.ssh/id_rsa.pub"
}

variable "ssh_key_name" {
  description = "Name for EC2 key pair"
  type        = string
  default     = "coffee"
}

# ---------------------
# VPC + networking
# ---------------------
resource "aws_vpc" "coffee_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "coffee-vpc"
  }
}

resource "aws_subnet" "coffee_subnet" {
  count = 2
  vpc_id                  = aws_vpc.coffee_vpc.id
  cidr_block              = cidrsubnet(aws_vpc.coffee_vpc.cidr_block, 8, count.index)
  availability_zone       = element(["ap-south-1a", "ap-south-1b"], count.index)
  map_public_ip_on_launch = true

  tags = {
    Name = "coffee-subnet-${count.index}"
  }
}

resource "aws_internet_gateway" "coffee_igw" {
  vpc_id = aws_vpc.coffee_vpc.id

  tags = {
    Name = "coffee-igw"
  }
}

resource "aws_route_table" "coffee_route_table" {
  vpc_id = aws_vpc.coffee_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.coffee_igw.id
  }

  tags = {
    Name = "coffee-route-table"
  }
}

resource "aws_route_table_association" "coffee_association" {
  count          = 2
  subnet_id      = aws_subnet.coffee_subnet[count.index].id
  route_table_id = aws_route_table.coffee_route_table.id
}

# ---------------------
# Security groups
# ---------------------
resource "aws_security_group" "coffee_cluster_sg" {
  vpc_id = aws_vpc.coffee_vpc.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "coffee-cluster-sg"
  }
}

resource "aws_security_group" "coffee_node_sg" {
  vpc_id = aws_vpc.coffee_vpc.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # allow all egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "coffee-node-sg"
  }
}

# ---------------------
# Key pair for NodeGroup SSH
# ---------------------
resource "aws_key_pair" "coffee" {
  key_name   = var.ssh_key_name
  public_key = file(var.ssh_public_key_path)
}

# ---------------------
# IAM roles
# ---------------------
# EKS Cluster Role
resource "aws_iam_role" "coffee_cluster_role" {
  name = "coffee-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "eks.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "coffee_cluster_role_policy" {
  role       = aws_iam_role.coffee_cluster_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# Node Group Role (EC2)
resource "aws_iam_role" "coffee_node_group_role" {
  name = "coffee-node-group-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "coffee_node_group_role_policy" {
  role       = aws_iam_role.coffee_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
}

resource "aws_iam_role_policy_attachment" "coffee_node_group_cni_policy" {
  role       = aws_iam_role.coffee_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

resource "aws_iam_role_policy_attachment" "coffee_node_group_registry_policy" {
  role       = aws_iam_role.coffee_node_group_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

# ---------------------
# EBS CSI Addon Role (for the addon)
# ---------------------
# NOTE: this role *is used by the addon* — the driver runs on nodes, so the role needs EC2 trust.
resource "aws_iam_role" "ebs_csi_role" {
  name = "EBS-CSI-Role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = { Service = "ec2.amazonaws.com" }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_role_policy" {
  role       = aws_iam_role.ebs_csi_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------------------
# EKS Cluster
# ---------------------
resource "aws_eks_cluster" "coffee" {
  name     = "coffee-cluster"
  role_arn = aws_iam_role.coffee_cluster_role.arn

  vpc_config {
    subnet_ids         = aws_subnet.coffee_subnet[*].id
    security_group_ids = [aws_security_group.coffee_cluster_sg.id]
  }

  # tags
  tags = {
    Name = "coffee-cluster"
  }
}

# ---------------------
# EKS Addon: AWS EBS CSI Driver
# ---------------------
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.coffee.name
  addon_name                  = "aws-ebs-csi-driver"

  addon_version               = null
  resolve_conflicts_on_update = "OVERWRITE"

  # attach the role we created for the driver
  service_account_role_arn    = aws_iam_role.ebs_csi_role.arn
}

# ---------------------
# EKS Node Group
# ---------------------
resource "aws_eks_node_group" "coffee" {
  cluster_name    = aws_eks_cluster.coffee.name
  node_group_name = "coffee-node-group"
  node_role_arn   = aws_iam_role.coffee_node_group_role.arn
  subnet_ids      = aws_subnet.coffee_subnet[*].id

  scaling_config {
    desired_size = 3
    max_size     = 3
    min_size     = 3
  }

  instance_types = ["t3.medium"]

  remote_access {
    ec2_ssh_key               = aws_key_pair.coffee.key_name
    source_security_group_ids = [aws_security_group.coffee_node_sg.id]
  }

  tags = {
    Name = "coffee-node-group"
  }
}

# ---------------------
# Outputs
# ---------------------
output "cluster_name" {
  value = aws_eks_cluster.coffee.name
}

output "cluster_endpoint" {
  value = aws_eks_cluster.coffee.endpoint
}

output "nodegroup_name" {
  value = aws_eks_node_group.coffee.node_group_name
}

output "key_pair_name" {
  value = aws_key_pair.coffee.key_name
}
