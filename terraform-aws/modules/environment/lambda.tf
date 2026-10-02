# order-status Lambda: order-status-q -> update the order in MySQL -> OrderStatusUpdated.
# It runs inside the VPC because the database is private.

data "archive_file" "order_status" {
  type        = "zip"
  source_dir  = var.lambda_source_dir
  output_path = "${path.root}/.build/order_status-${var.env}.zip"
  excludes    = ["test_app.py", "__pycache__"]
}

resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-order-status-lambda"
  description = "order-status Lambda: outbound only (MySQL, Secrets Manager, EventBridge)"
  vpc_id      = var.vpc_id

  egress {
    description = "MySQL inside the VPC, AWS APIs through the NAT gateway"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role" "order_status" {
  name = "${var.name_prefix}-order-status-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "order_status_vpc" {
  role       = aws_iam_role.order_status.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole" # logs + VPC network interfaces
}

resource "aws_iam_role_policy" "order_status" {
  name = "order-status"
  role = aws_iam_role.order_status.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsumeOrderStatusQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:ChangeMessageVisibility"]
        Resource = aws_sqs_queue.queue["order-status"].arn
      },
      {
        Sid      = "ReadDatabaseSecret"
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_db_instance.mysql.master_user_secret[0].secret_arn
      },
      {
        Sid      = "DecryptDatabaseSecret"
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.env.arn
      },
      {
        Sid      = "PublishOrderStatusUpdated"
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.retail.arn
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "order_status" {
  name              = "/aws/lambda/${var.name_prefix}-order-status"
  retention_in_days = 14
}

resource "aws_lambda_function" "order_status" {
  function_name    = "${var.name_prefix}-order-status"
  role             = aws_iam_role.order_status.arn
  runtime          = "python3.12"
  handler          = "app.handler"
  filename         = data.archive_file.order_status.output_path
  source_code_hash = data.archive_file.order_status.output_base64sha256
  timeout          = 30
  memory_size      = 256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST        = aws_db_instance.mysql.address
      DB_PORT        = tostring(aws_db_instance.mysql.port)
      DB_NAME        = aws_db_instance.mysql.db_name
      DB_SECRET_ARN  = aws_db_instance.mysql.master_user_secret[0].secret_arn
      EVENT_BUS_NAME = aws_cloudwatch_event_bus.retail.name
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.order_status,
    aws_iam_role_policy_attachment.order_status_vpc,
  ]
}

resource "aws_lambda_event_source_mapping" "order_status" {
  event_source_arn        = aws_sqs_queue.queue["order-status"].arn
  function_name           = aws_lambda_function.order_status.arn
  batch_size              = 10
  function_response_types = ["ReportBatchItemFailures"] # only failed messages are retried

  depends_on = [aws_iam_role_policy.order_status]
}

resource "aws_cloudwatch_metric_alarm" "order_status_errors" {
  alarm_name          = "${var.name_prefix}-order-status-lambda-errors"
  alarm_description   = "The order-status Lambda is throwing errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.order_status.function_name }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts.arn]
  ok_actions          = [aws_sns_topic.alerts.arn]
}
