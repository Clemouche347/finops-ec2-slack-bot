output "function_url" {
  description = "Lambda Function URL to paste into the Slack app manifest, as both the slash command URL and the interactivity request URL"
  value       = aws_lambda_function_url.bot.function_url
}

output "secret_arn" {
  description = "ARN of the Secrets Manager secret. Push a JSON value with signing_secret and bot_token before first use."
  value       = local.secret_arn
}

output "dlq_url" {
  description = "URL of the dead letter queue holding failed auto-stop invocations"
  value       = aws_sqs_queue.dlq.id
}

output "alerts_topic_arn" {
  description = "SNS topic receiving alarm notifications. Other CloudWatch alarms can be wired to it."
  value       = aws_sns_topic.alerts.arn
}