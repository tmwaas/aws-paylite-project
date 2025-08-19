terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}
variable "prefix" { type = string }
variable "names"  { type = list(string) }

resource "aws_ecr_repository" "repos" {
  for_each             = toset(var.names)
  name                 = "${var.prefix}/${each.key}"
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration { encryption_type = "AES256" }
  force_delete         = true
}

output "repo_urls" {
  value = { for k, r in aws_ecr_repository.repos : k => r.repository_url }
}
