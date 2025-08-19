# Example wiring (costs apply)
terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}
provider "aws" { region = var.region }

variable "region" {
  type    = string
  default = "us-east-1"
}
variable "project" {
  type    = string
  default = "tmw-paylite"
}

module "net" {
  source   = "../../modules/network"
  name     = "${var.project}-prod"
  cidr     = "10.40.0.0/16"
  az_count = 2
  region   = var.region
  tags     = { Project = var.project, Env = "prod-demo" }
}

module "ecr" {
  source = "../../modules/ecr_repos"
  prefix = "tmw"
  names  = ["payments-api", "risk-scorer"]
}

module "ecs_payments" {
  source            = "../../modules/ecs_fargate"
  name              = "${var.project}-payments"
  vpc_id            = module.net.vpc_id
  public_subnet_ids = module.net.public_subnet_ids
  image             = "${module.ecr.repo_urls["payments-api"]}:latest"
}

module "eks" {
  source            = "../../modules/eks_cluster"
  name              = "${var.project}-eks"
  vpc_id            = module.net.vpc_id
  public_subnet_ids = module.net.public_subnet_ids
  region            = var.region
}

output "alb_dns" { value = module.ecs_payments.alb_dns }
output "eks_cluster" { value = module.eks.cluster_name }
