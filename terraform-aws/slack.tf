# CloudWatch alarms -> SNS (one topic per environment) -> Slack, through
# Amazon Q Developer in chat applications (formerly AWS Chatbot).
#
# Off until you authorize your Slack workspace once in the AWS console and set the
# GitHub variables SLACK_TEAM_ID and SLACK_CHANNEL_ID (docs/week3/SLACK.md).
#
# The chat service's API isn't available in us-east-1, so its configuration is
# created in us-east-2 (Ohio). It still receives the alarms from us-east-1.

locals {
  slack_enabled = var.slack_team_id != "" && var.slack_channel_id != ""
}

provider "aws" {
  alias  = "chat"
  region = "us-east-2"

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}

# What the Slack integration may do in AWS: read CloudWatch, to show alarm details
# and graphs. Nothing else (no commands can change resources from Slack).
resource "aws_iam_role" "slack" {
  count = local.slack_enabled ? 1 : 0

  name = "${var.project}-slack-alerts"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "chatbot.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "slack" {
  count = local.slack_enabled ? 1 : 0

  role       = aws_iam_role.slack[0].name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"
}

resource "aws_chatbot_slack_channel_configuration" "alerts" {
  count    = local.slack_enabled ? 1 : 0
  provider = aws.chat

  configuration_name    = "${var.project}-alerts"
  iam_role_arn          = aws_iam_role.slack[0].arn
  slack_team_id         = var.slack_team_id
  slack_channel_id      = var.slack_channel_id
  sns_topic_arns        = [for env in module.env : env.settings.alerts_topic_arn]
  guardrail_policy_arns = ["arn:aws:iam::aws:policy/CloudWatchReadOnlyAccess"]
  logging_level         = "ERROR"
}
