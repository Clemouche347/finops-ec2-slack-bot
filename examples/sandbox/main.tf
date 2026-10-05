terraform {
  required_version = ">= 1.11"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.0" }
  }
}

provider "aws" {
  region  = "eu-west-3"
  profile = "ec2bot-sandbox"
  max_retries = 3
  default_tags {
    tags = {
      Project   = "ec2-slack-bot"
      ManagedBy = "terraform"
      Owner     = "your-name"
    }
  }
}

data "aws_vpc" "default" { default = true }

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

resource "aws_security_group" "sandbox" {
  name        = "ec2bot-sandbox"
  description = "Sandbox instance, egress only"
  vpc_id      = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.sandbox.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "SSM agent"
}

resource "aws_iam_role" "ssm" {
  name = "ec2bot-sandbox-ssm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "ec2bot-sandbox-ssm"
  role = aws_iam_role.ssm.name
}

resource "aws_instance" "sandbox" {
  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = "t3.micro"
  subnet_id                   = data.aws_subnets.default.ids[0]
  vpc_security_group_ids      = [aws_security_group.sandbox.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm.name

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  tags = {
    Name            = "ec2bot-sandbox-1"
    SlackBotManaged = "true"
    Env             = "sandbox"
  }

  lifecycle {
    ignore_changes = [ami]
  }

  timeouts {
    create = "3m"
  }
}

output "instance_id" { value = aws_instance.sandbox.id }