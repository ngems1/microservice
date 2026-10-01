# AWS permissions for pods (EKS Pod Identity).
# Each role is linked to ONE service account in THIS environment's namespace, and
# every statement also requires the caller's namespace tag to match (ABAC), so a
# dev pod can never act on prod resources. Services not listed get no AWS access.

data "aws_iam_policy_document" "pod_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

locals {
  db_secret_arn = aws_db_instance.mysql.master_user_secret[0].secret_arn

  read_db_secret = [
    {
      Sid       = "ReadDatabaseSecret"
      Effect    = "Allow"
      Action    = "secretsmanager:GetSecretValue"
      Resource  = local.db_secret_arn
      Condition = local.this_namespace_only
    },
    {
      Sid       = "DecryptDatabaseSecret"
      Effect    = "Allow"
      Action    = "kms:Decrypt"
      Resource  = aws_kms_key.env.arn
      Condition = local.this_namespace_only
    },
  ]

  # Policies are stored as JSON strings so every map value has the same type.
  pod_roles = {
    # Order service: saves orders in MySQL, publishes OrderCreated.
    checkoutservice = jsonencode(concat(local.read_db_secret, [{
      Sid       = "PublishOrderCreated"
      Effect    = "Allow"
      Action    = "events:PutEvents"
      Resource  = aws_cloudwatch_event_bus.retail.arn
      Condition = local.this_namespace_only
    }]))

    # Product service: reads products from MySQL.
    productcatalogservice = jsonencode(local.read_db_secret)

    # Inventory service: stock in DynamoDB, consumes inventory-q, publishes results.
    inventoryservice = jsonencode([
      {
        Sid       = "InventoryTable"
        Effect    = "Allow"
        Action    = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:Scan", "dynamodb:ConditionCheckItem"]
        Resource  = aws_dynamodb_table.inventory.arn
        Condition = local.this_namespace_only
      },
      {
        Sid       = "ConsumeInventoryQueue"
        Effect    = "Allow"
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
        Resource  = aws_sqs_queue.queue["inventory"].arn
        Condition = local.this_namespace_only
      },
      {
        Sid       = "PublishInventoryResult"
        Effect    = "Allow"
        Action    = "events:PutEvents"
        Resource  = aws_cloudwatch_event_bus.retail.arn
        Condition = local.this_namespace_only
      },
    ])

    # Notification service: consumes notification-q, logs every message sent.
    emailservice = jsonencode([
      {
        Sid       = "ConsumeNotificationQueue"
        Effect    = "Allow"
        Action    = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
        Resource  = aws_sqs_queue.queue["notification"].arn
        Condition = local.this_namespace_only
      },
      {
        Sid       = "NotificationLog"
        Effect    = "Allow"
        Action    = ["dynamodb:GetItem", "dynamodb:PutItem"]
        Resource  = aws_dynamodb_table.notifications.arn
        Condition = local.this_namespace_only
      },
    ])
  }
}

resource "aws_iam_role" "pod" {
  for_each = local.pod_roles

  name               = "${var.name_prefix}-${each.key}"
  assume_role_policy = data.aws_iam_policy_document.pod_trust.json
}

resource "aws_iam_role_policy" "pod" {
  for_each = local.pod_roles

  name = "${each.key}-${var.env}"
  role = aws_iam_role.pod[each.key].id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = jsondecode(each.value)
  })
}

resource "aws_eks_pod_identity_association" "pod" {
  for_each = local.pod_roles

  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = each.key
  role_arn        = aws_iam_role.pod[each.key].arn
}
