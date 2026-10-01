# Order flow for one environment:
#   checkout     --OrderCreated-------------------> bus --> inventory-q    --> inventoryservice
#   inventory    --InventoryReserved / Failed-----> bus --> order-status-q --> order-status Lambda
#   order-status --OrderStatusUpdated-------------> bus --> notification-q --> emailservice
# One queue per consumer, each with its own dead-letter queue (after 3 failed tries).

locals {
  flows = {
    "inventory" = {
      description = "OrderCreated from checkout, for inventoryservice"
      pattern     = { source = ["boutique.checkout"], "detail-type" = ["OrderCreated"] }
    }
    "order-status" = {
      description = "Inventory results, for the order-status Lambda"
      pattern     = { source = ["boutique.inventory"], "detail-type" = ["InventoryReserved", "InventoryFailed"] }
    }
    "notification" = {
      description = "Final order status, for emailservice"
      pattern     = { source = ["boutique.orderstatus"], "detail-type" = ["OrderStatusUpdated"] }
    }
  }
}

resource "aws_cloudwatch_event_bus" "retail" {
  name = "${var.name_prefix}-events"
}

resource "aws_sqs_queue" "dlq" {
  for_each = local.flows

  name                      = "${var.name_prefix}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "queue" {
  for_each = local.flows

  name                       = "${var.name_prefix}-${each.key}-q"
  visibility_timeout_seconds = 60 # longer than any consumer needs for one message
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20 # long polling
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = 3
  })
}

resource "aws_cloudwatch_event_rule" "flow" {
  for_each = local.flows

  name           = "${var.name_prefix}-${each.key}"
  description    = each.value.description
  event_bus_name = aws_cloudwatch_event_bus.retail.name
  event_pattern  = jsonencode(each.value.pattern)
}

resource "aws_cloudwatch_event_target" "flow" {
  for_each = local.flows

  rule           = aws_cloudwatch_event_rule.flow[each.key].name
  event_bus_name = aws_cloudwatch_event_bus.retail.name
  target_id      = "${each.key}-queue"
  arn            = aws_sqs_queue.queue[each.key].arn

  retry_policy {
    maximum_event_age_in_seconds = 3600
    maximum_retry_attempts       = 10
  }

  # If EventBridge cannot deliver to the queue at all, keep the event in the DLQ.
  dead_letter_config {
    arn = aws_sqs_queue.dlq[each.key].arn
  }
}

resource "aws_sqs_queue_policy" "queue" {
  for_each  = local.flows
  queue_url = aws_sqs_queue.queue[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowItsEventBridgeRule"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.queue[each.key].arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.flow[each.key].arn } }
    }]
  })
}

resource "aws_sqs_queue_policy" "dlq" {
  for_each  = local.flows
  queue_url = aws_sqs_queue.dlq[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowItsEventBridgeRule"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.dlq[each.key].arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_cloudwatch_event_rule.flow[each.key].arn } }
    }]
  })
}

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each = local.flows

  alarm_name          = "${var.name_prefix}-${each.key}-dlq-not-empty"
  alarm_description   = "Messages for the ${each.key} consumer are failing and landing in its dead-letter queue"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq[each.key].name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}

resource "aws_cloudwatch_metric_alarm" "queue_backlog" {
  for_each = local.flows

  alarm_name          = "${var.name_prefix}-${each.key}-backlog"
  alarm_description   = "The ${each.key} consumer is not keeping up (oldest message older than 5 minutes)"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions          = { QueueName = aws_sqs_queue.queue[each.key].name }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 300
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
}
