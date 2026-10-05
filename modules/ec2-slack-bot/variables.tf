variable "name_prefix" {
  description = "Prefix for all resource names"
  type        = string
  default     = "ec2bot"
}

variable "managed_tag" {
  description = "Tag key marking instances the bot is allowed to control"
  type        = string
  default     = "SlackBotManaged"
}

variable "allowed_channels" {
  description = "Slack channel IDs allowed to run commands. Empty list disables the check."
  type        = list(string)
  default     = []
}

variable "alert_channel" {
  description = "Slack channel ID where CloudWatch alarms are posted"
  type        = string
}

variable "alert_email" {
  description = "Email subscribed to the alerts topic. Empty disables the subscription."
  type        = string
  default     = ""
}

variable "slack_secret_arn" {
  description = "ARN of an existing secret holding signing_secret and bot_token. Empty makes the module create an empty one."
  type        = string
  default     = ""
}

variable "reserved_concurrency" {
  description = "Reserved concurrent executions for the Lambda. null leaves it unreserved."
  type        = number
  default     = null
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days"
  type        = number
  default     = 14
}

variable "secret_recovery_days" {
  description = "Secrets Manager recovery window. Set to 0 for immediate deletion in sandbox environments."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Additional tags applied to all resources"
  type        = map(string)
  default     = {}
}