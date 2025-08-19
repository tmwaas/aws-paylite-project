terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

# vars come from variables.tf:
# variable "region"  { type = string, default = "us-east-1" }
# variable "project" { type = string, default = "tmw-paylite" }

module "net" {
  source   = "../../modules/network"
  name     = var.project
  cidr     = "10.20.0.0/16"
  az_count = 2
  tags     = { Project = var.project, Env = "dev-free" }
}

resource "aws_security_group" "host_sg" {
  name   = "${var.project}-host"
  vpc_id = module.net.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Grafana (prefer SSM tunnel; open 3000 only if needed)
  ingress {
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Project = var.project, Env = "dev-free" }
}

# Canonical Ubuntu 24.04 LTS (Noble) amd64, HVM, EBS gp3 — region-aware
data "aws_ssm_parameter" "ubuntu_2404_amd64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

module "host" {
  source        = "../../modules/ec2_host"
  name          = "${var.project}-devfree"
  ami_id        = data.aws_ssm_parameter.ubuntu_2404_amd64.value
  subnet_id     = module.net.public_subnet_ids[0]
  sg_id         = aws_security_group.host_sg.id
  instance_type = "t2.micro"
  tags          = { Project = var.project, Env = "dev-free" }
}

output "ec2_instance_id" {
  value = module.host.instance_id
}

output "ec2_public_ip" {
  value = module.host.public_ip
}
