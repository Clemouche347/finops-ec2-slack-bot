data "aws_caller_identity" "me" {}
data "aws_region" "current" {}

resource "aws_secretsmanager_secret" "slack" {
  count                   = var.slack_secret_arn == "" ? 1 : 0
  name                    = "${var.name_prefix}/slack"
  description             = "signing_secret et bot_token de l'app Slack"
  recovery_window_in_days = var.secret_recovery_days
  tags                    = var.tags
}

locals {
  secret_arn = (
    var.slack_secret_arn != ""
    ? var.slack_secret_arn
    : aws_secretsmanager_secret.slack[0].arn
  )
}