terraform {
  required_version = ">= 1.11"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.7" }
  }
}

provider "aws" {
  region  = "eu-west-3"
  profile = "ec2bot-sandbox"
  default_tags {
    tags = {
      Project   = "ec2-slack-bot"
      ManagedBy = "terraform"
    }
  }
}

module "ec2_slack_bot" {
  source = "../../modules/ec2-slack-bot"

  allowed_channels     = ["C0XXXXXXXXX"]
  alert_channel        = "C0XXXXXXXXX"
  alert_email          = "ops@example.com"
  secret_recovery_days = 0
}

output "function_url" {
  value = module.ec2_slack_bot.function_url
}