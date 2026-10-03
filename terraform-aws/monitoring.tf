# Grafana (namespace "monitoring", installed by the deploy workflow) reads AWS metrics
# from CloudWatch: ALB requests / 5xx / latency, SQS queue depth and DLQs, RDS CPU,
# connections, storage and latency. Read-only, through EKS Pod Identity (no keys).
# Prometheus (same namespace) needs no AWS access: it scrapes the cluster itself.

resource "aws_iam_role" "grafana" {
  name               = "${var.project}-grafana-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
}

resource "aws_iam_role_policy" "grafana" {
  name = "cloudwatch-read"
  role = aws_iam_role.grafana.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:GetMetricData",
          "cloudwatch:GetMetricStatistics",
          "cloudwatch:ListMetrics",
          "cloudwatch:DescribeAlarms",
          "cloudwatch:DescribeAlarmsForMetric",
          "cloudwatch:DescribeAlarmHistory",
        ]
        Resource = "*" # CloudWatch metric reads can't be scoped to resources
      },
      {
        Sid      = "QueryEditorHelpers"
        Effect   = "Allow"
        Action   = ["ec2:DescribeRegions", "tag:GetResources"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_eks_pod_identity_association" "grafana" {
  cluster_name    = module.eks.cluster_name
  namespace       = "monitoring"
  service_account = "grafana"
  role_arn        = aws_iam_role.grafana.arn
}
