# Phase 5 tunnel test: one tiny WireGuard endpoint in AWS that the home server dials out to.
# No SSH, no inbound except WireGuard from home; commands run through SSM. Destroy after use.

data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

data "aws_availability_zones" "up" { state = "available" }

resource "aws_vpc" "this" {
  cidr_block           = "10.100.0.0/16" # clear of home LAN, k3s (10.42/10.43) and the tunnel (10.200.0.0/24)
  enable_dns_hostnames = true
  tags                 = { Name = "qwenops-tunnel" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "qwenops-tunnel" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.100.1.0/24"
  availability_zone       = data.aws_availability_zones.up.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "qwenops-tunnel-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "qwenops-tunnel-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "wg" {
  name        = "qwenops-tunnel-wg"
  description = "WireGuard from home only"
  vpc_id      = aws_vpc.this.id

  ingress {
    description = "WireGuard from the home server"
    protocol    = "udp"
    from_port   = 51820
    to_port     = 51820
    cidr_blocks = [var.home_cidr]
  }
  egress {
    description = "Packages and SSM over HTTPS"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Package mirrors over HTTP"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "WireGuard replies to home"
    protocol    = "udp"
    from_port   = 0
    to_port     = 65535
    cidr_blocks = [var.home_cidr]
  }
}

# SSM instead of SSH: no key pair, no port 22.
resource "aws_iam_role" "node" {
  name = "qwenops-tunnel-node"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "sts:AssumeRole", Principal = { Service = "ec2.amazonaws.com" } }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "node" {
  name = "qwenops-tunnel-node"
  role = aws_iam_role.node.name
}

resource "aws_instance" "wg" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = "t4g.nano"
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.wg.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    aws_private_key = var.aws_private_key
    home_public_key = var.home_public_key
    postgres_ca     = var.postgres_ca
  })

  tags = { Name = "qwenops-tunnel" }
}
