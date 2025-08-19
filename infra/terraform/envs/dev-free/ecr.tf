data "aws_caller_identity" "current" {}

variable "ecr_prefix" {
  type    = string
  default = "tmw"
}

module "ecr" {
  source = "../../modules/ecr_repos"
  prefix = var.ecr_prefix
  names  = ["payments-api", "risk-scorer"]
}

output "ecr_repo_urls" { value = module.ecr.repo_urls }
