resource "aws_iam_role" "lambda" {
  name = "${var.name_prefix}-lambda"
  tags = var.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda" {
  name = "${var.name_prefix}-lambda"
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DescribeNoResourceLevel"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid      = "StartStopTaggedOnly"
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "arn:aws:ec2:*:${data.aws_caller_identity.me.account_id}:instance/*"
        Condition = {
          StringEquals = { "aws:ResourceTag/${var.managed_tag}" = "true" }
        }
      },
      {
        Sid      = "DenyUntagged"
        Effect   = "Deny"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "*"
        Condition = {
          StringNotEquals = { "aws:ResourceTag/${var.managed_tag}" = "true" }
        }
      },
      {
        Sid    = "ManageOwnSchedules"
        Effect = "Allow"
        Action = [
          "scheduler:CreateSchedule",
          "scheduler:UpdateSchedule",
          "scheduler:DeleteSchedule",
          "scheduler:GetSchedule",
        ]
        Resource = "arn:aws:scheduler:${data.aws_region.current.region}:${data.aws_caller_identity.me.account_id}:schedule/${aws_scheduler_schedule_group.main.name}/*"
      },
      {
        Sid      = "PassSchedulerRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.scheduler.arn
        Condition = {
          StringEquals = { "iam:PassedToService" = "scheduler.amazonaws.com" }
        }
      },
      {
        Sid      = "ReadSlackSecret"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = local.secret_arn
      },
    ]
  })
}

resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-scheduler"
  tags = var.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "scheduler.amazonaws.com" }
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.me.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.name_prefix}-scheduler"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = [aws_lambda_function.bot.arn, "${aws_lambda_function.bot.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.dlq.arn
      },
    ]
  })
}