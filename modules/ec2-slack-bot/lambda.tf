data "archive_file" "bot" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/build/bot.zip"
}

resource "aws_cloudwatch_log_group" "bot" {
  name              = "/aws/lambda/${var.name_prefix}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "bot" {
  function_name    = var.name_prefix
  role             = aws_iam_role.lambda.arn
  handler          = "handler.handler"
  runtime          = "python3.13"
  architectures    = ["arm64"]
  filename         = data.archive_file.bot.output_path
  source_code_hash = data.archive_file.bot.output_base64sha256
  timeout          = 10
  memory_size      = 256
  tags             = var.tags

  reserved_concurrent_executions = var.reserved_concurrency

  environment {
    variables = {
      MANAGED_TAG        = var.managed_tag
      SLACK_SECRET_ARN   = local.secret_arn
      SCHEDULE_GROUP     = aws_scheduler_schedule_group.main.name
      SCHEDULER_ROLE_ARN = aws_iam_role.scheduler.arn
      ALLOWED_CHANNELS   = join(",", var.allowed_channels)
      ALERT_CHANNEL      = var.alert_channel
      DLQ_ARN            = aws_sqs_queue.dlq.arn
    }
  }

  logging_config {
    log_format            = "JSON"
    log_group             = aws_cloudwatch_log_group.bot.name
    application_log_level = "INFO"
    system_log_level      = "INFO"
  }

  depends_on = [aws_cloudwatch_log_group.bot]
}

resource "aws_lambda_function_url" "bot" {
  function_name      = aws_lambda_function.bot.function_name
  authorization_type = "NONE"
}

resource "aws_lambda_permission" "url" {
  statement_id           = "AllowPublicFunctionUrl"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.bot.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

resource "aws_scheduler_schedule_group" "main" {
  name = var.name_prefix
  tags = var.tags
}