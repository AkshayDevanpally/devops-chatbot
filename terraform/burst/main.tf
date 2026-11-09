# Phase 6 burst node: one AWS machine that joins the home k3s cluster as a worker over WireGuard.
# Home dials out (no port forward); k3s API, flannel VXLAN and image pulls all go through the tunnel.
# No SSH: commands through SSM. It terminates itself when idle or too old; `make burst-down` cleans up.

data "aws_ssm_parameter" "ubuntu" {
  # Ubuntu, not Amazon Linux: the pods require the k8s-chatbot AppArmor profile.
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

data "aws_availability_zones" "up" { state = "available" }

resource "aws_vpc" "this" {
  cidr_block           = "10.100.0.0/16" # clear of home LAN, k3s (10.42/10.43) and the tunnel (10.200.0.0/24)
  enable_dns_hostnames = true
  tags                 = { Name = "qwenops-burst" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "qwenops-burst" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.100.1.0/24"
  availability_zone       = data.aws_availability_zones.up.names[0]
  map_public_ip_on_launch = true
  tags                    = { Name = "qwenops-burst-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "qwenops-burst-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_security_group" "node" {
  name        = "qwenops-burst-node"
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
    description = "HTTPS: k3s install, container images, the model, SSM"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "Ubuntu package mirrors"
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

resource "aws_iam_role" "node" {
  name = "qwenops-burst-node"
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
  name = "qwenops-burst-node"
  role = aws_iam_role.node.name
}

resource "aws_instance" "node" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.node.id]
  iam_instance_profile   = aws_iam_instance_profile.node.name

  # "shutdown" from the idle and max-lifetime timers terminates the instance (stops billing).
  instance_initiated_shutdown_behavior = "terminate"

  dynamic "instance_market_options" {
    for_each = var.spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        spot_instance_type             = "one-time"
        instance_interruption_behavior = "terminate"
      }
    }
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1          # pods can't reach the instance's credentials
  }
  root_block_device {
    volume_type = "gp3"
    volume_size = 30 # Ollama image (~4 GB) + k3s images + model
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/user-data.sh.tftpl", {
    aws_private_key  = var.aws_private_key
    home_public_key  = var.home_public_key
    home_lan_ip      = var.home_lan_ip
    k3s_token        = var.k3s_token
    k3s_version      = var.k3s_version
    apparmor_profile = var.apparmor_profile
    idle_minutes     = var.idle_minutes
    idle_checks      = ceil(var.idle_minutes / 5)
    max_minutes      = var.max_hours * 60
  })

  tags = { Name = "qwenops-burst" }
}
