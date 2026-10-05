resource "aws_sqs_queue" "dlq" {
  name                      = "${var.name_prefix}-dlq"
  message_retention_seconds = 1209600
  tags                      = var.tags
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.dlq.arn
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.me.account_id }
      }
    }]
  })
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  alarm_name          = "${var.name_prefix}-dlq-not-empty"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
  tags                = var.tags
}